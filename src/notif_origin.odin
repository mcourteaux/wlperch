// Where a notification came from: the window, and so the workspace, of the
// app that sent it, shown on its popup (in the project's colour on a
// project workspace) and focused by a click on the popup.
//
// The bus tells which process sent the Notify call; sway knows which
// process owns each window. The sender may be a child of the window's
// process (notify-send from a shell in a terminal, a hook of a program
// running there), so we walk up its parents. A sender without a window (a
// portal relaying a sandboxed app, a helper daemon) falls back to windows
// whose app id matches the notification's desktop entry or app name. When
// that leaves windows on several workspaces (one Firefox for all its
// windows), an urgent window or one whose title shares the notification's
// text decides; otherwise no workspace is shown.
package main

import "core:strings"

// The decision, without side effects. `pid`: the sender (0 if unknown);
// `parent(pid)`: its parent's pid (0 if unknown).
notif_origin_pick :: proc(pid: i32, app, desktop, summary, body: string, windows: []Play_Window, parent: proc(pid: i32) -> i32) -> (ws: string, con: i64) {
	cands := make([dynamic]Play_Window, context.temp_allocator)
	if pid > 1 {
		owns := make(map[i32]bool, 16, context.temp_allocator)
		for w in windows {owns[w.pid] = true}
		p := pid
		for _ in 0 ..< 32 {
			if p <= 1 {break}
			if owns[p] {
				for w in windows {if w.pid == p {append(&cands, w)}}
				break
			}
			p = parent(p)
		}
	}
	if len(cands) == 0 {
		for w in windows {if origin_app_matches(w.app, desktop, app) {append(&cands, w)}}
	}
	return origin_choose(cands[:], summary, body)
}

// A window's app id against a desktop entry or an app name:
// "org.telegram.desktop._1a2b" for "org.telegram.desktop", "firefox" for
// "org.mozilla.firefox" or "Firefox".
@(private = "file")
origin_app_matches :: proc(app_id, desktop, app: string) -> bool {
	if app_id == "" {return false}
	id := strings.to_lower(app_id, context.temp_allocator)
	for name in ([]string{desktop, app}) {
		if len(name) < 2 {continue}
		n := strings.to_lower(strings.trim_suffix(name, ".desktop"), context.temp_allocator)
		if id == n || strings.has_prefix(id, strings.concatenate({n, "."}, context.temp_allocator)) {return true}
		short := n[strings.last_index_byte(n, '.') + 1:]
		id_short := id[strings.last_index_byte(id, '.') + 1:]
		if len(short) >= 2 && (id == short || id_short == short) {return true}
	}
	return false
}

@(private = "file")
origin_choose :: proc(cands: []Play_Window, summary, body: string) -> (ws: string, con: i64) {
	if len(cands) == 0 {return}
	// One workspace for all of them: that one (the window too when it's one).
	one :: proc(ws: []Play_Window) -> (string, i64, bool) {
		if len(ws) == 0 {return "", 0, false}
		for w in ws {if w.ws != ws[0].ws {return "", 0, false}}
		return ws[0].ws, len(ws) == 1 ? ws[0].con : 0, true
	}
	if w, c, ok := one(cands); ok {return w, c}
	urgent := make([dynamic]Play_Window, context.temp_allocator)
	for w in cands {if w.urgent {append(&urgent, w)}}
	if w, c, ok := one(urgent[:]); ok {return w, c}
	titled := make([dynamic]Play_Window, context.temp_allocator)
	for w in cands {if origin_title_matches(w.title, summary, body) {append(&titled, w)}}
	if w, c, ok := one(titled[:]); ok {return w, c}
	return
}

// The window's title and the notification's text share something: the
// title's main part ("Inbox" of "Inbox — Mozilla Firefox") is in the
// text, or the summary is in the title.
@(private = "file")
origin_title_matches :: proc(title, summary, body: string) -> bool {
	main := title
	for sep in ([]string{" — ", " - ", " | "}) {
		if i := strings.last_index(main, sep); i > 0 {main = main[:i]}
	}
	main = strings.trim_space(main)
	if len(main) >= 3 && (strings.contains(summary, main) || strings.contains(body, main)) {return true}
	return len(summary) >= 3 && strings.contains(title, summary)
}

// The sender's window right now (on the main thread, from the Notify call).
notif_origin_lookup :: proc(bus: ^Sd_Bus, sender, app, desktop, summary, body: string) -> (ws: string, con: i64) {
	pid: i32
	if sender != "" {pid = bus_name_pid(bus, sender)}
	return notif_origin_pick(pid, app, desktop, summary, body, tree_windows(), proc_parent)
}
