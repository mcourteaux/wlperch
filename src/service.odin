// The daemon as a systemd user service (optional): setup's "Background
// service" card can switch the daemon from sway's `exec wlperch daemon` to
// ~/.config/systemd/user/wlperch.service, which restarts it if it crashes
// (Restart=on-failure; a clean `wlperch quit` stays quit) and is bound to
// the graphical session (sway-systemd's session.sh, or any setup that starts
// graphical-session.target and imports WAYLAND_DISPLAY and SWAYSOCK).
// "Back to sway" undoes it. Without systemd nothing changes: sway's exec
// line is the default and keeps working.
//
// KillMode=process: only the daemon itself is stopped with the service.
// Apps started from the launcher stay in the service's cgroup, and a
// restart must not take them (or a running lock screen) down with it.
//
// Under systemd the daemon starts with systemd's environment: it takes over
// sway's (/proc/<sway pid>/environ, found by SWAYSOCK) first, so apps it
// launches get the same environment as from a sway key binding.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

DAEMON_UNIT_NAME :: "wlperch.service"

DAEMON_UNIT :: `# wlperch's background daemon (written by wlperch setup; "Back to sway"
# on the Background service card removes it).
[Unit]
Description=wlperch daemon (panels, notifications, idle lock)
Documentation=https://github.com/mcourteaux/wlperch
PartOf=graphical-session.target
After=graphical-session.target
Requisite=graphical-session.target

[Service]
ExecStart=%h/.local/bin/wlperch daemon
Environment=WLPERCH_SYSTEMD=1
Restart=on-failure
RestartSec=1
# Only the daemon: apps it launched and a lock screen keep running.
KillMode=process

[Install]
WantedBy=graphical-session.target
`

@(private = "file")
user_unit_dir :: proc() -> string {
	return strings.concatenate({sway_config_home(), "/systemd/user"}, context.temp_allocator)
}

daemon_unit_path :: proc() -> string {
	return strings.concatenate({user_unit_dir(), "/", DAEMON_UNIT_NAME}, context.temp_allocator)
}

// Enabled: systemd starts the daemon with the graphical session.
daemon_unit_enabled :: proc() -> bool {
	return os.exists(strings.concatenate({user_unit_dir(), "/graphical-session.target.wants/", DAEMON_UNIT_NAME}, context.temp_allocator))
}

// The sway file's daemon line, commented out while systemd starts it.
sway_file_daemon_line :: proc(text: string, systemd: bool) -> string {
	if !systemd {return text}
	out, _ := strings.replace(text, "\nexec wlperch daemon\n", "\n# systemd starts it instead (wlperch.service; setup's Background service card):\n# exec wlperch daemon\n", 1, context.temp_allocator)
	return out
}

// sway's pid from SWAYSOCK (".../sway-ipc.<uid>.<pid>.sock").
sway_pid_from_sock :: proc(sock: string) -> int {
	base := sock[strings.last_index_byte(sock, '/') + 1:]
	f := strings.split(base, ".", context.temp_allocator)
	if len(f) < 4 || f[0] != "sway-ipc" {return 0}
	return strconv.parse_int(f[2]) or_else 0
}

// Started by systemd: take sway's environment (before any thread exists).
daemon_env_from_sway :: proc() {
	if os.get_env("WLPERCH_SYSTEMD", context.temp_allocator) != "1" || os.get_env("WLPERCH_SWAY_ENV", context.temp_allocator) == "1" {return}
	pid := sway_pid_from_sock(os.get_env("SWAYSOCK", context.temp_allocator))
	data, err := os.read_entire_file(fmt.tprintf("/proc/%d/environ", pid), context.temp_allocator)
	if pid <= 0 || err != nil {
		log.warn("systemd: sway's environment not found (SWAYSOCK); launched apps get systemd's")
		return
	}
	SKIP :: [?]string{"INVOCATION_ID", "JOURNAL_STREAM", "NOTIFY_SOCKET", "MANAGER_PID", "SYSTEMD_EXEC_PID", "LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES", "WATCHDOG_PID", "WATCHDOG_USEC", "SHLVL", "_"}
	n := 0
	outer: for kv in strings.split(string(data), "\x00", context.temp_allocator) {
		k, _, v := strings.partition(kv, "=")
		if k == "" {continue}
		for s in SKIP {if k == s {continue outer}}
		posix.setenv(strings.clone_to_cstring(k, context.temp_allocator), strings.clone_to_cstring(v, context.temp_allocator), true)
		n += 1
	}
	for k in ([]cstring{"INVOCATION_ID", "JOURNAL_STREAM", "NOTIFY_SOCKET", "SYSTEMD_EXEC_PID", "MANAGER_PID"}) {posix.unsetenv(k)}
	posix.setenv("WLPERCH_SWAY_ENV", "1", true) // a re-exec keeps it
	log.infof("systemd: started as %s, with sway's environment (%d variables)", DAEMON_UNIT_NAME, n)
}

// ---- Setup ----------------------------------------------------------------------------

@(private = "file")
service_done :: proc(ok: bool, msg: string) {
	sync.guard(&setup.mu)
	c := &setup.comps[.Service]
	c.busy = false
	c.msg_ok = ok
	delete(c.message)
	c.message = strings.clone(msg)
	log.infof("setup service: %s", msg)
}

systemctl_user :: proc(args: ..string) -> (ok: bool, out: string) {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "systemctl", "--user")
	append(&argv, ..args)
	o, code := run_code_env(argv[:], nil, true, 10 * time.Second, context.temp_allocator)
	return code == 0, strings.trim_space(o)
}

// systemd's graphical session runs (the unit needs it).
graphical_session_active :: proc() -> bool {
	ok, _ := systemctl_user("is-active", "--quiet", "graphical-session.target")
	return ok
}

@(private = "file")
wait_daemon :: proc(up: bool, timeout: time.Duration) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		if ipc_send("ping") == up {return true}
		time.sleep(100 * time.Millisecond)
	}
	return false
}

// The sway file again, with or without its exec line (only wlperch's own).
@(private = "file")
rewrite_sway_file :: proc() -> string {
	if setup.comps[.Sway].state != .Installed && setup.comps[.Sway].state != .Outdated {return "the sway file isn't wlperch's: check that nothing else runs `exec wlperch daemon`"}
	sway_keys_load()
	if !write_through(sway_file(), sway_file_text(sway_keys.list[:])) {return "couldn't rewrite the sway file"}
	return ""
}

setup_service_systemd :: proc() {
	if !graphical_session_active() {
		service_done(false, "needs systemd's graphical session first (Desktop portal card: Start session)")
		return
	}
	os.make_directory_all(user_unit_dir())
	if !write_file_atomic(daemon_unit_path(), DAEMON_UNIT) {
		service_done(false, fmt.tprintf("couldn't write %s", daemon_unit_path()))
		return
	}
	systemctl_user("daemon-reload")
	if ok, out := systemctl_user("enable", DAEMON_UNIT_NAME); !ok {
		service_done(false, fmt.tprintf("systemctl --user enable failed: %s", out))
		return
	}
	note := rewrite_sway_file()
	// The running daemon hands over to the service.
	if ipc_send("ping") {
		ipc_send("quit")
		wait_daemon(false, 5 * time.Second)
	}
	if ok, out := systemctl_user("start", DAEMON_UNIT_NAME); !ok {
		service_done(false, fmt.tprintf("systemctl --user start failed: %s", out))
		return
	}
	up := wait_daemon(true, 5 * time.Second)
	msg := up ? "systemd runs the daemon now (restarts it after a crash)" : "enabled, but the daemon didn't come up: journalctl --user -u wlperch"
	if note != "" {msg = fmt.tprintf("%s; %s", msg, note)}
	service_done(up, msg)
}

setup_service_sway :: proc() {
	systemctl_user("disable", "--now", DAEMON_UNIT_NAME)
	wait_daemon(false, 5 * time.Second)
	os.remove(daemon_unit_path())
	systemctl_user("daemon-reload")
	note := rewrite_sway_file()
	exe := os.exists(setup.bin_path) ? setup.bin_path : setup.self_path
	launch_detached({exe, "daemon"})
	up := wait_daemon(true, 5 * time.Second)
	msg := up ? "sway starts the daemon again (systemd's unit removed)" : "unit removed, but the daemon didn't start"
	if note != "" {msg = fmt.tprintf("%s; %s", msg, note)}
	service_done(up, msg)
}

// Start / stop through systemd when it runs the daemon.
setup_service_start_systemd :: proc() {
	ok, out := systemctl_user("start", DAEMON_UNIT_NAME)
	up := ok && wait_daemon(true, 5 * time.Second)
	service_done(up, up ? "started (systemd)" : fmt.tprintf("didn't start: %s", out))
}

setup_service_stop_systemd :: proc() {
	ok, out := systemctl_user("stop", DAEMON_UNIT_NAME)
	service_done(ok, ok ? "stopped (systemd starts it again at the next login)" : out)
}
