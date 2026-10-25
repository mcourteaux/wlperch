// Unit tests for fullscreen.odin: which outputs a fullscreen view covers (from
// a get_tree reply) and whether it's a game (from process info).
package main

import "core:sys/posix"
import "core:testing"

@(private = "file")
TREE :: `{"id": 1, "type": "root", "nodes": [
 {"id": 2, "type": "output", "name": "__i3", "current_workspace": null, "nodes": [
  {"id": 3, "type": "workspace", "name": "__i3_scratch", "nodes": [], "floating_nodes": [
   {"id": 4, "type": "floating_con", "pid": 400, "app_id": "scratch", "fullscreen_mode": 0}]}]},
 {"id": 10, "type": "output", "name": "DP-3", "current_workspace": "1", "nodes": [
  {"id": 11, "type": "workspace", "name": "1", "fullscreen_mode": 1, "nodes": [
   {"id": 12, "type": "con", "pid": 1200, "app_id": "foot", "fullscreen_mode": 0},
   {"id": 13, "type": "con", "layout": "splitv", "fullscreen_mode": 0, "nodes": [
    {"id": 14, "type": "con", "pid": 1400, "app_id": null, "fullscreen_mode": 1,
     "shell": "xwayland", "window_properties": {"class": "steam_app_1091500", "instance": "steam_app_1091500"}}]}],
   "floating_nodes": []},
  {"id": 15, "type": "workspace", "name": "3", "nodes": [
   {"id": 16, "type": "con", "pid": 1600, "app_id": "mpv", "fullscreen_mode": 1}], "floating_nodes": []}]},
 {"id": 20, "type": "output", "name": "DP-1", "current_workspace": "2", "nodes": [
  {"id": 21, "type": "workspace", "name": "2", "nodes": [
   {"id": 22, "type": "con", "pid": 2200, "app_id": "firefox", "fullscreen_mode": 0}],
   "floating_nodes": [
   {"id": 23, "type": "floating_con", "pid": 2300, "app_id": "pavucontrol", "fullscreen_mode": 0}]}]}]}`

@(test)
test_fullscreen_find_per_output :: proc(t: ^testing.T) {
	v, ok := jparse(TREE)
	testing.expect(t, ok)
	found := fullscreen_find(v)
	// DP-3 shows workspace 1 with the game fullscreen; mpv on the hidden
	// workspace 3 covers nothing; DP-1 has none; the scratchpad doesn't count.
	if !testing.expect_value(t, len(found), 1) {return}
	f := found[0]
	testing.expect_value(t, f.output, "DP-3")
	testing.expect_value(t, f.con, 14)
	testing.expect_value(t, f.pid, 1400)
	testing.expect_value(t, f.class, "steam_app_1091500")
	testing.expect(t, !f.global)

	// Switch DP-3 to workspace 3: mpv covers it now.
	v2, _ := jparse(`{"type": "root", "nodes": [
	 {"type": "output", "name": "DP-3", "current_workspace": "3", "nodes": [
	  {"type": "workspace", "name": "1", "nodes": [{"id": 14, "pid": 1400, "fullscreen_mode": 1}]},
	  {"type": "workspace", "name": "3", "nodes": [{"id": 16, "pid": 1600, "app_id": "mpv", "fullscreen_mode": 1}]}]},
	 {"type": "output", "name": "DP-1", "current_workspace": "2", "nodes": [{"type": "workspace", "name": "2", "nodes": []}]}]}`)
	found = fullscreen_find(v2)
	if testing.expect_value(t, len(found), 1) {
		testing.expect_value(t, found[0].output, "DP-3")
		testing.expect_value(t, found[0].app_id, "mpv")
	}

	// No fullscreen anywhere.
	v3, _ := jparse(`{"type": "root", "nodes": [{"type": "output", "name": "DP-1", "current_workspace": "2", "nodes": [
	 {"type": "workspace", "name": "2", "nodes": [{"id": 5, "pid": 50, "fullscreen_mode": 0}]}]}]}`)
	testing.expect_value(t, len(fullscreen_find(v3)), 0)
}

@(test)
test_fullscreen_find_global_and_containers :: proc(t: ^testing.T) {
	// Global fullscreen (mode 2) on a hidden workspace still covers every output.
	v, _ := jparse(`{"type": "root", "nodes": [
	 {"type": "output", "name": "__i3", "nodes": []},
	 {"type": "output", "name": "DP-3", "current_workspace": "1", "nodes": [
	  {"type": "workspace", "name": "1", "nodes": []},
	  {"type": "workspace", "name": "4", "nodes": [{"id": 9, "pid": 90, "app_id": "game.exe", "fullscreen_mode": 2}]}]},
	 {"type": "output", "name": "DP-1", "current_workspace": "2", "nodes": [{"type": "workspace", "name": "2", "nodes": []}]}]}`)
	found := fullscreen_find(v)
	if testing.expect_value(t, len(found), 2) {
		testing.expect_value(t, found[0].output, "DP-3")
		testing.expect_value(t, found[1].output, "DP-1")
		testing.expect(t, found[0].global && found[1].global)
		testing.expect_value(t, found[1].con, 9)
	}
	// A fullscreen container (not a view): its first view is the one classified.
	v2, _ := jparse(`{"type": "root", "nodes": [{"type": "output", "name": "DP-1", "current_workspace": "2", "nodes": [
	 {"type": "workspace", "name": "2", "nodes": [{"id": 30, "type": "con", "fullscreen_mode": 1, "nodes": [
	  {"id": 31, "pid": 310, "app_id": "a"}, {"id": 32, "pid": 320, "app_id": "b"}]}]}]}]}`)
	found = fullscreen_find(v2)
	if testing.expect_value(t, len(found), 1) {
		testing.expect_value(t, found[0].con, 31)
		testing.expect_value(t, found[0].app_id, "a")
	}
	// A floating fullscreen view counts too.
	v3, _ := jparse(`{"type": "root", "nodes": [{"type": "output", "name": "DP-1", "current_workspace": "2", "nodes": [
	 {"type": "workspace", "name": "2", "nodes": [], "floating_nodes": [{"id": 40, "pid": 400, "app_id": "vlc", "fullscreen_mode": 1}]}]}]}`)
	testing.expect_value(t, len(fullscreen_find(v3)), 1)
}

@(test)
test_game_classify :: proc(t: ^testing.T) {
	Case :: struct {
		app_id, class: string,
		chain:         []Proc_Info,
		game:          bool,
	}
	cases := []Case {
		// Steam / Proton under XWayland.
		{"", "steam_app_1091500", nil, true},
		{"gamescope", "", nil, true},
		// wine names its X11 class after the .exe.
		{"", "Witcher3.EXE", nil, true},
		// Process names: wine processes are called after the Windows program.
		{"", "", {{comm = "game.exe", args = {"Z:\\games\\game.exe"}}}, true},
		{"", "", {{comm = "SomeLongGameNam", args = {"C:\\Program Files\\Some\\SomeLongGameName.exe", "-dx11"}}}, true},
		{"", "", {{comm = "wine64-preloade", args = {"/usr/bin/wine64-preloader"}}}, true},
		{"", "", {{comm = "x"}, {comm = "wineserver"}}, true}, // a parent
		{"", "", {{comm = "reaper", args = {"/home/u/.steam/reaper", "SteamLaunch", "AppId=570", "--", "game"}}}, true},
		{"", "", {{comm = "python3", args = {"python3", "/steam/common/Proton 9.0/proton", "waitforexitandrun", "game.exe"}}}, true},
		// Steam / Lutris environment.
		{"", "", {{comm = "dota2", args = {"./dota2"}, env = {"SteamAppId=570"}}}, true},
		{"", "", {{comm = "sh"}, {comm = "game", env = {"STEAM_COMPAT_APP_ID=123"}}}, true},
		{"", "", {{comm = "game", env = {"LUTRIS_GAME_UUID=abc"}}}, true},
		{"", "", {{comm = "steam", env = {"SteamAppId=0"}}}, false}, // 0 = no game
		{"", "", {{comm = "x", env = {"SteamAppId="}}}, false},
		// Not games.
		{"mpv", "", {{comm = "mpv", args = {"mpv", "film.mkv"}}}, false},
		{"firefox", "", {{comm = "firefox", args = {"/usr/lib64/firefox/firefox"}}, {comm = "sway"}}, false},
		{"foot", "", {{comm = "foot", args = {"foot", "-e", "vim", "notes.exe.txt"}}}, false},
		{"", "", {{comm = "winecfgish"}}, false},
		{"", "", {{comm = "reaper", args = {"reaper"}}}, false}, // the DAW, not Steam's
		{"", "", nil, false},
	}
	for c, i in cases {
		game, why := game_classify(c.app_id, c.class, c.chain)
		testing.expectf(t, game == c.game, "case %d (%q %q): game = %v (%s), want %v", i, c.app_id, c.class, game, why, c.game)
		if game {testing.expectf(t, why != "", "case %d: a reason", i)}
	}
}

@(test)
test_fullscreen_mode_parse :: proc(t: ^testing.T) {
	testing.expect_value(t, parse_fullscreen_mode(""), Fullscreen_Mode.Games)
	testing.expect_value(t, parse_fullscreen_mode("games"), Fullscreen_Mode.Games)
	testing.expect_value(t, parse_fullscreen_mode(" All "), Fullscreen_Mode.All)
	testing.expect_value(t, parse_fullscreen_mode("off"), Fullscreen_Mode.Off)
	testing.expect_value(t, parse_fullscreen_mode("bogus"), Fullscreen_Mode.Games)
}

@(test)
test_proc_chain_self :: proc(t: ^testing.T) {
	// Our own process: readable, with a parent; we're no game.
	chain := proc_chain(i32(posix.getpid()))
	testing.expect(t, len(chain) >= 1)
	if len(chain) > 0 {testing.expect(t, chain[0].comm != "")}
	game, _ := game_classify("", "", chain[:1])
	testing.expect(t, !game)
}
