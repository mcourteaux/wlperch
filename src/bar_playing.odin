// Which workspaces hold the window of an app that is playing audio, for the
// speaker on the bar's workspace pills.
//
// The audio server knows which process plays (a stream's
// application.process.id); sway knows which process owns each window. The
// playing process may be a child of the window's (a browser's audio
// process), so we walk up its parents. One process can own windows on many
// workspaces (one Firefox for all its windows): then the playing MPRIS
// player's title, which is the tab's, picks the window whose title has it,
// and if none does, all of that app's workspaces get the speaker.
package main

import "core:encoding/json"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"

Play_Window :: struct {
	ws, app, title: string,
	pid:            i32,
}

Play_Player :: struct {
	pid:     i32,
	title:   string,
	playing: bool,
}

Play_Stream :: struct {
	pid: i32,
	app: string, // the audio server's application.name ("Firefox")
}

Playing_Ws :: struct {
	ws, app: string,
}

@(private = "file")
Bar_Playing :: struct {
	mu:  sync.Mutex,
	ws:  map[string]string, // workspace -> the app playing there
	sig: string,
}
@(private = "file") bplay: Bar_Playing

// The app playing audio on workspace `name`, or "".
bar_ws_playing :: proc(name: string) -> string {
	sync.guard(&bplay.mu)
	return bplay.ws[name]
}

// The decision, without side effects. `streams`: the audio streams that
// play; `parent(pid)`: its parent's pid (0 if unknown).
playing_workspaces :: proc(streams: []Play_Stream, windows: []Play_Window, players: []Play_Player, parent: proc(pid: i32) -> i32, allocator := context.temp_allocator) -> []Playing_Ws {
	out := make([dynamic]Playing_Ws, allocator)
	owns := make(map[i32]bool, 16, context.temp_allocator)
	for w in windows {owns[w.pid] = true}
	owner :: proc(pid: i32, owns: map[i32]bool, parent: proc(pid: i32) -> i32) -> i32 {
		p := pid
		for _ in 0 ..< 32 {
			if p <= 1 {return 0}
			if owns[p] {return p}
			p = parent(p)
		}
		return 0
	}
	done := make(map[i32]bool, 8, context.temp_allocator)
	mark :: proc(out: ^[dynamic]Playing_Ws, w: Play_Window, app: string) {
		for o in out {if o.ws == w.ws {return}}
		append(out, Playing_Ws{w.ws, app != "" ? app : w.app})
	}
	for s in streams {
		w := owner(s.pid, owns, parent)
		if w == 0 || done[w] {continue}
		done[w] = true
		// Its media players: a paused one keeps its stream open on some
		// servers, so an app with players plays only while one says so.
		titles := make([dynamic]string, context.temp_allocator)
		has_players, any_playing := false, false
		for p in players {
			if owner(p.pid, owns, parent) != w {continue}
			has_players = true
			if !p.playing {continue}
			any_playing = true
			if len(p.title) >= 3 {append(&titles, p.title)}
		}
		if has_players && !any_playing {continue}
		matched := false
		first_ws := ""
		one_ws := true
		for win in windows {
			if win.pid != w {continue}
			if first_ws == "" {first_ws = win.ws} else if win.ws != first_ws {one_ws = false}
		}
		if !one_ws {
			for win in windows {
				if win.pid != w {continue}
				for t in titles {
					if strings.contains(win.title, t) {
						mark(&out, win, s.app)
						matched = true
						break
					}
				}
			}
		}
		if matched {continue}
		for win in windows {if win.pid == w {mark(&out, win, s.app)}}
	}
	return out[:]
}

// The parent of `pid`, from /proc (0 if it's gone).
@(private = "file")
proc_parent :: proc(pid: i32) -> i32 {
	buf: [64]u8
	path := strings.concatenate({"/proc/", strconv.itoa(buf[:], int(pid)), "/stat"}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return 0}
	s := string(data)
	// "pid (comm) state ppid ...": comm may hold spaces and parentheses.
	i := strings.last_index_byte(s, ')')
	if i < 0 {return 0}
	f := strings.fields(s[i + 1:], context.temp_allocator)
	if len(f) < 2 {return 0}
	v, _ := strconv.parse_int(f[1])
	return i32(v)
}

// The streams that play: not corked (paused) and not muted.
@(private = "file")
playing_streams :: proc() -> []Play_Stream {
	out := make([dynamic]Play_Stream, context.temp_allocator)
	s, ok := run({"pactl", "-f", "json", "list", "sink-inputs"}, allocator = context.temp_allocator)
	if !ok {return nil}
	root, jok := jparse(s)
	if !jok {return nil}
	for si in jarr(root) {
		if jbool(jobj(si, "corked")) || jbool(jobj(si, "mute")) {continue}
		props := jobj(si, "properties")
		pid, _ := strconv.parse_int(jstr(jobj(props, "application.process.id")))
		if pid > 1 {append(&out, Play_Stream{i32(pid), jstr(jobj(props, "application.name"))})}
	}
	return out[:]
}

// Every window, with its workspace, owner process and title.
@(private = "file")
tree_windows :: proc() -> []Play_Window {
	out := make([dynamic]Play_Window, context.temp_allocator)
	reply, ok := sway_request(IPC_GET_TREE, "")
	if !ok {return nil}
	root, jok := jparse(reply)
	if !jok {return nil}
	walk :: proc(n: json.Value, ws: string, out: ^[dynamic]Play_Window) {
		ws := ws
		t := jstr(jobj(n, "type"))
		if t == "workspace" {ws = jstr(jobj(n, "name"))}
		if pid := jint(jobj(n, "pid")); pid > 0 && (t == "con" || t == "floating_con") && ws != "" && ws != "__i3_scratch" {
			app := jstr(jobj(n, "app_id"))
			if app == "" {app = jstr(jobj(jobj(n, "window_properties"), "class"))}
			append(out, Play_Window{ws, app, jstr(jobj(n, "name")), i32(pid)})
		}
		for list in ([]string{"nodes", "floating_nodes"}) {
			for c in jarr(jobj(n, list)) {walk(c, ws, out)}
		}
	}
	walk(root, "", &out)
	return out[:]
}

// The pid behind a D-Bus name (0 if unknown).
bus_name_pid :: proc(bus: ^Sd_Bus, name: string) -> i32 {
	err: Sd_Bus_Error
	reply: ^Sd_Bus_Message
	r := sd_bus_call_method(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID", &err, &reply, "s", strings.clone_to_cstring(name, context.temp_allocator))
	sd_bus_error_free(&err)
	if r < 0 {return 0}
	defer sd_bus_message_unref(reply)
	pid: u32
	if sd_bus_message_read_basic(reply, 'u', &pid) < 0 {return 0}
	return i32(pid)
}

// Called by the bar's data thread every 2 s with the media players it just
// read; true when the speakers changed (the bar redraws).
bar_playing_update :: proc(players: []Play_Player) -> bool {
	ws := make(map[string]string, 8, context.temp_allocator)
	if streams := playing_streams(); len(streams) > 0 {
		for p in playing_workspaces(streams, tree_windows(), players, proc_parent) {ws[p.ws] = p.app}
	}
	b := strings.builder_make(context.temp_allocator)
	keys := make([dynamic]string, context.temp_allocator)
	for k in ws {append(&keys, k)}
	for i in 1 ..< len(keys) {for j := i; j > 0 && keys[j] < keys[j - 1]; j -= 1 {keys[j], keys[j - 1] = keys[j - 1], keys[j]}}
	for k in keys {strings.write_string(&b, k); strings.write_byte(&b, 0); strings.write_string(&b, ws[k]); strings.write_byte(&b, 0)}
	sig := strings.to_string(b)
	sync.guard(&bplay.mu)
	if sig == bplay.sig {return false}
	delete(bplay.sig)
	bplay.sig = strings.clone(sig)
	for k, v in bplay.ws {
		delete(k)
		delete(v)
	}
	clear(&bplay.ws)
	for k, v in ws {bplay.ws[strings.clone(k)] = strings.clone(v)}
	return true
}
