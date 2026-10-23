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
	dir := "/tmp/wlperch-test"
	os.make_directory_all(dir)
	path := "/tmp/wlperch-test/desk_and_tv.sh"
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
