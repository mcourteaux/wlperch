// Fullscreen apps and games: which outputs a fullscreen view covers, and
// whether that view is a game. Notification popups, the low-memory card and
// the idle countdown keep off a covered output ([notifications] fullscreen).
//
// The sway thread works the covers out from the get_tree it already fetches
// on window / workspace events (no polling); /proc is read only when a new
// fullscreen view shows up.
package main

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"

import "wl"

Fullscreen_Mode :: enum u8 {
	Games, // hold popups over fullscreen games only (default)
	All,   // over any fullscreen view
	Off,   // popups show over anything
}

parse_fullscreen_mode :: proc(s: string) -> Fullscreen_Mode {
	switch strings.to_lower(strings.trim_space(s), context.temp_allocator) {
	case "all", "any", "always": return .All
	case "off", "never", "no", "false": return .Off
	}
	return .Games
}

// A fullscreen view as found in the tree, on the output it covers.
Fs_Found :: struct {
	output: string,
	con:    i64,
	pid:    i32,
	app_id: string,
	class:  string, // XWayland WM_CLASS class
	global: bool,   // fullscreen_mode 2: spans every output
}

// One output covered by a fullscreen view (sway.fs).
Fs_Cover :: struct {
	output: string,
	con:    i64,
	pid:    i32,
	app:    string, // app_id, or the X11 class
	game:   bool,
	why:    string, // what made it a game
	global: bool,
}

// ---- The tree -------------------------------------------------------------------

@(private = "file")
first_view :: proc(n: json.Value) -> json.Value {
	if jobj(n, "pid") != nil {return n}
	for k in ([]string{"nodes", "floating_nodes"}) {
		for child in jarr(jobj(n, k)) {
			if v := first_view(child); v != nil {return v}
		}
	}
	return nil
}

@(private = "file")
find_mode :: proc(n: json.Value, mode: i64) -> json.Value {
	if jint(jobj(n, "fullscreen_mode")) == mode && jstr(jobj(n, "type")) != "workspace" {return n}
	for k in ([]string{"nodes", "floating_nodes"}) {
		for child in jarr(jobj(n, k)) {
			if f := find_mode(child, mode); f != nil {return f}
		}
	}
	return nil
}

@(private = "file")
found_from :: proc(node: json.Value, output: string, global: bool) -> (f: Fs_Found, ok: bool) {
	v := first_view(node)
	if v == nil {return}
	return Fs_Found {
		output = output,
		con    = jint(jobj(v, "id")),
		pid    = i32(jint(jobj(v, "pid"))),
		app_id = jstr(jobj(v, "app_id")),
		class  = jstr(jobj(jobj(v, "window_properties"), "class")),
		global = global,
	}, true
}

// The outputs a fullscreen view covers, from a get_tree reply: the view that
// is fullscreen on the workspace each output shows, or one global fullscreen
// view over all of them. Strings point into the JSON.
fullscreen_find :: proc(tree: json.Value, allocator := context.temp_allocator) -> [dynamic]Fs_Found {
	out := make([dynamic]Fs_Found, allocator)
	outputs := make([dynamic]json.Value, context.temp_allocator)
	for o in jarr(jobj(tree, "nodes")) {
		if jstr(jobj(o, "type")) == "output" && jstr(jobj(o, "name")) != "__i3" {append(&outputs, o)}
	}
	// Global fullscreen sits in its workspace but shows over everything.
	if g := find_mode(tree, 2); g != nil {
		for o in outputs {
			if f, ok := found_from(g, jstr(jobj(o, "name")), true); ok {append(&out, f)}
		}
		return out
	}
	for o in outputs {
		cur := jstr(jobj(o, "current_workspace"))
		for ws in jarr(jobj(o, "nodes")) {
			if jstr(jobj(ws, "type")) != "workspace" || jstr(jobj(ws, "name")) != cur {continue}
			if fs := find_mode(ws, 1); fs != nil {
				if f, ok := found_from(fs, jstr(jobj(o, "name")), false); ok {append(&out, f)}
			}
		}
	}
	return out
}

// ---- Is it a game? --------------------------------------------------------------

// What /proc says about one process of the view's chain (the view's own
// first, then its parents).
Proc_Info :: struct {
	comm: string,
	args: []string,
	env:  []string, // only the variables game_classify looks at, KEY=VALUE
}

@(private = "file")
GAME_ENV :: [?]string{"SteamAppId", "SteamGameId", "STEAM_COMPAT_APP_ID", "LUTRIS_GAME_UUID"}

@(private = "file")
WINE_NAMES :: [?]string{"wine", "wine64", "wine-preloader", "wine64-preloader", "wineserver", "gamescope"}

// Last path component, for both / and Windows \ paths.
@(private = "file")
base_name :: proc(s: string) -> string {
	i := max(strings.last_index_byte(s, '/'), strings.last_index_byte(s, '\\'))
	return s[i + 1:]
}

@(private = "file")
is_exe :: proc(s: string) -> bool {
	return len(s) > 4 && strings.equal_fold(s[len(s) - 4:], ".exe")
}

// A game, going by the view's app_id / X11 class and its process chain:
//   - Steam's XWayland class steam_app_<id>, or gamescope;
//   - a Windows program: class or argv[0] ending in .exe (wine names its
//     processes after the .exe), or a wine / wine-preloader / wineserver /
//     gamescope process, or Proton;
//   - Steam's reaper ("reaper SteamLaunch AppId=…");
//   - Steam / Lutris environment: SteamAppId, SteamGameId,
//     STEAM_COMPAT_APP_ID (not 0), LUTRIS_GAME_UUID.
game_classify :: proc(app_id, class: string, chain: []Proc_Info) -> (game: bool, why: string) {
	for id in ([]string{app_id, class}) {
		low := strings.to_lower(id, context.temp_allocator)
		if strings.has_prefix(low, "steam_app_") {return true, fmt.tprintf("Steam (%s)", id)}
		if low == "gamescope" {return true, "gamescope"}
		if is_exe(id) {return true, fmt.tprintf("Windows program %s", id)}
	}
	for p, depth in chain {
		self := depth == 0 ? "" : " (parent)"
		names := [2]string{p.comm, len(p.args) > 0 ? base_name(p.args[0]) : ""}
		for name in names {
			if name == "" {continue}
			if is_exe(name) {return true, fmt.tprintf("Windows program %s%s", name, self)}
			for w in WINE_NAMES {
				// comm is cut at 15 bytes: "wine64-preloade".
				if name == w || (len(name) == 15 && strings.has_prefix(w, name)) {return true, fmt.tprintf("%s%s", w, self)}
			}
		}
		if names[1] == "reaper" {
			for a in p.args {if a == "SteamLaunch" {return true, "Steam (reaper)"}}
		}
		for a in p.args {
			if base_name(a) == "proton" {return true, "Proton"}
		}
		for kv in p.env {
			eq := strings.index_byte(kv, '=')
			if eq < 0 {continue}
			k, v := kv[:eq], kv[eq + 1:]
			if v == "" || v == "0" {continue}
			for g in GAME_ENV {if k == g {return true, fmt.tprintf("%s=%s", k, v)}}
		}
	}
	return false, ""
}

@(private = "file")
read_proc :: proc(pid: i32, file: string) -> (string, bool) {
	data, err := os.read_entire_file(fmt.tprintf("/proc/%d/%s", pid, file), context.temp_allocator)
	if err != nil {return "", false}
	return string(data), true
}

@(private = "file")
split_nul :: proc(s: string) -> []string {
	parts := make([dynamic]string, context.temp_allocator)
	rest := s
	for rest != "" {
		i := strings.index_byte(rest, 0)
		if i < 0 {append(&parts, rest); break}
		if i > 0 {append(&parts, rest[:i])}
		rest = rest[i + 1:]
	}
	return parts[:]
}

// The view's process and a few parents (temp allocator). environ is only
// readable for our own processes; the rest is skipped quietly.
proc_chain :: proc(pid: i32, depth := 4) -> []Proc_Info {
	chain := make([dynamic]Proc_Info, context.temp_allocator)
	pid := pid
	for _ in 0 ..< depth {
		if pid <= 1 {break}
		stat, ok := read_proc(pid, "stat")
		if !ok {break}
		p: Proc_Info
		comm, _ := read_proc(pid, "comm")
		p.comm = strings.trim_right(comm, "\n")
		if cmd, ok2 := read_proc(pid, "cmdline"); ok2 {p.args = split_nul(cmd)}
		if env, ok3 := read_proc(pid, "environ"); ok3 {
			keep := make([dynamic]string, context.temp_allocator)
			for kv in split_nul(env) {
				for g in GAME_ENV {
					if len(kv) > len(g) && kv[len(g)] == '=' && strings.has_prefix(kv, g) {append(&keep, kv)}
				}
			}
			p.env = keep[:]
		}
		append(&chain, p)
		// "pid (comm) state ppid …": comm may hold spaces and parentheses.
		close := strings.last_index_byte(stat, ')')
		if close < 0 {break}
		f := strings.fields(stat[close + 1:], context.temp_allocator)
		if len(f) < 2 {break}
		ppid, pok := strconv.parse_int(f[1])
		if !pok {break}
		pid = i32(ppid)
	}
	return chain[:]
}

// ---- Kept in sway (the sway thread) ------------------------------------------------

// Called by sway_refresh_tree with the tree it just parsed. Classifies new
// fullscreen views (reusing what's known for the same view) and bumps
// sway.fs_seq when anything changed.
fullscreen_update :: proc(tree: json.Value) {
	found := fullscreen_find(tree)
	covers := make([dynamic]Fs_Cover, context.temp_allocator)
	{
		sync.guard(&sway.mu)
		for f in found {
			c := Fs_Cover{output = f.output, con = f.con, pid = f.pid, app = f.app_id != "" ? f.app_id : f.class, global = f.global}
			known := false
			for old in sway.fs {
				if old.con == f.con && old.pid == f.pid {
					c.game, c.why = old.game, strings.clone(old.why, context.temp_allocator) // sway.fs is replaced below
					known = true
					break
				}
			}
			for prev in covers {
				if !known && prev.con == f.con && prev.pid == f.pid {
					c.game, c.why = prev.game, prev.why
					known = true
				}
			}
			if !known {c.why = "?"} // classified below, outside the lock
			append(&covers, c)
		}
	}
	for &c, i in covers {
		if c.why != "?" {continue}
		f := found[i]
		c.game, c.why = game_classify(f.app_id, f.class, proc_chain(f.pid))
		for &d in covers[i + 1:] {
			if d.con == c.con && d.pid == c.pid {d.game, d.why = c.game, c.why}
		}
	}

	sync.guard(&sway.mu)
	same := len(covers) == len(sway.fs)
	if same {
		for c, i in covers {
			o := sway.fs[i]
			if c.output != o.output || c.con != o.con || c.pid != o.pid || c.global != o.global {same = false}
		}
	}
	if same {return}
	for c in sway.fs {delete(c.output); delete(c.app); delete(c.why)}
	clear(&sway.fs)
	for c in covers {
		append(&sway.fs, Fs_Cover{output = strings.clone(c.output), con = c.con, pid = c.pid, app = strings.clone(c.app), game = c.game, why = strings.clone(c.why), global = c.global})
	}
	sway.fs_seq += 1
}

// What covers which output, in the log (main thread: the sway thread has no logger).
fullscreen_log :: proc() {
	sync.guard(&sway.mu)
	for c in sway.fs {
		log.infof("fullscreen: %s covered by %s (pid %d%s)%s%s", c.output, c.app, c.pid, c.global ? ", global" : "", c.game ? fmt.tprintf(", a game: %s", c.why) : ", not a game", cover_holds(c) ? "; popups keep off it" : "")
	}
	if len(sway.fs) == 0 {log.info("fullscreen: no output covered")}
}

// ---- The main thread's view ----------------------------------------------------------

// Bumped whenever the covered outputs change (the popups re-place).
fullscreen_seq :: proc() -> int {
	sync.guard(&sway.mu)
	return sway.fs_seq
}

@(private = "file")
cover_holds :: proc(c: Fs_Cover) -> bool {
	switch config.notif_fullscreen {
	case .Off:   return false
	case .All:   return true
	case .Games: return c.game
	}
	return false
}

@(private = "file")
blocks_locked :: proc(output: string) -> bool {
	if output == "" {return false}
	for c in sway.fs {if c.output == output && cover_holds(c) {return true}}
	return false
}

// A fullscreen view that holds popups ([notifications] fullscreen) covers this output.
fullscreen_blocks :: proc(output: string) -> bool {
	sync.guard(&sway.mu)
	return blocks_locked(output)
}

// The covered outputs that hold popups (temp allocator), and whether a game covers any.
fullscreen_blocked :: proc() -> (outputs: []string, game: bool) {
	sync.guard(&sway.mu)
	list := make([dynamic]string, context.temp_allocator)
	for c in sway.fs {
		if !cover_holds(c) {continue}
		append(&list, strings.clone(c.output, context.temp_allocator))
		if c.game {game = true}
	}
	return list[:], game
}

@(private = "file")
wl_output_for :: proc(conn: string) -> ^wl.Output {
	if conn == "" {return nil}
	for o in plat.outputs {if o.conn == conn {return o.output}}
	return nil
}

// Where a popup goes: the focused output, or the first other one when a
// fullscreen game covers that. free = false when every output is covered
// (the popup should wait); output is then the focused one, for the few that
// show anyway. output nil = let the compositor pick (no sway info).
Popup_Place :: struct {
	output: ^wl.Output,
	conn:   string, // temp allocator
	free:   bool,
}

popup_place :: proc() -> Popup_Place {
	sync.guard(&sway.mu)
	focus := strings.clone(sway.focused_output, context.temp_allocator)
	order := make([dynamic]string, context.temp_allocator)
	if focus != "" {append(&order, focus)}
	for o in sway.outputs {
		if o.active && o.name != focus {append(&order, strings.clone(o.name, context.temp_allocator))}
	}
	any_blocked := false
	for name in order {
		wo := wl_output_for(name)
		if wo == nil {continue}
		if !blocks_locked(name) {return {wo, name, true}}
		any_blocked = true
	}
	return {wl_output_for(focus), focus, !any_blocked}
}
