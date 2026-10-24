#+feature dynamic-literals
// Unit tests: `./build.sh test` (or `odin test src -collection:third_party=third_party`).
package main

import "core:encoding/hex"
import "core:fmt"
import "core:encoding/ini"
import "core:encoding/json"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core:log"

import "xkb"

PRESET_SAMPLE :: `[popup]
width = 860

# [display.commented]
# DP-9 = off

[display.desk_and_tv]
DP-3 = 3440x1440 pos 0 0
DP-1 = mode 2560x1440 pos 3440 0 transform 90
DP-2 = 1920x1080@60Hz pos 4880,0 scale 2   ; the TV
HDMI-A-1 = off
workspaces = DP-2: 9 10, DP-3: 1
run = "echo hi"

[display.empty]
name = Typo

[display.tv]
name = Just the TV
DP-2 = 1920x1080 pos 0 0
DP-3 = disable
`

@(test)
test_display_presets :: proc(t: ^testing.T) {
	ps := presets_from_ini_text(PRESET_SAMPLE)
	defer {
		for &p in ps {preset_destroy(&p)}
		delete(ps)
	}
	testing.expect_value(t, len(ps), 2) // [display.empty] has no outputs
	if len(ps) != 2 {return}
	p := ps[0]
	testing.expect_value(t, p.key, "desk_and_tv")
	testing.expect_value(t, p.label, "Desk and TV")
	testing.expect_value(t, p.run, "echo hi")
	testing.expect_value(t, len(p.outputs), 4)
	if len(p.outputs) != 4 {return}

	testing.expect_value(t, p.outputs[0].name, "DP-3")
	testing.expect_value(t, p.outputs[0].w, 3440)
	testing.expect_value(t, p.outputs[0].scale, 0) // not given: left alone
	testing.expect_value(t, p.outputs[1].w, 2560)
	testing.expect_value(t, p.outputs[1].transform, "90")
	testing.expect_value(t, p.outputs[2].x, 4880)
	testing.expect_value(t, p.outputs[2].h, 1080)
	testing.expect_value(t, p.outputs[2].refresh, 60)
	testing.expect_value(t, p.outputs[2].scale, 2)
	testing.expect_value(t, p.outputs[3].enabled, false)
	testing.expect_value(t, len(p.workspaces), 3)
	if len(p.workspaces) == 3 {
		testing.expect_value(t, p.workspaces[1].ws, "10")
		testing.expect_value(t, p.workspaces[1].output, "DP-2")
		testing.expect_value(t, p.workspaces[2].output, "DP-3")
	}
	testing.expect_value(t, ps[1].label, "Just the TV")
	testing.expect_value(t, ps[1].outputs[1].enabled, false)

	// Rotated output: logical size is swapped.
	_, _, w, h := preset_output_rect(p.outputs[1])
	testing.expect_value(t, w, 1440)
	testing.expect_value(t, h, 2560)
	// Scaled output: logical size is divided by the scale.
	_, _, w, h = preset_output_rect(p.outputs[2])
	testing.expect_value(t, w, 960)
}

@(test)
test_display_default_presets :: proc(t: ^testing.T) {
	sync_outputs :: proc(outs: []Sway_Output) {
		clear(&sway.outputs)
		append(&sway.outputs, ..outs)
		sway.ok = true
	}
	defer {
		delete(sway.outputs)
		sway.outputs = {}
		sway.ok = false
	}
	sync_outputs({{name = "eDP-1", model = "Unknown", active = true, mode_w = 1920, mode_h = 1200, refresh = 60.001, scale = 1.25, transform = "normal"}})
	one := displays_default_presets()
	testing.expect(t, strings.contains(one, "[display.default]\nname = Default\neDP-1 = 1920x1200@60.001Hz pos 0 0 scale 1.25\n"), one)

	sync_outputs({
		{name = "DP-3", model = "LG ULTRAWIDE", active = true, mode_w = 3440, mode_h = 1440, refresh = 59.973, scale = 1, transform = "normal"},
		{name = "DP-1", model = "P27q-20", active = true, x = 3440, mode_w = 2560, mode_h = 1440, scale = 1, transform = "90"},
		{name = "HDMI-A-1", active = false, transform = "normal"},
	})
	many := displays_default_presets()
	ps := presets_from_ini_text(many)
	defer {
		for &p in ps {preset_destroy(&p)}
		delete(ps)
	}
	testing.expect_value(t, len(ps), 4) // all + one per monitor
	if len(ps) != 4 {return}
	testing.expect_value(t, ps[0].key, "all")
	testing.expect_value(t, ps[0].outputs[1].transform, "90")
	testing.expect_value(t, ps[0].outputs[1].x, 3440)
	testing.expect_value(t, ps[0].outputs[2].enabled, false)
	testing.expect_value(t, ps[2].key, "only-dp-1")
	testing.expect_value(t, ps[2].label, "P27q-20 only")
	testing.expect_value(t, ps[2].outputs[1].x, 0) // moved to the origin when alone
	testing.expect_value(t, ps[2].outputs[0].enabled, false)
	testing.expect_value(t, ps[3].label, "HDMI-A-1 only")
	testing.expect_value(t, ps[3].outputs[2].enabled, true)
	testing.expect_value(t, ps[3].outputs[2].w, 0) // never on: sway picks the mode
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
	dir :: "/tmp/wlperch-test/nobt"
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

@(test)
test_timetracker :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	saved := tracker
	defer tracker = saved
	tracker = Tracker{running = -1}
	append(&tracker.projects, Project{key = "neon", name = "NeonRAW", client = "Zec"})
	append(&tracker.projects, Project{key = "home", name = "Home Lab"})

	// Workspace names -> projects.
	testing.expect_value(t, project_for_workspace("NeonRAW 1"), 0)
	testing.expect_value(t, project_for_workspace("NeonRAW 12"), 0)
	testing.expect_value(t, project_for_workspace("Home Lab 2"), 1)
	testing.expect_value(t, project_for_workspace("NeonRAWx 1"), -1)
	testing.expect_value(t, project_for_workspace("NeonRAW"), -1)
	testing.expect_value(t, project_for_workspace("4"), -1)
	testing.expect_value(t, project_find("neon"), 0)
	testing.expect_value(t, project_find("home lab"), 1)

	// Log parsing (bad lines are skipped).
	LOG :: "2026-10-23T08:00:00Z\t2026-10-23T09:30:00Z\tNeonRAW\tZec\n" +
		"garbage line\n" +
		"2026-10-23T10:00:00Z\t2026-10-23T09:00:00Z\tNeonRAW\tZec\n" + // end before start
		"2026-10-22T23:00:00Z\t2026-10-23T01:00:00Z\tHome Lab\t\n"
	timelog_parse(LOG, &tracker.entries)
	testing.expect_value(t, len(tracker.entries), 2)
	testing.expect_value(t, tracker.entries[0].end - tracker.entries[0].start, 5400)

	// Totals clip segments to the requested range.
	day, _ := time.datetime_to_time(2026, 10, 23, 0, 0, 0)
	from := time.to_unix_seconds(day)
	totals := tracker_totals(from, from + 86400)
	testing.expect_value(t, totals["NeonRAW"], 5400)
	testing.expect_value(t, totals["Home Lab"], 3600) // only the part after midnight UTC
	testing.expect_value(t, fmt_duration(5400), "1:30")
	testing.expect_value(t, fmt_duration(3725, true), "1:02:05")
}

@(test)
test_group_lock_plan :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	saved := tracker
	defer tracker = saved
	tracker = Tracker{running = -1}
	append(&tracker.projects, Project{key = "neon", name = "NeonRAW"})
	append(&tracker.projects, Project{key = "acme", name = "ACME"})
	outs := []string{"DP-3", "DP-1"} // left to right
	ret := make(map[string]string)

	// Enter NeonRAW on the right monitor: the left one follows to "NeonRAW 1".
	vis := map[string]string{"DP-3" = "7", "DP-1" = "NeonRAW 2"}
	moves := plan_sync("1", "NeonRAW 2", "DP-1", outs, vis, &ret)
	testing.expect_value(t, len(moves), 1)
	if len(moves) == 1 {
		testing.expect_value(t, moves[0].output, "DP-3")
		testing.expect_value(t, moves[0].workspace, "NeonRAW 1")
		testing.expect(t, moves[0].pin)
	}
	testing.expect_value(t, ret["DP-3"], "7") // remembered for the way back

	// Leave NeonRAW on the right monitor: the left one returns to 7.
	vis = map[string]string{"DP-3" = "NeonRAW 1", "DP-1" = "1"}
	moves = plan_sync("NeonRAW 2", "1", "DP-1", outs, vis, &ret)
	testing.expect_value(t, len(moves), 1)
	if len(moves) == 1 {
		testing.expect_value(t, moves[0].output, "DP-3")
		testing.expect_value(t, moves[0].workspace, "7")
		testing.expect(t, !moves[0].pin)
	}

	// Switch project to project: the other monitor follows to ACME, and the
	// return workspace stays the non-project one remembered earlier.
	vis = map[string]string{"DP-3" = "NeonRAW 1", "DP-1" = "ACME 2"}
	moves = plan_sync("NeonRAW 2", "ACME 2", "DP-1", outs, vis, &ret)
	testing.expect_value(t, len(moves), 1)
	if len(moves) == 1 {testing.expect_value(t, moves[0].workspace, "ACME 1")}
	testing.expect_value(t, ret["DP-3"], "7")

	// Moving between plain workspaces does nothing; so does staying put.
	vis = map[string]string{"DP-3" = "7", "DP-1" = "2"}
	testing.expect_value(t, len(plan_sync("1", "2", "DP-1", outs, vis, &ret)), 0)
	testing.expect_value(t, len(plan_sync("2", "2", "DP-1", outs, vis, &ret)), 0)
	// Within the same project (NeonRAW 1 -> NeonRAW 2 on one monitor): nothing.
	testing.expect_value(t, len(plan_sync("NeonRAW 1", "NeonRAW 2", "DP-1", outs, vis, &ret)), 0)
}

@(test)
test_breaks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	saved := tracker
	defer tracker = saved
	tracker = Tracker{running = -1}
	append(&tracker.projects, Project{key = "neon", name = "NeonRAW"})
	LOG :: "2026-10-23T08:00:00Z\t2026-10-23T10:00:00Z\tNeonRAW\tZec\n" +
		"2026-10-23T10:00:00Z\t2026-10-23T10:15:00Z\tNeonRAW\tZec\tidle\n" +
		"2026-10-23T10:15:00Z\t2026-10-23T11:00:00Z\tNeonRAW\tZec\n" +
		"2026-10-23T11:00:00Z\t2026-10-23T11:05:00Z\tNeonRAW\tZec\tidle\n" +
		"2026-10-23T12:00:00Z\t2026-10-23T12:30:00Z\t(no project)\t\tidle\n"
	timelog_parse(LOG, &tracker.entries)
	testing.expect_value(t, len(tracker.entries), 5)
	testing.expect(t, tracker.entries[1].idle)
	testing.expect(t, !tracker.entries[0].idle)

	day, _ := time.datetime_to_time(2026, 10, 23, 0, 0, 0)
	from := time.to_unix_seconds(day)
	// Breaks don't count as work.
	work := tracker_totals(from, from + 86400)
	testing.expect_value(t, work["NeonRAW"], 2 * 3600 + 45 * 60)
	b := tracker_breaks(from, from + 86400)
	testing.expect_value(t, b["NeonRAW"].count, 2)
	testing.expect_value(t, b["NeonRAW"].secs, 20 * 60)
	testing.expect_value(t, b[NO_PROJECT].count, 1)
	testing.expect_value(t, b[NO_PROJECT].secs, 30 * 60)
}

@(test)
test_jsonc_array_end :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, text: string, want_last: string) {
		open := strings.index_byte(text, '[')
		_, last, ok := jsonc_array_end(text, open)
		testing.expect(t, ok)
		got := last < 0 ? "<empty>" : text[:last]
		testing.expect_value(t, got, want_last)
	}
	check(t, `["a", "b"]`, `["a", "b"`)
	check(t, "[\n  \"a\",\n  \"clock\" // the time\n]", "[\n  \"a\",\n  \"clock\"")
	check(t, "[\"a\" /* x ] */ ]", "[\"a\"")
	check(t, "[ // only a comment ]\n]", "<empty>")
	check(t, `["a]b"]`, `["a]b"`)
}

// Undoing what setup's "Add to my bar" inserts.
@(test)
test_jsonc_remove :: proc(t: ^testing.T) {
	hooked := "{\n    \"include\": [\"wlperch.jsonc\"],\n    \"modules-right\": [\"clock\", \"custom/wlperch\"],\n    \"custom/wlperch\": {}\n}"
	text := jsonc_remove_strings(hooked, "wlperch.jsonc")
	text = jsonc_remove_empty_member(text, "include")
	text = jsonc_remove_strings(text, "custom/wlperch", exact = true)
	// The user's own definition (an object key) stays.
	testing.expect_value(t, text, "{\n    \"modules-right\": [\"clock\"],\n    \"custom/wlperch\": {}\n}")

	// First element, other includes kept, exact names only.
	text = jsonc_remove_strings(`["custom/media-prev", "group/media", "custom/media-prev2"]`, "custom/media-prev", exact = true)
	testing.expect_value(t, text, `["group/media", "custom/media-prev2"]`)
	text = jsonc_remove_strings(`"include": ["a.jsonc", "~/.config/waybar/wlperch.jsonc"]`, "wlperch.jsonc")
	testing.expect_value(t, jsonc_remove_empty_member(text, "include"), `"include": ["a.jsonc"]`)
}

@(test)
test_sensor_history_binary :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	now: f64 = 1_800_000_000
	cutoff := now - SENSOR_HISTORY_DAYS * 86400
	h: map[string][dynamic]Sensor_Sample
	// Samples outside the window never get in; non-increasing times are ignored.
	testing.expect(t, !history_append(&h, "dev/temp", cutoff - 1, 20, cutoff))
	testing.expect(t, history_append(&h, "dev/temp", cutoff + 10, 21.5, cutoff))
	testing.expect(t, history_append(&h, "dev/temp", now, 22.25, cutoff))
	testing.expect(t, !history_append(&h, "dev/temp", now, 23, cutoff))
	testing.expect(t, history_append(&h, "air/co2", now - 3600, 612, cutoff))

	data := history_encode(h)
	testing.expect_value(t, string(data[:4]), SENSOR_HISTORY_MAGIC)
	back: map[string][dynamic]Sensor_Sample
	testing.expect(t, history_decode(data, &back, cutoff))
	testing.expect_value(t, len(back), 2)
	testing.expect_value(t, len(back["dev/temp"]), 2)
	testing.expect_value(t, back["dev/temp"][1].v, 22.25)
	testing.expect_value(t, back["air/co2"][0].t, now - 3600)

	// A later cutoff drops what aged out, on decode and on trim.
	later: map[string][dynamic]Sensor_Sample
	history_decode(data, &later, cutoff + 60)
	testing.expect_value(t, len(later["dev/temp"]), 1)
	testing.expect(t, history_trim(&back, cutoff + 60))
	testing.expect_value(t, len(back["dev/temp"]), 1)
	testing.expect(t, !history_trim(&back, cutoff + 60))

	// Truncated file: keeps what was readable, reports the damage.
	cut: map[string][dynamic]Sensor_Sample
	testing.expect(t, !history_decode(data[:len(data) - 5], &cut, cutoff))
	testing.expect(t, !history_decode(transmute([]byte)string("nope"), &cut, cutoff))
}

@(test)
test_notification_markup :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, strip_markup("<b>report.pdf</b> is ready &amp; waiting"), "report.pdf is ready & waiting")
	testing.expect_value(t, strip_markup(`<a href="https://x">link</a> &lt;3 &#65;&#x42;`), "link <3 AB")
	testing.expect_value(t, strip_markup("one<br/>two"), "one\ntwo")
	testing.expect_value(t, strip_markup("a < b"), "a < b")
	testing.expect_value(t, strip_markup("  plain  "), "plain")
}

@(test)
test_notification_history_binary :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	now := time.to_unix_seconds(time.now())
	px := make([]u32, ICON_PX * ICON_PX)
	for &p, i in px {p = u32(i) | 0xff000000}
	icon := &Notif_Icon{key = 42, size = ICON_PX, px = px, rounded = true}
	mk :: proc(id: u32, at: i64, app, summary: string, icon: ^Notif_Icon, transient := false) -> ^Notification {
		n := new(Notification)
		n^ = {id = id, at = at, app = strings.clone(app), summary = strings.clone(summary), body = strings.clone("body"), icon = icon, urgency = 1, value = -1, transient = transient}
		return n
	}
	list := []^Notification{
		mk(1, now - 8 * 86400, "Old", "too old", nil),
		mk(2, now - 3600, "Firefox", "Download complete", icon),
		mk(3, now, "Volume", "65%", nil, transient = true),
		mk(4, now, "Slack", "Server down", icon),
	}
	list[3].read = true
	data := notifications_encode(list, 4, true)
	// One icon stored once for two entries; the transient one isn't stored.
	back, next_id, dnd := notifications_decode(data, now - NOTIFY_HISTORY_DAYS * 86400)
	testing.expect_value(t, next_id, 4)
	testing.expect(t, dnd)
	testing.expect_value(t, len(back), 2) // "Old" aged out, "Volume" transient
	if len(back) == 2 {
		testing.expect_value(t, back[0].summary, "Download complete")
		testing.expect_value(t, back[1].app, "Slack")
		testing.expect(t, back[1].read)
		testing.expect(t, back[0].icon != nil && back[0].icon == back[1].icon)
		testing.expect(t, back[0].icon != nil && back[0].icon.px[5] == px[5] && back[0].icon.rounded)
	}
	// Damaged tail: what came before survives.
	cut, _, _ := notifications_decode(data[:len(data) - 3], 0)
	testing.expect_value(t, len(cut), 2) // no cutoff: Old + Firefox; Slack was cut off
	bad, _, _ := notifications_decode(transmute([]u8)string("nope"), 0)
	testing.expect_value(t, len(bad), 0)
}

// Tuya vectors made offline with tinytuya 1.20's own functions and a dummy
// key (pack_message, AESCipher, decrypt_udp, the session key steps).
@(private = "file") TUYA_TEST_KEY :: "0123456789abcdef"

@(private = "file")
unhex :: proc(s: string) -> []byte {
	b, _ := hex.decode(transmute([]byte)s, context.temp_allocator)
	return b
}

@(test)
test_tuya_framing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	key := transmute([]byte)string(TUYA_TEST_KEY)
	k := tuya_udp_key()
	testing.expect_value(t, string(hex.encode(k[:], context.temp_allocator)), "6c1ec8e2bb9bb59ab50b0daf649b410a")

	// 3.3 status query: ECB payload, CRC32 frame.
	query := `{"gwId":"testdevice0000000000","devId":"testdevice0000000000","uid":"testdevice0000000000","t":"1700000000"}`
	frame33 := "000055aa000000010000000a000000787b615f96a69a699ee142581f0a327055b2e3d016ba3e5cba2b9ebb4a385227f4c43a69275220231352c24112a53f9ca40dee6c10527f1ee3ee5166513e490966585f1225bfec8694a58b472a635badc1fc095fabb69877a4faab8be9fab648a2be23f34440aefb47c4fa7fbe7027af0155cceb360000aa55"
	cmd, payload := tuya_query(.V33, "testdevice0000000000", 1700000000)
	testing.expect_value(t, cmd, TUYA_DP_QUERY)
	testing.expect_value(t, payload, query)
	testing.expect_value(t, string(hex.encode(tuya_encode(.V33, key, 1, cmd, transmute([]byte)payload), context.temp_allocator)), frame33)
	// The same frame parses back (sent frames have no return code).
	f, ok := tuya_unpack(unhex(frame33), nil, .Never)
	testing.expect(t, ok)
	testing.expect_value(t, f.seq, 1)
	plain, dok := tuya_ecb_decrypt(key, f.payload)
	testing.expect(t, dok)
	testing.expect_value(t, string(plain), query)
	// A flipped bit fails the CRC.
	bad := unhex(frame33)
	bad[20] ~= 1
	_, ok = tuya_unpack(bad, nil, .Never)
	testing.expect(t, !ok)

	// 3.4 DP_QUERY_NEW: {} encrypted with the session key, HMAC-SHA256 frame.
	frame34 := "000055aa000000020000001000000034cb70ddc25a2a2045b4c13084418a9abbb94488ee8863425df208c2ef28301a083cd5c8b8d156eddeb31c6557bbf58ce90000aa55"
	cmd, payload = tuya_query(.V34, "x", 0)
	testing.expect_value(t, cmd, TUYA_DP_QUERY_NEW)
	testing.expect_value(t, string(hex.encode(tuya_encode(.V34, key, 2, cmd, transmute([]byte)payload), context.temp_allocator)), frame34)
	_, ok = tuya_unpack(unhex(frame34), transmute([]byte)string("fedcba9876543210"), .Never)
	testing.expect(t, !ok) // wrong HMAC key

	// 3.5: 0x6699 + AES-GCM (fixed IV to compare against tinytuya).
	frame35 := "00006699000000000003000000100000001e303132333435363738396162193f15291e1a8b8909eaff0bdeadc63a604300009966"
	testing.expect_value(t, string(hex.encode(tuya_encode(.V35, key, 3, cmd, transmute([]byte)payload, transmute([]byte)string("0123456789ab")), context.temp_allocator)), frame35)
	// Random IV: still round trips.
	f, ok = tuya_unpack(tuya_encode(.V35, key, 4, cmd, transmute([]byte)payload), key, .Never)
	testing.expect(t, ok && string(f.payload) == "{}" && f.seq == 4)
	testing.expect_value(t, tuya_frame_size(unhex(frame35)), len(frame35) / 2)
	testing.expect_value(t, tuya_frame_size(unhex(frame35)[:10]), 0)
	testing.expect_value(t, tuya_frame_size(transmute([]byte)string("junkjunk")), -1)
}

@(test)
test_tuya_replies :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	key := transmute([]byte)string(TUYA_TEST_KEY)
	// 3.3 reply: return code, "3.3" header, ECB JSON, CRC.
	reply33 := "000055aa000000010000000a0000005b00000000332e330000000000000000000000001dd89c1281a1deb692d9e15dfe1c332c67cf861911fb83e855b7aafe57c41ed385683833300dbe074e72fa4d791ce26e9883ee23925113e07a560f677a79f42a4e1f70b80000aa55"
	f, ok := tuya_unpack(unhex(reply33))
	testing.expect(t, ok)
	text, dok := tuya_decode_payload(.V33, key, f.payload)
	testing.expect(t, dok)
	testing.expect_value(t, text, `{"devId":"x","dps":{"1":true,"3":21},"t":1700000000}`)
	// 3.5 reply: GCM, return code inside the ciphertext.
	reply35 := "00006699000000000007000000100000005e6162636465666768696a6b6ce5d27cb5608b6ca55930b43af63edf090a15ec9c1a9f4321a6c6b65a637572832d2b73b30c91eb7cbdd92a6b0dec3b4ebb8928033ae9fdcd9c0d559b04056eb3014bfa5da42812d08afc9f3c3dfaa794e35f00009966"
	f, ok = tuya_unpack(unhex(reply35), key)
	testing.expect(t, ok && f.seq == 7 && f.retcode == 0)
	text, dok = tuya_decode_payload(.V35, key, f.payload)
	testing.expect(t, dok)
	testing.expect_value(t, text, `{"dps":{"1":215,"2":48,"4":100},"t":1700000000}`)
	// Tampered tag: rejected.
	bad := unhex(reply35)
	bad[len(bad) - 6] ~= 1
	_, ok = tuya_unpack(bad, key)
	testing.expect(t, !ok)

	// ECB round trip, including a block-sized message (gets a full padding block).
	for msg in ([]string{"", "{}", "0123456789abcdef", `{"dps":{"1":215}}`}) {
		enc := tuya_ecb_encrypt(key, transmute([]byte)msg)
		testing.expect_value(t, len(enc), (len(msg) / 16 + 1) * 16)
		dec, rok := tuya_ecb_decrypt(key, enc)
		testing.expect(t, rok && string(dec) == msg)
	}

	// Session keys from fixed nonces, and the HMAC the device proves itself with.
	ln := transmute([]byte)string("localnonce000000")
	rn := transmute([]byte)string("remotenonce00000")
	k34 := tuya_session_key(.V34, key, ln, rn)
	k35 := tuya_session_key(.V35, key, ln, rn)
	testing.expect_value(t, string(hex.encode(k34[:], context.temp_allocator)), "b33c7e583acff03245603ecdc3a94494")
	testing.expect_value(t, string(hex.encode(k35[:], context.temp_allocator)), "3267549aca55d0ab29571875c5a3de79")
}

@(test)
test_tuya_udp :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// 6667: 0x55AA + return code + ECB with the UDP key.
	udp33 := "000055aa00000000000000130000008c00000000d09766676f3369eb10b5e9f132fd802ab772b5567e90aaa8d81c1bdd88c509859c12198743b37f0b83597862ecb4a3c8165883272f7e926294cee45e6e97346c40b1058c6d8cd9456f3f7e28eed4932b57a3eb380b1674ed82d5a2a17b0f7be0343378fd637a924ca2f95eab619c9c2e2dd3a795424f2879a4492a51a7d90f079b131a640000aa55"
	text, ok := tuya_decrypt_udp(unhex(udp33))
	testing.expect(t, ok)
	testing.expect_value(t, text, `{"ip":"192.168.1.20","gwId":"testdevice0000000000","active":2,"encrypt":true,"productKey":"abc","version":"3.3"}`)
	// 7000: 0x6699 + GCM with the UDP key.
	udp35 := "00006699000000000000000000130000008c3031323334353637383961627f0e8c5c409ea2eaa8b6c4436693f7333135c536aeaada5e4d17a3aa76b0489c4d5e87e177367a301786330d169ef3b6e9861bae925d7fa1de7fa1ef733656903b0a8778f23b0fed83df2e169b8c66abae7cd3c67945c60263903c190caf6ca646b3ef434d4f0ce782daf1596549a789fd9f9838712ea8f7a5bb84d327ec1a0300009966"
	text, ok = tuya_decrypt_udp(unhex(udp35))
	testing.expect(t, ok)
	testing.expect_value(t, text, `{"ip":"192.168.1.21","gwId":"testdevice0000000001","active":2,"encrypt":true,"productKey":"abc","version":"3.5"}`)
	// 6666: plain JSON.
	text, ok = tuya_decrypt_udp(transmute([]byte)string(`{"gwId":"a"}`))
	testing.expect(t, ok && text == `{"gwId":"a"}`)
	// Our discovery probe matches tinytuya's.
	disc := "00006699000000000000000000250000003d3031323334353637383961627f0e835e0dc9a2e1b3e59a027287fb6b6f25ce36b3b18f073545b9be65ea18cd4498a2acb738e0f5d7563cb82d76b0330300009966"
	testing.expect_value(t, string(hex.encode(tuya_discovery_request("192.168.1.5", transmute([]byte)string("0123456789ab")), context.temp_allocator)), disc)
	_, ok = tuya_decrypt_udp(transmute([]byte)string("not a tuya packet"))
	testing.expect(t, !ok)
}

@(test)
test_sensor_decoding :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// devices.json (tinytuya format; mapping values may be a JSON string).
	devices := `[{"id": "dev1", "name": "Kitchen SRW-TH03", "product_name": "SRW-TH03", "category": "wsdcg", "key": "0123456789abcdef",
		"mapping": {"1": {"code": "va_temperature", "values": "{\"unit\":\"℃\",\"scale\":1}"}, "2": {"code": "humidity_value", "values": {"unit": "%", "scale": 0}}}},
		{"id": "dev2", "name": "MT15/MT29 attic ", "product_name": "", "category": "", "mapping": {"4": {"code": "co2_value", "values": "{\"unit\":\"ppm\"}"}}}]`
	defs: [dynamic]Sensor_Def
	sensor_defs_from_devices_json(devices, &defs)
	testing.expect_value(t, len(defs), 2)
	if len(defs) != 2 {return}
	testing.expect_value(t, defs[0].name, "Kitchen")
	testing.expect_value(t, defs[0].kind, Sensor_Kind.Climate)
	testing.expect_value(t, defs[0].dps["1"].scale, 1)
	testing.expect_value(t, defs[0].dps["1"].unit, "℃")
	testing.expect_value(t, defs[1].kind, Sensor_Kind.Air) // from its codes

	// [sensor.*]: built-in layout for the kind, dpN overrides, and an override
	// of a devices.json entry by id.
	m, _ := ini.load_map_from_string("[sensor.office]\nid = dev3\nkey = 0123456789abcdef\nkind = room\n[sensor.garage]\nid = dev4\ndp7 = co2_value 0 ppm\n[sensor.x]\nid = dev1\nname = Pantry\nip = 10.0.0.5\n", context.temp_allocator)
	sensor_defs_from_ini(m, &defs)
	testing.expect_value(t, len(defs), 4)
	if len(defs) != 4 {return}
	testing.expect_value(t, defs[0].name, "Pantry")
	testing.expect_value(t, defs[0].ip, "10.0.0.5")
	office, garage := defs[3], defs[2]
	if office.id != "dev3" {office, garage = garage, office}
	testing.expect_value(t, office.name, "Office")
	testing.expect_value(t, office.dps["1"].code, "va_temperature")
	testing.expect_value(t, office.dps["4"].code, "battery_percentage")
	testing.expect_value(t, garage.kind, Sensor_Kind.Air)
	testing.expect_value(t, len(garage.dps), 1)

	// Reported values -> state -> file text that parses back.
	st: Sensor_State
	reply, _ := jparse(`{"dps": {"1": 215, "2": 48, "9": "c", "23": true}}`)
	sensor_state_merge(&st, "dev1", jobj(reply, "dps").(json.Object), 1700000000.5)
	testing.expect_value(t, st["dev1"]["1"].raw, "215")
	testing.expect_value(t, st["dev1"]["9"].raw, `"c"`)
	back, ok := jparse(sensor_state_encode(st))
	testing.expect(t, ok)
	testing.expect_value(t, jint(jobj(jobj(jobj(back, "dev1"), "2"), "v")), 48)
	testing.expect_value(t, jfloat(jobj(jobj(jobj(back, "dev1"), "1"), "t")), 1700000000.5)
	// Through the mapping: scale, unit, unmapped DPs, enums and booleans.
	temp := sensor_decode(&defs[0], "1", st["dev1"]["1"])
	testing.expect(t, temp.is_num && temp.code == "va_temperature" && temp.unit == "℃")
	testing.expect_value(t, temp.num, 21.5)
	testing.expect_value(t, temp.t, 1700000000.5)
	unit := sensor_decode(&defs[0], "9", st["dev1"]["9"])
	testing.expect(t, !unit.is_num && unit.code == "dp9" && unit.text == "c")
	testing.expect_value(t, sensor_decode(&defs[0], "23", st["dev1"]["23"]).text, "on")
	p, _ := sensor_parse_dp("ch2o_value 3 mg/m³")
	testing.expect(t, p.code == "ch2o_value" && p.scale == 3 && p.unit == "mg/m³")
}

// "Replace whole bar" and "Restore my bar": the user's files (one a symlink
// into a dotfiles folder) come back byte for byte; existing backups stay.
@(test)
test_waybar_full_round_trip :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/wlperch-test-waybar-%d", posix.getpid())
	defer os.remove_all(root)
	dir := fmt.tprintf("%s/waybar", root)
	dots := fmt.tprintf("%s/dotfiles", root)
	testing.expect(t, os.make_directory_all(dir) == nil && os.make_directory_all(dots) == nil)
	path :: proc(dir, name: string) -> string {return fmt.tprintf("%s/%s", dir, name)}
	cpath :: proc(dir, name: string) -> cstring {return strings.clone_to_cstring(path(dir, name), context.temp_allocator)}
	read :: proc(dir, name: string) -> string {
		data, _ := os.read_entire_file(path(dir, name), context.temp_allocator)
		return string(data)
	}
	is_link :: proc(dir, name: string) -> bool {
		st: posix.stat_t
		return posix.lstat(cpath(dir, name), &st) == .OK && posix.S_ISLNK(st.st_mode)
	}
	MY_CFG :: "{\n    \"modules-right\": [\"clock\"] // mine\n}\n"
	MY_CSS :: "* { font-size: 13px; }\n"
	OLD_BACKUP :: "an older backup\n"
	testing.expect(t, os.write_entire_file(path(dots, "config.jsonc"), MY_CFG) == nil)
	testing.expect(t, posix.symlink(cpath(dots, "config.jsonc"), cpath(dir, "config.jsonc")) == .OK)
	testing.expect(t, os.write_entire_file(path(dir, "style.css"), MY_CSS) == nil)
	testing.expect(t, os.write_entire_file(path(dir, "config.jsonc.before-wlperch-full"), OLD_BACKUP) == nil)

	_, ok := waybar_full_install(dir)
	testing.expect(t, ok)
	active, current, backups := waybar_full_status(dir)
	testing.expect(t, active && current)
	testing.expect_value(t, len(backups), 2)
	// The taken name got a timestamp; the link itself was moved, not its target.
	testing.expect_value(t, read(dir, "config.jsonc.before-wlperch-full"), OLD_BACKUP)
	testing.expect(t, len(backups) == 2 && strings.has_prefix(backups[0], "config.jsonc.before-wlperch-full-") && is_link(dir, backups[0]))
	testing.expect_value(t, read(dir, "style.css.before-wlperch-full"), MY_CSS)
	testing.expect(t, !is_link(dir, "config.jsonc"))
	testing.expect(t, strings.has_suffix(read(dir, "config.jsonc"), WAYBAR_FULL_JSONC))
	testing.expect_value(t, read(dots, "config.jsonc"), MY_CFG)
	testing.expect(t, os.exists(path(dir, "wlperch.jsonc")))

	// Installing again (an update) makes no new backups.
	_, ok = waybar_full_install(dir)
	testing.expect(t, ok)
	_, _, again := waybar_full_status(dir)
	testing.expect(t, len(again) == 2 && again[0] == backups[0])

	_, ok = waybar_full_restore(dir)
	testing.expect(t, ok)
	testing.expect(t, is_link(dir, "config.jsonc"))
	target, _ := os.read_link(path(dir, "config.jsonc"), context.temp_allocator)
	testing.expect_value(t, target, path(dots, "config.jsonc"))
	testing.expect_value(t, read(dir, "config.jsonc"), MY_CFG)
	testing.expect_value(t, read(dir, "style.css"), MY_CSS)
	testing.expect_value(t, read(dir, "config.jsonc.before-wlperch-full"), OLD_BACKUP)
	testing.expect(t, !os.exists(path(dir, "style.css.before-wlperch-full")))
	testing.expect(t, !os.exists(path(dir, "wlperch.jsonc"))) // the restored bar doesn't use it
	active, _, _ = waybar_full_status(dir)
	testing.expect(t, !active)

	// Hand edits to our layout are kept aside on restore.
	_, ok = waybar_full_install(dir)
	testing.expect(t, ok)
	testing.expect(t, os.write_entire_file(path(dir, "style.css"), strings.concatenate({read(dir, "style.css"), "#clock { color: red; }\n"}, context.temp_allocator)) == nil)
	_, ok = waybar_full_restore(dir)
	testing.expect(t, ok)
	testing.expect_value(t, read(dir, "style.css"), MY_CSS)
	testing.expect(t, strings.has_suffix(read(dir, "style.css.wlperch-full-edited"), "#clock { color: red; }\n"))
	testing.expect_value(t, read(dir, "config.jsonc"), MY_CFG)

	// No bar config at all: nothing to back up, and restore removes ours.
	empty := fmt.tprintf("%s/empty", root)
	_, ok = waybar_full_install(empty)
	testing.expect(t, ok)
	_, ok = waybar_full_restore(empty)
	testing.expect(t, ok)
	entries, _ := os.read_all_directory_by_path(empty, context.temp_allocator)
	testing.expect_value(t, len(entries), 0)
}

@(test)
test_calc_eval :: proc(t: ^testing.T) {
	ok :: proc(t: ^testing.T, src: string, want: string, loc := #caller_location) {
		v, err := calc_eval(src)
		testing.expectf(t, err == "", "%q: %s", src, err, loc = loc)
		testing.expect_value(t, calc_decimal(v), want, loc = loc)
	}
	ok(t, "1 + 2 * 3", "7")
	ok(t, "-2^2", "-4")
	ok(t, "2^-1", "0.5")
	ok(t, "2^3^2", "512")
	ok(t, "7 % -3", "-2")
	ok(t, "-7 mod 3", "2")
	ok(t, "0xff & 0b1010 | 0o100", "74")
	ok(t, "3 xor 5", "6")
	ok(t, "~0", "-1")
	ok(t, "1 << 100", "1267650600228229401496703205376")
	ok(t, "0xFFFFFFFFFFFFFFFF + 1", "18446744073709551616")
	ok(t, "floor(7/2) + ceil(-1.5)", "2")
	ok(t, "round(2.5) trunc(-2.7)", "-6")
	ok(t, "2pi / tau", "1")
	ok(t, "3(4+1)", "15")
	ok(t, "5! + 0!", "121")
	ok(t, "sqrt 16", "4")
	ok(t, "log(8, 2)", "3")
	ok(t, "gcd(12, 18) lcm(4, 6)", "72")
	ok(t, "max(1, 2.5, 2)", "2.5")
	ok(t, "0.1 + 0.2", "0.30000000000000004")
	ok(t, "1_000 / 8", "125")
	ok(t, "0x1.8p+1", "3")
	ok(t, "1.5e3", "1500")

	v, _ := calc_eval("asin(1)", degrees = true)
	testing.expect_value(t, calc_decimal(v), "90")
	v, _ = calc_eval("ans * 2", ans = calc_int(21))
	testing.expect_value(t, calc_decimal(v), "42")

	for bad in ([]string{"", "(1 + 2", "foo(1)", "2 3", "1 & 0.5", "5 % 0"}) {
		_, err := calc_eval(bad)
		testing.expectf(t, err != "", "%q should fail", bad)
	}
}

@(test)
test_calc_formats :: proc(t: ^testing.T) {
	testing.expect_value(t, calc_hexfloat(3), "0x1.8p+1")
	testing.expect_value(t, calc_hexfloat(1), "0x1p+0")
	testing.expect_value(t, calc_hexfloat(-0.1), "-0x1.999999999999ap-4")
	testing.expect_value(t, calc_hexfloat(5e-324), "0x0.0000000000001p-1022")
	testing.expect_value(t, calc_hexfloat(0), "0x0p+0")

	find :: proc(fs: []Calc_Format, label: string) -> string {
		for f in fs {if f.label == label {return f.copy}}
		return ""
	}
	fs := calc_formats(calc_int(255))
	testing.expect_value(t, find(fs, "hex"), "0xFF")
	testing.expect_value(t, find(fs, "oct"), "0o377")
	testing.expect_value(t, find(fs, "bin"), "0b11111111")
	testing.expect_value(t, find(fs, "f64 bits"), "0x406FE00000000000")
	testing.expect_value(t, find(fs, "f32 bits"), "0x437F0000")
	fs = calc_formats(calc_int(-1))
	testing.expect_value(t, find(fs, "hex (64-bit)"), "0xFFFFFFFFFFFFFFFF")
	fs = calc_formats(calc_flt(0.1))
	testing.expect_value(t, find(fs, "hex"), "") // not whole: no integer bases
	testing.expect_value(t, find(fs, "f32 bits ≈"), "0x3DCCCCCD")
}

@(test)
test_github_urls :: proc(t: ^testing.T) {
	o, n, ok := github_split_repo("halide/Halide")
	testing.expect(t, ok && o == "halide" && n == "Halide")
	o, n, ok = github_split_repo(" https://github.com/cli/cli.git ")
	testing.expect(t, ok && o == "cli" && n == "cli")
	for bad in ([]string{"", "halide", "/x", "a/", "a/b/c"}) {
		_, _, ok = github_split_repo(bad)
		testing.expectf(t, !ok, "%q accepted", bad)
	}
	web :: proc(api, type, repo: string) -> string {
		s := github_web_url(api, type, repo)
		defer delete(s)
		return strings.clone(s, context.temp_allocator)
	}
	testing.expect_value(t, web("https://api.github.com/repos/o/r/pulls/7", "PullRequest", "o/r"), "https://github.com/o/r/pull/7")
	testing.expect_value(t, web("https://api.github.com/repos/o/r/issues/3", "Issue", "o/r"), "https://github.com/o/r/issues/3")
	testing.expect_value(t, web("https://api.github.com/repos/o/r/releases/123", "Release", "o/r"), "https://github.com/o/r/releases")
	testing.expect_value(t, web("", "CheckSuite", "o/r"), "https://github.com/o/r/actions")
	testing.expect_value(t, web("", "Discussion", ""), "https://github.com/notifications")
	testing.expect(t, notif_direct("mention") && !notif_direct("subscribed"))
}

@(test)
test_lock_rewrite :: proc(t: ^testing.T) {
	cases := [][2]string{
		{"bindsym $mod+l exec --no-startup-id swaylock -t -i /x/wall.webp\n", "bindsym $mod+l exec --no-startup-id wlperch lock\n"},
		{"exec swayidle -w timeout 300 'swaylock -f' before-sleep '/usr/bin/swaylock -f -c 000000'\n", "exec swayidle -w timeout 300 'wlperch lock -f' before-sleep 'wlperch lock -f'\n"},
		{"timeout 60 'pgrep -xu \"$USER\" swaylock >/dev/null && swaymsg \"output * power off\"'\n", "timeout 60 'pgrep -xu \"$USER\" wlperch-lock >/dev/null && swaymsg \"output * power off\"'\n"},
		{"pgrep swaylock || swaylock -f\n", "pgrep wlperch-lock || wlperch lock -f\n"},
		// Left alone: comments, the SIGUSR1 unlock, other words.
		{"# bindsym x exec swaylock\n", "# bindsym x exec swaylock\n"},
		{"unlock 'pkill -xu \"$USER\" -SIGUSR1 swaylock'\n", "unlock 'pkill -xu \"$USER\" -SIGUSR1 swaylock'\n"},
		{"exec myswaylock --fancy\n", "exec myswaylock --fancy\n"},
	}
	for c in cases {
		got, _ := lock_rewrite(c[0])
		testing.expect_value(t, got, c[1])
	}
}

@(test)
test_lock_setup_round_trip :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/wlperch-test-lock-%d", posix.getpid())
	defer os.remove_all(root)
	old_cfg := strings.clone(os.get_env("XDG_CONFIG_HOME", context.temp_allocator), context.temp_allocator)
	old_data := strings.clone(os.get_env("XDG_DATA_HOME", context.temp_allocator), context.temp_allocator)
	defer {
		os.set_env("XDG_CONFIG_HOME", old_cfg)
		os.set_env("XDG_DATA_HOME", old_data)
	}
	os.set_env("XDG_CONFIG_HOME", fmt.tprintf("%s/config", root))
	os.set_env("XDG_DATA_HOME", fmt.tprintf("%s/data", root))
	sway := fmt.tprintf("%s/config/sway", root)
	dots := fmt.tprintf("%s/dotfiles", root)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/config.d", sway)) == nil && os.make_directory_all(dots) == nil)
	read :: proc(p: string) -> string {
		data, _ := os.read_entire_file(p, context.temp_allocator)
		return string(data)
	}
	is_link :: proc(p: string) -> bool {
		st: posix.stat_t
		return posix.lstat(strings.clone_to_cstring(p, context.temp_allocator), &st) == .OK && posix.S_ISLNK(st.st_mode)
	}
	MAIN :: "set $mod Mod4\nbindsym $mod+Mod1+l exec swaylock -t -i /x/wall.png\n"
	IDLE :: "exec swayidle -w timeout 300 'swaylock -f' before-sleep 'swaylock -f'\n"
	main_p := fmt.tprintf("%s/config", sway)
	idle_p := fmt.tprintf("%s/config.d/90-idle.conf", sway)
	idle_dots := fmt.tprintf("%s/90-idle.conf", dots)
	testing.expect(t, os.write_entire_file(main_p, MAIN) == nil)
	testing.expect(t, os.write_entire_file(idle_dots, IDLE) == nil)
	testing.expect(t, posix.symlink(strings.clone_to_cstring(idle_dots, context.temp_allocator), strings.clone_to_cstring(idle_p, context.temp_allocator)) == .OK)

	c: Component
	lock_setup_check(&c, proc(c: ^Component, line: string) {})
	testing.expect_value(t, c.state, Comp_State.Missing)

	lock_switch(apply = false)
	testing.expect_value(t, read(main_p), "set $mod Mod4\nbindsym $mod+Mod1+l exec wlperch lock\n")
	// Edited through the link: the dotfile changed, the link stayed.
	testing.expect(t, is_link(idle_p))
	testing.expect_value(t, read(idle_dots), "exec swayidle -w timeout 300 'wlperch lock -f' before-sleep 'wlperch lock -f'\n")
	lock_setup_check(&c, proc(c: ^Component, line: string) {})
	testing.expect_value(t, c.state, Comp_State.Installed)

	lock_switch_back(apply = false)
	testing.expect_value(t, read(main_p), MAIN)
	testing.expect_value(t, read(idle_dots), IDLE)
	testing.expect(t, is_link(idle_p))
	lock_setup_check(&c, proc(c: ^Component, line: string) {})
	testing.expect_value(t, c.state, Comp_State.Missing)

	// Nothing set up: our own file comes and goes.
	os.remove(idle_p)
	testing.expect(t, os.write_entire_file(main_p, "set $mod Mod4\n") == nil)
	lock_switch(apply = false)
	ours := fmt.tprintf("%s/config.d/%s", sway, LOCK_CONF_NAME)
	testing.expect_value(t, read(ours), LOCK_CONF)
	lock_switch_back(apply = false)
	testing.expect(t, !os.exists(ours))
	testing.expect_value(t, read(main_p), "set $mod Mod4\n")
	delete(setup.comps[.Lock].message)
	setup.comps[.Lock].message = ""
}

@(test)
test_desktop_entry :: proc(t: ^testing.T) {
	// Exec quoting and field codes.
	argv := desktop_exec_argv(`env GDK_BACKEND=wayland "/opt/My App/app" --name=%c %U -x "a \"b\"" 100%%`, "My App", "myapp", "")
	want := []string{"env", "GDK_BACKEND=wayland", "/opt/My App/app", "--name=My App", "-x", `a "b"`, "100%"}
	testing.expect_value(t, len(argv), len(want))
	for w, i in want {
		if i < len(argv) {testing.expect_value(t, argv[i], w)}
	}
	argv = desktop_exec_argv("gimp %i %f", "", "gimp", "")
	testing.expect_value(t, strings.join(argv, "|", context.temp_allocator), "gimp|--icon|gimp")
	testing.expect_value(t, desktop_unescape(`a\sb\\c`), `a b\c`)

	// Localized keys: the closest locale wins, whatever the order.
	ENTRY :: "[Desktop Entry]\nName[nl]=Bestanden\nName=Files\nName[nl_BE]=Bestanden (BE)\nName[de]=Dateien\nActions=new;\n\n[Desktop Action new]\nName=New Window\nExec=files --new\n"
	g := desktop_parse(ENTRY, {"nl_BE", "nl"})
	testing.expect_value(t, g["Desktop Entry"]["Name"], "Bestanden (BE)")
	g = desktop_parse(ENTRY, {"nl"})
	testing.expect_value(t, g["Desktop Entry"]["Name"], "Bestanden")
	g = desktop_parse(ENTRY, nil)
	testing.expect_value(t, g["Desktop Entry"]["Name"], "Files")
	testing.expect_value(t, g["Desktop Action new"]["Exec"], "files --new")
}

@(test)
test_launcher_matching :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_score("ff", "firefox") > 0)
	testing.expect(t, fuzzy_score("xz", "firefox") < 0)
	// Prefix > word start > inside a word > scattered letters.
	testing.expect(t, fuzzy_score("term", "terminal") > fuzzy_score("term", "gnome terminal"))
	testing.expect(t, fuzzy_score("term", "gnome terminal") > fuzzy_score("term", "xterminal"))
	testing.expect(t, fuzzy_score("term", "xterminal") > fuzzy_score("term", "the remote"))
	testing.expect(t, fuzzy_score("gc", "gnome calculator") > fuzzy_score("gc", "logic"))

	mk :: proc(name, generic, bin: string) -> App_Entry {
		return {name = name, name_lc = strings.to_lower(name, context.temp_allocator), generic_lc = strings.to_lower(generic, context.temp_allocator), bin_lc = bin}
	}
	firefox := mk("Firefox", "Web Browser", "firefox")
	files := mk("Files", "File Manager", "nautilus")
	fonts_app := mk("Fonts", "Font Viewer", "gnome-font-viewer")
	// Matches on the program and the generic name too; every word must match.
	testing.expect(t, launcher_score(&files, {"nautilus"}) > 0)
	testing.expect(t, launcher_score(&firefox, {"browser"}) > 0)
	testing.expect(t, launcher_score(&firefox, {"web", "browser"}) > 0)
	testing.expect(t, launcher_score(&firefox, {"web", "files"}) < 0)
	testing.expect(t, launcher_score(&files, {"fi"}) > launcher_score(&fonts_app, {"fi"}))
}

@(test)
test_menu_rewrite :: proc(t: ^testing.T) {
	cases := [][2]string{
		{"set $menu wofi --show drun\n", "set $menu wlperch toggle launch --center\n"},
		{"set $menuterm wofi --show run\n", "set $menuterm wlperch toggle run --center\n"},
		{"bindsym $mod+d exec rofi -show drun -theme-str 'window {width: 40%;}'\n", "bindsym $mod+d exec wlperch toggle launch --center\n"},
		{"bindsym $mod+c exec rofi -show calc -modi calc -no-show-match\n", "bindsym $mod+c exec wlperch toggle calc --center\n"},
		{"bindsym $mod+d exec pkill fuzzel || fuzzel\n", "bindsym $mod+d exec pkill fuzzel || wlperch toggle launch --center\n"},
		{"bindsym $mod+d exec /usr/bin/tofi-drun --drun-launch=true\n", "bindsym $mod+d exec wlperch toggle launch --center\n"},
		{"bindsym $mod+r exec 'dmenu_run -i'\n", "bindsym $mod+r exec 'wlperch toggle run --center'\n"},
		// Emoji pickers open the emoji panel.
		{"set $emoji ~/.config/wofi-emoji/wofi-emoji\n", "set $emoji wlperch toggle emoji --center\n"},
		{"bindsym $mod+period exec rofi -modi emoji -show emoji\n", "bindsym $mod+period exec wlperch toggle emoji --center\n"},
		// Left alone: comments, dmenu-style pickers, window switchers, other words.
		{"# set $menu wofi --show drun\n", "# set $menu wofi --show drun\n"},
		{"bindsym $mod+v exec cliphist list | wofi --dmenu | cliphist decode | wl-copy\n", "bindsym $mod+v exec cliphist list | wofi --dmenu | cliphist decode | wl-copy\n"},
		{"bindsym $mod+Tab exec rofi -show window\n", "bindsym $mod+Tab exec rofi -show window\n"},
		{"for_window [app_id=\"wofi\"] floating enable\n", "for_window [app_id=\"wofi\"] floating enable\n"},
	}
	for c in cases {
		got, _ := menu_rewrite(c[0])
		testing.expect_value(t, got, c[1])
	}
}

@(test)
test_emoji_search :: proc(t: ^testing.T) {
	emoji_load()
	testing.expect(t, len(emoji_table) > 3000)
	best :: proc(words: []string) -> string {
		tone := emoji_tone_asked(words)
		top: f32 = -1
		ch := ""
		for &e in emoji_table {
			if s := emoji_score(&e, words, tone); s > top {top, ch = s, e.ch}
		}
		return ch
	}
	testing.expect_value(t, best({"thumbs", "up"}), "👍")
	testing.expect_value(t, best({"thumbs", "up", "dark"}), "👍🏿")
	testing.expect_value(t, best({"party"}), "🎉") // party popper; partying face next
	testing.expect_value(t, best({"red", "heart"}), "❤️")
	// Variants stay out of a plain search; their base knows it has them.
	for &e in emoji_table {
		if e.ch == "👍🏿" {testing.expect(t, emoji_score(&e, {"thumbs"}, false) < 0)}
		if e.ch == "👍" {testing.expect(t, e.tones)}
	}
}

@(test)
test_menu_setup_round_trip :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/wlperch-test-menu-%d", posix.getpid())
	defer os.remove_all(root)
	old_cfg := strings.clone(os.get_env("XDG_CONFIG_HOME", context.temp_allocator), context.temp_allocator)
	old_data := strings.clone(os.get_env("XDG_DATA_HOME", context.temp_allocator), context.temp_allocator)
	defer {
		os.set_env("XDG_CONFIG_HOME", old_cfg)
		os.set_env("XDG_DATA_HOME", old_data)
	}
	os.set_env("XDG_CONFIG_HOME", fmt.tprintf("%s/config", root))
	os.set_env("XDG_DATA_HOME", fmt.tprintf("%s/data", root))
	sway := fmt.tprintf("%s/config/sway", root)
	dots := fmt.tprintf("%s/dotfiles", root)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/config.d", sway)) == nil && os.make_directory_all(dots) == nil)
	read :: proc(p: string) -> string {
		data, _ := os.read_entire_file(p, context.temp_allocator)
		return string(data)
	}
	MAIN :: "set $mod Mod4\nset $menu wofi --show drun\nset $menuterm wofi --show run\nbindsym $mod+d exec $menu\n"
	main_dots := fmt.tprintf("%s/config", dots)
	main_p := fmt.tprintf("%s/config", sway)
	testing.expect(t, os.write_entire_file(main_dots, MAIN) == nil)
	testing.expect(t, posix.symlink(strings.clone_to_cstring(main_dots, context.temp_allocator), strings.clone_to_cstring(main_p, context.temp_allocator)) == .OK)

	c: Component
	menu_setup_check(&c, proc(c: ^Component, line: string) {})
	testing.expect_value(t, c.state, Comp_State.Missing)
	menu_switch(apply = false)
	testing.expect_value(t, read(main_dots), "set $mod Mod4\nset $menu wlperch toggle launch --center\nset $menuterm wlperch toggle run --center\nbindsym $mod+d exec $menu\n")
	menu_setup_check(&c, proc(c: ^Component, line: string) {})
	testing.expect_value(t, c.state, Comp_State.Installed)
	menu_switch_back(apply = false)
	testing.expect_value(t, read(main_dots), MAIN)
	st: posix.stat_t
	testing.expect(t, posix.lstat(strings.clone_to_cstring(main_p, context.temp_allocator), &st) == .OK && posix.S_ISLNK(st.st_mode))

	// No launcher bound: our own file comes and goes.
	testing.expect(t, os.write_entire_file(main_dots, "set $mod Mod4\n") == nil)
	menu_switch(apply = false)
	ours := fmt.tprintf("%s/config.d/%s", sway, MENU_CONF_NAME)
	testing.expect_value(t, read(ours), MENU_CONF)
	menu_switch_back(apply = false)
	testing.expect(t, !os.exists(ours))
	delete(setup.comps[.Menu].message)
	setup.comps[.Menu].message = ""
}

@(test)
test_theme_rewrite :: proc(t: ^testing.T) {
	cases := [][2]string{
		{"bindsym $mod+Shift+w exec ~/.config/hypr/scripts/switch-theme.sh summer-night\n", "bindsym $mod+Shift+w exec wlperch theme dark\n"},
		{"bindsym $mod+Shift+x exec ~/.config/hypr/scripts/switch-theme.sh summer-day\n", "bindsym $mod+Shift+x exec wlperch theme light\n"},
		{"bindsym $mod+t exec --no-startup-id toggle-theme\n", "bindsym $mod+t exec --no-startup-id wlperch theme toggle\n"},
		{"bindsym $mod+t exec darkman toggle\n", "bindsym $mod+t exec wlperch theme toggle\n"},
		// Not theme switches / chains / comments: kept.
		{"bindsym $mod+d exec wofi --show drun\n", "bindsym $mod+d exec wofi --show drun\n"},
		{"# bindsym $mod+w exec switch-theme.sh night\n", "# bindsym $mod+w exec switch-theme.sh night\n"},
		{"bindsym $mod+w exec switch-theme.sh night; exec foo\n", "bindsym $mod+w exec switch-theme.sh night; exec foo\n"},
	}
	for c in cases {
		out, _ := theme_rewrite(c[0])
		testing.expect_value(t, out, c[1])
	}
}

@(test)
test_theme_targets :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/wlperch-theme-test-%d", posix.getpid())
	defer {_ = os.remove_all(root)}
	testing.expect(t, os.make_directory_all(root) == nil)
	read :: proc(p: string) -> string {
		data, _ := os.read_entire_file(p, context.temp_allocator)
		return string(data)
	}
	// colors.css -> waybar-dark.css swaps to its light twin (relative link), and back.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/waybar-dark.css", root), "d") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/waybar-light.css", root), "l") == nil)
	link := fmt.tprintf("%s/colors.css", root)
	testing.expect(t, posix.symlink("waybar-dark.css", strings.clone_to_cstring(link, context.temp_allocator)) == .OK)
	_, changed, ok := theme_swap_link(link, true)
	testing.expect(t, changed && ok)
	testing.expect_value(t, read(link), "l")
	_, changed, ok = theme_swap_link(link, true)
	testing.expect(t, !changed && ok)
	_, changed, ok = theme_swap_link(link, false)
	testing.expect(t, changed && ok)
	testing.expect_value(t, read(link), "d")
	// Absolute target.
	abs := fmt.tprintf("%s/abs.css", root)
	testing.expect(t, posix.symlink(strings.clone_to_cstring(fmt.tprintf("%s/waybar-dark.css", root), context.temp_allocator), strings.clone_to_cstring(abs, context.temp_allocator)) == .OK)
	_, changed, ok = theme_swap_link(abs, true)
	testing.expect(t, changed && ok)
	testing.expect_value(t, read(abs), "l")
	// No twin: left alone.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/x-dark.css", root), "d") == nil)
	lone := fmt.tprintf("%s/lone.css", root)
	testing.expect(t, posix.symlink("x-dark.css", strings.clone_to_cstring(lone, context.temp_allocator)) == .OK)
	_, changed, _ = theme_swap_link(lone, true)
	testing.expect(t, !changed)

	ini := fmt.tprintf("%s/settings.ini", root)
	testing.expect(t, os.write_entire_file(ini, "[Settings]\ngtk-theme-name=Adwaita-dark\ngtk-application-prefer-dark-theme=1\n") == nil)
	changed, ok = gtk_ini_update(ini, true, "Adwaita")
	testing.expect(t, changed && ok)
	testing.expect_value(t, read(ini), "[Settings]\ngtk-theme-name=Adwaita\ngtk-application-prefer-dark-theme=0\n")

	vs := fmt.tprintf("%s/settings.json", root)
	testing.expect(t, os.write_entire_file(vs, "{\n  \"workbench.colorTheme\": \"Everforest Dark\",\n  \"x\": 1\n}\n") == nil)
	changed, ok = vscode_set_theme(vs, "Everforest Light")
	testing.expect(t, changed && ok)
	testing.expect_value(t, read(vs), "{\n  \"workbench.colorTheme\": \"Everforest Light\",\n  \"x\": 1\n}\n")
}

// Switching theme keys imports the script's theme JSON into the config, and
// switching back restores sway and the config byte for byte.
@(test)
test_theme_switch_keys :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/wlperch-theme-keys-%d", posix.getpid())
	defer {_ = os.remove_all(root)}
	old_cfg := strings.clone(os.get_env("XDG_CONFIG_HOME", context.temp_allocator), context.temp_allocator)
	old_data := strings.clone(os.get_env("XDG_DATA_HOME", context.temp_allocator), context.temp_allocator)
	defer {
		os.set_env("XDG_CONFIG_HOME", old_cfg)
		os.set_env("XDG_DATA_HOME", old_data)
	}
	os.set_env("XDG_CONFIG_HOME", fmt.tprintf("%s/config", root))
	os.set_env("XDG_DATA_HOME", fmt.tprintf("%s/data", root))
	read :: proc(p: string) -> string {
		data, _ := os.read_entire_file(p, context.temp_allocator)
		return string(data)
	}
	scripts := fmt.tprintf("%s/hypr/scripts", root)
	themes := fmt.tprintf("%s/hypr/themes", root)
	sway := fmt.tprintf("%s/config/sway", root)
	testing.expect(t, os.make_directory_all(scripts) == nil && os.make_directory_all(themes) == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/config.d", sway)) == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/config/wlperch", root)) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/night.json", themes), `{"wallpaper": "castle.jpg", "kittyTheme": "Arthur", "nvimTheme": "gruvbox-material", "kvantumTheme": ""}`) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/day.json", themes), `{"wallpaper": "field.jpg", "kittyTheme": "Catppuccin-Latte"}`) == nil)
	MAIN := fmt.tprintf("set $mod Mod4\nbindsym $mod+Shift+w exec %s/switch-theme.sh night\nbindsym $mod+Shift+x exec %s/switch-theme.sh day\n", scripts, scripts)
	CONF :: "# wlperch configuration\n\n[popup]\nwidth = 860\n\n[theme.dark]\nkitty_theme =\nnvim_colorscheme = mine\n\n[clocks]\nuse_24h = true\n"
	main_p := fmt.tprintf("%s/config", sway)
	conf_p := fmt.tprintf("%s/config/wlperch/config.ini", root)
	testing.expect(t, os.write_entire_file(main_p, MAIN) == nil)
	testing.expect(t, os.write_entire_file(conf_p, CONF) == nil)

	c: Component
	theme_setup_check(&c, proc(c: ^Component, line: string) {})
	testing.expect_value(t, c.state, Comp_State.Missing)
	theme_switch_keys(apply = false)
	testing.expect_value(t, read(main_p), "set $mod Mod4\nbindsym $mod+Shift+w exec wlperch theme dark\nbindsym $mod+Shift+x exec wlperch theme light\n")
	// Empty keys filled, set ones kept, missing ones added; a missing section appended.
	testing.expect_value(t, read(conf_p), "# wlperch configuration\n\n[popup]\nwidth = 860\n\n[theme.dark]\nkitty_theme = Arthur\nnvim_colorscheme = mine\nwallpaper = ~/Pictures/wallpapers/castle.jpg\n\n[clocks]\nuse_24h = true\n\n# Imported by wlperch setup from your theme script.\n[theme.light]\nwallpaper = ~/Pictures/wallpapers/field.jpg\nkitty_theme = Catppuccin-Latte\n")
	theme_setup_check(&c, proc(c: ^Component, line: string) {})
	testing.expect_value(t, c.state, Comp_State.Installed)
	theme_switch_keys_back(apply = false)
	testing.expect_value(t, read(main_p), MAIN)
	testing.expect_value(t, read(conf_p), CONF)
	testing.expect(t, !os.exists(fmt.tprintf("%s/data/wlperch/theme-backup/manifest", root)))
	edited, _ := os.read_all_directory_by_path(fmt.tprintf("%s/data/wlperch/theme-backup", root), context.temp_allocator)
	testing.expect_value(t, len(edited), 0)
	delete(setup.comps[.Theme].message)
	setup.comps[.Theme].message = ""
}

@(test)
test_bar_rewrite :: proc(t: ^testing.T) {
	cases := [][2]string{
		{"bar {\n    swaybar_command waybar\n}\n", "bar {\n    swaybar_command wlperch-bar\n}\n"},
		{"exec_always waybar -c ~/.config/waybar/top.jsonc\n", "exec_always wlperch-bar\n"},
		{"exec /usr/bin/waybar\n", "exec wlperch-bar\n"},
		// sway execs swaybar_command as one program name: "wlperch bar" never ran.
		{"bar {\n    swaybar_command wlperch bar\n}\n", "bar {\n    swaybar_command wlperch-bar\n}\n"},
		{"    bindsym $mod+Shift+c exec killall waybar && swaymsg reload\n", "    bindsym $mod+Shift+c exec swaymsg reload\n"},
		// swaybar (no program named): ours goes into the block.
		{"bar {\n    position top\n    colors {\n        statusline #ffffff\n    }\n}\n", "bar {\n    swaybar_command wlperch-bar\n    position top\n    colors {\n        statusline #ffffff\n    }\n}\n"},
		// Left alone: comments, rules, a block already running something else.
		{"# exec waybar\n", "# exec waybar\n"},
		{"for_window [app_id=\"waybar\"] floating enable\n", "for_window [app_id=\"waybar\"] floating enable\n"},
		{"bar {\n    swaybar_command wlperch-bar\n}\n", "bar {\n    swaybar_command wlperch-bar\n}\n"},
	}
	for c in cases {
		got, _ := bar_rewrite(c[0])
		testing.expect_value(t, got, c[1])
	}
	// One line of a block (as switch_uses sees it) is not a block without a command.
	_, n := bar_rewrite("bar {\n")
	testing.expect_value(t, n, 0)
}

@(test)
test_bar_setup_round_trip :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/wlperch-test-bar-%d", posix.getpid())
	defer os.remove_all(root)
	old_cfg := strings.clone(os.get_env("XDG_CONFIG_HOME", context.temp_allocator), context.temp_allocator)
	old_data := strings.clone(os.get_env("XDG_DATA_HOME", context.temp_allocator), context.temp_allocator)
	defer {
		os.set_env("XDG_CONFIG_HOME", old_cfg)
		os.set_env("XDG_DATA_HOME", old_data)
	}
	os.set_env("XDG_CONFIG_HOME", fmt.tprintf("%s/config", root))
	os.set_env("XDG_DATA_HOME", fmt.tprintf("%s/data", root))
	sway := fmt.tprintf("%s/config/sway", root)
	dots := fmt.tprintf("%s/dotfiles", root)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/config.d", sway)) == nil && os.make_directory_all(dots) == nil)
	read :: proc(p: string) -> string {
		data, _ := os.read_entire_file(p, context.temp_allocator)
		return string(data)
	}
	MAIN :: "set $mod Mod4\nbindsym $mod+Shift+c exec killall waybar && swaymsg reload\ninclude config.d/*\n"
	BAR :: "# Status Bar: waybar\nbar {\n    swaybar_command waybar\n}\n"
	main_dots := fmt.tprintf("%s/config", dots)
	bar_dots := fmt.tprintf("%s/90-bar.conf", dots)
	main_p := fmt.tprintf("%s/config", sway)
	bar_p := fmt.tprintf("%s/config.d/90-bar.conf", sway)
	testing.expect(t, os.write_entire_file(main_dots, MAIN) == nil && os.write_entire_file(bar_dots, BAR) == nil)
	for pair in ([][2]string{{main_dots, main_p}, {bar_dots, bar_p}}) {
		testing.expect(t, posix.symlink(strings.clone_to_cstring(pair[0], context.temp_allocator), strings.clone_to_cstring(pair[1], context.temp_allocator)) == .OK)
	}

	c: Component
	bar_setup_check(&c, proc(c: ^Component, line: string) {})
	testing.expect_value(t, c.state, Comp_State.Missing)
	bar_switch(apply = false)
	testing.expect_value(t, read(main_dots), "set $mod Mod4\nbindsym $mod+Shift+c exec swaymsg reload\ninclude config.d/*\n")
	testing.expect_value(t, read(bar_dots), "# Status Bar: waybar\nbar {\n    swaybar_command wlperch-bar\n}\n")
	bar_setup_check(&c, proc(c: ^Component, line: string) {})
	testing.expect_value(t, c.state, Comp_State.Installed)
	bar_switch_back(apply = false)
	testing.expect_value(t, read(main_dots), MAIN)
	testing.expect_value(t, read(bar_dots), BAR)
	st: posix.stat_t
	for p in ([]string{main_p, bar_p}) {
		testing.expect(t, posix.lstat(strings.clone_to_cstring(p, context.temp_allocator), &st) == .OK && posix.S_ISLNK(st.st_mode))
	}

	// No bar at all: our own file comes and goes.
	testing.expect(t, os.remove(bar_p) == nil)
	testing.expect(t, os.write_entire_file(main_dots, "set $mod Mod4\n") == nil)
	bar_switch(apply = false)
	ours := fmt.tprintf("%s/config.d/%s", sway, BAR_CONF_NAME)
	testing.expect_value(t, read(ours), BAR_CONF)
	bar_switch_back(apply = false)
	testing.expect(t, !os.exists(ours))
	delete(setup.comps[.Bar].message)
	setup.comps[.Bar].message = ""
}

@(test)
test_bar_clock_and_workspaces :: proc(t: ^testing.T) {
	tm, _ := time.datetime_to_time(2026, 10, 24, 9, 5, 7)
	dt, _ := time.time_to_datetime(tm)
	runs := bar_clock_text("%a %d %b  <b>%H:%M</b>%%", dt)
	testing.expect_value(t, len(runs), 3)
	if len(runs) == 3 {
		testing.expect_value(t, runs[0][0], "Sat 24 Oct  ")
		testing.expect_value(t, runs[1], [2]string{"09:05", "b"})
		testing.expect_value(t, runs[2][0], "%")
	}
	cal, line, col := bar_calendar(dt)
	testing.expect_value(t, cal[0], "October 2026")
	testing.expect_value(t, cal[2], "          1  2  3  4") // the 1st is a Thursday
	testing.expect_value(t, cal[line][col * 3:col * 3 + 2], "24")

	// Numbered first, then each project's workspaces (config order), then the rest.
	saved_projects := tracker.projects
	saved_ws := bsway.workspaces
	defer {
		delete(tracker.projects)
		delete(bsway.workspaces)
		tracker.projects = saved_projects
		bsway.workspaces = saved_ws
	}
	tracker.projects = {}
	append(&tracker.projects, Project{key = "a", name = "Alpha", color = 0xff0000}, Project{key = "b", name = "Beta", color = 0x00ff00})
	bsway.workspaces = {}
	for n in ([]string{"Beta 1", "music", "3", "Alpha 2", "1", "Alpha 1"}) {
		num := -1
		if v, ok := strconv.parse_int(n); ok {num = v}
		append(&bsway.workspaces, Bar_Ws{name = n, num = num, output = "DP-1"})
	}
	append(&bsway.workspaces, Bar_Ws{name = "2", num = 2, output = "DP-2"})
	groups := bar_ws_groups("DP-1")
	names: [dynamic]string
	names.allocator = context.temp_allocator
	for g in groups {
		for w in g.ws {append(&names, fmt.tprintf("%d:%s", g.project, w.name))}
	}
	testing.expect_value(t, strings.join(names[:], ",", context.temp_allocator), "-1:1,-1:3,0:Alpha 1,0:Alpha 2,1:Beta 1,-1:music")
	testing.expect_value(t, len(groups), 5)
}

@(test)
test_portal_parse_scheme :: proc(t: ^testing.T) {
	testing.expect_value(t, portal_parse_scheme("v u 1\n"), "dark")
	testing.expect_value(t, portal_parse_scheme("v u 2"), "light")
	testing.expect_value(t, portal_parse_scheme("v u 0"), "no preference")
	testing.expect_value(t, portal_parse_scheme(""), "")
	testing.expect_value(t, portal_parse_scheme("Call failed: Could not activate remote peer"), "")
}

@(test)
test_compose_dead_keys :: proc(t: ^testing.T) {
	ctx := xkb.context_new(xkb.CONTEXT_NO_FLAGS)
	defer xkb.context_unref(ctx)
	c: xkb.Compose
	c.table = xkb.compose_table_new_from_locale(ctx, "en_US.UTF-8", xkb.COMPOSE_COMPILE_NO_FLAGS)
	if c.table == nil {
		log.warn("no compose table for en_US.UTF-8; skipping")
		return
	}
	xkb.compose_init(&c, ctx)
	defer xkb.compose_destroy(&c)

	sym :: proc(name: cstring) -> xkb.Keysym {return xkb.keysym_from_name(name, 0)}
	buf: [64]u8
	feed :: proc(c: ^xkb.Compose, s: xkb.Keysym, buf: []u8) -> (xkb.Compose_Action, string) {
		a, n := xkb.compose_key(c, s, buf)
		return a, string(buf[:n])
	}

	// Plain keys pass straight through.
	a, txt := feed(&c, sym("e"), buf[:])
	testing.expect_value(t, a, xkb.Compose_Action.Pass)

	// dead ^ + space -> "^"; dead ^ + e -> "ê".
	a, _ = feed(&c, sym("dead_circumflex"), buf[:])
	testing.expect_value(t, a, xkb.Compose_Action.Swallow)
	testing.expect(t, xkb.compose_active(&c))
	a, txt = feed(&c, sym("space"), buf[:])
	testing.expect_value(t, a, xkb.Compose_Action.Text)
	testing.expect_value(t, txt, "^")
	testing.expect(t, !xkb.compose_active(&c))

	feed(&c, sym("dead_circumflex"), buf[:])
	a, txt = feed(&c, sym("e"), buf[:])
	testing.expect_value(t, a, xkb.Compose_Action.Text)
	testing.expect_value(t, txt, "ê")

	// Modifiers don't disturb a pending sequence: dead ^ + Shift + E -> "Ê".
	feed(&c, sym("dead_circumflex"), buf[:])
	a, _ = feed(&c, sym("Shift_L"), buf[:])
	testing.expect_value(t, a, xkb.Compose_Action.Pass)
	a, txt = feed(&c, sym("E"), buf[:])
	testing.expect_value(t, txt, "Ê")

	// Escape cancels (eaten, so it doesn't close the panel); the next key is normal.
	feed(&c, sym("dead_circumflex"), buf[:])
	a, _ = feed(&c, sym("Escape"), buf[:])
	testing.expect_value(t, a, xkb.Compose_Action.Swallow)
	testing.expect(t, !xkb.compose_active(&c))
	a, _ = feed(&c, sym("x"), buf[:])
	testing.expect_value(t, a, xkb.Compose_Action.Pass)

	// Recreating the state (new keymap) drops a half-typed sequence.
	feed(&c, sym("dead_circumflex"), buf[:])
	xkb.compose_init(&c, ctx)
	testing.expect(t, !xkb.compose_active(&c))
	a, _ = feed(&c, sym("space"), buf[:])
	testing.expect_value(t, a, xkb.Compose_Action.Pass)
}

@(test)
test_theme_sway_colors :: proc(t: ^testing.T) {
	testing.expect(t, sway_client_colors_valid(.Focused, "#4a5b85 #232836 #e4e7ee #7d9c5a #4a5b85"))
	testing.expect(t, sway_client_colors_valid(.Unfocused, "#1f232b #111318 #8a92a3"))
	testing.expect(t, sway_client_colors_valid(.Urgent, "#f7768eff #F7768E #111318"))
	testing.expect(t, sway_client_colors_valid(.Background, "#111318"))
	testing.expect(t, !sway_client_colors_valid(.Background, "#111318 #111318"))
	testing.expect(t, !sway_client_colors_valid(.Focused_Tab_Title, "#2b303b #1a1d24 #c8ccd6 #2b303b"))
	testing.expect(t, !sway_client_colors_valid(.Focused, "#4a5b85 #232836"))
	testing.expect(t, !sway_client_colors_valid(.Focused, "4a5b85 #232836 #e4e7ee"))
	testing.expect(t, !sway_client_colors_valid(.Focused, "#4a5b8g #232836 #e4e7ee"))
	// Every built-in value is one sway takes.
	builtin := SWAY_COLORS
	for m in Theme_Mode {
		for class in Sway_Client_Class {testing.expect(t, sway_client_colors_valid(class, builtin[m][class]))}
	}
	saved := config.theme_targets
	defer config.theme_targets = saved
	config.theme_targets[.Light] = {}
	config.theme_targets[.Light].sway_colors = true
	config.theme_targets[.Light].sway_client[.Urgent] = "#ff0000 #ff0000 #ffffff"
	cmds := theme_sway_commands(.Light)
	testing.expect_value(t, len(cmds), len(Sway_Client_Class))
	testing.expect_value(t, cmds[int(Sway_Client_Class.Focused)], "client.focused #7f9bd6 #dce5f7 #1b1f28 #4f7a1f #7f9bd6")
	testing.expect_value(t, cmds[int(Sway_Client_Class.Urgent)], "client.urgent #ff0000 #ff0000 #ffffff")
	testing.expect_value(t, cmds[int(Sway_Client_Class.Background)], "client.background #e8eaf0")
	config.theme_targets[.Light].sway_colors = false
	testing.expect_value(t, len(theme_sway_commands(.Light)), 0)
}
