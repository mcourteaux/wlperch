// sway -C output parsing and the wlperch.conf variant without clashing keys.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
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
test_sway_keys_file_text :: proc(t: ^testing.T) {
	keys := sway_keys_parse(SWAY_FILE, context.temp_allocator)
	if !testing.expect(t, len(keys) >= 6, "wlperch.conf has bindings") {return}
	// Defaults: the file as shipped, under setup's banner.
	testing.expect_value(t, sway_file_text(keys[:]), strings.concatenate({SWAY_BANNER, SWAY_FILE}, context.temp_allocator))
	// One active binding moved to another key, one switched off, one optional one on.
	moved, off, opt := -1, -1, -1
	for &k, i in keys {
		switch {
		case k.def_on && moved < 0: moved = i
		case k.def_on && off < 0:   off = i
		case !k.def_on && opt < 0:  opt = i
		}
	}
	if !testing.expect(t, moved >= 0 && off >= 0 && opt >= 0) {return}
	keys[moved].key = {}
	copy(keys[moved].key[:], "$mod+F12")
	keys[off].on = false
	keys[opt].on = true
	out := sway_file_text(keys[:])
	testing.expect(t, strings.contains(out, fmt.tprintf("\nbindsym %s$mod+F12 %s\n", keys[moved].flags, keys[moved].cmd)))
	testing.expect(t, strings.contains(out, fmt.tprintf("# bindsym %s%s %s\n", keys[off].flags, keys[off].def_key, keys[off].cmd)))
	testing.expect(t, strings.contains(out, fmt.tprintf("\nbindsym %s%s %s\n", keys[opt].flags, keys[opt].def_key, keys[opt].cmd)))
	// Parsing the result gives the same choices back.
	again := sway_keys_parse(out, context.temp_allocator)
	testing.expect_value(t, len(again), len(keys))
	for &k, i in again {
		if i >= len(keys) {break}
		testing.expect_value(t, k.cmd, keys[i].cmd)
		testing.expect_value(t, k.def_on, keys[i].on)
		testing.expect_value(t, k.def_key, sway_key_text(&keys[i]))
	}
}

@(test)
test_sway_keys_clashes :: proc(t: ^testing.T) {
	ov :: proc(key, to, from: string) -> string {
		return fmt.tprintf("00:00:00.010 [INFO] [sway/commands/bind.c:286] Overwriting binding '%s' for device '*' to `%s` from `%s`\n", key, to, from)
	}
	out := strings.concatenate({
		// the user's key, then the draft takes it
		ov("Mod4+p", "exec WLPERCH_KEYCHECK=4 wlperch track go", "exec rofi -show run"),
		// an older wlperch.conf took Mod4+o from the user, then the draft rebinds it
		ov("Mod4+o", "exec wlperch toggle --center", "exec wofi"),
		ov("Mod4+o", "exec WLPERCH_KEYCHECK=0 wlperch toggle --center", "exec wlperch toggle --center"),
		// two draft bindings on one key
		ov("Mod4+F5", "exec WLPERCH_KEYCHECK=6 wlperch track pin", "exec WLPERCH_KEYCHECK=5 wlperch track move"),
		// the user's own duplicate: not ours
		ov("Mod4+Return", "exec kitty", "exec foot"),
		// an older wlperch.conf on a key the draft moved away from: no clash
		ov("Mod4+equal", "exec wlperch toggle calc --center", "exec firefox"),
	}, context.temp_allocator)
	clash := make(map[int]string, context.temp_allocator)
	sway_keys_clashes(out, &clash)
	testing.expect_value(t, clash[4], "exec rofi -show run")
	testing.expect_value(t, clash[0], "exec wofi")
	testing.expect(t, strings.contains(clash[6], "another wlperch key: exec wlperch track move"))
	testing.expect(t, strings.contains(clash[5], "another wlperch key: exec wlperch track pin"))
	testing.expect_value(t, len(clash), 4) // not the user's own duplicate, not the old file's key
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
	old_data := strings.clone(os.get_env("XDG_DATA_HOME", context.temp_allocator), context.temp_allocator)
	os.set_env("XDG_DATA_HOME", DIR + "/data") // the key choices file
	sway_keys.loaded = false
	os.unset_env("SWAYSOCK") // the default config under XDG_CONFIG_HOME, not the running sway's
	defer {
		if old_xdg != "" {os.set_env("XDG_CONFIG_HOME", old_xdg)} else {os.unset_env("XDG_CONFIG_HOME")}
		if old_sock != "" {os.set_env("SWAYSOCK", old_sock)}
		if old_data != "" {os.set_env("XDG_DATA_HOME", old_data)} else {os.unset_env("XDG_DATA_HOME")}
		sway_keys.loaded = false
		clear(&sway_keys.list)
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

	// The draft check: the clashing row is found, and moving it fixes it.
	sway_keys_load()
	sway_keys_check()
	row := -1
	for &k, i in sway_keys.list {if k.on && k.def_key == key {row = i}}
	if !testing.expect(t, row >= 0) {return}
	testing.expect_value(t, sway_keys.clash[row], "exec rofi -show run")
	testing.expect_value(t, sway_keys_clash_count(), 1)
	k := &sway_keys.list[row]
	k.key = {}
	copy(k.key[:], "$mod+F9")
	sway_keys_check()
	testing.expect_value(t, sway_keys_clash_count(), 0)
	copy(k.key[:], key) // back to the clashing default for the install test below
	k.key[len(key)] = 0

	setup_install_sway()
	testing.expect(t, !os.exists(DIR + "/sway/config.d/wlperch.conf"), "backed out")
	after, _ := os.read_entire_file(DIR + "/sway/config", context.temp_allocator)
	testing.expect_value(t, string(after), user)
	testing.expect(t, sway_keys_clash_count() > 0, "the editor shows the clash")
	testing.expect(t, strings.contains(setup.comps[.Sway].message, "already bound"))

	setup_install_sway_skipping()
	data, err := os.read_entire_file(DIR + "/sway/config.d/wlperch.conf", context.temp_allocator)
	testing.expect(t, err == nil, "installed without the keys")
	testing.expect(t, strings.has_prefix(string(data), SWAY_BANNER + "# Key bindings as chosen in wlperch setup."))
	testing.expect_value(t, len(sway_config_check().conflicts), 0)
	testing.expect(t, setup.comps[.Sway].msg_ok)
}

// A copy of wlperch.conf under another name, symlinked from elsewhere (a
// dotfiles repo): setup adopts it, Update writes through the link, and a key
// changed by hand in it is kept.
@(test)
test_sway_adopts_renamed_symlinked_file :: proc(t: ^testing.T) {
	DIR :: "/tmp/wlperch-test/swayadopt"
	os.remove_all(DIR)
	os.make_directory_all(DIR + "/cfg/sway/config.d")
	os.make_directory_all(DIR + "/dotfiles")
	defer os.remove_all(DIR)
	old_xdg := strings.clone(os.get_env("XDG_CONFIG_HOME", context.temp_allocator), context.temp_allocator)
	old_data := strings.clone(os.get_env("XDG_DATA_HOME", context.temp_allocator), context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", DIR + "/cfg")
	os.set_env("XDG_DATA_HOME", DIR + "/data")
	sway_keys.loaded = false
	defer {
		if old_xdg != "" {os.set_env("XDG_CONFIG_HOME", old_xdg)} else {os.unset_env("XDG_CONFIG_HOME")}
		if old_data != "" {os.set_env("XDG_DATA_HOME", old_data)} else {os.unset_env("XDG_DATA_HOME")}
		sway_keys.loaded = false
		clear(&sway_keys.list)
	}
	// The template with its first active binding moved to $mod+F9 by hand.
	moved_cmd := ""
	b := strings.builder_make(context.temp_allocator)
	rest := SWAY_FILE
	for line in strings.split_lines_iterator(&rest) {
		f := strings.fields(strings.trim_space(line), context.temp_allocator)
		if moved_cmd == "" && len(f) >= 3 && f[0] == "bindsym" && !strings.has_prefix(f[1], "--") {
			moved_cmd = strings.join(f[2:], " ", context.temp_allocator)
			fmt.sbprintf(&b, "bindsym $mod+F9 %s\n", moved_cmd)
			continue
		}
		fmt.sbprintf(&b, "%s\n", line)
	}
	if !testing.expect(t, moved_cmd != "") {return}
	target := DIR + "/dotfiles/45-wlperch.conf"
	link := DIR + "/cfg/sway/config.d/45-wlperch.conf"
	_ = os.write_entire_file(target, strings.to_string(b))
	posix.symlink(cstring(DIR + "/dotfiles/45-wlperch.conf"), cstring(DIR + "/cfg/sway/config.d/45-wlperch.conf"))

	testing.expect_value(t, sway_file(), link)
	sway_keys_load()
	found := false
	for &k in sway_keys.list {
		if k.cmd == moved_cmd {
			found = true
			testing.expect_value(t, sway_key_text(&k), "$mod+F9")
		}
	}
	testing.expect(t, found)

	// What Update writes, through the link (the link stays a link).
	testing.expect(t, write_through(sway_file(), sway_file_text(sway_keys.list[:])))
	st: posix.stat_t
	posix.lstat(cstring(DIR + "/cfg/sway/config.d/45-wlperch.conf"), &st)
	testing.expect(t, posix.S_ISLNK(st.st_mode), "still a symlink")
	data, _ := os.read_entire_file(target, context.temp_allocator)
	testing.expect(t, strings.has_prefix(string(data), SWAY_BANNER))
	testing.expect(t, strings.contains(string(data), fmt.tprintf("bindsym $mod+F9 %s", moved_cmd)))
	testing.expect(t, is_wlperch_sway_file(string(data)))
}
