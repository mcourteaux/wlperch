// Setup component "Dark / light": switches the sway key bindings of a theme
// script (…/switch-theme.sh night, toggle-theme, darkman) over to
// `wlperch theme dark|light|toggle`, and back.
//
// A script called with a theme name whose settings live next to it in
// ../themes/<name>.json (gtkTheme, kittyTheme, nvimTheme, wallpaper,
// vsCodeTheme…) has those copied into the empty keys of [theme.dark] /
// [theme.light] in wlperch's config, so nothing it switched is lost. The
// sway files and the config are backed up in
// ~/.local/share/wlperch/theme-backup/ (see config_switch.odin); with no
// theme binding anywhere, config.d/wlperch-theme.conf binds Mod+Shift+T.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"

THEME_CONF_NAME :: "wlperch-theme.conf"

THEME_CONF :: `# wlperch dark / light switch (written by wlperch setup; "Switch back" removes it).
bindsym $mod+Shift+t exec wlperch theme toggle
`

THEME_SWITCH :: Config_Switch {
	backup  = "theme-backup",
	files   = theme_candidate_files,
	rewrite = theme_rewrite,
}

@(private = "file")
theme_switch_spec :: proc() -> Config_Switch {
	s := THEME_SWITCH
	s.new_path = fmt.tprintf("%s/sway/config.d/%s", sway_config_home(), THEME_CONF_NAME)
	s.new_text = THEME_CONF
	return s
}

// wlperch's config first: switch_back restores in reverse, so the sway
// files (which say what to import) are back before the config is compared.
@(private = "file")
theme_candidate_files :: proc() -> []string {
	out: [dynamic]string
	out.allocator = context.temp_allocator
	cp := config_path()
	append(&out, strings.clone(cp, context.temp_allocator))
	delete(cp)
	append(&out, ..sway_candidate_files(scripts = false)[:])
	return out[:]
}

// A theme command in a sway line: what follows `exec`, and the wlperch mode
// that replaces it ("" = not one).
Theme_Bind :: struct {
	start, end: int, // the command, in the line
	mode:       string, // dark | light | toggle
	script:     string, // the program, ~ expanded
	arg:        string, // its first argument
}

theme_bind_parse :: proc(line: string) -> (b: Theme_Bind, ok: bool) {
	t := strings.trim_left_space(line)
	if strings.has_prefix(t, "#") {return}
	i := strings.index(line, "exec ")
	if i < 0 {return}
	start := i + len("exec ")
	for strings.has_prefix(line[start:], "--no-startup-id ") {start += len("--no-startup-id ")}
	for start < len(line) && line[start] == ' ' {start += 1}
	end := len(strings.trim_right_space(line))
	cmd := line[start:end]
	if strings.contains_any(cmd, ";&|") {return}
	f := strings.fields(cmd, context.temp_allocator)
	if len(f) == 0 {return}
	prog := f[0][strings.last_index_byte(f[0], '/') + 1:]
	if prog == "wlperch" {return}
	args := strings.to_lower(strings.join(f[1:], " ", context.temp_allocator), context.temp_allocator)
	switch {
	case prog == "darkman":
		switch {
		case strings.contains(args, "toggle"): b.mode = "toggle"
		case strings.contains(args, "dark"):   b.mode = "dark"
		case strings.contains(args, "light"):  b.mode = "light"
		}
	case strings.contains(strings.to_lower(prog, context.temp_allocator), "theme"):
		switch {
		case strings.contains(args, "dark") || strings.contains(args, "night"): b.mode = "dark"
		case strings.contains(args, "light") || strings.contains(args, "day"):  b.mode = "light"
		case len(f) == 1 || strings.contains(args, "toggle"):                   b.mode = "toggle"
		}
	}
	if b.mode == "" {return}
	b.start, b.end = start, end
	b.script = f[0]
	if strings.has_prefix(b.script, "~/") {
		b.script = strings.concatenate({os.get_env("HOME", context.temp_allocator), b.script[1:]}, context.temp_allocator)
	}
	if len(f) > 1 {b.arg = f[1]}
	return b, true
}

// Theme settings a bound script reads from ../themes/<arg>.json, as
// wlperch [theme.<mode>] keys.
@(private = "file")
Theme_Import :: struct {
	mode: string,
	keys: [dynamic][2]string,
}

@(private = "file")
theme_imports :: proc() -> []Theme_Import {
	out: [dynamic]Theme_Import
	out.allocator = context.temp_allocator
	for f in sway_candidate_files(scripts = false) {
		data, err := os.read_entire_file(f, context.temp_allocator)
		if err != nil {continue}
		for line in strings.split_lines(string(data), context.temp_allocator) {
			b, ok := theme_bind_parse(line)
			if !ok || b.arg == "" || b.mode == "toggle" {continue}
			dir := b.script[:max(strings.last_index_byte(b.script, '/'), 0)]
			path := fmt.tprintf("%s/../themes/%s.json", dir, b.arg)
			jdata, jerr := os.read_entire_file(path, context.temp_allocator)
			if jerr != nil {continue}
			v, jok := jparse(string(jdata))
			if !jok {continue}
			imp := Theme_Import{mode = b.mode}
			imp.keys.allocator = context.temp_allocator
			add :: proc(imp: ^Theme_Import, key, val: string) {
				if val != "" {append(&imp.keys, [2]string{key, val})}
			}
			if w := jstr(jobj(v, "wallpaper")); w != "" {add(&imp, "wallpaper", fmt.tprintf("~/Pictures/wallpapers/%s", w))}
			add(&imp, "kitty_theme", jstr(jobj(v, "kittyTheme")))
			add(&imp, "nvim_colorscheme", jstr(jobj(v, "nvimTheme")))
			add(&imp, "kvantum_theme", jstr(jobj(v, "kvantumTheme")))
			add(&imp, "vscode_theme", jstr(jobj(v, "vsCodeTheme")))
			if len(imp.keys) > 0 {append(&out, imp)}
		}
	}
	return out[:]
}

// wlperch's config: fill empty [theme.dark] / [theme.light] keys from the
// imports (adding the sections when missing). Sway text: theme commands ->
// wlperch theme <mode>.
theme_rewrite :: proc(text: string, allocator := context.temp_allocator) -> (out: string, changes: int) {
	// (switch_uses passes single lines: a lone "[popup]" isn't the config.)
	if strings.count(text, "\n") > 1 && (strings.has_prefix(text, "[popup]") || strings.contains(text, "\n[popup]")) {
		return theme_config_import(text, theme_imports(), allocator)
	}
	b := strings.builder_make(allocator)
	for line in strings.split_after(text, "\n", context.temp_allocator) {
		tb, ok := theme_bind_parse(line)
		if !ok {
			strings.write_string(&b, line)
			continue
		}
		strings.write_string(&b, line[:tb.start])
		fmt.sbprintf(&b, "wlperch theme %s", tb.mode)
		strings.write_string(&b, line[tb.end:])
		changes += 1
	}
	return strings.to_string(b), changes
}

@(private = "file")
theme_config_import :: proc(text: string, imports: []Theme_Import, allocator := context.temp_allocator) -> (out: string, changes: int) {
	if len(imports) == 0 {return strings.clone(text, allocator), 0}
	lines := strings.split_after(text, "\n", context.temp_allocator)
	result := strings.builder_make(allocator)
	for imp in imports {
		section := fmt.tprintf("[theme.%s]", imp.mode)
		// Where the section is and which keys it sets.
		sec_line, sec_end := -1, len(lines)
		for l, i in lines {
			t := strings.trim_space(l)
			if sec_line < 0 {
				if t == section {sec_line = i}
			} else if strings.has_prefix(t, "[") {
				sec_end = i
				break
			}
		}
		missing: [dynamic][2]string
		missing.allocator = context.temp_allocator
		for kv in imp.keys {
			found := false
			if sec_line >= 0 {
				for i in sec_line + 1 ..< sec_end {
					t := strings.trim_space(lines[i])
					eq := strings.index_byte(t, '=')
					if eq < 0 || strings.trim_space(t[:eq]) != kv[0] {continue}
					found = true
					if strings.trim_space(t[eq + 1:]) == "" {
						lines[i] = fmt.tprintf("%s = %s\n", kv[0], kv[1])
						changes += 1
					}
				}
			}
			if !found {append(&missing, kv)}
		}
		if len(missing) == 0 {continue}
		add := strings.builder_make(context.temp_allocator)
		if sec_line < 0 {
			if n := len(lines); n > 0 && lines[n - 1] != "" && !strings.has_suffix(lines[n - 1], "\n") {lines[n - 1] = strings.concatenate({lines[n - 1], "\n"}, context.temp_allocator)}
			fmt.sbprintf(&add, "\n# Imported by wlperch setup from your theme script.\n%s\n", section)
		}
		for kv in missing {fmt.sbprintf(&add, "%s = %s\n", kv[0], kv[1])}
		changes += len(missing)
		// After the section's last setting (or at the end for a new one).
		at := sec_line < 0 ? len(lines) : sec_end
		for at > sec_line + 1 && sec_line >= 0 && strings.trim_space(lines[at - 1]) == "" {at -= 1}
		grown: [dynamic]string
		grown.allocator = context.temp_allocator
		append(&grown, ..lines[:at])
		append(&grown, strings.to_string(add))
		append(&grown, ..lines[at:])
		lines = grown[:]
	}
	for l in lines {strings.write_string(&result, l)}
	return strings.to_string(result), changes
}

theme_setup_check :: proc(p: ^Component, add_detail: proc(c: ^Component, line: string)) {
	spec := theme_switch_spec()
	entries, installed := switch_manifest(spec)
	uses, ours := switch_uses(spec, "wlperch theme")
	switch {
	case installed:
		p.state = len(uses) > 0 ? .Outdated : .Installed
		add_detail(p, "your theme keys run wlperch theme")
		for e in entries {add_detail(p, e[0] == "new" ? fmt.tprintf("added %s", e[1]) : fmt.tprintf("changed %s", e[1]))}
		for u in uses {add_detail(p, fmt.tprintf("still the old switch: %s", u))}
	case len(uses) > 0:
		p.state = .Missing
		for u in uses {add_detail(p, u)}
		for imp in theme_imports() {
			names := make([dynamic]string, 0, len(imp.keys), context.temp_allocator)
			for kv in imp.keys {append(&names, kv[0])}
			add_detail(p, fmt.tprintf("copies %s settings into [theme.%s]: %s", imp.mode, imp.mode, strings.join(names[:], ", ", context.temp_allocator)))
		}
	case ours:
		p.state = .Custom
		add_detail(p, "your sway config already runs wlperch theme")
	case:
		p.state = .Missing
		add_detail(p, fmt.tprintf("no theme switch bound; adds %s (Mod+Shift+T)", spec.new_path))
	}
}

@(private = "file")
theme_done :: proc(ok: bool, msg: string) {
	sync.guard(&setup.mu)
	c := &setup.comps[.Theme]
	c.busy = false
	c.msg_ok = ok
	delete(c.message)
	c.message = strings.clone(msg)
	log.infof("setup theme: %s", msg)
}

setup_install_theme :: proc() {theme_switch_keys(apply = true)}
setup_remove_theme :: proc() {theme_switch_keys_back(apply = true)}

// apply: restart the daemon (re-reads the imported settings) and reload sway.
theme_switch_keys :: proc(apply: bool) {
	spec := theme_switch_spec()
	_, ours := switch_uses(spec, "wlperch theme")
	changed, err := switch_apply(spec, allow_new = !ours)
	if err != "" {
		theme_done(false, err)
		return
	}
	if changed == 0 {
		theme_done(true, "nothing to change")
		return
	}
	if apply {ipc_send("restart")}
	reloaded := apply && sway_command("reload")
	theme_done(true, reloaded ? "switched to wlperch theme (sway reloaded)" : "switched to wlperch theme; reload sway to apply")
}

theme_switch_keys_back :: proc(apply: bool) {
	spec := theme_switch_spec()
	kept, err := switch_back(spec)
	if err != "" {
		theme_done(false, err)
		return
	}
	if apply {ipc_send("restart")}
	reloaded := apply && sway_command("reload")
	msg := reloaded ? "your theme switch is back (sway reloaded)" : "your theme switch is back; reload sway to apply"
	if kept > 0 {msg = fmt.tprintf("%s; your later edits are in %s/*.edited", msg, switch_backup_dir(spec))}
	theme_done(true, msg)
}

setup_toggle_theme :: proc() {
	ok := ipc_send("theme toggle")
	theme_done(ok, ok ? "switched" : "the background service isn't running")
}
