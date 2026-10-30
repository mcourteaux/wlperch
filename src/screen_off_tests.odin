// Monitors off after a long idle: which ones, and the sway command.
package main

import "core:testing"

@(test)
test_screen_off_targets :: proc(t: ^testing.T) {
	outs := []Out_Power{{"DP-1", true, true}, {"DP-2", true, false}, {"HDMI-A-1", false, true}, {"eDP-1", true, true}}
	names := screens_to_power_off(outs)
	// Only enabled monitors that are on: one already dark stays the lock screen's / the user's.
	testing.expect_value(t, len(names), 2)
	testing.expect_value(t, names[0], "DP-1")
	testing.expect_value(t, names[1], "eDP-1")
	testing.expect_value(t, len(screens_to_power_off([]Out_Power{{"DP-1", true, false}})), 0)
	testing.expect_value(t, screen_power_command(names, false), `output "DP-1" power off; output "eDP-1" power off`)
	testing.expect_value(t, screen_power_command(names[:1], true), `output "DP-1" power on`)
	testing.expect_value(t, screen_power_command(nil, true), "")
}

// Monitors-off follows the idle lock: no lock in effect, no monitors off.
@(test)
test_screen_off_follows_idle_lock :: proc(t: ^testing.T) {
	// swayidle locks after 300 s: monitors may go off.
	testing.expect(t, screen_off_allowed(idle_policy_of(false, 300, 0)))
	// swayidle stopped (a game stream's prep command), no idle_lock_seconds: they stay on.
	testing.expect(t, !screen_off_allowed(idle_policy_of(false, 0, 0)))
	// Locked by hand while swayidle is stopped: still no idle lock, still on.
	testing.expect(t, !screen_off_allowed(idle_policy_of(true, 0, 0)))
	// wlperch locks by itself (idle_lock_seconds): allowed without swayidle.
	testing.expect(t, screen_off_allowed(idle_policy_of(false, 0, 600)))
	// The earlier of the two locks is the policy's.
	testing.expect_value(t, idle_policy_of(false, 300, 600).lock_after, 300)
	testing.expect_value(t, idle_policy_of(false, 900, 600).lock_after, 600)
}

@(test)
test_game_hold_pick :: proc(t: ^testing.T) {
	covers := []Fs_Cover{{output = "DP-1", app = "firefox"}, {output = "DP-3", app = "game.exe", game = true, why = "Windows program game.exe"}}
	hold, app, why := game_hold_pick(covers, true)
	testing.expect(t, hold && app == "game.exe" && why == "Windows program game.exe")
	hold, _, _ = game_hold_pick(covers, false)
	testing.expect(t, !hold, "games_keep_awake = false")
	hold, _, _ = game_hold_pick(covers[:1], true)
	testing.expect(t, !hold, "a fullscreen app that isn't a game")
	hold, _, _ = game_hold_pick(nil, true)
	testing.expect(t, !hold)
}
