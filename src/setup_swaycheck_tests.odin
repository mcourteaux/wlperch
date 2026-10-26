// sway -C output parsing and the wlperch.conf variant without clashing keys.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_sway_check_parse :: proc(t: ^testing.T) {
	out := `00:00:00.010 [INFO] [sway/commands/bind.c:286] Overwriting binding 'Mod4+p' for device '*' to ` + "`exec wlperch track go`" + ` from ` + "`exec rofi -show run`" + `
00:00:00.011 [INFO] [sway/commands/bind.c:286] Overwriting binding 'Mod4+Return' for device '*' to ` + "`exec kitty`" + ` from ` + "`exec foot`" + `
00:00:00.012 [INFO] [sway/commands/bind.c:286] Overwriting binding 'Mod4+o' for device '*' to ` + "`exec wofi`" + ` from ` + "`exec wlperch toggle --center`" + `
00:00:00.013 [ERROR] [sway/config.c:830] Error on line 3 'bogus here': Unknown/invalid command 'bogus' (/home/u/.config/sway/config.d/wlperch.conf)
00:00:00.014 [ERROR] [sway/config.c:830] Error on line 9 'old thing': Unknown/invalid command 'old' (/home/u/.config/sway/config)
00:00:00.015 [ERROR] [sway/config.c:440] Error(s) loading config!`
	c := sway_check_parse(out)
	// The user's own duplicate (Return) isn't ours; both directions of ours are.
	testing.expect_value(t, len(c.conflicts), 2)
	if len(c.conflicts) == 2 {
		testing.expect_value(t, c.conflicts[0].key, "Mod4+p")
		testing.expect_value(t, c.conflicts[0].ours, "exec wlperch track go")
		testing.expect_value(t, c.conflicts[0].theirs, "exec rofi -show run")
		testing.expect_value(t, c.conflicts[1].key, "Mod4+o")
		testing.expect_value(t, c.conflicts[1].ours, "exec wlperch toggle --center")
		testing.expect_value(t, c.conflicts[1].theirs, "exec wofi")
	}
	// Only the error in wlperch's file counts.
	testing.expect_value(t, len(c.errors), 1)
	testing.expect(t, strings.contains(sway_check_text(c), "Mod4+p is already bound in your sway config (exec rofi -show run)"))
}

@(test)
test_sway_file_without_keys :: proc(t: ^testing.T) {
	testing.expect_value(t, sway_file_text(nil), SWAY_FILE)
	// A command wlperch.conf binds, read from the file itself.
	cmd := ""
	text := SWAY_FILE
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "bindsym") && strings.contains(l, "wlperch") {
			f := strings.fields(l, context.temp_allocator)
			if len(f) >= 3 {cmd = strings.join(f[2:], " ", context.temp_allocator)}
			break
		}
	}
	if !testing.expect(t, cmd != "", "wlperch.conf binds a wlperch command") {return}
	out := sway_file_text({cmd})
	testing.expect(t, strings.has_prefix(out, SWAY_SKIP_MARK))
	skips := sway_file_skips(out)
	testing.expect_value(t, len(skips), 1)
	if len(skips) == 1 {testing.expect_value(t, skips[0], cmd)}
	// Recognised as ours (Installed, not Outdated).
	testing.expect_value(t, sway_file_text(sway_file_skips(out)), out)
	// The binding is commented out, nothing else is.
	commented := 0
	rest := out
	for line in strings.split_lines_iterator(&rest) {if strings.has_prefix(line, "# ") && strings.has_suffix(line, cmd) {commented += 1}}
	testing.expect(t, commented >= 1)
}

// End to end with the real sway -C: a config that already binds a key
// wlperch.conf binds is left as it was, and installing without those keys
// works. Skipped when sway isn't installed.
@(test)
test_sway_install_backs_out_on_conflict :: proc(t: ^testing.T) {
	if !os.exists("/usr/bin/sway") && !os.exists("/usr/local/bin/sway") {return}
	DIR :: "/tmp/wlperch-test/swaycheck"
	os.remove_all(DIR)
	os.make_directory_all(DIR + "/sway/config.d")
	defer os.remove_all(DIR)
	old_xdg := strings.clone(os.get_env("XDG_CONFIG_HOME", context.temp_allocator), context.temp_allocator)
	old_sock := strings.clone(os.get_env("SWAYSOCK", context.temp_allocator), context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", DIR)
	os.unset_env("SWAYSOCK") // the default config under XDG_CONFIG_HOME, not the running sway's
	defer {
		if old_xdg != "" {os.set_env("XDG_CONFIG_HOME", old_xdg)} else {os.unset_env("XDG_CONFIG_HOME")}
		if old_sock != "" {os.set_env("SWAYSOCK", old_sock)}
	}
	// A key wlperch.conf binds, bound to something else by "the user".
	key := ""
	text := SWAY_FILE
	for line in strings.split_lines_iterator(&text) {
		f := strings.fields(strings.trim_space(line), context.temp_allocator)
		if len(f) >= 3 && f[0] == "bindsym" && strings.contains(line, "wlperch") {key = f[1]; break}
	}
	if !testing.expect(t, key != "") {return}
	user := fmt.tprintf("set $mod Mod4\nbindsym %s exec rofi -show run\ninclude %s/sway/config.d/*\n", key, DIR)
	_ = os.write_entire_file(DIR + "/sway/config", user)

	setup_install_sway()
	testing.expect(t, !os.exists(DIR + "/sway/config.d/wlperch.conf"), "backed out")
	after, _ := os.read_entire_file(DIR + "/sway/config", context.temp_allocator)
	testing.expect_value(t, string(after), user)
	testing.expect(t, len(sway_pending_skip) > 0, "offers to leave the keys out")
	testing.expect(t, strings.contains(setup.comps[.Sway].message, "already bound"))

	setup_install_sway_skipping()
	data, err := os.read_entire_file(DIR + "/sway/config.d/wlperch.conf", context.temp_allocator)
	testing.expect(t, err == nil, "installed without the keys")
	testing.expect(t, strings.has_prefix(string(data), SWAY_SKIP_MARK))
	testing.expect_value(t, len(sway_config_check().conflicts), 0)
	testing.expect(t, setup.comps[.Sway].msg_ok)
	for x in sway_pending_skip {delete(x)}
	delete(sway_pending_skip)
	sway_pending_skip = nil
}
