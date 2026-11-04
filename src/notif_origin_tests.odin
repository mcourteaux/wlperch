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
