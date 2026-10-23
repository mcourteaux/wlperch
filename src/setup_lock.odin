// Setup component "Lock screen": switches swayidle / the lock key binding
// from swaylock to `wlperch lock`, and back.
//
// Switching rewrites the swaylock commands in the sway config, config.d/*,
// scripts next to them (~/.config/sway/*.sh) and swayidle's own config. Every
// file is copied to ~/.local/share/wlperch/lock-backup/ first; symlinked files
// (dotfiles) are edited through the link. With no swaylock anywhere, a
// config.d/wlperch-lock.conf with swayidle + a key binding is written instead.
// Switching back restores the copies (keeping the current file next to the
// backup when it was edited since).
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

@(private = "file")
config_home_dir :: proc() -> string {
	if x := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); x != "" {return x}
	return strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.config"}, context.temp_allocator)
}

@(private = "file")
data_home_dir :: proc() -> string {
	if x := os.get_env("XDG_DATA_HOME", context.temp_allocator); x != "" {return strings.concatenate({x, "/wlperch"}, context.temp_allocator)}
	return strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.local/share/wlperch"}, context.temp_allocator)
}

@(private = "file")
backup_dir :: proc() -> string {return strings.concatenate({data_home_dir(), "/lock-backup"}, context.temp_allocator)}

// One line per changed file: "edit<TAB>path<TAB>backup" or "new<TAB>path".
@(private = "file")
manifest_path :: proc() -> string {return strings.concatenate({backup_dir(), "/manifest"}, context.temp_allocator)}

// Files that may start or bind a locker.
@(private = "file")
lock_candidate_files :: proc() -> []string {
	out: [dynamic]string
	out.allocator = context.temp_allocator
	sway := strings.concatenate({config_home_dir(), "/sway"}, context.temp_allocator)
	append(&out, strings.concatenate({sway, "/config"}, context.temp_allocator))
	for dir in ([]string{strings.concatenate({sway, "/config.d"}, context.temp_allocator), sway}) {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {continue}
		for e in entries {
			if dir == sway && !strings.has_suffix(e.name, ".sh") {continue}
			if strings.contains(e.name, ".before-wlperch") || strings.has_suffix(e.name, "~") {continue}
			full := strings.concatenate({dir, "/", e.name}, context.temp_allocator)
			if os.is_dir(full) {continue}
			append(&out, full)
		}
	}
	append(&out, strings.concatenate({config_home_dir(), "/swayidle/config"}, context.temp_allocator))
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

// Where swaylock is used: "file (lines …)" for each file with active uses.
@(private = "file")
swaylock_uses :: proc() -> (uses: []string, wlperch_used: bool) {
	out: [dynamic]string
	out.allocator = context.temp_allocator
	for f in lock_candidate_files() {
		data, err := os.read_entire_file(f, context.temp_allocator)
		if err != nil {continue}
		lines := strings.builder_make(context.temp_allocator)
		for line, n in strings.split_lines(string(data), context.temp_allocator) {
			t := strings.trim_space(line)
			if strings.has_prefix(t, "#") {continue}
			if strings.contains(t, "wlperch lock") {wlperch_used = true}
			if _, c := lock_rewrite(line); c > 0 {
				if strings.builder_len(lines) > 0 {strings.write_string(&lines, ", ")}
				fmt.sbprintf(&lines, "%d", n + 1)
			}
		}
		if strings.builder_len(lines) > 0 {append(&out, fmt.tprintf("%s (line %s)", f, strings.to_string(lines)))}
	}
	return out[:], wlperch_used
}

@(private = "file")
read_manifest :: proc() -> (entries: [][3]string, ok: bool) {
	data, err := os.read_entire_file(manifest_path(), context.temp_allocator)
	if err != nil {return nil, false}
	out: [dynamic][3]string
	out.allocator = context.temp_allocator
	for line in strings.split_lines(string(data), context.temp_allocator) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) >= 2 {append(&out, [3]string{f[0], f[1], len(f) > 2 ? f[2] : ""})}
	}
	return out[:], true
}

// Write through a symlink (dotfiles) instead of replacing it.
@(private = "file")
write_through :: proc(path, content: string) -> bool {
	target := path
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if rp := posix.realpath(cpath, nil); rp != nil {
		target = strings.clone(string(rp), context.temp_allocator)
		posix.free(rp)
	}
	tmp := strings.concatenate({target, ".wlperch-tmp"}, context.temp_allocator)
	mode := os.Permissions_Default_File
	if fi, err := os.stat(target, context.temp_allocator); err == nil {mode = fi.mode}
	if os.write_entire_file(tmp, content, mode) != nil {return false}
	return os.rename(tmp, target) == nil
}

lock_setup_check :: proc(p: ^Component, add_detail: proc(c: ^Component, line: string)) {
	entries, installed := read_manifest()
	uses, wlperch_used := swaylock_uses()
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
		add_detail(p, fmt.tprintf("no locker set up; adds %s/sway/config.d/%s", config_home_dir(), LOCK_CONF_NAME))
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
	os.make_directory_all(backup_dir())
	old, had := read_manifest()
	manifest := strings.builder_make(context.temp_allocator)
	for e in old {fmt.sbprintf(&manifest, "%s\t%s\t%s\n", e[0], e[1], e[2])}
	changed := 0
	for f in lock_candidate_files() {
		data, err := os.read_entire_file(f, context.temp_allocator)
		if err != nil {continue}
		text, n := lock_rewrite(string(data))
		if n == 0 {continue}
		// The first switch keeps the original; a later one (new swaylock lines) its own copy.
		name, _ := strings.replace_all(strings.trim_prefix(f, "/"), "/", "%", context.temp_allocator)
		bk := free_name(fmt.tprintf("%s/%s", backup_dir(), name))
		if os.write_entire_file(bk, data) != nil || !write_through(f, text) {
			lock_done(false, fmt.tprintf("couldn't change %s", f))
			return
		}
		fmt.sbprintf(&manifest, "edit\t%s\t%s\n", f, bk)
		changed += 1
	}
	if changed == 0 && !had {
		_, wlperch_used := swaylock_uses()
		if !wlperch_used {
			f := fmt.tprintf("%s/sway/config.d/%s", config_home_dir(), LOCK_CONF_NAME)
			os.make_directory_all(fmt.tprintf("%s/sway/config.d", config_home_dir()))
			if os.write_entire_file(f, LOCK_CONF) != nil {
				lock_done(false, fmt.tprintf("couldn't write %s", f))
				return
			}
			fmt.sbprintf(&manifest, "new\t%s\n", f)
			changed += 1
		}
	}
	if changed == 0 {
		lock_done(true, "nothing to change")
		return
	}
	if os.write_entire_file(manifest_path(), strings.to_string(manifest)) != nil {
		lock_done(false, "couldn't write the backup list")
		return
	}
	restarted := apply && apply_lock_change()
	lock_done(true, restarted ? "switched to wlperch lock (sway reloaded, swayidle restarted)" : "switched to wlperch lock; reload sway / log in again to apply")
}

// Undo lock_switch from the backups.
lock_switch_back :: proc(apply: bool) {
	entries, ok := read_manifest()
	if !ok {
		lock_done(false, "no backups found")
		return
	}
	kept := 0
	#reverse for e in entries {
		switch e[0] {
		case "new":
			os.remove(e[1])
		case "edit":
			orig, err := os.read_entire_file(e[2], context.temp_allocator)
			if err != nil {
				lock_done(false, fmt.tprintf("backup of %s is missing", e[1]))
				return
			}
			// Edited since we switched it: keep that version next to the backup.
			if cur, cerr := os.read_entire_file(e[1], context.temp_allocator); cerr == nil {
				if want, _ := lock_rewrite(string(orig)); string(cur) != want {
					_ = os.write_entire_file(strings.concatenate({e[2], ".edited"}, context.temp_allocator), cur)
					kept += 1
				}
			}
			if !write_through(e[1], string(orig)) {
				lock_done(false, fmt.tprintf("couldn't restore %s", e[1]))
				return
			}
			os.remove(e[2])
		}
	}
	os.remove(manifest_path())
	restarted := apply && apply_lock_change()
	msg := restarted ? "swaylock restored (sway reloaded, swayidle restarted)" : "swaylock restored; reload sway / log in again to apply"
	if kept > 0 {msg = fmt.tprintf("%s; your later edits are in %s/*.edited", msg, backup_dir())}
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

// base, or base.2, base.3…: never overwrite a backup.
@(private = "file")
free_name :: proc(base: string) -> string {
	if !os.exists(base) {return base}
	for n := 2; ; n += 1 {
		p := fmt.tprintf("%s.%d", base, n)
		if !os.exists(p) {return p}
	}
}
