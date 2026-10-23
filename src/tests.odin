// Unit tests: `./build.sh test` (or `odin test src -collection:third_party=third_party`).
package main

import "core:encoding/ini"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
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

@(test)
test_children_get_default_sigpipe :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	out, ok := run({"sh", "-c", "grep SigIgn /proc/self/status"})
	testing.expect(t, ok)
	f := strings.fields(out)
	testing.expect(t, len(f) == 2)
	if len(f) != 2 {return}
	mask, _ := strconv.parse_u64(f[1], 16)
	testing.expect_value(t, mask & (1 << 12), 0) // bit for signal 13 (SIGPIPE)
}

// Without BlueZ (busctl fails) the Bluetooth card must be omitted.
@(test)
test_bluetooth_absent :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir :: "/tmp/wlwidgets-test/nobt"
	os.make_directory_all(dir)
	testing.expect(t, os.write_entire_file(dir + "/busctl", "#!/bin/sh\nexit 1\n", os.Permissions_Default_File + {.Execute_User}) == nil)
	old := os.get_env("PATH", context.temp_allocator)
	os.set_env("PATH", strings.concatenate({dir, ":", old}))
	defer os.set_env("PATH", old)

	bluetooth_refresh_now()
	testing.expect(t, !bluetooth.ok || !bluetooth.adapter, "card guard must hide the Bluetooth section")
}

PANELS_SAMPLE :: `
[panel.main]
header = true
columns = audio system | weather clocks

[panel.perf]
title = "Performance"
width = 700
columns = cpu memory | processes bogus
`

@(test)
test_panels_load :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	m, _ := ini.load_map_from_string(PANELS_SAMPLE, context.allocator)
	clear(&panels)
	defer clear(&panels)
	panels_load(PANELS_SAMPLE, m)
	testing.expect_value(t, len(panels), 2)
	if len(panels) != 2 {return}
	testing.expect_value(t, panels[0].name, "main")
	testing.expect(t, panels[0].header)
	testing.expect_value(t, len(panels[0].columns), 2)
	testing.expect_value(t, panels[1].title, "Performance")
	testing.expect_value(t, panels[1].width, 700)
	// Unknown modules are dropped, known ones kept in order.
	testing.expect_value(t, len(panels[1].columns[1]), 1)
	testing.expect_value(t, panels[1].columns[1][0], "processes")
	testing.expect_value(t, panel_find("perf"), 1)
	testing.expect_value(t, panel_find("nope"), -1)
}
