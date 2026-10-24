// Unit tests for the idle countdown: finding swayidle's lock timeout and
// fitting the countdown into it.
package main

import "core:math"
import "core:testing"

@(test)
test_countdown_swayidle_args :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// The usual setup (swayidle.sh after the shell expanded it): the
	// pgrep check of the locker is not a lock.
	args := []string {
		"-w",
		"timeout", "300", "wlperch lock -f",
		"timeout", "360", `swaymsg "output * power off"`, "resume", `swaymsg "output * power on"`,
		"timeout", "60", `pgrep -xu "$USER" wlperch-lock >/dev/null && swaymsg "output * power off"`,
		"resume", `pgrep -xu "$USER" wlperch-lock >/dev/null && swaymsg "output * power on"`,
		"before-sleep", "wlperch lock -f",
		"lock", "wlperch lock -f",
		"unlock", `pkill -xu "$USER" -SIGUSR1 swaylock`,
	}
	secs, found, events, _ := swayidle_lock_timeout(args)
	testing.expect(t, found && events)
	testing.expect_value(t, secs, 300)

	// swaylock, loginctl, the shortest lock wins.
	secs, found, _, _ = swayidle_lock_timeout({"timeout", "600", "swaylock -f -c 000000", "timeout", "240", "loginctl lock-session"})
	testing.expect(t, found)
	testing.expect_value(t, secs, 240)

	// Only before-sleep: no idle lock.
	_, found, events, _ = swayidle_lock_timeout({"-w", "before-sleep", "wlperch lock -f"})
	testing.expect(t, !found && events)

	// No events: the config file (-C) is read instead.
	_, _, events2, conf := swayidle_lock_timeout({"-w", "-C", "/x/conf"})
	testing.expect(t, !events2)
	testing.expect_value(t, conf, "/x/conf")

	testing.expect(t, !is_lock_command("loginctl unlock-session"))
	testing.expect(t, !is_lock_command("pgrep swaylock && swaymsg 'output * power off'"))
}

@(test)
test_countdown_swayidle_config :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "# idle\ntimeout 120 'swaymsg \"output * power off\"' resume 'swaymsg \"output * power on\"'\n" +
		"timeout 90 \"wlperch lock -f\" # lock\nbefore-sleep 'wlperch lock -f'\n"
	w := shell_words(text)
	testing.expect_value(t, len(w), 10)
	if len(w) == 10 {
		testing.expect_value(t, w[2], `swaymsg "output * power off"`)
		testing.expect_value(t, w[8], "before-sleep")
	}
	secs, found, _, _ := swayidle_lock_timeout(w)
	testing.expect(t, found)
	testing.expect_value(t, secs, 90)
}

@(test)
test_countdown_plan :: proc(t: ^testing.T) {
	// swayidle locks: the countdown follows it.
	testing.expect_value(t, countdown_plan(300, 0, 15), Countdown_Plan{lock_after = 300, length = 15})
	// Nothing locks on idle: no countdown.
	testing.expect_value(t, countdown_plan(0, 0, 15), Countdown_Plan{})
	// wlperch locks by itself, earlier than swayidle (or without it).
	testing.expect_value(t, countdown_plan(300, 120, 15), Countdown_Plan{lock_after = 120, length = 15, self_lock = true})
	testing.expect_value(t, countdown_plan(0, 120, 15), Countdown_Plan{lock_after = 120, length = 15, self_lock = true})
	// swayidle's comes first (or at the same time): swayidle's lock, no second one.
	testing.expect_value(t, countdown_plan(300, 300, 15), Countdown_Plan{lock_after = 300, length = 15})
	// Off, and fitted into a short timeout.
	testing.expect_value(t, countdown_plan(300, 0, 0), Countdown_Plan{lock_after = 300})
	testing.expect_value(t, countdown_plan(10, 0, 15), Countdown_Plan{lock_after = 10, length = 5})
	testing.expect_value(t, countdown_plan(6, 0, 15), Countdown_Plan{lock_after = 6})
}

// The arc's angle stand-in orders directions like their clockwise angle.
@(test)
test_countdown_pseudo_angle :: proc(t: ^testing.T) {
	prev := f32(-1)
	for i in 0 ..< 360 {
		a := f32(i) * math.PI / 180
		pa := pseudo_angle(math.sin(a), math.cos(a))
		testing.expectf(t, pa > prev && pa >= 0 && pa < 4, "angle %d: %v after %v", i, pa, prev)
		prev = pa
	}
}
