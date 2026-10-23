// Setup component "Launcher": switches the sway key bindings of rofi, wofi,
// fuzzel, tofi, bemenu, dmenu and j4-dmenu-desktop over to wlperch's launcher
// panels, and back.
//
// Only app / command launching is switched (rofi -show drun|run|combi|calc,
// wofi --show drun|run, …); dmenu-style uses (`… | wofi --dmenu`), window
// switchers and emoji pickers stay. The sway config and config.d/* are
// rewritten with backups in ~/.local/share/wlperch/launcher-backup/ (see
// config_switch.odin); with no launcher bound anywhere, a
// config.d/wlperch-launcher.conf with Mod+D / Mod+Shift+D is written instead.
package main

import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"

MENU_CONF_NAME :: "wlperch-launcher.conf"

MENU_CONF :: `# wlperch launcher (written by wlperch setup; "Switch back" removes it).
# Apps, panels and sums; Shift: run a command.
bindsym $mod+d exec wlperch toggle launch --center
bindsym $mod+Shift+d exec wlperch toggle run --center
`

MENU_LAUNCH :: "wlperch toggle launch --center"
MENU_RUN :: "wlperch toggle run --center"
MENU_CALC :: "wlperch toggle calc --center"

MENU_SWITCH :: Config_Switch {
	backup  = "launcher-backup",
	files   = menu_candidate_files,
	rewrite = menu_rewrite,
}

@(private = "file")
menu_switch_spec :: proc() -> Config_Switch {
	s := MENU_SWITCH
	s.new_path = fmt.tprintf("%s/sway/config.d/%s", sway_config_home(), MENU_CONF_NAME)
	s.new_text = MENU_CONF
	return s
}

@(private = "file")
menu_candidate_files :: proc() -> []string {return sway_candidate_files(scripts = false)[:]}

@(private = "file")
is_word :: proc(c: u8) -> bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.'
}

// What a launcher invocation does, from its program and arguments: the
// wlperch command that replaces it, or "" (dmenu use, window switcher, …).
menu_replacement :: proc(prog: string, args: []string) -> string {
	mode := ""
	dmenu := false
	for a, i in args {
		switch {
		case a == "-dmenu" || a == "--dmenu" || a == "-d" && prog == "fuzzel":
			dmenu = true
		case a == "-show" || a == "--show" || a == "-S":
			if i + 1 < len(args) {mode = args[i + 1]}
		case strings.has_prefix(a, "--show="):
			mode = a[len("--show="):]
		}
	}
	if dmenu {return ""}
	switch prog {
	case "rofi":
		switch mode {
		case "drun", "combi": return MENU_LAUNCH
		case "run":           return MENU_RUN
		case "calc":          return MENU_CALC
		}
	case "wofi":
		switch mode {
		case "drun": return MENU_LAUNCH
		case "run":  return MENU_RUN
		}
	case "fuzzel", "tofi-drun", "j4-dmenu-desktop":
		return MENU_LAUNCH
	case "tofi-run", "bemenu-run", "dmenu_run", "wmenu-run":
		return MENU_RUN
	}
	return ""
}

@(private = "file")
MENU_PROGS := [?]string{"rofi", "wofi", "fuzzel", "tofi-drun", "tofi-run", "j4-dmenu-desktop", "bemenu-run", "dmenu_run", "wmenu-run"}

// Rewrite launcher commands in sway config text:
//   set $menu wofi --show drun        -> set $menu wlperch toggle launch --center
//   bindsym $mod+d exec rofi -show run -> … exec wlperch toggle run --center
// Comment lines, pkill/killall/pgrep commands and dmenu-style uses stay.
menu_rewrite :: proc(text: string, allocator := context.temp_allocator) -> (out: string, changes: int) {
	b := strings.builder_make(allocator)
	for line in strings.split_after(text, "\n", context.temp_allocator) {
		t := strings.trim_left_space(line)
		if strings.has_prefix(t, "#") {
			strings.write_string(&b, line)
			continue
		}
		pos := 0
		i := 0
		for i < len(line) {
			// The next word that names a launcher.
			if !is_word(line[i]) && line[i] != '/' {
				i += 1
				continue
			}
			start := i
			for i < len(line) && (is_word(line[i]) || line[i] == '/') {i += 1}
			word := line[start:i]
			prog := word[strings.last_index_byte(word, '/') + 1:]
			if !slice_has(MENU_PROGS[:], prog) {continue}
			// The shell command it belongs to: from the last separator.
			seg := line[:start]
			quote: u8 = 0
			for k in 0 ..< len(seg) {
				c := seg[k]
				if quote != 0 {
					if c == quote {quote = 0}
				} else if c == '\'' || c == '"' {
					quote = c
				}
			}
			piped := false
			if k := strings.last_index_any(seg, "';&|(\""); k >= 0 {
				piped = seg[k] == '|' && (k == 0 || seg[k - 1] != '|')
				seg = seg[k + 1:]
			}
			if piped || strings.contains(seg, "pkill") || strings.contains(seg, "killall") || strings.contains(seg, "pgrep") {continue}
			// Its arguments: to the closing quote (inside one) or a separator,
			// skipping over quoted arguments.
			j := i
			for j < len(line) {
				c := line[j]
				if quote != 0 && c == quote {break}
				if quote == 0 && (c == '\'' || c == '"') {
					if e := strings.index_byte(line[j + 1:], c); e >= 0 {
						j += e + 2
						continue
					}
				}
				if strings.index_byte(";&|)\\\n", c) >= 0 {break}
				j += 1
			}
			args := strings.fields(line[i:j], context.temp_allocator)
			for &a in args {a = strings.trim(a, "'\"")}
			rep := menu_replacement(prog, args)
			if rep == "" {continue}
			strings.write_string(&b, line[pos:start])
			strings.write_string(&b, rep)
			// Keep the space before a separator ("… drun ; exec x").
			tail := line[i:j]
			if ws := len(tail) - len(strings.trim_right_space(tail)); ws > 0 && j < len(line) && line[j] != '\n' {
				strings.write_string(&b, tail[len(tail) - ws:])
			}
			pos = j
			i = j
			changes += 1
		}
		strings.write_string(&b, line[pos:])
	}
	return strings.to_string(b), changes
}

@(private = "file")
slice_has :: proc(s: []string, v: string) -> bool {
	for x in s {if x == v {return true}}
	return false
}

menu_setup_check :: proc(p: ^Component, add_detail: proc(c: ^Component, line: string)) {
	spec := menu_switch_spec()
	entries, installed := switch_manifest(spec)
	uses, ours := switch_uses(spec, "wlperch toggle launch")
	switch {
	case installed:
		p.state = len(uses) > 0 ? .Outdated : .Installed
		add_detail(p, "your launcher keys open wlperch's launcher")
		for e in entries {add_detail(p, e[0] == "new" ? fmt.tprintf("added %s", e[1]) : fmt.tprintf("changed %s", e[1]))}
		for u in uses {add_detail(p, fmt.tprintf("still the old launcher: %s", u))}
	case len(uses) > 0:
		p.state = .Missing
		for u in uses {add_detail(p, u)}
	case ours:
		p.state = .Custom
		add_detail(p, "your sway config already opens wlperch's launcher")
	case:
		p.state = .Missing
		add_detail(p, fmt.tprintf("no launcher bound; adds %s (Mod+D, Mod+Shift+D)", spec.new_path))
	}
}

@(private = "file")
menu_done :: proc(ok: bool, msg: string) {
	sync.guard(&setup.mu)
	c := &setup.comps[.Menu]
	c.busy = false
	c.msg_ok = ok
	delete(c.message)
	c.message = strings.clone(msg)
	log.infof("setup launcher: %s", msg)
}

setup_install_menu :: proc() {menu_switch(apply = true)}
setup_remove_menu :: proc() {menu_switch_back(apply = true)}

menu_switch :: proc(apply: bool) {
	spec := menu_switch_spec()
	_, ours := switch_uses(spec, "wlperch toggle launch")
	changed, err := switch_apply(spec, allow_new = !ours)
	if err != "" {
		menu_done(false, err)
		return
	}
	if changed == 0 {
		menu_done(true, "nothing to change")
		return
	}
	reloaded := apply && sway_command("reload")
	menu_done(true, reloaded ? "switched to wlperch's launcher (sway reloaded)" : "switched to wlperch's launcher; reload sway to apply")
}

menu_switch_back :: proc(apply: bool) {
	spec := menu_switch_spec()
	kept, err := switch_back(spec)
	if err != "" {
		menu_done(false, err)
		return
	}
	reloaded := apply && sway_command("reload")
	msg := reloaded ? "your launcher is back (sway reloaded)" : "your launcher is back; reload sway to apply"
	if kept > 0 {msg = fmt.tprintf("%s; your later edits are in %s/*.edited", msg, switch_backup_dir(spec))}
	menu_done(true, msg)
}

// Open the launcher, to try it.
setup_open_menu :: proc() {
	ok := ipc_send("show launch --center")
	menu_done(ok, ok ? "opened" : "the background service isn't running")
}
