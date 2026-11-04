package main

import "core:testing"

@(test)
test_notif_origin_pick :: proc(t: ^testing.T) {
	wins := []Play_Window {
		{"1", "org.mozilla.firefox", "Mail — Mozilla Firefox", 500, 11, false},
		{"DentOffice 2", "org.mozilla.firefox", "Pull request #12 — Mozilla Firefox", 500, 12, false},
		{"Pallas 1", "kitty", "✳ refactor", 700, 21, false},
		{"Pallas 1b", "kitty", "zsh", 710, 22, false},
		{"4", "kitty", "logs", 720, 23, false},
		{"4", "kitty", "build", 720, 24, false},
		{"4", "org.telegram.desktop._75b3", "Telegram", 800, 31, false},
	}
	// 900 (notify-send) -> 901 (zsh) -> 700 (kitty on Pallas 1); 950 has no window.
	parent :: proc(pid: i32) -> i32 {
		switch pid {
		case 900: return 901
		case 901: return 700
		case 950: return 1
		}
		return 0
	}
	ws, con := notif_origin_pick(900, "notify-send", "", "Claude is ready", "", wins, parent)
	testing.expect_value(t, ws, "Pallas 1")
	testing.expect_value(t, con, 21)
	// Its own window process.
	ws, con = notif_origin_pick(710, "kitty", "", "Done", "", wins, parent)
	testing.expect_value(t, ws, "Pallas 1b")
	// Two windows of one process on one workspace: the workspace, no window.
	ws, con = notif_origin_pick(720, "kitty", "", "Bell", "", wins, parent)
	testing.expect_value(t, ws, "4")
	testing.expect_value(t, con, 0)
	// One Firefox on two workspaces: the title decides, else nothing.
	ws, con = notif_origin_pick(500, "Firefox", "firefox", "Pull request #12", "new review", wins, parent)
	testing.expect_value(t, ws, "DentOffice 2")
	testing.expect_value(t, con, 12)
	ws, _ = notif_origin_pick(500, "Firefox", "firefox", "Calendar", "in 5 minutes", wins, parent)
	testing.expect_value(t, ws, "")
	// No window behind the sender (a portal): by the desktop entry.
	ws, con = notif_origin_pick(950, "Telegram", "org.telegram.desktop", "Ann", "hi", wins, parent)
	testing.expect_value(t, ws, "4")
	testing.expect_value(t, con, 31)
	// Unknown sender and app: nothing.
	ws, _ = notif_origin_pick(0, "cron", "", "Backup", "done", wins, parent)
	testing.expect_value(t, ws, "")
	// An urgent window settles it.
	urgent := []Play_Window{
		{"1", "org.mozilla.firefox", "Mail — Mozilla Firefox", 500, 11, false},
		{"2", "org.mozilla.firefox", "Chat — Mozilla Firefox", 500, 12, true},
	}
	ws, _ = notif_origin_pick(500, "Firefox", "", "Ping", "", urgent, parent)
	testing.expect_value(t, ws, "2")
}

// The origin workspace is kept in the history file (WLN3); a WLN2 file,
// from before, loads without one. The window isn't kept.
@(test)
test_notification_origin_history :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	mk :: proc(id: u32, summary, ws: string, con: i64 = 0) -> ^Notification {
		n := new(Notification)
		n^ = {id = id, app = "Shell", summary = summary, value = -1, count = 1, origin_ws = ws, origin_con = con}
		return n
	}
	list := make([dynamic]^Notification)
	append(&list, mk(1, "Build finished", "Pallas 1b", 42), mk(2, "From a script", ""))
	data := notifications_encode(list[:], 2, false)
	testing.expect_value(t, (^u32)(raw_data(data))^, u32(NOTIFY_MAGIC))
	back, _, _ := notifications_decode(data, 0)
	testing.expect_value(t, len(back), 2)
	if len(back) == 2 {
		testing.expect_value(t, back[0].origin_ws, "Pallas 1b")
		testing.expect_value(t, back[0].origin_con, i64(0))
		testing.expect_value(t, back[1].origin_ws, "")
		testing.expect_value(t, back[1].summary, "From a script")
	}

	// A WLN2 file: the same entries, without the origin after each count.
	old := make([dynamic]u8)
	append(&old, ..data[:4])
	(^u32)(raw_data(old[:]))^ = NOTIFY_MAGIC_V2
	r := 4 + 4 + 1 + 4 // magic, next_id, dnd, icon count (no icons here)
	append(&old, ..data[4:r])
	append(&old, ..data[r:r + 4]) // entry count
	pos := r + 4
	for _ in 0 ..< 2 {
		start := pos
		pos += 4 + 8 + 1 + 1 + 4 + 8
		for _ in 0 ..< 4 {pos += 2 + int((^u16)(&data[pos])^)}
		pos += 4 // count
		append(&old, ..data[start:pos])
		pos += 2 + int((^u16)(&data[pos])^)
	}
	v2, _, _ := notifications_decode(old[:], 0)
	testing.expect_value(t, len(v2), 2)
	if len(v2) == 2 {
		testing.expect_value(t, v2[0].summary, "Build finished")
		testing.expect_value(t, v2[0].origin_ws, "")
		testing.expect_value(t, v2[1].count, 1)
	}
}
