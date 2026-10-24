// Setup component "Bar": switches sway from waybar (or swaybar) to
// `wlperch bar`, and back.
//
// The sway config and config.d/* are rewritten with backups in
// ~/.local/share/wlperch/bar-backup/ (see config_switch.odin):
//   swaybar_command waybar          -> swaybar_command wlperch-bar
//   exec[_always] waybar …          -> exec[_always] wlperch-bar
//   bar { … } without a command     -> gets "swaybar_command wlperch-bar"
//   killall waybar && swaymsg reload -> swaymsg reload (sway restarts its bar)
// With no bar anywhere, a config.d/wlperch-bar.conf is written instead.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:sync"
import "core:time"

BAR_CONF_NAME :: "wlperch-bar.conf"

BAR_CONF :: `# wlperch bar (written by wlperch setup; "Switch back" removes it).
bar {
    swaybar_command wlperch-bar
}
`

BAR_SWITCH :: Config_Switch {
	backup  = "bar-backup",
	files   = bar_candidate_files,
	rewrite = bar_rewrite,
}

@(private = "file")
bar_switch_spec :: proc() -> Config_Switch {
	s := BAR_SWITCH
	s.new_path = fmt.tprintf("%s/sway/config.d/%s", sway_config_home(), BAR_CONF_NAME)
	s.new_text = BAR_CONF
	return s
}

@(private = "file")
bar_candidate_files :: proc() -> []string {return sway_candidate_files(scripts = false)[:]}

// The first word of a command ("waybar", "/usr/bin/waybar") is waybar.
@(private = "file")
is_waybar :: proc(word: string) -> bool {
	w := strings.trim(word, "'\"")
	return w == "waybar" || strings.has_suffix(w, "/waybar")
}

bar_rewrite :: proc(text: string, allocator := context.temp_allocator) -> (out: string, changes: int) {
	b := strings.builder_make(allocator)
	lines := strings.split_after(text, "\n", context.temp_allocator)
	depth := 0       // braces inside a bar { } block
	in_bar := false
	has_cmd := false // the open bar block names its program
	for line, li in lines {
		t := strings.trim_space(line)
		indent := line[:len(line) - len(strings.trim_left_space(line))]
		if strings.has_prefix(t, "#") || t == "" {
			strings.write_string(&b, line)
			continue
		}
		f := strings.fields(t, context.temp_allocator)
		// A bar block: note whether it names a program; add ours if not.
		if !in_bar && len(f) >= 2 && f[0] == "bar" && f[len(f) - 1] == "{" {
			in_bar, depth, has_cmd = true, 1, false
			// Look ahead for swaybar_command at this block's top level (only a
			// block we see the end of counts: switch_uses passes single lines).
			d := 1
			closed := false
			for l2 in lines[li + 1:] {
				t2 := strings.trim_space(l2)
				if strings.has_prefix(t2, "#") {continue}
				if strings.has_prefix(t2, "swaybar_command") && d == 1 {has_cmd = true}
				d += strings.count(t2, "{") - strings.count(t2, "}")
				if d <= 0 {
					closed = true
					break
				}
			}
			strings.write_string(&b, line)
			if closed && !has_cmd {
				fmt.sbprintf(&b, "%s    swaybar_command wlperch-bar\n", indent)
				changes += 1
			}
			continue
		}
		if in_bar {
			depth += strings.count(t, "{") - strings.count(t, "}")
			if depth <= 0 {in_bar = false}
		}
		switch {
		case len(f) >= 2 && f[0] == "swaybar_command" && is_waybar(f[1]):
			fmt.sbprintf(&b, "%sswaybar_command wlperch-bar\n", indent)
			changes += 1
			continue
		case len(f) == 3 && f[0] == "swaybar_command" && f[1] == "wlperch" && f[2] == "bar":
			// Written by an earlier setup: sway execs the whole string as one
			// program name, so it never started.
			fmt.sbprintf(&b, "%sswaybar_command wlperch-bar\n", indent)
			changes += 1
			continue
		case len(f) >= 2 && (f[0] == "exec" || f[0] == "exec_always") && is_waybar(f[1]):
			fmt.sbprintf(&b, "%s%s wlperch-bar\n", indent, f[0])
			changes += 1
			continue
		}
		// "killall waybar && swaymsg reload": sway restarts its bar itself, and
		// killall would fail (nothing called waybar) and stop the chain.
		out_line := line
		for pat in ([]string{"killall -q waybar && ", "killall waybar && ", "pkill -x waybar && ", "pkill waybar && ", "killall waybar; ", "pkill waybar; "}) {
			if strings.contains(out_line, pat) {
				out_line, _ = strings.replace_all(out_line, pat, "", context.temp_allocator)
				changes += 1
			}
		}
		strings.write_string(&b, out_line)
	}
	return strings.to_string(b), changes
}

bar_setup_check :: proc(p: ^Component, add_detail: proc(c: ^Component, line: string)) {
	spec := bar_switch_spec()
	entries, installed := switch_manifest(spec)
	uses, ours := switch_uses(spec, "wlperch-bar")
	switch {
	case installed:
		p.state = len(uses) > 0 ? .Outdated : .Installed
		add_detail(p, "sway runs wlperch's bar")
		for e in entries {add_detail(p, e[0] == "new" ? fmt.tprintf("added %s", e[1]) : fmt.tprintf("changed %s", e[1]))}
		for u in uses {add_detail(p, fmt.tprintf("still the old bar: %s", u))}
	case ours && len(uses) == 0:
		p.state = .Custom
		add_detail(p, "your sway config already runs wlperch bar")
	case len(uses) > 0:
		p.state = .Missing
		for u in uses {add_detail(p, u)}
	case:
		p.state = .Missing
		add_detail(p, fmt.tprintf("no bar configured; adds %s", spec.new_path))
	}
}

@(private = "file")
bar_done :: proc(ok: bool, msg: string) {
	sync.guard(&setup.mu)
	c := &setup.comps[.Bar]
	c.busy = false
	c.msg_ok = ok
	delete(c.message)
	c.message = strings.clone(msg)
	log.infof("setup bar: %s", msg)
}

// Our processes with this name in this Wayland session (another session's
// bar is none of our business).
@(private = "file")
session_pids :: proc(name: string) -> []posix.pid_t {
	out: [dynamic]posix.pid_t
	out.allocator = context.temp_allocator
	display := posix_getenv("WAYLAND_DISPLAY")
	want := strings.concatenate({"WAYLAND_DISPLAY=", display}, context.temp_allocator)
	me := posix.getuid()
	entries, err := os.read_all_directory_by_path("/proc", context.temp_allocator)
	if err != nil {return nil}
	for e in entries {
		pid, ok := strconv.parse_int(e.name)
		if !ok {continue}
		comm, cerr := os.read_entire_file(fmt.tprintf("/proc/%d/comm", pid), context.temp_allocator)
		if cerr != nil || strings.trim_space(string(comm)) != name {continue}
		st: posix.stat_t
		if posix.stat(fmt.ctprintf("/proc/%d", pid), &st) != .OK || st.st_uid != me {continue}
		env, eerr := os.read_entire_file(fmt.tprintf("/proc/%d/environ", pid), context.temp_allocator)
		if eerr != nil {continue}
		mine := false
		for kv in strings.split(string(env), "\x00", context.temp_allocator) {
			if kv == want {mine = true}
		}
		if mine {append(&out, posix.pid_t(pid))}
	}
	return out[:]
}

@(private = "file")
stop_all :: proc(name: string) {
	for pid in session_pids(name) {posix.kill(pid, .SIGTERM)}
}

bar_switch :: proc(apply: bool) {
	spec := bar_switch_spec()
	_, ours := switch_uses(spec, "wlperch-bar")
	changed, err := switch_apply(spec, allow_new = !ours)
	if err != "" {
		bar_done(false, err)
		return
	}
	if changed == 0 {
		bar_done(true, "nothing to change")
		return
	}
	if !apply {
		bar_done(true, "switched to wlperch's bar")
		return
	}
	// sway restarts the bars of its bar blocks on reload; a waybar started
	// with exec keeps running, so it goes, and ours starts if sway didn't.
	reloaded := sway_command("reload")
	time.sleep(time.Second)
	stop_all("waybar")
	if len(session_pids("wlperch-bar")) == 0 {launch_detached({self_exe(), "bar"})}
	bar_done(true, reloaded ? "switched to wlperch's bar (sway reloaded)" : "switched to wlperch's bar; reload sway to apply")
}

setup_install_bar :: proc() {bar_switch(apply = true)}

setup_restart_bar :: proc() {
	ok, msg := bar_restart()
	bar_done(ok, msg)
}

// Start a fresh bar with the running one's arguments (sway's "-b <id>"); it
// takes over from the old one (see bar_lock). The installed binary is
// preferred, so a restart also picks up a new build.
bar_restart :: proc() -> (ok: bool, msg: string) {
	args: [dynamic]string
	args.allocator = context.temp_allocator
	exe := fmt.tprintf("%s/.local/bin/wlperch", os.get_env("HOME", context.temp_allocator))
	if !os.exists(exe) {exe = self_exe()}
	append(&args, exe, "bar")
	old := session_pids("wlperch-bar")
	if len(old) > 0 {
		cmdline, _ := os.read_entire_file(fmt.tprintf("/proc/%d/cmdline", old[0]), context.temp_allocator)
		parts := strings.split(strings.trim_right(string(cmdline), "\x00"), "\x00", context.temp_allocator)
		for p, i in parts {
			if p == "-b" && i + 1 < len(parts) {append(&args, "-b", parts[i + 1])}
		}
	}
	if !launch_detached(args[:]) {return false, "couldn't start wlperch bar"}
	return true, len(old) > 0 ? "bar restarted" : "bar started"
}
setup_remove_bar :: proc() {bar_switch_back(apply = true)}

// apply: reload sway and swap the running bars (not in tests).
bar_switch_back :: proc(apply: bool) {
	spec := bar_switch_spec()
	kept, err := switch_back(spec)
	if err != "" {
		bar_done(false, err)
		return
	}
	reloaded := false
	if apply {
		reloaded = sway_command("reload")
		time.sleep(time.Second)
		stop_all("wlperch-bar")
		// A waybar started with exec (not a bar block) doesn't come back by itself.
		if len(session_pids("waybar")) == 0 && len(session_pids("swaybar")) == 0 {
			uses, _ := switch_uses(spec, "wlperch-bar")
			if len(uses) > 0 {launch_detached({"waybar"})}
		}
	}
	msg := reloaded ? "your bar is back (sway reloaded)" : "your bar is back; reload sway to apply"
	if kept > 0 {msg = fmt.tprintf("%s; your later edits are in %s/*.edited", msg, switch_backup_dir(spec))}
	bar_done(true, msg)
}
