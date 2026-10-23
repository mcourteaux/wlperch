// Setup component "Lock screen": switches swayidle / the lock key binding
// from swaylock to `wlperch lock`, and back.
//
// Switching rewrites the swaylock commands in the sway config, config.d/*,
// scripts next to them (~/.config/sway/*.sh) and swayidle's own config, with
// backups in ~/.local/share/wlperch/lock-backup/ (see config_switch.odin).
// With no swaylock anywhere, a config.d/wlperch-lock.conf with swayidle + a
// key binding is written instead.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

LOCK_CONF_NAME :: "wlperch-lock.conf"

LOCK_CONF :: `# wlperch lock screen (written by wlperch setup; "Switch back" removes it).
# Lock after 5 minutes idle and before sleep; screens off a minute later.
exec swayidle -w timeout 300 'wlperch lock -f' timeout 360 'swaymsg "output * power off"' resume 'swaymsg "output * power on"' before-sleep 'wlperch lock -f' lock 'wlperch lock -f'
bindsym $mod+Mod1+l exec wlperch lock
`

LOCK_SWITCH :: Config_Switch {
	backup  = "lock-backup",
	files   = lock_candidate_files,
	rewrite = lock_rewrite,
}

@(private = "file")
lock_switch_spec :: proc() -> Config_Switch {
	s := LOCK_SWITCH
	s.new_path = fmt.tprintf("%s/sway/config.d/%s", sway_config_home(), LOCK_CONF_NAME)
	s.new_text = LOCK_CONF
	return s
}

// Files that may start or bind a locker.
@(private = "file")
lock_candidate_files :: proc() -> []string {
	out := sway_candidate_files(scripts = true)
	append(&out, strings.concatenate({sway_config_home(), "/swayidle/config"}, context.temp_allocator))
	return out[:]
}

@(private = "file")
is_word :: proc(c: u8) -> bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.'
}

// Rewrite swaylock commands in a config or shell text:
//   swaylock -f -i x.png   -> wlperch lock -f     (swaylock's own options dropped)
//   pgrep … swaylock       -> pgrep … wlperch-lock (the locker's process name)
// Comment lines and pkill/killall lines (swaylock's SIGUSR1 unlock, which
// wlperch deliberately doesn't have) are left alone.
lock_rewrite :: proc(text: string, allocator := context.temp_allocator) -> (out: string, changes: int) {
	b := strings.builder_make(allocator)
	for line in strings.split_after(text, "\n", context.temp_allocator) {
		t := strings.trim_left_space(line)
		if strings.has_prefix(t, "#") || !strings.contains(line, "swaylock") || strings.contains(line, "pkill") || strings.contains(line, "killall") {
			strings.write_string(&b, line)
			continue
		}
		pos := 0 // in line
		for {
			i := strings.index(line[pos:], "swaylock")
			if i < 0 {break}
			i += pos
			end := i + len("swaylock")
			start := i
			for start > 0 && (line[start - 1] == '/' || is_word(line[start - 1])) {start -= 1}
			token := line[start:end]
			if (end < len(line) && is_word(line[end])) || (token != "swaylock" && !strings.has_suffix(token, "/swaylock")) {
				// Part of another word ("myswaylock"): keep.
				strings.write_string(&b, line[pos:end])
				pos = end
				continue
			}
			strings.write_string(&b, line[pos:start])
			// The shell command this word belongs to starts after the last separator.
			seg := line[:start]
			if k := strings.last_index_any(seg, "';&|("); k >= 0 {seg = seg[k + 1:]}
			if strings.contains(seg, "pgrep") {
				strings.write_string(&b, "wlperch-lock")
				pos = end
			} else {
				// Its arguments run to the end of the quoted string / command.
				j := end
				for j < len(line) && strings.index_byte("'\";&|)\\\n", line[j]) < 0 {j += 1}
				daemonize := false
				for arg in strings.fields(line[end:j], context.temp_allocator) {
					if arg == "-f" || arg == "--daemonize" {daemonize = true}
				}
				strings.write_string(&b, daemonize ? "wlperch lock -f" : "wlperch lock")
				if j > end && line[j - 1] == ' ' {strings.write_byte(&b, ' ')}
				pos = j
			}
			changes += 1
		}
		strings.write_string(&b, line[pos:])
	}
	return strings.to_string(b), changes
}

lock_setup_check :: proc(p: ^Component, add_detail: proc(c: ^Component, line: string)) {
	spec := lock_switch_spec()
	entries, installed := switch_manifest(spec)
	uses, wlperch_used := switch_uses(spec, "wlperch lock")
	switch {
	case installed:
		p.state = len(uses) > 0 ? .Outdated : .Installed
		add_detail(p, "swayidle and the lock key use wlperch lock")
		for e in entries {add_detail(p, e[0] == "new" ? fmt.tprintf("added %s", e[1]) : fmt.tprintf("changed %s", e[1]))}
		for u in uses {add_detail(p, fmt.tprintf("still swaylock: %s", u))}
	case len(uses) > 0:
		p.state = .Missing
		for u in uses {add_detail(p, fmt.tprintf("swaylock: %s", u))}
	case wlperch_used:
		p.state = .Custom
		add_detail(p, "your sway config already runs wlperch lock")
	case:
		p.state = .Missing
		add_detail(p, fmt.tprintf("no locker set up; adds %s", spec.new_path))
	}
}

@(private = "file")
lock_done :: proc(ok: bool, msg: string) {
	sync.guard(&setup.mu)
	c := &setup.comps[.Lock]
	c.busy = false
	c.msg_ok = ok
	delete(c.message)
	c.message = strings.clone(msg)
	log.infof("setup lock: %s", msg)
}

setup_install_lock :: proc() {lock_switch(apply = true)}
setup_remove_lock :: proc() {lock_switch_back(apply = true)}

// Switch every swaylock use to wlperch lock (or add our own file when there
// are none), then (apply) reload sway and restart this session's swayidle.
lock_switch :: proc(apply: bool) {
	spec := lock_switch_spec()
	_, wlperch_used := switch_uses(spec, "wlperch lock")
	changed, err := switch_apply(spec, allow_new = !wlperch_used)
	if err != "" {
		lock_done(false, err)
		return
	}
	if changed == 0 {
		lock_done(true, "nothing to change")
		return
	}
	restarted := apply && apply_lock_change()
	lock_done(true, restarted ? "switched to wlperch lock (sway reloaded, swayidle restarted)" : "switched to wlperch lock; reload sway / log in again to apply")
}

// Undo lock_switch from the backups.
lock_switch_back :: proc(apply: bool) {
	spec := lock_switch_spec()
	kept, err := switch_back(spec)
	if err != "" {
		lock_done(false, err)
		return
	}
	restarted := apply && apply_lock_change()
	msg := restarted ? "swaylock restored (sway reloaded, swayidle restarted)" : "swaylock restored; reload sway / log in again to apply"
	if kept > 0 {msg = fmt.tprintf("%s; your later edits are in %s/*.edited", msg, switch_backup_dir(spec))}
	lock_done(true, msg)
}

setup_lock_now :: proc() {
	exe := os.exists(setup.bin_path) ? setup.bin_path : setup.self_path
	ok := launch_detached({exe, "lock"})
	lock_done(ok, ok ? "locked" : "couldn't start wlperch lock")
}

// Reload sway (bindings) and restart the swayidle of this session from the
// exec line that starts it. Returns false when sway isn't reachable.
@(private = "file")
apply_lock_change :: proc() -> bool {
	if !sway_command("reload") {return false}
	cmd := swayidle_exec_line()
	if cmd == "" {return true}
	disp := os.get_env("WAYLAND_DISPLAY", context.temp_allocator)
	out, _ := run({"pgrep", "-xu", fmt.tprintf("%d", posix.getuid()), "swayidle"}, 2 * time.Second, context.temp_allocator)
	for pid in strings.fields(out, context.temp_allocator) {
		// Only this session's swayidle (another sway may be running).
		env, err := os.read_entire_file(fmt.tprintf("/proc/%s/environ", pid), context.temp_allocator)
		if err != nil {continue}
		mine := false
		for kv in strings.split(string(env), "\x00", context.temp_allocator) {
			if kv == fmt.tprintf("WAYLAND_DISPLAY=%s", disp) {mine = true}
		}
		if !mine {continue}
		run({"kill", pid}, 2 * time.Second, context.temp_allocator)
	}
	time.sleep(200 * time.Millisecond)
	sway_command(fmt.tprintf("exec %s", cmd))
	return true
}

// The command of the sway `exec` line that starts swayidle (directly or
// through a script), or "".
@(private = "file")
swayidle_exec_line :: proc() -> string {
	for f in lock_candidate_files() {
		if strings.has_suffix(f, ".sh") || strings.has_suffix(f, "/swayidle/config") {continue}
		data, err := os.read_entire_file(f, context.temp_allocator)
		if err != nil {continue}
		for line in strings.split_lines(string(data), context.temp_allocator) {
			t := strings.trim_space(line)
			rest: string
			switch {
			case strings.has_prefix(t, "exec "):        rest = t[5:]
			case strings.has_prefix(t, "exec_always "): rest = t[12:]
			case:                                       continue
			}
			rest = strings.trim_space(strings.trim_prefix(strings.trim_space(rest), "--no-startup-id"))
			if strings.contains(rest, "swayidle") {return rest}
			// A script that runs swayidle.
			script := strings.fields(rest, context.temp_allocator)
			if len(script) == 0 {continue}
			path := script[0]
			if strings.has_prefix(path, "~/") {path = strings.concatenate({os.get_env("HOME", context.temp_allocator), path[1:]}, context.temp_allocator)}
			if body, berr := os.read_entire_file(path, context.temp_allocator); berr == nil && strings.contains(string(body), "swayidle") {return rest}
		}
	}
	return ""
}
