// Named idle holds: `wlperch idle hold <name> [--pid PID]` keeps the
// session awake (no idle lock, no monitors-off) until `wlperch idle release
// <name>`, or until process PID exits. It is the same mechanism as the game
// hold (game_hold.odin): the daemon's idle inhibitor (awake.odin), which everything that waits for
// inactivity honours. With --pid a crashed or killed caller can't leave the
// session awake for good: e.g. a game stream's prep command
//   sh -c "wlperch idle hold sunshine --pid $PPID"
// holds while Sunshine runs, or until its undo command releases it.
//
// The holds are kept in $XDG_RUNTIME_DIR/wlperch-idle-holds
// ("<daemon pid>\t<name>\t<pid>" per line): the bar's eye and setup read it,
// and a new daemon (re-exec, or restarted by systemd) takes them over as long
// as their process lives.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"


IDLE_HOLDS_NAME :: "wlperch-idle-holds"

Idle_Hold :: struct {
	name: string,
	pid:  int, // 0: until released
}

@(private = "file")
ih: struct {
	holds:     [dynamic]Idle_Hold,
	check_at:  time.Tick, // next look at the holds' processes ({}: none)
}

@(private = "file")
CHECK_EVERY :: 2 * time.Second

@(private = "file")
holds_path :: proc() -> string {
	dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if dir == "" {dir = "/tmp"}
	return fmt.tprintf("%s/%s", dir, IDLE_HOLDS_NAME)
}

// A process that runs (not gone, not a zombie waiting to be reaped).
pid_alive :: proc(pid: int) -> bool {
	if pid <= 0 {return false}
	if posix.kill(posix.pid_t(pid), posix.Signal(0)) != .OK && posix.errno() != .EPERM {return false}
	stat, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator)
	if err != nil {return false}
	// "pid (comm) S …": the state after the last ')'.
	s := string(stat)
	if i := strings.last_index_byte(s, ')'); i >= 0 && i + 2 < len(s) {return s[i + 2] != 'Z'}
	return true
}

// "<daemon pid>\t<name>\t<pid>" lines (pure, tested).
idle_holds_parse :: proc(text: string, allocator := context.temp_allocator) -> (daemon: int, holds: []Idle_Hold) {
	out := make([dynamic]Idle_Hold, allocator)
	for line in strings.split_lines(text, context.temp_allocator) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 3 || f[1] == "" {continue}
		daemon = strconv.parse_int(f[0]) or_else 0
		append(&out, Idle_Hold{strings.clone(f[1], allocator), strconv.parse_int(f[2]) or_else 0})
	}
	return daemon, out[:]
}

idle_holds_format :: proc(daemon: int, holds: []Idle_Hold) -> string {
	b := strings.builder_make(context.temp_allocator)
	for h in holds {fmt.sbprintf(&b, "%d\t%s\t%d\n", daemon, h.name, h.pid)}
	return strings.to_string(b)
}

// For the bar and setup: the holds in effect ("" names if the daemon that
// wrote them is gone).
idle_holds_current :: proc() -> []Idle_Hold {
	data, err := os.read_entire_file(holds_path(), context.temp_allocator)
	if err != nil {return nil}
	daemon, holds := idle_holds_parse(string(data))
	if !pid_alive(daemon) {return nil}
	return holds
}

@(private = "file")
save :: proc() {
	if len(ih.holds) == 0 {
		_ = os.remove(holds_path())
		return
	}
	_ = os.write_entire_file(holds_path(), transmute([]u8)idle_holds_format(int(posix.getpid()), ih.holds[:]))
}

// Take or drop the inhibitor to match the holds.
@(private = "file")
apply :: proc() {
	awake_want(.Holds, len(ih.holds) > 0)
	ih.check_at = {}
	for h in ih.holds {if h.pid > 0 {ih.check_at = time.tick_add(time.tick_now(), CHECK_EVERY)}}
	save()
}

@(private = "file")
find :: proc(name: string) -> int {
	for h, i in ih.holds {if h.name == name {return i}}
	return -1
}

@(private = "file")
remove_at :: proc(i: int) {
	delete(ih.holds[i].name)
	ordered_remove(&ih.holds, i)
}

// After platform_init: the holds of the image before (re-exec) or of a
// daemon that died, as long as their process lives.
idle_hold_init :: proc() {
	data, err := os.read_entire_file(holds_path(), context.temp_allocator)
	if err != nil {return}
	_, holds := idle_holds_parse(string(data))
	for h in holds {
		if h.pid > 0 && !pid_alive(h.pid) {continue}
		append(&ih.holds, Idle_Hold{strings.clone(h.name), h.pid})
		log.infof("idle: held by %s%s (taken over)", h.name, h.pid > 0 ? fmt.tprintf(" while pid %d runs", h.pid) : "")
	}
	apply()
}

idle_hold_take :: proc(name: string, pid: int) -> string {
	if pid > 0 && !pid_alive(pid) {return fmt.tprintf("no process %d\n", pid)}
	if i := find(name); i >= 0 {
		ih.holds[i].pid = pid
	} else {
		append(&ih.holds, Idle_Hold{strings.clone(name), pid})
	}
	log.infof("idle: held by %s%s: no idle lock or monitors-off", name, pid > 0 ? fmt.tprintf(" while pid %d runs", pid) : "")
	apply()
	return "ok\n"
}

idle_hold_release :: proc(name: string) -> string {
	i := find(name)
	if i < 0 {return fmt.tprintf("no hold named %s\n", name)}
	remove_at(i)
	log.infof("idle: %s released", name)
	apply()
	return "ok\n"
}

// Main loop: holds whose process is gone end.
idle_hold_tick :: proc() {
	if ih.check_at == {} || time.tick_diff(ih.check_at, time.tick_now()) < 0 {return}
	changed := false
	for i := len(ih.holds) - 1; i >= 0; i -= 1 {
		h := ih.holds[i]
		if h.pid > 0 && !pid_alive(h.pid) {
			log.infof("idle: %s released (pid %d exited)", h.name, h.pid)
			remove_at(i)
			changed = true
		}
	}
	if changed {apply()} else {ih.check_at = time.tick_add(time.tick_now(), CHECK_EVERY)}
}

idle_hold_timeout :: proc() -> time.Duration {
	if ih.check_at == {} {return -1}
	return max(time.tick_diff(time.tick_now(), ih.check_at), 0)
}

// The daemon's `idle` command: hold / release / status.
idle_command :: proc(f: []string) -> string {
	sub := len(f) > 0 ? f[0] : "status"
	switch sub {
	case "hold":
		if len(f) < 2 {return "usage: idle hold <name> [pid]\n"}
		pid := 0
		if len(f) > 2 {
			n, ok := strconv.parse_int(f[2])
			if !ok || n <= 0 {return "usage: idle hold <name> [pid]\n"}
			pid = n
		}
		return idle_hold_take(f[1], pid)
	case "release":
		if len(f) < 2 {return "usage: idle release <name>\n"}
		return idle_hold_release(f[1])
	case "status":
		return idle_status()
	}
	return "usage: idle [status | hold <name> [pid] | release <name>]\n"
}

// What keeps the session awake and who locks, one "key value" per line.
@(private = "file")
idle_status :: proc() -> string {
	pol := idle_policy()
	b := strings.builder_make(context.temp_allocator)
	manager := idle_managed(pol) ? "wlperch" : pol.swayidle ? "swayidle" : config.lock_idle_seconds > 0 ? "wlperch" : "none"
	fmt.sbprintf(&b, "manager %s\n", manager)
	fmt.sbprintf(&b, "lock_after %d\n", pol.lock_after)
	fmt.sbprintf(&b, "locked %d\n", int(pol.locked))
	fmt.sbprintf(&b, "screen_off %d\n", screen_off_allowed(pol) ? config.lock_screen_off_seconds : 0)
	fmt.sbprintf(&b, "locked_screen_off %d\n", config.lock_locked_off_seconds)
	fmt.sbprintf(&b, "logind %s\n", logind_status())
	for h in ih.holds {fmt.sbprintf(&b, "hold %s %d\n", h.name, h.pid)}
	if app, why := game_hold_current(); app != "" {fmt.sbprintf(&b, "game %s (%s)\n", app, why)}
	return strings.to_string(b)
}

IDLE_USAGE :: `usage: wlperch idle [status]
       wlperch idle hold <name> [--pid PID]
       wlperch idle release <name>
  hold      keep the session awake (no idle lock, no monitors-off) until
            released, or until process PID exits
  release   end the hold <name>
  status    who locks on idle, after how long, and what holds it now
`

// `wlperch idle …` from a shell: talks to the daemon.
idle_cli :: proc(args: []string) -> int {
	words := make([dynamic]string, context.temp_allocator)
	append(&words, "idle")
	pid := ""
	i := 0
	for i < len(args) {
		a := args[i]
		switch {
		case a == "-h" || a == "--help":
			fmt.print(IDLE_USAGE)
			return 0
		case a == "--pid" && i + 1 < len(args):
			n, ok := strconv.parse_int(args[i + 1])
			if !ok || n <= 0 {
				fmt.eprintf("wlperch idle: not a process id: %s\n", args[i + 1])
				return 2
			}
			i += 1
			pid = args[i]
		case strings.has_prefix(a, "--pid="):
			pid = a[len("--pid="):]
		case strings.contains_any(a, " \t\n"):
			fmt.eprintln("wlperch idle: a hold's name can't contain spaces")
			return 2
		case:
			append(&words, a)
		}
		i += 1
	}
	if len(words) == 1 {append(&words, "status")}
	switch words[1] {
	case "status", "release":
	case "hold":
		if len(words) != 3 {
			fmt.eprint(IDLE_USAGE)
			return 2
		}
		if pid != "" {append(&words, pid)}
	case:
		fmt.eprint(IDLE_USAGE)
		return 2
	}
	reply, ok := ipc_query(strings.join(words[:], " ", context.temp_allocator))
	if !ok {
		fmt.eprintln("wlperch idle: the daemon is not running")
		return 1
	}
	fmt.print(reply)
	return words[1] == "status" || reply == "ok\n" ? 0 : 1
}
