// logind (or elogind: the same D-Bus API) for wlperch's idle manager, the
// parts swayidle did besides its timeouts:
//   - before sleep: a "delay" sleep inhibitor; on PrepareForSleep(true) the
//     daemon locks (`wlperch lock -f`, back once the lock is up) and only
//     then lets go of the inhibitor, so the machine never wakes up to an
//     unlocked screen. After resume it takes a new one.
//   - `loginctl lock-session`: the session's Lock signal locks. Unlock
//     (`loginctl unlock-session`) is logged and ignored: wlperch lock only
//     unlocks with the password.
//   - the session's IdleHint: true while idle-locked / monitors off.
// Only while wlperch is the idle manager (idle_managed: idle_lock_seconds >
// 0 and no swayidle in this session), looked at again every RECHECK.
//
// Optional: without a system bus or without logind on it, everything else
// (idle lock, monitors off, holds) works; only locking before sleep and on
// loginctl isn't there (logind_status says so, and setup's Idle card).
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

@(private = "file")
LOGIN1 :: "org.freedesktop.login1"
@(private = "file")
RECHECK :: 10 * time.Second
@(private = "file")
LOCK_WAIT :: 5 * time.Second // before sleep: at most this long for the lock to come up

@(private = "file")
ld: struct {
	ctx:       runtime.Context,
	bus:       ^Sd_Bus,
	available: bool, // logind answers on the system bus
	session:   string, // object path of this session ("" unknown)
	inhibit:   posix.FD, // the sleep delay inhibitor (-1: none)
	managed:   bool, // wlperch is the idle manager (as of the last look)
	check_at:  time.Tick,
	locking:   bool, // a lock -f before sleep is on its way
	lock_done: bool, // set by the waiting thread
	lock_ok:   bool,
	hint:      int, // the IdleHint sent last (-1: none)
} = {inhibit = -1, hint = -1}

@(private = "file")
exe_path :: proc() -> string {
	if target, err := os.read_link("/proc/self/exe", context.temp_allocator); err == nil {
		path := strings.trim_suffix(target, " (deleted)")
		if os.exists(path) {return path}
	}
	return "wlperch"
}

@(private = "file")
MANAGER_PATH :: "/org/freedesktop/login1"
@(private = "file")
MANAGER :: LOGIN1 + ".Manager"

// A call's result: logged when it failed.
@(private = "file")
called :: proc(r: c.int, err: ^Sd_Bus_Error, member: string) -> bool {
	defer sd_bus_error_free(err)
	if r < 0 {
		log.debugf("logind: %s failed: %s", member, err.message)
		return false
	}
	return true
}

// The object path from a reply of type "o".
@(private = "file")
read_path :: proc(m: ^Sd_Bus_Message) -> string {
	p: cstring
	if sd_bus_message_read_basic(m, 'o', &p) < 0 || p == nil {return ""}
	return strings.clone(string(p))
}

// This session's object: XDG_SESSION_ID, else the one of our process, else
// the user's graphical session (a daemon started by systemd isn't in it).
@(private = "file")
find_session :: proc() -> string {
	reply: ^Sd_Bus_Message
	if id := os.get_env("XDG_SESSION_ID", context.temp_allocator); id != "" {
		err: Sd_Bus_Error
		if called(sd_bus_call_method(ld.bus, LOGIN1, MANAGER_PATH, MANAGER, "GetSession", &err, &reply, "s", strings.clone_to_cstring(id, context.temp_allocator)), &err, "GetSession") {
			defer sd_bus_message_unref(reply)
			if p := read_path(reply); p != "" {return p}
		}
	}
	err1: Sd_Bus_Error
	if called(sd_bus_call_method(ld.bus, LOGIN1, MANAGER_PATH, MANAGER, "GetSessionByPID", &err1, &reply, "u", u32(posix.getpid())), &err1, "GetSessionByPID") {
		defer sd_bus_message_unref(reply)
		if p := read_path(reply); p != "" {return p}
	}
	err2: Sd_Bus_Error
	if called(sd_bus_call_method(ld.bus, LOGIN1, MANAGER_PATH, MANAGER, "GetUser", &err2, &reply, "u", u32(posix.getuid())), &err2, "GetUser") {
		user := read_path(reply)
		sd_bus_message_unref(reply)
		defer delete(user)
		err: Sd_Bus_Error
		defer sd_bus_error_free(&err)
		m: ^Sd_Bus_Message
		if user != "" && sd_bus_get_property(ld.bus, LOGIN1, strings.clone_to_cstring(user, context.temp_allocator), LOGIN1 + ".User", "Display", &err, &m, "(so)") >= 0 {
			defer sd_bus_message_unref(m)
			id, p: cstring
			if sd_bus_message_read(m, "(so)", &id, &p) >= 0 && p != nil && string(p) != "/" {return strings.clone(string(p))}
		}
	}
	return ""
}

@(private = "file")
take_inhibitor :: proc() {
	if ld.inhibit >= 0 || !ld.available {return}
	reply: ^Sd_Bus_Message
	err: Sd_Bus_Error
	if !called(sd_bus_call_method(ld.bus, LOGIN1, MANAGER_PATH, MANAGER, "Inhibit", &err, &reply, "ssss", cstring("sleep"), cstring("wlperch"), cstring("Lock the screen before sleep"), cstring("delay")), &err, "Inhibit") {
		log.warn("logind: no sleep inhibitor: the screen won't lock before sleep")
		return
	}
	defer sd_bus_message_unref(reply)
	fd: c.int = -1
	if sd_bus_message_read_basic(reply, 'h', &fd) < 0 || fd < 0 {return}
	// The message owns its fd: keep a copy.
	ld.inhibit = posix.FD(posix.fcntl(posix.FD(fd), .DUPFD_CLOEXEC, c.int(3)))
	log.debug("logind: sleep inhibitor taken")
}

@(private = "file")
drop_inhibitor :: proc() {
	if ld.inhibit < 0 {return}
	posix.close(ld.inhibit)
	ld.inhibit = -1
	log.debug("logind: sleep inhibitor released")
}

// Before sleep: lock, and let the machine go once the lock is up.
@(private = "file")
on_prepare_for_sleep :: proc(going: bool) {
	if !going {
		log.info("logind: resumed")
		ld.hint = -1
		if ld.managed && config.lock_before_sleep {take_inhibitor()}
		return
	}
	if !ld.managed || ld.inhibit < 0 {return}
	if locked, _, _ := session_lock_state(); locked || ld.locking {
		if !ld.locking {drop_inhibitor()}
		return
	}
	log.info("logind: going to sleep, locking first")
	ld.locking, ld.lock_done = true, false
	thread.run(proc() {
		ok := run_wait({exe_path(), "lock", "-f"}, LOCK_WAIT)
		sync.atomic_store(&ld.lock_ok, ok)
		sync.atomic_store(&ld.lock_done, true)
		wake_main()
	}, init_context = ld.ctx)
}

@(private = "file")
on_signal :: proc "c" (m: ^Sd_Bus_Message, userdata: rawptr, ret_error: ^Sd_Bus_Error) -> c.int {
	context = ld.ctx
	switch {
	case sd_bus_message_is_signal(m, MANAGER, "PrepareForSleep") > 0:
		going: c.int
		if sd_bus_message_read(m, "b", &going) >= 0 {on_prepare_for_sleep(going != 0)}
	case sd_bus_message_is_signal(m, LOGIN1 + ".Session", "Lock") > 0:
		if ld.managed {idle_lock_now("loginctl lock-session")}
	case sd_bus_message_is_signal(m, LOGIN1 + ".Session", "Unlock") > 0:
		if ld.managed {log.info("logind: unlock-session ignored: wlperch lock unlocks only with the password")}
	}
	return 0
}

// After platform_init.
logind_init :: proc() {
	ld.ctx = context
	if sd_bus_open_system(&ld.bus) < 0 {
		ld.bus = nil
		log.info("logind: no system bus: no lock before sleep or on loginctl lock-session")
		return
	}
	sd_bus_set_method_call_timeout(ld.bus, u64(2 * time.Second / time.Microsecond))
	reply: ^Sd_Bus_Message
	err: Sd_Bus_Error
	owned: c.int
	if sd_bus_call_method(ld.bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", &err, &reply, "s", cstring(LOGIN1)) >= 0 {
		sd_bus_message_read(reply, "b", &owned)
		sd_bus_message_unref(reply)
	}
	sd_bus_error_free(&err)
	if owned == 0 {
		log.info("logind: not on the system bus: no lock before sleep or on loginctl lock-session")
		sd_bus_flush_close_unref(ld.bus)
		ld.bus = nil
		return
	}
	ld.available = true
	ld.session = find_session()
	sd_bus_add_match(ld.bus, nil, "type='signal',sender='org.freedesktop.login1',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'", on_signal, nil)
	if ld.session != "" {
		for member in ([]string{"Lock", "Unlock"}) {
			rule := fmt.tprintf("type='signal',sender='org.freedesktop.login1',interface='org.freedesktop.login1.Session',member='%s',path='%s'", member, ld.session)
			sd_bus_add_match(ld.bus, nil, strings.clone_to_cstring(rule, context.temp_allocator), on_signal, nil)
		}
	} else {
		log.warn("logind: this session not found: loginctl lock-session won't lock")
	}
	log.infof("logind: session %s", ld.session != "" ? ld.session : "unknown")
	ld.check_at = time.tick_now()
	sd_bus_flush(ld.bus)
}

logind_fd :: proc() -> (fd: posix.FD, events: posix.Poll_Event) {
	if ld.bus == nil {return -1, {}}
	return posix.FD(sd_bus_get_fd(ld.bus)), transmute(posix.Poll_Event)i16(sd_bus_get_events(ld.bus))
}

logind_timeout :: proc() -> time.Duration {
	if ld.bus == nil {return -1}
	best := max(time.tick_diff(time.tick_now(), ld.check_at), 0)
	usec: u64
	if sd_bus_get_timeout(ld.bus, &usec) > 0 && usec != max(u64) {
		ts: posix.timespec
		posix.clock_gettime(.MONOTONIC, &ts)
		now := u64(ts.tv_sec) * 1_000_000 + u64(ts.tv_nsec) / 1000
		best = min(best, usec > now ? time.Duration(usec - now) * time.Microsecond : 0)
	}
	return best
}

// Main loop.
logind_tick :: proc() {
	if ld.bus == nil {return}
	for sd_bus_process(ld.bus, nil) > 0 {}
	if ld.locking && sync.atomic_load(&ld.lock_done) {
		ld.locking = false
		log.infof("logind: %s, letting the machine sleep", sync.atomic_load(&ld.lock_ok) ? "locked" : "the lock didn't confirm in time")
		drop_inhibitor()
	}
	if time.tick_diff(ld.check_at, time.tick_now()) >= 0 {
		ld.check_at = time.tick_add(time.tick_now(), RECHECK)
		managed := idle_managed(idle_policy())
		if managed != ld.managed {log.infof("logind: %s", managed ? "wlperch locks before sleep and on loginctl lock-session" : "left to swayidle / off")}
		ld.managed = managed
		if managed && config.lock_before_sleep && !ld.locking {
			take_inhibitor()
		} else if !ld.locking {
			drop_inhibitor()
		}
	}
	sd_bus_flush(ld.bus)
}

// The session's IdleHint, while wlperch manages idle.
logind_idle_hint :: proc(idle: bool) {
	if ld.bus == nil || ld.session == "" || !ld.managed || ld.hint == int(idle) {return}
	ld.hint = int(idle)
	sd_bus_call_method_async(ld.bus, nil, LOGIN1, strings.clone_to_cstring(ld.session, context.temp_allocator), LOGIN1 + ".Session", "SetIdleHint", nil, nil, "b", c.int(idle ? 1 : 0))
	sd_bus_flush(ld.bus)
}

// For `wlperch idle status` and setup.
logind_status :: proc() -> string {
	switch {
	case !ld.available:            return "unavailable"
	case !ld.managed:              return "standby"
	case !config.lock_before_sleep: return "on (no lock before sleep)"
	case ld.inhibit >= 0:          return "on (locks before sleep)"
	}
	return "on (no sleep inhibitor)"
}

logind_shutdown :: proc() {
	drop_inhibitor()
	if ld.bus != nil {
		sd_bus_flush_close_unref(ld.bus)
		ld.bus = nil
	}
}
