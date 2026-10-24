// Unit tests for the bar's audio module: scroll steps stay within 0–100 %.
package main

import "core:encoding/ini"
import "core:testing"

@(test)
test_bar_volume_step :: proc(t: ^testing.T) {
	// steps < 0: scrolled up (louder).
	testing.expect_value(t, bar_volume_step(40, -1, 5), 45)
	testing.expect_value(t, bar_volume_step(40, -3, 5), 55)
	testing.expect_value(t, bar_volume_step(97, -1, 5), 100)
	testing.expect_value(t, bar_volume_step(100, -1, 5), 100)
	// Above 100 % (set elsewhere): up does nothing, down lowers it.
	testing.expect_value(t, bar_volume_step(130, -2, 5), 130)
	testing.expect_value(t, bar_volume_step(130, 1, 5), 125)
	testing.expect_value(t, bar_volume_step(40, 1, 5), 35)
	testing.expect_value(t, bar_volume_step(3, 1, 5), 0)
	testing.expect_value(t, bar_volume_step(0, 2, 5), 0)
	testing.expect_value(t, bar_volume_step(50, -1, 10), 60)
}

@(test)
test_bar_config_audio :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	saved := bar_cfg
	defer bar_cfg = saved
	bar_cfg = {}
	defaults, _ := ini.load_map_from_string(DEFAULT_CONFIG, context.temp_allocator)
	bar_config_load(defaults, defaults)
	found := false
	for m in bar_cfg.sides[2] {if m == .Audio {found = true}}
	testing.expect(t, found, "audio is among the default right-side modules")
	testing.expect_value(t, bar_cfg.volume_step, 5)
	// waybar's name works too; the step is clamped.
	bar_cfg = {}
	user, _ := ini.load_map_from_string("[bar]\nright = pulseaudio clock\nvolume_step = 90\n", context.temp_allocator)
	bar_config_load(user, defaults)
	testing.expect_value(t, len(bar_cfg.sides[2]), 2)
	if len(bar_cfg.sides[2]) == 2 {testing.expect_value(t, bar_cfg.sides[2][0], Bar_Mod.Audio)}
	testing.expect_value(t, bar_cfg.volume_step, 25)
}
