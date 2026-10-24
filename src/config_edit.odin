// Editing config.ini in place: single keys set or removed while comments,
// blank lines and order stay as they are. Plus the table of settings the
// setup window offers (setup_settings.odin), validated with the same limits
// config_load clamps to.
package main

import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

// ---- The ini writer ------------------------------------------------------------

// "[name]" -> name, as core:encoding/ini reads a section header.
@(private = "file")
ini_header :: proc(trimmed: string) -> (name: string, ok: bool) {
	if len(trimmed) == 0 || trimmed[0] != '[' {return "", false}
	end := strings.index_byte(trimmed, ']')
	if end < 0 {end = len(trimmed)}
	return strings.trim_space(trimmed[1:end]), true
}

// The key of a `key = value` line ("" for comments and anything else).
@(private = "file")
ini_key :: proc(trimmed: string) -> string {
	if len(trimmed) == 0 || trimmed[0] == ';' || trimmed[0] == '#' || trimmed[0] == '[' {return ""}
	eq := strings.index_byte(trimmed, '=')
	if eq < 0 {return ""}
	return strings.trim_space(trimmed[:eq])
}

// How a value is written: as is, or quoted when the reader would otherwise
// lose something (surrounding spaces, a leading quote). Line breaks become spaces.
ini_format_value :: proc(value: string, allocator := context.temp_allocator) -> string {
	v, _ := strings.replace_all(value, "\r", "", context.temp_allocator)
	v, _ = strings.replace_all(v, "\n", " ", context.temp_allocator)
	needs_quotes := len(v) > 0 && (v[0] == '"' || v[0] == '\'' || strings.trim_space(v) != v)
	if !needs_quotes {return strings.clone(v, allocator)}
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '"')
	for r in v {
		if r == '"' || r == '\\' {strings.write_byte(&b, '\\')}
		strings.write_rune(&b, r)
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// `key = value` in [section]: every existing line for that key in the section
// is replaced (keeping its indentation); otherwise the line goes after the
// section's last key, or a new [section] is appended at the end.
ini_set_value :: proc(text, section, key, value: string, allocator := context.temp_allocator) -> string {
	context.allocator = context.temp_allocator
	lines := strings.split_after(text, "\n")
	cur := ""
	matched := false
	insert_after := -1 // line index the new key follows
	has_keys := false
	in_head := false // the header and the comment lines right under it
	for line, i in lines {
		l := strings.trim_space(line)
		if name, ok := ini_header(l); ok {
			cur = name
			in_head = cur == section && insert_after < 0
			if in_head {insert_after = i}
			continue
		}
		if cur == section && ini_key(l) != "" {
			if ini_key(l) == key {matched = true}
			insert_after = i
			has_keys = true
			in_head = false
		} else if in_head && !has_keys && l != "" {
			insert_after = i // no key yet: after the section's leading comments
		} else {
			in_head = false
		}
	}
	entry := fmt.tprintf("%s = %s\n", key, ini_format_value(value))
	b := strings.builder_make(allocator)
	cur = ""
	for line, i in lines {
		l := strings.trim_space(line)
		if name, ok := ini_header(l); ok {cur = name}
		if matched && cur == section && ini_key(l) == key {
			indent := line[:strings.index(line, l)]
			strings.write_string(&b, indent)
			strings.write_string(&b, entry)
			continue
		}
		strings.write_string(&b, line)
		if !matched && i == insert_after {
			if !strings.has_suffix(line, "\n") {strings.write_byte(&b, '\n')}
			strings.write_string(&b, entry)
		}
	}
	if insert_after < 0 {
		out := strings.to_string(b)
		if len(out) > 0 {
			if !strings.has_suffix(out, "\n") {strings.write_byte(&b, '\n')}
			if !strings.has_suffix(strings.to_string(b), "\n\n") {strings.write_byte(&b, '\n')}
		}
		fmt.sbprintf(&b, "[%s]\n%s", section, entry)
	}
	return strings.to_string(b)
}

// Drops every `key = …` line of [section]; comments and the header stay.
ini_remove_key :: proc(text, section, key: string, allocator := context.temp_allocator) -> string {
	lines := strings.split_after(text, "\n", context.temp_allocator)
	b := strings.builder_make(allocator)
	cur := ""
	for line in lines {
		l := strings.trim_space(line)
		if name, ok := ini_header(l); ok {cur = name}
		if cur == section && ini_key(l) == key {continue}
		strings.write_string(&b, line)
	}
	return strings.to_string(b)
}

@(private = "file")
config_rewrite :: proc(edit: proc(text: string, data: [3]string) -> string, data: [3]string) -> bool {
	path := config_path()
	defer delete(path)
	text: string
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		text = string(data)
	} else {
		text = default_config_text()
	}
	out := edit(text, data)
	if out == text {return true}
	dir := path[:strings.last_index_byte(path, '/')]
	os.make_directory_all(dir)
	// Written next to it and renamed over: readers (and inotify watchers)
	// never see half a file. Keeps the file's permissions (sensor keys).
	mode := os.Permissions_Default_File
	if fi, err := os.stat(path, context.temp_allocator); err == nil {mode = fi.mode & os.Permissions_All}
	tmp := strings.concatenate({path, ".wlperch-tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, out, mode) != nil {return false}
	return os.rename(tmp, path) == nil
}

// Set `key = value` in [section] of the config file, keeping everything else
// (comments, order; creates the file with defaults first).
config_set_value :: proc(section, key, value: string) -> bool {
	return config_rewrite(proc(text: string, d: [3]string) -> string {return ini_set_value(text, d[0], d[1], d[2])}, {section, key, value})
}

// Remove `key` from [section]: the default applies again.
config_remove_value :: proc(section, key: string) -> bool {
	return config_rewrite(proc(text: string, d: [3]string) -> string {return ini_remove_key(text, d[0], d[1])}, {section, key, ""})
}

// ---- Settings offered in the setup window --------------------------------------

Setting_Kind :: enum {
	Bool,
	Int,    // stepper (wide ranges) or slider (`slider` set)
	Float,  // slider
	Choice, // segmented control or combo
	Text,
	Color,  // #rrggbb
	Path,   // a file; "~/" allowed
}

// What makes a change take effect (setup does it right after writing).
Setting_Apply :: enum {
	Daemon,     // the daemon restarts (re-executes, state kept)
	Bar,        // the bar re-reads config.ini by itself
	Daemon_Bar, // both
	Lock,       // read when the screen locks
	Theme,      // the daemon restarts; used at the next dark / light switch
	Setup,      // the setup window itself, right away
}

Setting_Choice :: struct {value, label: string}

Setting :: struct {
	group:      string,
	section:    string,
	key:        string,
	label:      string,
	kind:       Setting_Kind,
	apply:      Setting_Apply,
	ilim:       Int_Limits,
	flim:       Float_Limits,
	step:       int,    // stepper increment
	slider:     bool,   // Int: a slider instead of a stepper
	unit:       string, // shown after numbers
	choices:    []Setting_Choice,
	help:       string, // "" = the comment above the key in DEFAULT_CONFIG
	hint:       string, // placeholder for an empty text field
	old_section, old_key: string, // a renamed key that still counts
	old_scale:  int,              // old value * old_scale = new value (0 = 1)
}

SETTINGS_GROUPS := [?]string{"Panel", "Clock and weather", "Bar", "Memory", "Lock screen", "Time tracking", "GitHub", "Launcher", "Setup window", "Dark theme", "Light theme"}

@(private = "file") CH_UNITS :: []Setting_Choice{{"metric", "Metric"}, {"imperial", "Imperial"}}
@(private = "file") CH_BAR_POS :: []Setting_Choice{{"top", "Top"}, {"bottom", "Bottom"}}
@(private = "file") CH_ANCHOR :: []Setting_Choice{{"top right", "Top right"}, {"top left", "Top left"}, {"top", "Top centre"}, {"bottom right", "Bottom right"}, {"bottom left", "Bottom left"}, {"bottom", "Bottom centre"}}
@(private = "file") CH_SWAY_COLORS :: []Setting_Choice{{"auto", "wlperch palette"}, {"off", "Leave alone"}}
@(private = "file") CH_LOCK_BG :: []Setting_Choice{{"", "Auto"}, {"color", "Colour"}, {"image", "Picture"}, {"blur", "Blurred screen"}}

THEME_HELP_SWAY :: `sway's titlebars and borders (client.* colours) in wlperch's palette for this mode, set over IPC and again after "swaymsg reload". One class can be changed with sway_client_<class> = border background text [indicator child_border] in config.ini.`
THEME_HELP_GTK :: `GTK theme for this mode. "auto" switches Adwaita <-> Adwaita-dark while one of those is in use; empty = leave alone.`

@(rodata)
SETTINGS := [?]Setting {
	// Panel
	{group = "Panel", section = "popup", key = "close_on_click_outside", label = "Close on click outside", kind = .Bool, apply = .Daemon, help = "Clicking anywhere outside an open panel closes it."},
	{group = "Panel", section = "popup", key = "anchor", label = "Position", kind = .Choice, apply = .Daemon, choices = CH_ANCHOR, help = "Where panels open when they aren't opened from the bar (the bar opens them under the clicked module)."},
	{group = "Panel", section = "popup", key = "width", label = "Width", kind = .Int, apply = .Daemon, ilim = LIM_POPUP_WIDTH, step = 20, unit = "px", help = "Width of the main panel (logical pixels); other panels set their own."},
	{group = "Panel", section = "popup", key = "max_height", label = "Maximum height", kind = .Int, apply = .Daemon, ilim = LIM_POPUP_MAX_HEIGHT, step = 50, unit = "px"},
	{group = "Panel", section = "popup", key = "output", label = "Output", kind = .Text, apply = .Daemon, hint = "focused output", help = "Connector to show panels on (e.g. DP-1). Empty = the focused output."},
	{group = "Panel", section = "popup", key = "release_gpu_after", label = "Release GPU memory after", kind = .Int, apply = .Daemon, ilim = LIM_RELEASE_GPU, step = 10, unit = "s"},
	{group = "Panel", section = "system", key = "history_seconds", label = "Graph history", kind = .Int, apply = .Daemon, ilim = LIM_HISTORY, step = 30, unit = "s"},
	// Clock and weather
	{group = "Clock and weather", section = "clocks", key = "use_24h", label = "24-hour clock", kind = .Bool, apply = .Daemon, help = "13:00 instead of 1:00 PM in the panels (the bar has its own format below)."},
	{group = "Clock and weather", section = "clocks", key = "zones", label = "World clocks", kind = .Text, apply = .Daemon},
	{group = "Clock and weather", section = "weather", key = "location", label = "Weather location", kind = .Text, apply = .Daemon, hint = "auto"},
	{group = "Clock and weather", section = "weather", key = "units", label = "Units", kind = .Choice, apply = .Daemon, choices = CH_UNITS, help = "Temperatures, wind and rain in metric or imperial units."},
	{group = "Clock and weather", section = "nightlight", key = "command", label = "Night light command", kind = .Text, apply = .Daemon, help = "Run by the night light tile, e.g. wlsunset -l {lat} -L {lon} -t 4000 -T 6500 for its temperatures. {lat} and {lon} are the weather location's coordinates."},
	// Bar
	{group = "Bar", section = "bar", key = "position", label = "Position", kind = .Choice, apply = .Bar, choices = CH_BAR_POS, help = "Screen edge of wlperch's own bar."},
	{group = "Bar", section = "bar", key = "height", label = "Height", kind = .Int, apply = .Bar, ilim = LIM_BAR_HEIGHT, slider = true, unit = "px", help = "Bar height in logical pixels."},
	{group = "Bar", section = "bar", key = "clock_format", label = "Clock format", kind = .Text, apply = .Bar, help = "strftime-like: %a %A %b %B %d %e %m %Y %H %I %M %S %p; <b>…</b> is bold. %S shows seconds."},
	{group = "Bar", section = "bar", key = "tray_icon_size", label = "Tray icon size", kind = .Int, apply = .Bar, ilim = LIM_BAR_TRAY, slider = true, unit = "px"},
	{group = "Bar", section = "bar", key = "volume_step", label = "Volume scroll step", kind = .Int, apply = .Bar, ilim = LIM_BAR_VOLSTEP, slider = true, unit = "%", help = "Volume change per scroll step on the bar's audio module (it never goes above 100 %)."},
	{group = "Bar", section = "bar", key = "outputs", label = "Outputs", kind = .Text, apply = .Bar, hint = "all outputs"},
	{group = "Bar", section = "sensors", key = "bar_room", label = "Sensor room", kind = .Text, apply = .Bar, hint = "first room", help = "Room whose temperature the bar's sensors module shows (empty = the first)."},
	// Memory
	{group = "Memory", section = "memory", key = "warn_free_percent", label = "Low-memory warning below", kind = .Int, apply = .Daemon, ilim = LIM_MEM_FREE_WARN, slider = true, unit = "% free", help = "A card with the biggest memory users (SIGTERM / SIGKILL buttons) once available memory drops below this share of RAM. Shows under do not disturb. 0 = off."},
	{group = "Memory", section = "memory", key = "bar_warn_percent", label = "Bar turns orange at", kind = .Int, apply = .Bar, ilim = LIM_MEM_BAR_WARN, slider = true, unit = "% used"},
	{group = "Memory", section = "memory", key = "critical_percent", label = "Critical at", kind = .Int, apply = .Daemon_Bar, ilim = LIM_MEM_CRITICAL, slider = true, unit = "% used", old_section = "system", old_key = "memory_warn_percent"},
	// Lock screen
	{group = "Lock screen", section = "lock", key = "background_mode", label = "Background", kind = .Choice, apply = .Lock, choices = CH_LOCK_BG, help = "What's behind the clock: the colour, the picture, or a frosted-glass copy of the screen (kept in memory only). Auto = the picture when one is set, else the colour."},
	{group = "Lock screen", section = "lock", key = "background", label = "Colour", kind = .Color, apply = .Lock, help = "Background colour (dark theme, or with a picture: behind it)."},
	{group = "Lock screen", section = "lock", key = "background_light", label = "Colour (light theme)", kind = .Color, apply = .Lock},
	{group = "Lock screen", section = "lock", key = "image", label = "Picture", kind = .Path, apply = .Lock, hint = "~/Pictures/lock.jpg", help = "A PNG or JPEG drawn over the colour, cover-fitted."},
	{group = "Lock screen", section = "lock", key = "blur", label = "Picture blur", kind = .Int, apply = .Lock, ilim = LIM_LOCK_BLUR, slider = true, help = "Blurs the picture this much; 0 = sharp."},
	{group = "Lock screen", section = "lock", key = "dim", label = "Picture dim", kind = .Float, apply = .Lock, flim = LIM_LOCK_DIM, help = "Darkens the picture (0 = not at all, 1 = black)."},
	{group = "Lock screen", section = "lock", key = "screenshot_blur", label = "Screen blur strength", kind = .Int, apply = .Lock, ilim = LIM_LOCK_SCREENSHOT_BLUR, slider = true},
	{group = "Lock screen", section = "lock", key = "blur_animate_ms", label = "Grow the screen blur over", kind = .Int, apply = .Lock, ilim = LIM_LOCK_BLUR_ANIMATE_MS, step = 100, unit = "ms", help = "Frosted-glass background only: the blur grows from the start strength below to the full strength in this time after locking; 0 = off. While it grows the screen stays partly readable, so it's off by default. Never animates when locked with -f (swayidle's timeout and before-sleep)."},
	{group = "Lock screen", section = "lock", key = "blur_animate_from", label = "Start the blur at", kind = .Int, apply = .Lock, ilim = LIM_LOCK_BLUR_ANIMATE_FROM, slider = true, unit = "%", help = "Share of the full blur the animation starts at; 0 = sharp."},
	{group = "Lock screen", section = "lock", key = "show_notifications", label = "Notification count", kind = .Bool, apply = .Lock},
	{group = "Lock screen", section = "lock", key = "show_media", label = "Playing track", kind = .Bool, apply = .Lock, help = "Show what's playing, with play / pause."},
	{group = "Lock screen", section = "lock", key = "show_bluetooth", label = "Bluetooth devices", kind = .Bool, apply = .Lock, help = "Connected devices with their battery, when the daemon runs."},
	{group = "Lock screen", section = "lock", key = "countdown_seconds", label = "Countdown before the idle lock", kind = .Int, apply = .Daemon, ilim = LIM_LOCK_COUNTDOWN, step = 5, unit = "s", help = "The screen dims and a ring counts down before it locks for inactivity; any key or mouse move cancels it. Follows swayidle's lock timeout and its idle inhibitors. 0 = off."},
	{group = "Lock screen", section = "lock", key = "idle_lock_seconds", label = "wlperch locks after", kind = .Int, apply = .Daemon, ilim = LIM_LOCK_IDLE, step = 30, unit = "s", help = "0 = swayidle locks on idle (the usual setup). A number: wlperch itself locks after this much idle time, for setups without an idle lock in swayidle. A swayidle lock that comes earlier still wins."},
	// Notifications
	{group = "Notifications", section = "notifications", key = "hold_when_idle", label = "Hold popups when away after", kind = .Int, apply = .Daemon, ilim = LIM_NOTIF_HOLD_IDLE, step = 5, unit = "s", help = "After this long without input, popups stop timing out and wait for you; once you're back each gets its full time again. A playing video counts as activity. 0 = off."},
	// Time tracking
	{group = "Time tracking", section = "timetracker", key = "idle_seconds", label = "Break after", kind = .Int, apply = .Daemon, ilim = LIM_IDLE_SECONDS, step = 30, unit = "s", old_section = "timetracker", old_key = "idle_minutes", old_scale = 60},
	// GitHub
	{group = "GitHub", section = "github", key = "enabled", label = "GitHub panel", kind = .Bool, apply = .Daemon, help = "Review requests, your pull requests with their checks, assigned issues and notifications, through the gh tool (log in once with \"gh auth login\"). Read-only."},
	{group = "GitHub", section = "github", key = "repo", label = "Repository", kind = .Text, apply = .Daemon, hint = "owner/name"},
	{group = "GitHub", section = "github", key = "refresh_minutes", label = "Refresh every", kind = .Int, apply = .Daemon, ilim = LIM_GITHUB_REFRESH, step = 1, unit = "min"},
	// Launcher
	{group = "Launcher", section = "launcher", key = "terminal", label = "Terminal", kind = .Text, apply = .Daemon, hint = "detect", help = "For apps that need a terminal, with the option that runs a command (e.g. \"alacritty -e\"). Empty = $TERMINAL, sway's $term or the first one installed."},
	// Setup window
	{group = "Setup window", section = "setup", key = "dim_background", label = "Dim the rest of the screen", kind = .Bool, apply = .Setup, help = "While this window is open and focused, everything around it is dimmed (not while it is tiled). A click on the dim closes the window, like Escape."},
	{group = "Setup window", section = "setup", key = "dim_strength", label = "Dim strength", kind = .Int, apply = .Setup, ilim = LIM_SETUP_DIM, slider = true, unit = "%", help = "How dark the dim is; the light theme uses a bit less."},
	// Dark / light
	{group = "Dark theme", section = "theme.dark", key = "wallpaper", label = "Wallpaper", kind = .Path, apply = .Theme, hint = "leave alone", help = "An image for sway's outputs."},
	{group = "Dark theme", section = "theme.dark", key = "gtk_theme", label = "GTK theme", kind = .Text, apply = .Theme, hint = "leave alone", help = THEME_HELP_GTK},
	{group = "Dark theme", section = "theme.dark", key = "icon_theme", label = "Icon theme", kind = .Text, apply = .Theme, hint = "leave alone", help = "Icon theme name (gsettings icon-theme)."},
	{group = "Dark theme", section = "theme.dark", key = "kitty_theme", label = "kitty theme", kind = .Text, apply = .Theme, hint = "leave alone", help = "A theme name from \"kitty +kitten themes\" (all kitty windows)."},
	{group = "Dark theme", section = "theme.dark", key = "nvim_colorscheme", label = "nvim colorscheme", kind = .Text, apply = .Theme, hint = "leave alone", help = "Written with \"set background\" to the nvim file of [theme] nvim_file; have nvim source it."},
	{group = "Dark theme", section = "theme.dark", key = "vscode_theme", label = "VS Code theme", kind = .Text, apply = .Theme, hint = "leave alone", help = "VS Code's workbench.colorTheme, e.g. \"Default Dark Modern\"."},
	{group = "Dark theme", section = "theme.dark", key = "kvantum_theme", label = "Kvantum theme", kind = .Text, apply = .Theme, hint = "leave alone", help = "Kvantum theme for Qt apps."},
	{group = "Dark theme", section = "theme.dark", key = "sway_colors", label = "sway window colours", kind = .Choice, apply = .Theme, choices = CH_SWAY_COLORS, help = THEME_HELP_SWAY},
	{group = "Light theme", section = "theme.light", key = "wallpaper", label = "Wallpaper", kind = .Path, apply = .Theme, hint = "leave alone", help = "An image for sway's outputs."},
	{group = "Light theme", section = "theme.light", key = "gtk_theme", label = "GTK theme", kind = .Text, apply = .Theme, hint = "leave alone", help = THEME_HELP_GTK},
	{group = "Light theme", section = "theme.light", key = "icon_theme", label = "Icon theme", kind = .Text, apply = .Theme, hint = "leave alone", help = "Icon theme name (gsettings icon-theme)."},
	{group = "Light theme", section = "theme.light", key = "kitty_theme", label = "kitty theme", kind = .Text, apply = .Theme, hint = "leave alone", help = "A theme name from \"kitty +kitten themes\" (all kitty windows)."},
	{group = "Light theme", section = "theme.light", key = "nvim_colorscheme", label = "nvim colorscheme", kind = .Text, apply = .Theme, hint = "leave alone", help = "Written with \"set background\" to the nvim file of [theme] nvim_file; have nvim source it."},
	{group = "Light theme", section = "theme.light", key = "vscode_theme", label = "VS Code theme", kind = .Text, apply = .Theme, hint = "leave alone", help = "VS Code's workbench.colorTheme, e.g. \"Default Dark Modern\"."},
	{group = "Light theme", section = "theme.light", key = "kvantum_theme", label = "Kvantum theme", kind = .Text, apply = .Theme, hint = "leave alone", help = "Kvantum theme for Qt apps."},
	{group = "Light theme", section = "theme.light", key = "sway_colors", label = "sway window colours", kind = .Choice, apply = .Theme, choices = CH_SWAY_COLORS, help = THEME_HELP_SWAY},
}

// The comment block right above `key` in [section] of DEFAULT_CONFIG, as one line.
setting_template_help :: proc(section, key: string, allocator := context.temp_allocator) -> string {
	text := DEFAULT_CONFIG
	cur := ""
	comment := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if name, ok := ini_header(l); ok {
			cur = name
			clear(&comment)
			continue
		}
		if strings.has_prefix(l, "#") {
			append(&comment, strings.trim_space(l[1:]))
			continue
		}
		if cur == section && ini_key(l) == key {
			return strings.join(comment[:], " ", allocator)
		}
		clear(&comment)
	}
	return ""
}

setting_help :: proc(s: Setting) -> string {
	return s.help != "" ? s.help : setting_template_help(s.section, s.key)
}

// The value config_load would use, as text: the user's (`set`), a renamed
// old key's (`legacy`), else the template's default.
setting_raw :: proc(s: Setting, m, defaults: ini.Map) -> (raw: string, set, legacy: bool) {
	if sec, ok := m[s.section]; ok {
		if _, has := sec[s.key]; has {return config_value(m, defaults, s.section, s.key), true, false}
	}
	if s.old_key != "" {
		v, old := config_value_legacy(m, defaults, s.section, s.key, s.old_section, s.old_key)
		if old {
			if s.old_scale > 1 {
				if n, nok := strconv.parse_int(strings.trim_space(v)); nok {v = fmt.tprintf("%d", n * s.old_scale)}
			}
			return v, true, true
		}
	}
	return config_value(m, defaults, s.section, s.key), false, false
}

setting_default :: proc(s: Setting, defaults: ini.Map) -> string {
	return config_value(defaults, defaults, s.section, s.key)
}

// Normalises user input the way config_load reads it, ready to write.
// ok = false (with why) for input config_load would ignore.
setting_normalize :: proc(s: Setting, input: string) -> (value: string, ok: bool, why: string) {
	in_ := strings.trim_space(input)
	switch s.kind {
	case .Bool:
		v, bok := parse_bool_value(in_)
		if !bok {return "", false, "true or false"}
		return v ? "true" : "false", true, ""
	case .Int:
		n, nok := strconv.parse_int(in_)
		if !nok {return "", false, "a whole number"}
		return fmt.tprintf("%d", clamp(n, s.ilim.lo, s.ilim.hi)), true, ""
	case .Float:
		f, fok := strconv.parse_f64(in_)
		if !fok {return "", false, "a number"}
		return format_float(clamp(f, s.flim.lo, s.flim.hi)), true, ""
	case .Choice:
		for c in s.choices {
			if strings.equal_fold(c.value, in_) {return c.value, true, ""}
		}
		return "", false, "not one of the choices"
	case .Color:
		c, cok := parse_hex_color(in_)
		if !cok {return "", false, "a colour like #14161b"}
		return fmt.tprintf("#%06x", c), true, ""
	case .Text, .Path:
		v, _ := strings.replace_all(input, "\n", " ", context.temp_allocator)
		return strings.trim_space(v), true, ""
	}
	return "", false, ""
}

// 0.35 -> "0.35", 1 -> "1".
format_float :: proc(f: f64) -> string {
	s := fmt.tprintf("%.2f", f)
	s = strings.trim_right(s, "0")
	return strings.trim_suffix(s, ".")
}

// ---- Watching config.ini ---------------------------------------------------------
// For the bar: an inotify fd on config.ini's directory (the file is replaced
// by rename, so the file itself can't be watched). -1 on failure.

config_watch_open :: proc() -> linux.Fd {
	path := config_path()
	defer delete(path)
	dir := path[:strings.last_index_byte(path, '/')]
	fd, err := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if err != .NONE {return -1}
	if _, werr := linux.inotify_add_watch(fd, strings.clone_to_cstring(dir, context.temp_allocator), {.CLOSE_WRITE, .MOVED_TO}); werr != .NONE {
		linux.close(fd)
		return -1
	}
	return fd
}

// Drains the watch: true when config.ini was written or replaced.
config_watch_changed :: proc(fd: linux.Fd) -> bool {
	buf: [4096]u8
	hit := false
	for {
		n, err := linux.read(fd, buf[:])
		if err != .NONE || n <= 0 {break}
		for off := 0; off + size_of(linux.Inotify_Event) <= n; {
			ev := (^linux.Inotify_Event)(&buf[off])
			name := string(cstring(&buf[off + size_of(linux.Inotify_Event)])) if ev.len > 0 else ""
			if name == "config.ini" {hit = true}
			off += size_of(linux.Inotify_Event) + int(ev.len)
		}
	}
	return hit
}
