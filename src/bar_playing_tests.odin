package main

import "core:testing"

@(private = "file")
test_parent :: proc(pid: i32) -> i32 {
	switch pid {
	case 501: return 500 // a browser's audio process under its main process
	case 500: return 1
	}
	return 1
}

@(test)
test_playing_workspaces :: proc(t: ^testing.T) {
	wins := []Play_Window{
		{"1", "firefox", "Mail — Mozilla Firefox", 500, 0, false},
		{"5", "firefox", "Some Video - YouTube — Mozilla Firefox", 500, 0, false},
		{"2", "mpv", "song.flac - mpv", 600, 0, false},
		{"3", "kitty", "zsh", 700, 0, false},
	}
	ws :: proc(r: []Playing_Ws) -> [dynamic]string {
		out := make([dynamic]string, context.temp_allocator)
		for p in r {append(&out, p.ws)}
		return out
	}
	// A child process plays; the MPRIS title picks the window on 5.
	r := playing_workspaces({{501, "Firefox"}}, wins, {{500, "Some Video", true}}, test_parent)
	testing.expect_value(t, len(r), 1)
	if len(r) == 1 {testing.expect_value(t, r[0].ws, "5"); testing.expect_value(t, r[0].app, "Firefox")}
	// No title matches: every workspace of that app.
	r = playing_workspaces({{501, "Firefox"}}, wins, {{500, "Other", true}}, test_parent)
	testing.expect_value(t, len(ws(r)), 2)
	// Its only player is paused: not playing, though the stream is open.
	r = playing_workspaces({{500, "Firefox"}}, wins, {{500, "Some Video", false}}, test_parent)
	testing.expect_value(t, len(r), 0)
	// An app without players, on one workspace.
	r = playing_workspaces({{600, ""}}, wins, nil, test_parent)
	testing.expect_value(t, len(r), 1)
	if len(r) == 1 {testing.expect_value(t, r[0].ws, "2"); testing.expect_value(t, r[0].app, "mpv")}
	// A stream of a process without a window (a speech daemon): nothing.
	r = playing_workspaces({{999, "speech"}}, wins, nil, test_parent)
	testing.expect_value(t, len(r), 0)
}
