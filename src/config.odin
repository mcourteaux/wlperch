// Configuration: ~/.config/wlwidgets/config.ini (written with defaults on first run).
package main

import "core:encoding/ini"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "wl"

Clock_Entry :: struct {
	tz:    string, // IANA name, "" = local
	label: string,
}

Config :: struct {
	// [popup]
	width:              i32,
	anchor:             u32,
	margin:             [4]i32,
	output:             string,
	close_on_click_outside: bool,
	max_height:         i32, // 0 = fit the output
	release_gpu_after:  time.Duration, // 0 = never

	// [weather]
	location:           string, // "auto", a place name, or "lat,lon"
	units:              string, // "metric" | "imperial"

	// [clocks]
	clocks:             [dynamic]Clock_Entry,
	clock_24h:          bool,

	// [network]
	public_ip_url:      string,
	ignore_interfaces:  [dynamic]string,

	// [nightlight]
	nightlight_cmd:     string,

	// [displays]
	preset_dirs:        [dynamic]string,
	preset_glob:        string,

	// [system]
	history_seconds:    int,
	memory_warn_pct:    int, // memory use (%) at which we draw attention
}

config: Config

DEFAULT_CONFIG :: `# wlwidgets configuration

[popup]
# Total popup width in logical pixels.
width = 860
# Any combination of: top bottom left right
anchor = top right
# Gap between the popup and the screen edges (top right bottom left).
margin = 4 0 0 0
# Connector to show on (e.g. DP-1). Empty = the focused output.
output =
close_on_click_outside = true
# Maximum popup height in logical pixels (0 = up to the output height). Scrolls when needed.
max_height = 0
# Seconds hidden before GPU memory is released (the daemon re-executes itself,
# ~40 MB instead of ~165 MB on NVIDIA). Next open then takes ~0.1 s longer. 0 = never.
release_gpu_after = 30

[weather]
# "auto" (IP geolocation), a place name ("Ghent"), or "lat,lon".
location = auto
# metric | imperial
units = metric

[clocks]
# Comma separated list of IANA zones; "Zone=Label" sets a label. "local" = system zone.
zones = local, UTC, America/New_York=New York, America/Los_Angeles=San Francisco, Asia/Tokyo=Tokyo
use_24h = true

[network]
public_ip_url = https://api.ipify.org
# Interface name prefixes to hide from the internal IP list.
ignore_interfaces = lo, docker, veth, br-, virbr, tailscale

[nightlight]
# {lat} and {lon} are replaced with the weather location's coordinates.
command = wlsunset -l {lat} -L {lon}

[displays]
# Directories scanned for display preset scripts (colon separated).
preset_dirs = ~/.local/bin:~/dotfiles/desktop/.local/bin
# Only scripts whose name matches this glob are considered.
preset_glob = *.sh

[system]
# Length of the CPU/GPU history graphs.
history_seconds = 120
# Memory use (%) at which the popup and the waybar button ("wlwidgets status") turn red.
memory_warn_percent = 90
`

config_path :: proc() -> string {
	base := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if base == "" {
		base = strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.config"}, context.temp_allocator)
	}
	return strings.concatenate({base, "/wlwidgets/config.ini"})
}

expand_home :: proc(path: string) -> string {
	if strings.has_prefix(path, "~/") {
		return strings.concatenate({os.get_env("HOME", context.temp_allocator), path[1:]})
	}
	return strings.clone(path)
}

@(private = "file")
split_list :: proc(s: string, sep: string) -> [dynamic]string {
	out: [dynamic]string
	for part in strings.split(s, sep, context.temp_allocator) {
		p := strings.trim_space(part)
		if p != "" {append(&out, strings.clone(p))}
	}
	return out
}

@(private = "file")
parse_bool :: proc(s: string, def: bool) -> bool {
	switch strings.to_lower(strings.trim_space(s), context.temp_allocator) {
	case "true", "yes", "1", "on":  return true
	case "false", "no", "0", "off": return false
	}
	return def
}

config_load :: proc() {
	path := config_path()
	if !os.exists(path) {
		dir := path[:strings.last_index_byte(path, '/')]
		os.make_directory_all(dir)
		if err := os.write_entire_file(path, DEFAULT_CONFIG); err != nil {
			log.warnf("could not write default config to %s: %v", path, err)
		} else {
			log.infof("wrote default config to %s", path)
		}
	}

	defaults, _ := ini.load_map_from_string(DEFAULT_CONFIG, context.allocator)
	m, _, ok := ini.load_map_from_path(path, context.allocator)
	if !ok {
		log.warnf("could not read %s, using defaults", path)
		m = defaults
	}
	get :: proc(m, d: ini.Map, section, key: string) -> string {
		if s, ok := m[section]; ok {
			if v, vok := s[key]; vok {return unquote(strings.trim_space(v))}
		}
		return unquote(strings.trim_space(d[section][key]))
	}

	c := &config
	c.width = i32(strconv.parse_int(get(m, defaults, "popup", "width")) or_else 860)
	c.width = clamp(c.width, 480, 2000)
	c.anchor = 0
	for a in strings.fields(get(m, defaults, "popup", "anchor"), context.temp_allocator) {
		switch a {
		case "top":    c.anchor |= wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP
		case "bottom": c.anchor |= wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM
		case "left":   c.anchor |= wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT
		case "right":  c.anchor |= wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT
		}
	}
	for f, i in strings.fields(get(m, defaults, "popup", "margin"), context.temp_allocator) {
		if i < 4 {c.margin[i] = i32(strconv.parse_int(f) or_else 0)}
	}
	c.output = strings.clone(get(m, defaults, "popup", "output"))
	c.close_on_click_outside = parse_bool(get(m, defaults, "popup", "close_on_click_outside"), true)
	c.max_height = i32(strconv.parse_int(get(m, defaults, "popup", "max_height")) or_else 0)
	c.release_gpu_after = time.Duration(max(strconv.parse_int(get(m, defaults, "popup", "release_gpu_after")) or_else 30, 0)) * time.Second

	c.location = strings.clone(get(m, defaults, "weather", "location"))
	c.units = strings.clone(get(m, defaults, "weather", "units"))

	for z in strings.split(get(m, defaults, "clocks", "zones"), ",", context.temp_allocator) {
		z := strings.trim_space(z)
		if z == "" {continue}
		e: Clock_Entry
		if eq := strings.index_byte(z, '='); eq >= 0 {
			e.tz = strings.clone(strings.trim_space(z[:eq]))
			e.label = strings.clone(strings.trim_space(z[eq + 1:]))
		} else {
			e.tz = strings.clone(z)
		}
		if strings.to_lower(e.tz, context.temp_allocator) == "local" {e.tz = ""}
		append(&c.clocks, e)
	}
	c.clock_24h = parse_bool(get(m, defaults, "clocks", "use_24h"), true)

	c.public_ip_url = strings.clone(get(m, defaults, "network", "public_ip_url"))
	c.ignore_interfaces = split_list(get(m, defaults, "network", "ignore_interfaces"), ",")

	c.nightlight_cmd = strings.clone(get(m, defaults, "nightlight", "command"))

	for d in split_list(get(m, defaults, "displays", "preset_dirs"), ":") {
		append(&c.preset_dirs, expand_home(d))
	}
	c.preset_glob = strings.clone(get(m, defaults, "displays", "preset_glob"))

	c.history_seconds = clamp(strconv.parse_int(get(m, defaults, "system", "history_seconds")) or_else 120, 30, 600)
	c.memory_warn_pct = clamp(strconv.parse_int(get(m, defaults, "system", "memory_warn_percent")) or_else 90, 1, 100)
}

// `location = "Ghent, Belgium"` -> Ghent, Belgium
unquote :: proc(s: string) -> string {
	if len(s) >= 2 && ((s[0] == '"' && s[len(s) - 1] == '"') || (s[0] == '\'' && s[len(s) - 1] == '\'')) {
		return s[1:len(s) - 1]
	}
	return s
}

popup_size :: proc() -> (w, h: i32) {
	return config.width, last_content_height > 0 ? last_content_height : 600
}

popup_placement :: proc() -> Popup_Placement {
	return {
		anchor = config.anchor,
		margin = config.margin,
		layer = wl.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
		output = config.output,
		backdrop = config.close_on_click_outside,
	}
}
