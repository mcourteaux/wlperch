// Unit tests for the config.ini writer (config_edit.odin) and the settings'
// validation against config_load's limits.
package main

import "core:encoding/ini"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
SAMPLE :: `# wlperch configuration

[popup]
# Total popup width in logical pixels.
width = 860
close_on_click_outside = true

[clocks]
# Comma separated list of IANA zones.
zones = local, UTC
use_24h = true

# Projects for time tracking.
# [project.acme]
# name = ACME

[lock]
background = #14161b
`

@(test)
test_ini_change_value :: proc(t: ^testing.T) {
	out := ini_set_value(SAMPLE, "popup", "width", "1000")
	want, _ := strings.replace(SAMPLE, "width = 860", "width = 1000", 1, context.temp_allocator)
	testing.expect_value(t, out, want)
	// Same key name in another section is left alone.
	out = ini_set_value(SAMPLE, "clocks", "use_24h", "false")
	testing.expect(t, strings.contains(out, "use_24h = false"))
	testing.expect(t, strings.contains(out, "close_on_click_outside = true"))
	// Unchanged lengths everywhere else: comments and blank lines intact.
	testing.expect_value(t, strings.count(out, "\n"), strings.count(SAMPLE, "\n"))
	testing.expect(t, strings.contains(out, "# Comma separated list of IANA zones.\nzones = local, UTC\nuse_24h = false\n\n# Projects"))
}

@(test)
test_ini_add_key_to_section :: proc(t: ^testing.T) {
	// After the section's last key, before the blank line and the comments that follow.
	out := ini_set_value(SAMPLE, "clocks", "extra", "1")
	testing.expect(t, strings.contains(out, "use_24h = true\nextra = 1\n\n# Projects for time tracking.\n# [project.acme]"), out)
	// A section with only a header gets the key right under it.
	out = ini_set_value("[a]\n\n[b]\nx = 1\n", "a", "k", "v")
	testing.expect_value(t, out, "[a]\nk = v\n\n[b]\nx = 1\n")
	// The last section, without a final newline.
	out = ini_set_value("[a]\nx = 1", "a", "y", "2")
	testing.expect_value(t, out, "[a]\nx = 1\ny = 2\n")
	// A commented-out key isn't the key.
	out = ini_set_value("[a]\n# k = old\n", "a", "k", "new")
	testing.expect_value(t, out, "[a]\n# k = old\nk = new\n")
}

@(test)
test_ini_add_missing_section :: proc(t: ^testing.T) {
	out := ini_set_value(SAMPLE, "memory", "warn_free_percent", "10")
	testing.expect(t, strings.has_prefix(out, SAMPLE))
	testing.expect_value(t, out[len(SAMPLE):], "\n[memory]\nwarn_free_percent = 10\n")
	// "# [project.acme]" is a comment, not the section.
	out = ini_set_value(SAMPLE, "project.acme", "name", "X")
	testing.expect(t, strings.has_suffix(out, "\n[project.acme]\nname = X\n"))
	testing.expect_value(t, ini_set_value("", "a", "k", "v"), "[a]\nk = v\n")
	testing.expect_value(t, ini_set_value("[x]\ny = 1\n\n", "a", "k", "v"), "[x]\ny = 1\n\n[a]\nk = v\n")
}

@(test)
test_ini_remove_key :: proc(t: ^testing.T) {
	out := ini_remove_key(SAMPLE, "popup", "width")
	testing.expect(t, strings.contains(out, "[popup]\n# Total popup width in logical pixels.\nclose_on_click_outside = true\n\n[clocks]"), out)
	testing.expect_value(t, len(out), len(SAMPLE) - len("width = 860\n"))
	// Missing key / section: unchanged.
	testing.expect_value(t, ini_remove_key(SAMPLE, "popup", "nope"), SAMPLE)
	testing.expect_value(t, ini_remove_key(SAMPLE, "nope", "width"), SAMPLE)
	// Set then remove gives the original back.
	testing.expect_value(t, ini_remove_key(ini_set_value(SAMPLE, "lock", "image", "~/a.png"), "lock", "image"), SAMPLE)
}

@(test)
test_ini_duplicates_and_quoting :: proc(t: ^testing.T) {
	// Every copy of the key in the section is set (the reader keeps the last).
	out := ini_set_value("[a]\nk = 1\n  k = 2\n[b]\nk = 3\n", "a", "k", "9")
	testing.expect_value(t, out, "[a]\nk = 9\n  k = 9\n[b]\nk = 3\n")
	// Values the reader would mangle are quoted, and read back as typed.
	out = ini_set_value("[a]\n", "a", "k", "\"quoted\" text")
	m, _ := ini.load_map_from_string(out, context.temp_allocator)
	testing.expect_value(t, unquote(strings.trim_space(m["a"]["k"])), "\"quoted\" text")
	out = ini_set_value("[a]\n", "a", "fmt", "%a %d %b  <b>%H:%M</b>")
	testing.expect_value(t, out, "[a]\nfmt = %a %d %b  <b>%H:%M</b>\n")
	testing.expect_value(t, ini_format_value("two\nlines"), "two lines")
}

@(test)
test_setting_normalize :: proc(t: ^testing.T) {
	find :: proc(section, key: string) -> Setting {
		for s in SETTINGS {if s.section == section && s.key == key {return s}}
		return {}
	}
	expect :: proc(t: ^testing.T, s: Setting, input, want: string, loc := #caller_location) {
		v, ok, _ := setting_normalize(s, input)
		testing.expect(t, ok, loc = loc)
		testing.expect_value(t, v, want, loc = loc)
	}
	reject :: proc(t: ^testing.T, s: Setting, input: string, loc := #caller_location) {
		_, ok, why := setting_normalize(s, input)
		testing.expect(t, !ok, loc = loc)
		testing.expect(t, why != "", loc = loc)
	}
	// Clamped to the same limits config_load uses.
	free := find("memory", "warn_free_percent")
	expect(t, free, "10", "10")
	expect(t, free, " 150 ", "99")
	expect(t, free, "-5", "0")
	reject(t, free, "lots")
	width := find("popup", "width")
	expect(t, width, "100", "480")
	expect(t, width, "5000", "2000")
	idle := find("timetracker", "idle_seconds")
	expect(t, idle, "1", "5")
	testing.expect_value(t, idle.ilim, LIM_IDLE_SECONDS)
	dim := find("lock", "dim")
	expect(t, dim, "0.5", "0.5")
	expect(t, dim, "2", "1")
	expect(t, dim, "0.350", "0.35")
	reject(t, dim, "dark")
	// Booleans, choices, colours.
	b := find("clocks", "use_24h")
	expect(t, b, "on", "true")
	expect(t, b, "No", "false")
	reject(t, b, "maybe")
	units := find("weather", "units")
	expect(t, units, "Imperial", "imperial")
	reject(t, units, "kelvin")
	col := find("lock", "background")
	expect(t, col, "#ABCDEF", "#abcdef")
	expect(t, col, "112233", "#112233")
	reject(t, col, "#12345")
	// Text: trimmed, one line.
	expect(t, find("weather", "location"), "  Ghent, Belgium \n", "Ghent, Belgium")

	// Every setting exists in the template (so reset has a default to fall
	// back on) and its default passes its own validation.
	defaults, _ := ini.load_map_from_string(DEFAULT_CONFIG, context.temp_allocator)
	for s in SETTINGS {
		_, has := defaults[s.section][s.key]
		testing.expectf(t, has, "[%s] %s is not in DEFAULT_CONFIG", s.section, s.key)
		_, ok, _ := setting_normalize(s, setting_default(s, defaults))
		testing.expectf(t, ok, "[%s] %s: default %q doesn't validate", s.section, s.key, setting_default(s, defaults))
		testing.expectf(t, setting_help(s) != "", "[%s] %s has no help", s.section, s.key)
	}
	testing.expect_value(t, setting_template_help("popup", "width"), "Total popup width in logical pixels.")
}

// The settings read what config_load reads: the renamed key counts until the
// new one is set, and reset (removing both) brings the default back.
@(test)
test_setting_raw_legacy :: proc(t: ^testing.T) {
	crit: Setting
	for s in SETTINGS {if s.key == "critical_percent" {crit = s}}
	idle: Setting
	for s in SETTINGS {if s.key == "idle_seconds" {idle = s}}
	defaults, _ := ini.load_map_from_string(DEFAULT_CONFIG, context.temp_allocator)

	m, _ := ini.load_map_from_string("[system]\nmemory_warn_percent = 70\n\n[timetracker]\nidle_minutes = 2\n", context.temp_allocator)
	raw, set, legacy := setting_raw(crit, m, defaults)
	testing.expect_value(t, raw, "70")
	testing.expect(t, set && legacy)
	raw, set, legacy = setting_raw(idle, m, defaults)
	testing.expect_value(t, raw, "120")
	testing.expect(t, set && legacy)

	m, _ = ini.load_map_from_string("[system]\nmemory_warn_percent = 70\n[memory]\ncritical_percent = 85\n", context.temp_allocator)
	raw, set, legacy = setting_raw(crit, m, defaults)
	testing.expect_value(t, raw, "85")
	testing.expect(t, set && !legacy)

	m, _ = ini.load_map_from_string("[popup]\n", context.temp_allocator)
	raw, set, legacy = setting_raw(crit, m, defaults)
	testing.expect_value(t, raw, "90")
	testing.expect(t, !set && !legacy)
}

// config_set_value / config_remove_value on a real file, read back by config_load.
@(test)
test_config_set_value_file :: proc(t: ^testing.T) {
	DIR :: "/tmp/wlperch-test-config-edit"
	dir := DIR
	os.make_directory_all(DIR + "/wlperch")
	defer os.remove_all(dir)
	old_xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	defer os.set_env("XDG_CONFIG_HOME", old_xdg)
	os.set_env("XDG_CONFIG_HOME", dir)
	saved := config
	defer config = saved

	ORIG :: "# mine\n[popup]\n# my width\nwidth = 900 \n\n[system]\nmemory_warn_percent = 70\n"
	_ = os.write_entire_file(DIR + "/wlperch/config.ini", ORIG)
	testing.expect(t, config_set_value("memory", "bar_warn_percent", "60"))
	testing.expect(t, config_set_value("popup", "width", "1000"))
	data, _ := os.read_entire_file(DIR + "/wlperch/config.ini", context.temp_allocator)
	testing.expect_value(t, string(data), "# mine\n[popup]\n# my width\nwidth = 1000\n\n[system]\nmemory_warn_percent = 70\n\n[memory]\nbar_warn_percent = 60\n")
	// Read back the way config_load does (not config_load itself: it also
	// rebuilds panels and projects, global state other tests own).
	defaults, _ := ini.load_map_from_string(DEFAULT_CONFIG, context.temp_allocator)
	m, _, _ := ini.load_map_from_path(DIR + "/wlperch/config.ini", context.temp_allocator)
	config_load_memory(m, defaults)
	testing.expect_value(t, parse_int_lim(config_value(m, defaults, "popup", "width"), LIM_POPUP_WIDTH), 1000)
	testing.expect_value(t, config.memory_bar_warn_pct, 60)
	testing.expect_value(t, config.memory_warn_pct, 70)

	testing.expect(t, config_remove_value("popup", "width"))
	m, _, _ = ini.load_map_from_path(DIR + "/wlperch/config.ini", context.temp_allocator)
	testing.expect_value(t, parse_int_lim(config_value(m, defaults, "popup", "width"), LIM_POPUP_WIDTH), 860)
	data, _ = os.read_entire_file(DIR + "/wlperch/config.ini", context.temp_allocator)
	testing.expect(t, strings.has_prefix(string(data), "# mine\n[popup]\n# my width\n\n[system]"))
}

// Every setting's group is laid out by the Settings tab; a group missing from
// SETTINGS_GROUPS would hide its rows.
@(test)
test_settings_groups_listed :: proc(t: ^testing.T) {
	for s in SETTINGS {
		found := false
		for g in SETTINGS_GROUPS {if g == s.group {found = true}}
		testing.expectf(t, found, "setting %s.%s: group %q is not in SETTINGS_GROUPS", s.section, s.key, s.group)
	}
}
