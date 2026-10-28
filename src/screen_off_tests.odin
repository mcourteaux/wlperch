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
