// Setup component "Idle": wlperch instead of swayidle. "Use wlperch idle"
// carries swayidle's timeouts over to [lock] idle_lock_seconds,
// screen_off_seconds and locked_screen_off_seconds (300 / 360 / 60 when
// there's no swayidle), comments out the sway `exec` lines that start
// swayidle (directly or through a script; backups in
// ~/.local/share/wlperch/idle-backup/, see config_switch.odin), stops this
// session's swayidle and restarts the daemon. From then on the daemon locks
// on idle, turns the monitors off, and locks before sleep and on `loginctl
// lock-session` (logind.odin). "Switch back" restores the files, sets
// idle_lock_seconds = 0 and starts swayidle again.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

IDLE_COMMENT :: "# wlperch locks on idle instead of swayidle (wlperch setup, Idle card; Switch back restores this):"

IDLE_SWITCH :: Config_Switch {
	backup  = "idle-backup",
	files   = idle_candidate_files,
	rewrite = idle_rewrite,
}

@(private = "file")
idle_candidate_files :: proc() -> []string {
	out := sway_candidate_files(scripts = false)
	return out[:]
}

// An `exec` line's command that starts swayidle, directly or through a
// script that runs it ("" if it doesn't).
@(private = "file")
starts_swayidle :: proc(line: string) -> bool {
	t := strings.trim_space(line)
	rest: string
	switch {
	case strings.has_prefix(t, "exec "):        rest = t[5:]
	case strings.has_prefix(t, "exec_always "): rest = t[12:]
	case:                                       return false
	}
	rest = strings.trim_space(strings.trim_prefix(strings.trim_space(rest), "--no-startup-id"))
	if strings.contains(rest, "swayidle") {return true}
	words := strings.fields(rest, context.temp_allocator)
	if len(words) == 0 {return false}
	path := words[0]
	if strings.has_prefix(path, "~/") {path = strings.concatenate({os.get_env("HOME", context.temp_allocator), path[1:]}, context.temp_allocator)}
	if !strings.has_prefix(path, "/") {return false}
	body, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil && len(body) < 65536 && strings.contains(string(body), "swayidle")
}

// Comment out the lines that start swayidle.
idle_rewrite :: proc(text: string, allocator := context.temp_allocator) -> (out: string, changes: int) {
	b := strings.builder_make(allocator)
	for line in strings.split_after(text, "\n", context.temp_allocator) {
		if strings.has_prefix(strings.trim_left_space(line), "#") || !starts_swayidle(line) {
			strings.write_string(&b, line)
			continue
		}
		indent := line[:len(line) - len(strings.trim_left_space(line))]
		fmt.sbprintf(&b, "%s%s\n%s# %s", indent, IDLE_COMMENT, indent, strings.trim_left_space(line))
		changes += 1
	}
	return strings.to_string(b), changes
}

// The daemon's view (`wlperch idle status`): it has the current config.
@(private = "file")
Idle_Status :: struct {
	running:     bool,
	manager:     string,
	lock_after:  int,
	screen_off:  int,
	locked_off:  int,
	logind:      string,
	holds:       []string,
}

@(private = "file")
idle_status_read :: proc() -> (st: Idle_Status) {
	reply, ok := ipc_query("idle status")
	if !ok {return}
	st.running = true
	out := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(reply, context.temp_allocator) {
		k, _, v := strings.partition(line, " ")
		switch k {
		case "manager":           st.manager = v
		case "lock_after":        st.lock_after = strconv.parse_int(v) or_else 0
		case "screen_off":        st.screen_off = strconv.parse_int(v) or_else 0
		case "locked_screen_off": st.locked_off = strconv.parse_int(v) or_else 0
		case "logind":            st.logind = v
		case "hold":
			name, _, pid := strings.partition(v, " ")
			append(&out, pid != "" && pid != "0" ? fmt.tprintf("%s (while pid %s runs)", name, pid) : name)
		}
	}
	st.holds = out[:]
	return
}

@(private = "file")
secs_text :: proc(n: int) -> string {
	if n > 0 && n % 60 == 0 {return fmt.tprintf("%d min", n / 60)}
	return fmt.tprintf("%d s", n)
}

idle_setup_check :: proc(p: ^Component, add_detail: proc(c: ^Component, line: string)) {
	uses, _ := switch_uses(IDLE_SWITCH, "\x00")
	_, switched := switch_manifest(IDLE_SWITCH)
	_, swayidle_secs, swayidle := session_lock_state()
	st := idle_status_read()
	// The daemon knows the config as it is now; without it, ours.
	ours := st.running ? st.manager == "wlperch" : config.lock_idle_seconds > 0
	lock_after := st.running ? st.lock_after : config.lock_idle_seconds
	switch {
	case ours && !swayidle && len(uses) == 0:
		p.state = .Running
		add_detail(p, fmt.tprintf("wlperch locks after %s idle", secs_text(lock_after)))
	case ours:
		p.state = .Outdated
		add_detail(p, fmt.tprintf("wlperch locks after %s idle, but swayidle runs too", secs_text(lock_after)))
	case swayidle:
		p.state = .Missing
		add_detail(p, swayidle_secs > 0 ? fmt.tprintf("swayidle locks after %s idle", secs_text(swayidle_secs)) : "swayidle runs, without an idle lock")
	case:
		p.state = .Missing
		add_detail(p, "nothing locks on idle")
	}
	for u in uses {add_detail(p, fmt.tprintf("starts swayidle: %s", u))}
	if ours && st.running {
		if st.screen_off > 0 {add_detail(p, fmt.tprintf("monitors off after %s idle", secs_text(st.screen_off)))}
		if st.locked_off > 0 {add_detail(p, fmt.tprintf("monitors off %s after locking", secs_text(st.locked_off)))}
	}
	switch {
	case st.logind == "unavailable":
		add_detail(p, "lock before sleep: not available (no logind)")
	case !ours || !st.running:
	case strings.has_prefix(st.logind, "on (locks"):
		add_detail(p, "locks before sleep and on loginctl lock-session (logind)")
	case strings.has_prefix(st.logind, "on (no lock"):
		add_detail(p, "lock before sleep: off ([lock] lock_before_sleep)")
	}
	if switched {add_detail(p, fmt.tprintf("backups in %s", switch_backup_dir(IDLE_SWITCH)))}
	for h in st.holds {add_detail(p, fmt.tprintf("on hold: %s (wlperch idle hold)", h))}
	if app, why := game_hold_current(); app != "" {
		add_detail(p, fmt.tprintf("on hold: fullscreen game %s (%s)", app, why))
	}
}

@(private = "file")
idle_done :: proc(ok: bool, msg: string) {
	sync.guard(&setup.mu)
	c := &setup.comps[.Idle]
	c.busy = false
	c.msg_ok = ok
	delete(c.message)
	c.message = strings.clone(msg)
	log.infof("setup idle: %s", msg)
}

// Stop this session's swayidle (not another sway's).
@(private = "file")
stop_session_swayidle :: proc() -> int {
	out, _ := run({"pgrep", "-xu", fmt.tprintf("%d", posix.getuid()), "swayidle"}, 2 * time.Second, context.temp_allocator)
	n := 0
	for pid in strings.fields(out, context.temp_allocator) {
		if !session_process(pid) {continue}
		run({"kill", pid}, 2 * time.Second, context.temp_allocator)
		n += 1
	}
	return n
}

setup_install_idle :: proc() {
	// swayidle's timeouts carry over; without it the usual 5 / 6 / 1 minutes.
	lock, off, locked_off := swayidle_timeouts(session_swayidle_args())
	if config.lock_idle_seconds > 0 {lock = config.lock_idle_seconds}
	if lock == 0 {lock = 300}
	if off == 0 {off = lock + 60}
	if locked_off == 0 {locked_off = 60}
	ok := config_set_value("lock", "idle_lock_seconds", fmt.tprintf("%d", lock))
	ok &&= config_set_value("lock", "screen_off_seconds", fmt.tprintf("%d", off))
	ok &&= config_set_value("lock", "locked_screen_off_seconds", fmt.tprintf("%d", locked_off))
	if !ok {
		idle_done(false, "couldn't write config.ini")
		return
	}
	config.lock_idle_seconds = lock
	changed, err := switch_apply(IDLE_SWITCH, allow_new = false)
	if err != "" {
		idle_done(false, err)
		return
	}
	stopped := stop_session_swayidle()
	restarted := ipc_send("restart")
	msg := fmt.tprintf("wlperch locks after %s idle, monitors off after %s (%s after locking)", secs_text(lock), secs_text(off), secs_text(locked_off))
	if changed > 0 {msg = fmt.tprintf("%s; swayidle's exec commented out", msg)}
	if stopped > 0 {msg = fmt.tprintf("%s; swayidle stopped", msg)}
	if !restarted {msg = fmt.tprintf("%s; start the background service to apply", msg)}
	idle_done(true, msg)
}

setup_remove_idle :: proc() {
	kept := 0
	if _, switched := switch_manifest(IDLE_SWITCH); switched {
		err: string
		kept, err = switch_back(IDLE_SWITCH)
		if err != "" {
			idle_done(false, err)
			return
		}
	}
	if !config_set_value("lock", "idle_lock_seconds", "0") {
		idle_done(false, "couldn't write config.ini")
		return
	}
	config.lock_idle_seconds = 0
	ipc_send("restart")
	msg := "swayidle locks on idle again"
	if cmd := swayidle_exec_line(); cmd != "" {
		if sway_command(fmt.tprintf("exec %s", cmd)) {msg = "swayidle is back (started again)"}
	} else {
		msg = "wlperch doesn't lock on idle any more (no swayidle line to start)"
	}
	if kept > 0 {msg = fmt.tprintf("%s; your later edits are in %s/*.edited", msg, switch_backup_dir(IDLE_SWITCH))}
	idle_done(true, msg)
}
