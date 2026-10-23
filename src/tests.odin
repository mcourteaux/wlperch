// Unit tests: `./build.sh test` (or `odin test src -collection:third_party=third_party`).
package main

import "core:os"
import "core:testing"

@(test)
test_shell_int :: proc(t: ^testing.T) {
	testing.expect_value(t, shell_int("3440"), 3440)
	testing.expect_value(t, shell_int("$((3440+1440))"), 4880)
	testing.expect_value(t, shell_int("$((3440 + 1440 * 2))"), 6320)
	testing.expect_value(t, shell_int("$(( (10 - 4) / 2 ))"), 3)
	testing.expect_value(t, shell_int("-200"), -200)
}

PRESET_SAMPLE :: `#!/bin/bash
if [[ "$XDG_SESSION_TYPE" = "wayland" ]]; then
  if [[ ! -z "${SWAYSOCK}" ]]; then
    echo "
    output DP-3 pos 0 0 res 3440x1440
    output DP-1 pos 3440 0 res 2560x1440 transform 90
    output DP-2 pos $((3440+1440)) 0 res 1920x1080@60Hz scale 2
    output HDMI-A-1 disable
    workspace 9 output DP-2
    " > ~/.config/sway/config.d/20-monitors.conf
  else
    echo "
    monitor = DP-3, 3440x1440, 0x0      , 1
    " > $HOME/.config/hypr/monitors.conf
  fi
else
  xrandr --output DP-0 --off
fi
`

@(test)
test_parse_preset :: proc(t: ^testing.T) {
	dir := "/tmp/wlwidgets-test"
	os.make_directory_all(dir)
	path := "/tmp/wlwidgets-test/desk_and_tv.sh"
	testing.expect(t, os.write_entire_file(path, PRESET_SAMPLE) == nil)
	defer os.remove(path)

	p, ok := parse_preset(path)
	defer preset_destroy(&p)
	testing.expect(t, ok)
	testing.expect_value(t, p.label, "Desk and TV")
	testing.expect_value(t, len(p.outputs), 4)
	if len(p.outputs) != 4 {return}

	testing.expect_value(t, p.outputs[0].name, "DP-3")
	testing.expect_value(t, p.outputs[0].w, 3440)
	testing.expect_value(t, p.outputs[1].transform, "90")
	testing.expect_value(t, p.outputs[2].x, 4880)
	testing.expect_value(t, p.outputs[2].h, 1080)
	testing.expect_value(t, p.outputs[2].scale, 2)
	testing.expect_value(t, p.outputs[3].enabled, false)

	// Rotated output: logical size is swapped.
	_, _, w, h := preset_output_rect(p.outputs[1])
	testing.expect_value(t, w, 1440)
	testing.expect_value(t, h, 2560)
	// Scaled output: logical size is divided by the scale.
	_, _, w, h = preset_output_rect(p.outputs[2])
	testing.expect_value(t, w, 960)
}

@(test)
test_history_ring :: proc(t: ^testing.T) {
	h: History
	for i in 0 ..< HISTORY_MAX + 5 {history_push(&h, f32(i))}
	testing.expect_value(t, h.count, HISTORY_MAX)
	// Newest sample is last.
	testing.expect_value(t, history_get(&h, 3, 2), f32(HISTORY_MAX + 4))
	testing.expect_value(t, history_get(&h, 3, 0), f32(HISTORY_MAX + 2))
}

@(test)
test_city_from_tz :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, city_from_tz("America/New_York"), "New York")
	testing.expect_value(t, city_from_tz("America/Argentina/Buenos_Aires"), "Buenos Aires")
	testing.expect_value(t, city_from_tz("UTC"), "UTC")
}

@(test)
test_format_offset :: proc(t: ^testing.T) {
	testing.expect_value(t, format_offset(120), "UTC+2")
	testing.expect_value(t, format_offset(-240), "UTC−4")
	testing.expect_value(t, format_offset(330), "UTC+5:30")
	testing.expect_value(t, format_offset(0), "UTC+0")
}

@(test)
test_weather_codes :: proc(t: ^testing.T) {
	_, d := weather_desc(0, true)
	testing.expect_value(t, d, "Clear sky")
	icon, _ := weather_desc(0, false)
	testing.expect_value(t, icon, ICON_W_NIGHT)
	_, d = weather_desc(95, true)
	testing.expect_value(t, d, "Thunderstorm")
}
