// wlperch as the idle manager: swayidle's timeouts carried over, its exec
// lines switched off, monitors off sooner once locked, named holds, and the
// daemon as a systemd service.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_swayidle_timeouts :: proc(t: ^testing.T) {
	// The user's swayidle.sh, as its process sees it.
	args := []string {
		"-w", "timeout", "300", "wlperch lock -f",
		"timeout", "360", `swaymsg "output * power off"`, "resume", `swaymsg "output * power on"`,
		"timeout", "60", `pgrep -xu "$USER" wlperch-lock >/dev/null && swaymsg "output * power off"`,
		"resume", `pgrep -xu "$USER" wlperch-lock >/dev/null && swaymsg "output * power on"`,
		"before-sleep", "wlperch lock -f", "lock", "wlperch lock -f",
	}
	lock, off, locked_off := swayidle_timeouts(args)
	testing.expect_value(t, lock, 300)
	testing.expect_value(t, off, 360)
	testing.expect_value(t, locked_off, 60)
	// swaylock and wlopm's dpms count too; nothing at all is 0.
	lock, off, locked_off = swayidle_timeouts([]string{"timeout", "600", "swaylock -f", "timeout", "900", "wlopm --off '*'", "timeout", "1200", "wlr-randr dpms off"})
	testing.expect_value(t, lock, 600)
	testing.expect_value(t, off, 1200)
	testing.expect_value(t, locked_off, 0)
	lock, off, locked_off = swayidle_timeouts(nil)
	testing.expect(t, lock == 0 && off == 0 && locked_off == 0)
}

@(test)
test_idle_rewrite :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/wlperch-idle-test-%d", os.get_pid())
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	script := fmt.tprintf("%s/idle.sh", dir)
	other := fmt.tprintf("%s/other.sh", dir)
	_ = os.write_entire_file(script, transmute([]u8)string("#!/bin/sh\nexec swayidle -w timeout 300 'wlperch lock -f'\n"))
	_ = os.write_entire_file(other, transmute([]u8)string("#!/bin/sh\necho hi\n"))
	text := fmt.tprintf("# Idle\nexec %s\nexec wljoywake\nexec_always swayidle -w timeout 60 x\n# exec swayidle\n  exec %s\n", script, other)
	out, n := idle_rewrite(text)
	testing.expect_value(t, n, 2)
	// Both swayidle starters commented out, with the note; the rest as it was.
	want := fmt.tprintf("# Idle\n%s\n# exec %s\nexec wljoywake\n%s\n# exec_always swayidle -w timeout 60 x\n# exec swayidle\n  exec %s\n", IDLE_COMMENT, script, IDLE_COMMENT, other)
	testing.expect_value(t, out, want)
	// Again: nothing left to do.
	_, n = idle_rewrite(out)
	testing.expect_value(t, n, 0)
}

@(test)
test_screen_off_step :: proc(t: ^testing.T) {
	base := time.Tick{1_000_000_000_000}
	at :: proc(b: time.Tick, s: int) -> time.Tick {return time.tick_add(b, time.Duration(s) * time.Second)}
	idle, locked := 360 * time.Second, 60 * time.Second
	// Idle 30 s, not locked: look again soon (a lock may come up).
	st := screen_off_step(at(base, 30), base, {}, idle, locked, true)
	testing.expect(t, !st.off && st.due == at(base, 32))
	// Locked at 300 s (the idle lock): off 60 s later, not at once.
	st = screen_off_step(at(base, 302), base, at(base, 300), idle, locked, true)
	testing.expect(t, !st.off && st.due == at(base, 360))
	st = screen_off_step(at(base, 360), base, at(base, 300), idle, locked, true)
	testing.expect(t, st.off && st.locked)
	// Locked by hand right away: 60 s.
	st = screen_off_step(at(base, 60), base, base, idle, locked, true)
	testing.expect(t, st.off && st.locked)
	// Not locked, 360 s idle: off, if the policy allows it…
	st = screen_off_step(at(base, 360), base, {}, idle, 0, true)
	testing.expect(t, st.off && !st.locked)
	// … else held: look again later.
	st = screen_off_step(at(base, 360), base, {}, idle, 0, false)
	testing.expect(t, !st.off && st.due != {})
	// Locked while the idle policy holds the plain timeout: the lock's still counts.
	st = screen_off_step(at(base, 400), base, at(base, 330), idle, locked, false)
	testing.expect(t, st.off && st.locked)
	// Both off: nothing to do.
	st = screen_off_step(at(base, 400), base, {}, 0, 0, true)
	testing.expect(t, !st.off && st.due == {})
}

@(test)
test_idle_holds_file :: proc(t: ^testing.T) {
	text := idle_holds_format(4242, []Idle_Hold{{"sunshine", 1234}, {"movie", 0}})
	testing.expect_value(t, text, "4242\tsunshine\t1234\n4242\tmovie\t0\n")
	daemon, holds := idle_holds_parse(text)
	testing.expect_value(t, daemon, 4242)
	testing.expect_value(t, len(holds), 2)
	testing.expect(t, holds[0].name == "sunshine" && holds[0].pid == 1234)
	testing.expect(t, holds[1].name == "movie" && holds[1].pid == 0)
	_, holds = idle_holds_parse("garbage\n\n1\t\t3\n")
	testing.expect_value(t, len(holds), 0)
	// Our own process runs; pid 0 / a negative one never does.
	testing.expect(t, pid_alive(os.get_pid()))
	testing.expect(t, !pid_alive(0))
}

@(test)
test_idle_managed :: proc(t: ^testing.T) {
	old := config.lock_idle_seconds
	defer config.lock_idle_seconds = old
	config.lock_idle_seconds = 300
	testing.expect(t, idle_managed(idle_policy_of(false, 0, 300)))
	// Any swayidle running keeps sleep and loginctl lock its job.
	testing.expect(t, !idle_managed(idle_policy_of(false, 0, 300, true)))
	testing.expect(t, !idle_managed(idle_policy_of(false, 600, 300)))
	config.lock_idle_seconds = 0
	testing.expect(t, !idle_managed(idle_policy_of(false, 0, 0)))
}

@(test)
test_daemon_service_bits :: proc(t: ^testing.T) {
	testing.expect_value(t, sway_pid_from_sock("/run/user/1000/sway-ipc.1000.2189.sock"), 2189)
	testing.expect_value(t, sway_pid_from_sock("/tmp/other.sock"), 0)
	text := "x\nexec wlperch daemon\ny\n"
	testing.expect_value(t, sway_file_daemon_line(text, false), text)
	out := sway_file_daemon_line(text, true)
	testing.expect(t, strings.contains(out, "\n# exec wlperch daemon\n"))
	testing.expect(t, !strings.contains(out, "\nexec wlperch daemon"))
	testing.expect(t, strings.contains(DAEMON_UNIT, "Restart=on-failure"))
	testing.expect(t, strings.contains(DAEMON_UNIT, "KillMode=process"))
}
