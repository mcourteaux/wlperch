// Configuration: ~/.config/wlperch/config.ini (written with defaults on first run).
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

	// [system]
	history_seconds:    int,

	// [sensors]
	sensors_dir:        string,
	sensors_watch:      string,
	sensors_bar_room:   string, // room shown by "wlperch status sensors"
	memory_warn_pct:    int, // memory use (%) at which we draw attention

	// [memory]
	memory_free_warn_pct: int, // low-memory card when available memory (%) drops below this; 0 = off
	memory_bar_warn_pct:  int, // bar memory module orange + pulsing from this use (%)

	// [notifications]
	notifications:      bool, // serve org.freedesktop.Notifications

	// [github]
	github:             bool,
	github_repo:        string, // owner/name, optional
	github_refresh:     time.Duration,

	// [lock]
	lock_pam_service:   string, // "" = swaylock's PAM file when present, else login
	lock_background:    u32,    // 0xRRGGBB
	lock_image:         string,
	lock_mode:          Lock_Bg_Mode,
	lock_screenshot_blur: int, // 0..100, see LOCK_BLUR_MIN_SIGMA
	lock_blur_animate_ms:   int, // 0 = off; see lock_blur_anim.odin
	lock_blur_animate_from: int, // % of the final blur the animation starts at
	lock_blur:          int,
	lock_dim:           f32,
	lock_notifications: bool,
	lock_media:         bool,
	lock_bluetooth:     bool,

	lock_background_light: u32, // used instead with the light theme (no image)
	lock_countdown_seconds: int, // overlay before the idle lock; 0 = off (idle_countdown.odin)
	lock_idle_seconds:      int, // > 0: wlperch itself locks after this much idle time

	// [launcher]
	launcher_terminal:  string, // prefix for Terminal=true apps; "" = detect

	// [theme], [theme.dark], [theme.light]
	theme_links:        [dynamic]string,
	theme_nvim_file:    string,
	theme_targets:      [Theme_Mode]Theme_Targets,
}

config: Config

DEFAULT_CONFIG :: `# wlperch configuration

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

# Display presets: one [display.<name>] section each, switched from the
# Displays card or with "wlperch display <name>" (list / next / prev / save).
# Every key is an output, its value sway's output settings: a mode, pos X Y,
# scale and transform, or "off". A new config starts with the layout found
# on the first run (and, with several monitors, each monitor on its own).
# The active preset is also written to ~/.config/sway/config.d/wlperch-displays.conf
# so sway starts with it.
#
# [display.desk]
# name = Desk                                 ; optional label
# DP-3 = 3440x1440 pos 0 0
# DP-1 = 2560x1440 pos 3440 0 transform 90
# HDMI-A-1 = off
# workspaces = DP-1: 1 2 3, DP-3: 4 5 6       ; optional: where these workspaces live
# run = pactl set-card-profile …              ; optional: run after switching

[system]
# Length of the CPU/GPU history graphs.
history_seconds = 120

[memory]
# Low-memory warning: a card at the top of the screen with the biggest memory
# users (SIGTERM / SIGKILL buttons) once available memory (MemAvailable) drops
# below this percentage of RAM. Shows under do not disturb. 0 = off.
warn_free_percent = 15
# The bar's memory module turns orange and slowly pulses from this memory use (%).
bar_warn_percent = 75
# Memory use (%) at which the bar's memory module, the wlperch button (also
# "wlperch status" for waybar) and the panel's memory card turn red.
critical_percent = 90

[notifications]
# Show desktop notifications (popups + the notification center) instead of
# dunst/mako. Only one program can do this: wlperch takes over as soon as the
# other one stops ("wlperch setup" can switch dunst off for you).
enabled = true

[github]
# GitHub at a glance through the gh command line tool (log in once with
# "gh auth login"): review requests, your pull requests with their checks,
# assigned issues and unread notifications, like "gh status". Read-only.
enabled = false
# Optional repository (owner/name) to follow as well: its default branch's
# checks, recent workflow runs, open pull requests / issues and latest release.
repo =
# Minutes between refreshes (opening the panel also refreshes stale data).
refresh_minutes = 5

[lock]
# The lock screen ("wlperch lock"): clock, date, unread notification count,
# what's playing and the battery. Wire it to swayidle / a key with
# "wlperch setup" or see contrib/sway/wlperch.conf.
# PAM service used to check the password. Empty = "swaylock" when
# /etc/pam.d/swaylock exists, else "login".
pam_service =
# What's behind the clock: color (the colour below), image (the picture
# below) or blur (a frosted-glass copy of the screen as it was when it
# locked; it is captured in memory only, never written to disk). Empty =
# image when one is set, else color.
background_mode =
# Background colour, and optionally a picture (PNG/JPEG) drawn over it,
# blurred by this much (0 = sharp) and darkened by dim (0..1).
background = #14161b
# Background with the light theme (when no picture is set).
background_light = #e9ebf0
image =
blur = 0
dim = 0.35
# How strongly the screenshot is blurred with background_mode = blur
# (0..100). Even 0 blurs by a ~20 px radius so no text stays readable.
screenshot_blur = 60
# background_mode = blur only: grow the blur over this many milliseconds
# after locking (0 = off, at most 3000), starting at blur_animate_from
# percent of it (0 = sharp). Opt-in: until it has grown, the screen as it
# was stays readable for a moment. Never animates when locked with -f
# (swayidle's timeout and before-sleep).
blur_animate_ms = 0
blur_animate_from = 10
# Show the unread notification count (and which apps) / the playing track /
# connected Bluetooth devices with their battery (needs the daemon).
# Notification text is never shown on the lock screen.
show_notifications = true
show_media = true
show_bluetooth = true
# Countdown before the screen locks for inactivity: the screen dims from
# its edges and a ring counts down; any key or mouse move cancels it (and
# goes to your app as usual). 0 = off. It follows the lock timeout of
# swayidle (e.g. "timeout 300 'wlperch lock -f'": shown from 285 s) and,
# like that lock, waits while an idle inhibitor (a playing video) is active.
countdown_seconds = 15
# 0 = swayidle locks on idle (nothing to change in its config). A number of
# seconds: wlperch locks by itself after that much idle time, with the
# countdown before it; for setups without an idle lock in swayidle. Needs
# the daemon running; a swayidle lock that comes earlier still wins.
idle_lock_seconds = 0

[launcher]
# The app launcher: "wlperch toggle launch --center" (apps, calculator,
# panels) and "wlperch toggle run --center" (commands); bind them in sway
# or let "wlperch setup" switch rofi/wofi over.
# Terminal for apps that need one, with the option that runs a command
# (e.g. "alacritty -e"). Empty = $TERMINAL, sway's $term or the first known
# terminal installed.
terminal =

[theme]
# Dark / light: "wlperch theme dark|light|toggle" or the quick settings tile.
# Switches wlperch itself and the rest of the desktop as far as set up here.
# GTK / libadwaita / portal apps follow the gsettings color-scheme, which is
# always switched (plus gtk-application-prefer-dark-theme in an existing
# gtk-3.0/gtk-4.0 settings.ini).
# Symlinks to swap between a "dark" and a "light" twin: colors.css ->
# waybar-dark.css becomes waybar-light.css when that file exists. Waybar
# reloads when one of its files changed.
links = ~/.config/waybar/colors.css, ~/.config/wofi/colors.css
# Written for nvim ("set background" + "colorscheme") when nvim_colorscheme is
# set below; have nvim source it (and watch it, to switch running editors).
nvim_file = ~/.vimrc.color

# Per mode. Empty = leave alone. gtk_theme "auto" switches Adwaita <->
# Adwaita-dark only while one of those is in use.
# kitty_theme: a theme name from "kitty +kitten themes" (all kitty windows).
# wallpaper: an image for sway's outputs. command: anything else (sh -c).
# sway_colors: auto = sway's window decorations (titlebars, borders) in
# wlperch's palette for the mode, re-applied after "swaymsg reload"; off =
# leave sway's client.* colours alone. One class can be overridden with
# sway_client_<class> = border background text [indicator child_border]
# (classes: focused, focused_inactive, focused_tab_title, unfocused, urgent,
# placeholder; background takes one colour), e.g.
#   sway_client_focused = #4a5b85 #232836 #e4e7ee #7d9c5a #4a5b85
[theme.dark]
gtk_theme = auto
icon_theme =
kitty_theme =
wallpaper =
nvim_colorscheme =
kvantum_theme =
vscode_theme =
command =
sway_colors = auto

[theme.light]
gtk_theme = auto
icon_theme =
kitty_theme =
wallpaper =
nvim_colorscheme =
kvantum_theme =
vscode_theme =
command =
sway_colors = auto

[bar]
# wlperch's own bar ("wlperch bar"), a waybar replacement: run it from sway
# with  bar { swaybar_command wlperch-bar }  ("wlperch setup" can switch).
# top | bottom
position = top
height = 34
# Connector names (e.g. DP-1 HDMI-A-1) to show the bar on; empty = all.
outputs =
# Modules per side, in order. Available: workspaces mode scratchpad window
# idle power-profile backlight battery media audio timer sensors memory clock
# tray notifications wlperch
left = workspaces mode scratchpad window
center =
right = idle power-profile backlight battery media audio timer sensors memory clock tray notifications wlperch
# strftime-like: %a %A %b %B %d %e %m %Y %H %I %M %S %p; <b>…</b> is bold.
clock_format = %a %d %b  <b>%H:%M</b>
# Tray icon size (logical pixels).
tray_icon_size = 20
# Volume change per scroll step of the audio module, in percent (never above 100 %).
volume_step = 5

[timetracker]
# Seconds without input after which you're on a break: counting pauses and the
# break is logged from your last input. Independent of the screen lock (that's
# swayidle's timeout); idle inhibitors (fullscreen video, the bar's idle
# button) count as presence. The old idle_minutes is still honoured.
idle_seconds = 300

# Projects for time tracking. "wlperch track <project>" (or the Time panel)
# creates one workspace per monitor ("<name> 1", "<name> 2", ...); time counts
# while one of them is focused. Numbered workspaces are not counted.
#
# [project.acme]
# name = ACME
# client = ACME Corp      ; omit for personal projects
# color = #7aa2f7         ; optional

[sensors]
# Tuya WiFi sensors (thermo-hygrometers, air monitors, heaters), read over the
# LAN. Off until devices are defined: a directory with a tinytuya devices.json
# (ids, local keys, data point mappings), and/or [sensor.<name>] sections.
dir =
# Room whose temperature "wlperch status sensors" shows in the bar (empty = first).
bar_room =

# [sensor.kitchen]
# id = bf0123456789abcdefghij     ; Tuya device id
# key = 0123456789abcdef          ; its local key (keep this file private: chmod 600)
# kind = room                     ; room | air | heater: picks a built-in data point layout
# ip =                            ; optional: learned from the device's broadcasts
# version =                       ; optional (3.3 / 3.4 / 3.5): idem
# dp1 = va_temperature 1 ℃        ; optional data points: code, decimals, unit

# ---- Panels -------------------------------------------------------------
# "wlperch toggle <name>" opens a panel; the first one is the default.
# columns: module names per column, columns separated by "|".
# Modules: quick audio network weather clocks displays bluetooth storage
#          cpu gpu memory processes thermals sensors time notifications media
#          calculator launcher
#          github github-repo github-inbox (need [github] enabled = true)
# quick = night light, do not disturb, Bluetooth, project toggles, keyboard
#         layouts and buttons that open the other panels.
# header = true shows the big clock and date on top;
# otherwise "title" (if set) is shown as a compact title row.
# tab = false leaves a panel out of the tab strip (open it with a key binding).

[panel.main]
header = true
columns = quick media audio calculator | weather clocks displays bluetooth

[panel.system]
title = System
width = 1180
columns = cpu memory storage | gpu thermals network | processes

[panel.sensors]
title = Home
width = 560
columns = sensors

[panel.notifications]
title = Notifications
width = 560
columns = notifications

[panel.time]
title = Time
width = 600
columns = time

[panel.audio]
title = Audio
width = 520
tab = false
columns = audio

[panel.calc]
title = Calculator
width = 560
tab = false
columns = calculator

[panel.launch]
width = 680
tab = false
columns = launcher

[panel.run]
width = 680
tab = false
columns = launcher

[panel.emoji]
width = 680
tab = false
columns = launcher

[panel.github]
title = GitHub
width = 1120
columns = github | github-repo github-inbox
`

// wlperch was called wlwidgets: move its config and data (projects, time log,
// sensor and notification history) over once.
migrate_old_name :: proc() {
	home := os.get_env("HOME", context.temp_allocator)
	cfg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if cfg == "" {cfg = strings.concatenate({home, "/.config"}, context.temp_allocator)}
	data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if data == "" {data = strings.concatenate({home, "/.local/share"}, context.temp_allocator)}
	for base in ([]string{cfg, data}) {
		old := strings.concatenate({base, "/wlwidgets"}, context.temp_allocator)
		new := strings.concatenate({base, "/wlperch"}, context.temp_allocator)
		if os.exists(old) && !os.exists(new) {
			if err := os.rename(old, new); err != nil {
				log.warnf("could not move %s to %s: %v", old, new, err)
			} else {
				log.infof("moved %s to %s", old, new)
			}
		}
	}
}

// DEFAULT_CONFIG plus display presets for the monitors connected right now.
default_config_text :: proc() -> string {
	sway_load_outputs()
	// Right after the display preset notes.
	base := DEFAULT_CONFIG
	at := strings.index(base, "\n[system]")
	return strings.concatenate({base[:at], displays_default_presets(), base[at:]}, context.temp_allocator)
}

config_path :: proc() -> string {
	base := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if base == "" {
		base = strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.config"}, context.temp_allocator)
	}
	return strings.concatenate({base, "/wlperch/config.ini"})
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
	v, ok := parse_bool_value(s)
	return ok ? v : def
}

@(private = "file")
parse_hex_color :: proc(s: string, def: u32) -> u32 {
	t := strings.trim_prefix(strings.trim_space(s), "#")
	if len(t) != 6 {return def}
	v, ok := strconv.parse_u64_of_base(t, 16)
	return ok ? u32(v) : def
}

config_load :: proc() {
	path := config_path()
	if !os.exists(path) {
		dir := path[:strings.last_index_byte(path, '/')]
		os.make_directory_all(dir)
		if err := os.write_entire_file(path, default_config_text()); err != nil {
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
	c.width = i32(parse_int_lim(get(m, defaults, "popup", "width"), LIM_POPUP_WIDTH))
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
	c.max_height = i32(parse_int_lim(get(m, defaults, "popup", "max_height"), LIM_POPUP_MAX_HEIGHT))
	c.release_gpu_after = time.Duration(parse_int_lim(get(m, defaults, "popup", "release_gpu_after"), LIM_RELEASE_GPU)) * time.Second

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

	c.history_seconds = parse_int_lim(get(m, defaults, "system", "history_seconds"), LIM_HISTORY)
	config_load_memory(m, defaults)

	c.notifications = parse_bool(get(m, defaults, "notifications", "enabled"), true)

	c.github = parse_bool(get(m, defaults, "github", "enabled"), false)
	c.github_repo = strings.clone(get(m, defaults, "github", "repo"))
	c.github_refresh = time.Duration(parse_int_lim(get(m, defaults, "github", "refresh_minutes"), LIM_GITHUB_REFRESH)) * time.Minute

	c.lock_pam_service = strings.clone(get(m, defaults, "lock", "pam_service"))
	c.lock_background = parse_hex_color(get(m, defaults, "lock", "background"), 0x14161b)
	c.lock_image = expand_home(get(m, defaults, "lock", "image"))
	c.lock_mode = lock_bg_mode_parse(get(m, defaults, "lock", "background_mode"), c.lock_image)
	c.lock_screenshot_blur = parse_int_lim(get(m, defaults, "lock", "screenshot_blur"), LIM_LOCK_SCREENSHOT_BLUR)
	c.lock_blur_animate_ms = parse_int_lim(get(m, defaults, "lock", "blur_animate_ms"), LIM_LOCK_BLUR_ANIMATE_MS)
	c.lock_blur_animate_from = parse_int_lim(get(m, defaults, "lock", "blur_animate_from"), LIM_LOCK_BLUR_ANIMATE_FROM)
	c.lock_blur = parse_int_lim(get(m, defaults, "lock", "blur"), LIM_LOCK_BLUR)
	c.lock_dim = f32(parse_float_lim(get(m, defaults, "lock", "dim"), LIM_LOCK_DIM))
	c.lock_notifications = parse_bool(get(m, defaults, "lock", "show_notifications"), true)
	c.lock_media = parse_bool(get(m, defaults, "lock", "show_media"), true)
	c.lock_bluetooth = parse_bool(get(m, defaults, "lock", "show_bluetooth"), true)

	c.lock_background_light = parse_hex_color(get(m, defaults, "lock", "background_light"), 0xe9ebf0)
	c.lock_countdown_seconds = parse_int_lim(get(m, defaults, "lock", "countdown_seconds"), LIM_LOCK_COUNTDOWN)
	c.lock_idle_seconds = parse_int_lim(get(m, defaults, "lock", "idle_lock_seconds"), LIM_LOCK_IDLE)
	if c.lock_idle_seconds > 0 {c.lock_idle_seconds = max(c.lock_idle_seconds, 10)}

	c.launcher_terminal = strings.clone(get(m, defaults, "launcher", "terminal"))

	config_load_theme(m, defaults)
	bar_config_load(m, defaults)

	c.sensors_dir = expand_home(get(m, defaults, "sensors", "dir"))
	c.sensors_watch = strings.clone(get(m, defaults, "sensors", "watch"))
	c.sensors_bar_room = strings.clone(get(m, defaults, "sensors", "bar_room"))
	sensors_load_defs(m)

	tracker.idle = tracker_idle_timeout(m, defaults)
	projects_load(string(src_for_projects(path)), m)

	// Panels: from the user's file, or the built-in set if it defines none.
	src, _ := os.read_entire_file(path, context.temp_allocator)
	panels_load(string(src), m)
	if len(panels) == 0 {panels_load(DEFAULT_CONFIG, defaults)}
	panels_ensure_launcher()
	// No sensors defined: drop the module (and a panel left empty, like the built-in "sensors").
	if !sensors_configured() {panels_drop_module("sensors")}
	if !c.github {
		for mod in ([]string{"github", "github-repo", "github-inbox"}) {panels_drop_module(mod)}
	}
}

// `location = "Ghent, Belgium"` -> Ghent, Belgium
Lock_Bg_Mode :: enum {Color, Image, Blur}

// [lock] background_mode: "" picks the picture when one is set.
lock_bg_mode_parse :: proc(s: string, image: string) -> Lock_Bg_Mode {
	switch strings.to_lower(strings.trim_space(s), context.temp_allocator) {
	case "blur", "screenshot": return .Blur
	case "color", "colour", "solid": return .Color
	case "image", "picture": return image != "" ? .Image : .Color
	}
	return image != "" ? .Image : .Color
}

// [theme], [theme.dark] and [theme.light].
config_load_theme :: proc(m, defaults: ini.Map) {
	get :: proc(m, d: ini.Map, section, key: string) -> string {
		if s, ok := m[section]; ok {
			if v, vok := s[key]; vok {return unquote(strings.trim_space(v))}
		}
		return unquote(strings.trim_space(d[section][key]))
	}
	c := &config
	clear(&c.theme_links)
	for l in split_list(get(m, defaults, "theme", "links"), ",") {append(&c.theme_links, expand_home(l))}
	c.theme_nvim_file = expand_home(get(m, defaults, "theme", "nvim_file"))
	for mode in Theme_Mode {
		sec := mode == .Dark ? "theme.dark" : "theme.light"
		t := &c.theme_targets[mode]
		t.gtk_theme = strings.clone(get(m, defaults, sec, "gtk_theme"))
		t.icon_theme = strings.clone(get(m, defaults, sec, "icon_theme"))
		t.kitty_theme = strings.clone(get(m, defaults, sec, "kitty_theme"))
		t.wallpaper = expand_home(get(m, defaults, sec, "wallpaper"))
		t.nvim_colorscheme = strings.clone(get(m, defaults, sec, "nvim_colorscheme"))
		t.kvantum_theme = strings.clone(get(m, defaults, sec, "kvantum_theme"))
		t.vscode_theme = strings.clone(get(m, defaults, sec, "vscode_theme"))
		t.command = strings.clone(get(m, defaults, sec, "command"))
		t.sway_colors = strings.to_lower(get(m, defaults, sec, "sway_colors"), context.temp_allocator) != "off"
		for class in Sway_Client_Class {
			key := strings.concatenate({"sway_client_", SWAY_CLIENT_NAMES[class]}, context.temp_allocator)
			v := get(m, defaults, sec, key)
			if v != "" && !sway_client_colors_valid(class, v) {
				log.warnf("[%s] %s: expected #rrggbb colours (%s), using the built-in", sec, key, class == .Background ? "one" : class == .Focused_Tab_Title ? "three" : "three to five")
				v = ""
			}
			t.sway_client[class] = strings.clone(v)
		}
	}
}

// Only the theme sections again, before a switch: the Settings tab saves a
// [theme.*] key and asks the daemon to switch, without a restart.
config_reload_theme :: proc() {
	defaults, _ := ini.load_map_from_string(DEFAULT_CONFIG, context.temp_allocator)
	m, _, ok := ini.load_map_from_path(config_path(), context.temp_allocator)
	if !ok {return}
	config_load_theme(m, defaults)
}

unquote :: proc(s: string) -> string {
	if len(s) >= 2 && ((s[0] == '"' && s[len(s) - 1] == '"') || (s[0] == '\'' && s[len(s) - 1] == '\'')) {
		return s[1:len(s) - 1]
	}
	return s
}

@(private = "file")
src_for_projects :: proc(path: string) -> []u8 {
	data, _ := os.read_entire_file(path, context.temp_allocator)
	return data
}

popup_size :: proc() -> (w, h: i32) {
	p := cur_panel()
	return p.width + 2 * (SHADOW - SHADOW_BASE), p.last_height > 0 ? p.last_height : 600
}

popup_placement :: proc() -> Popup_Placement {
	return {
		anchor = config.anchor,
		// Extra shadow margin overlaps the screen edge / bar instead of moving the panel.
		margin = config.margin - (SHADOW - SHADOW_BASE),
		layer = wl.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
		output = config.output,
		backdrop = config.close_on_click_outside,
	}
}

// [timetracker] idle_seconds; idle_seconds used to be idle_minutes: still
// honoured when idle_seconds isn't set.
tracker_idle_timeout :: proc(m, defaults: ini.Map) -> time.Duration {
	val :: proc(m: ini.Map, key: string) -> (string, bool) {
		if sec, ok := m["timetracker"]; ok {
			if v, has := sec[key]; has {return unquote(strings.trim_space(v)), true}
		}
		return "", false
	}
	dv, _ := val(defaults, "idle_seconds")
	idle_s := strconv.parse_int(dv) or_else 300
	if v, ok := val(m, "idle_seconds"); ok {
		idle_s = strconv.parse_int(v) or_else idle_s
	} else if v, ok := val(m, "idle_minutes"); ok {
		if mins, mok := strconv.parse_int(v); mok {idle_s = mins * 60}
	}
	return time.Duration(clamp(idle_s, LIM_IDLE_SECONDS.lo, LIM_IDLE_SECONDS.hi)) * time.Second
}

// [memory]: also re-read by the bar when config.ini changes.
config_load_memory :: proc(m, defaults: ini.Map) {
	c := &config
	// critical_percent used to be [system] memory_warn_percent: still honoured.
	crit, _ := config_value_legacy(m, defaults, "memory", "critical_percent", "system", "memory_warn_percent")
	c.memory_warn_pct = parse_int_lim(crit, LIM_MEM_CRITICAL)
	c.memory_free_warn_pct = parse_int_lim(config_value(m, defaults, "memory", "warn_free_percent"), LIM_MEM_FREE_WARN)
	c.memory_bar_warn_pct = parse_int_lim(config_value(m, defaults, "memory", "bar_warn_percent"), LIM_MEM_BAR_WARN)
}

// The value config_load sees for [section] key: the user's, else the default.
config_value :: proc(m, defaults: ini.Map, section, key: string) -> string {
	if s, ok := m[section]; ok {
		if v, vok := s[key]; vok {return unquote(strings.trim_space(v))}
	}
	if s, ok := defaults[section]; ok {return unquote(strings.trim_space(s[key]))}
	return ""
}

// Like config_value, but a key that was renamed: the old [old_section]
// old_key still counts while the new one isn't set. `legacy` says it did.
config_value_legacy :: proc(m, defaults: ini.Map, section, key, old_section, old_key: string) -> (v: string, legacy: bool) {
	if s, ok := m[section]; ok {
		if _, has := s[key]; has {return config_value(m, defaults, section, key), false}
	}
	if s, ok := m[old_section]; ok {
		if old, has := s[old_key]; has {return unquote(strings.trim_space(old)), true}
	}
	return config_value(m, defaults, section, key), false
}

// ---- Limits --------------------------------------------------------------------
// Shared by config_load and the setup window's settings, so both clamp alike.
// `fallback` is used when the text isn't a number (the template's default).

Int_Limits :: struct {lo, hi, fallback: int}
Float_Limits :: struct {lo, hi, fallback: f64}

LIM_POPUP_WIDTH :: Int_Limits{480, 2000, 860}
LIM_POPUP_MAX_HEIGHT :: Int_Limits{0, 8192, 0}
LIM_RELEASE_GPU :: Int_Limits{0, 86400, 30}
LIM_HISTORY :: Int_Limits{30, 600, 120}
LIM_MEM_CRITICAL :: Int_Limits{1, 100, 90}
LIM_MEM_FREE_WARN :: Int_Limits{0, 99, 15}
LIM_MEM_BAR_WARN :: Int_Limits{1, 100, 75}
LIM_GITHUB_REFRESH :: Int_Limits{1, 1440, 5}
LIM_LOCK_SCREENSHOT_BLUR :: Int_Limits{0, 100, 60}
LIM_LOCK_BLUR_ANIMATE_MS :: Int_Limits{0, 3000, 0}
LIM_LOCK_BLUR_ANIMATE_FROM :: Int_Limits{0, 100, 10}
LIM_LOCK_BLUR :: Int_Limits{0, 64, 0}
LIM_LOCK_DIM :: Float_Limits{0, 1, 0.35}
LIM_IDLE_SECONDS :: Int_Limits{5, 86400, 300}
LIM_BAR_HEIGHT :: Int_Limits{20, 80, 34}
LIM_BAR_TRAY :: Int_Limits{12, 48, 20}
LIM_BAR_VOLSTEP :: Int_Limits{1, 25, 5}
LIM_LOCK_COUNTDOWN :: Int_Limits{0, 120, 15}
LIM_LOCK_IDLE :: Int_Limits{0, 86400, 0}

parse_int_lim :: proc(s: string, l: Int_Limits) -> int {
	return clamp(strconv.parse_int(strings.trim_space(s)) or_else l.fallback, l.lo, l.hi)
}

parse_float_lim :: proc(s: string, l: Float_Limits) -> f64 {
	return clamp(strconv.parse_f64(strings.trim_space(s)) or_else l.fallback, l.lo, l.hi)
}

// true / yes / 1 / on and false / no / 0 / off; ok = false for anything else.
parse_bool_value :: proc(s: string) -> (v: bool, ok: bool) {
	switch strings.to_lower(strings.trim_space(s), context.temp_allocator) {
	case "true", "yes", "1", "on":  return true, true
	case "false", "no", "0", "off": return false, true
	}
	return false, false
}
