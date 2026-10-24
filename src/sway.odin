// Sway IPC client: outputs (screen layout) and keyboard layouts, kept up to
// date via the IPC event subscription.
package main

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

IPC_COMMAND :: 0
IPC_SUBSCRIBE :: 2
IPC_GET_OUTPUTS :: 3
IPC_GET_INPUTS :: 100
IPC_GET_WORKSPACES :: 1
IPC_GET_TREE :: 4
IPC_GET_CONFIG :: 9
EVENT_WORKSPACE :: 0x80000000
EVENT_WINDOW :: 0x80000003

PLACEHOLDER_APP_ID :: "wlperch-placeholder"

Sway_Output :: struct {
	name, make, model: string,
	active:            bool,
	focused:           bool,
	x, y, w, h:        i32, // logical rect
	mode_w, mode_h:    i32,
	refresh:           f32,
	scale:             f32,
	transform:         string,
}

Visible_Ws :: struct {
	output, ws: string,
}

Sway_State :: struct {
	mu:            sync.Mutex,
	ok:            bool,
	outputs:       [dynamic]Sway_Output,
	layouts:       [dynamic]string,
	active_layout: int,
	focused_ws:    string, // name of the focused workspace
	focused_ws_seq: int,   // bumped on every workspace change
	focused_output: string,
	visible:        [dynamic]Visible_Ws, // workspace shown on each output
	ws_windows:     map[string]int,      // workspace -> real windows (placeholders excluded)
	placeholder_at: map[string]string,   // placeholder title -> workspace it is actually on
	tree_seq:       int,
}
sway: Sway_State

@(private = "file")
cmd_mu: sync.Mutex
@(private = "file")
cmd_fd: posix.FD = -1

@(private = "file")
sway_connect :: proc() -> posix.FD {
	path := os.get_env("SWAYSOCK", context.temp_allocator)
	if path == "" {return -1}
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {return -1}
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	for i in 0 ..< min(len(path), len(addr.sun_path) - 1) {addr.sun_path[i] = auto_cast path[i]}
	if posix.connect(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK {
		posix.close(fd)
		return -1
	}
	posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC))
	return fd
}

@(private = "file")
write_all :: proc(fd: posix.FD, data: []u8) -> bool {
	off := 0
	for off < len(data) {
		n := posix.send(fd, &data[off], uint(len(data)) - uint(off), {.NOSIGNAL})
		if n <= 0 {return false}
		off += n
	}
	return true
}

@(private = "file")
read_all :: proc(fd: posix.FD, data: []u8) -> bool {
	off := 0
	for off < len(data) {
		n := posix.recv(fd, &data[off], uint(len(data)) - uint(off), {})
		if n < 0 && posix.errno() == .EINTR {continue}
		if n <= 0 {return false}
		off += n
	}
	return true
}

@(private = "file")
ipc_write :: proc(fd: posix.FD, type: u32, payload: string) -> bool {
	hdr: [14]u8
	copy(hdr[:], "i3-ipc")
	(cast(^u32le)&hdr[6])^ = u32le(len(payload))
	(cast(^u32le)&hdr[10])^ = u32le(type)
	return write_all(fd, hdr[:]) && (len(payload) == 0 || write_all(fd, transmute([]u8)payload))
}

@(private = "file")
ipc_read :: proc(fd: posix.FD, allocator := context.temp_allocator) -> (type: u32, payload: string, ok: bool) {
	hdr: [14]u8
	if !read_all(fd, hdr[:]) {return}
	if string(hdr[:6]) != "i3-ipc" {return}
	n := int((cast(^u32le)&hdr[6])^)
	type = u32((cast(^u32le)&hdr[10])^)
	buf := make([]u8, n, allocator)
	if !read_all(fd, buf) {return}
	return type, string(buf), true
}

// Synchronous request on the shared command connection.
sway_request :: proc(type: u32, payload: string, allocator := context.temp_allocator) -> (string, bool) {
	sync.guard(&cmd_mu)
	for attempt in 0 ..< 2 {
		if cmd_fd < 0 {cmd_fd = sway_connect()}
		if cmd_fd < 0 {return "", false}
		if ipc_write(cmd_fd, type, payload) {
			if _, reply, ok := ipc_read(cmd_fd, allocator); ok {return reply, true}
		}
		posix.close(cmd_fd)
		cmd_fd = -1
		_ = attempt
	}
	return "", false
}

sway_command :: proc(cmd: string) -> bool {
	reply, ok := sway_request(IPC_COMMAND, cmd)
	if !ok {return false}
	log.debugf("sway: %s -> %s", cmd, reply)
	return strings.contains(reply, `"success": true`) || strings.contains(reply, `"success":true`)
}

// The user's mouse_warping setting (last one in the main config; sway's
// default is "output"). sway can't report the live value, and get_config
// only returns the main file.
@(private = "file")
configured_mouse_warping :: proc() -> string {
	reply, ok := sway_request(IPC_GET_CONFIG, "")
	if !ok {return "output"}
	v, _ := jparse(reply)
	text := jstr(jobj(v, "config"))
	mode := "output"
	for line in strings.split_lines_iterator(&text) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 2 && f[0] == "mouse_warping" {mode = f[1]}
	}
	return mode
}

// Run a chain that hops focus across outputs without dragging the cursor
// along: sway warps it on every output change otherwise.
sway_command_no_warp :: proc(cmd: string) -> bool {
	restore := fmt.tprintf("mouse_warping %s", configured_mouse_warping())
	ok := sway_command(fmt.tprintf("mouse_warping none; %s; %s", cmd, restore))
	if !ok {sway_command(restore)} // a failing command stops the chain
	return ok
}

sway_refresh_workspaces :: proc() {
	reply, ok := sway_request(IPC_GET_WORKSPACES, "")
	if !ok {return}
	v, _ := jparse(reply)
	sync.guard(&sway.mu)
	for x in sway.visible {
		delete(x.output)
		delete(x.ws)
	}
	clear(&sway.visible)
	for ws in jarr(v) {
		name := jstr(jobj(ws, "name"))
		output := jstr(jobj(ws, "output"))
		if jbool(jobj(ws, "visible")) {
			append(&sway.visible, Visible_Ws{strings.clone(output), strings.clone(name)})
		}
		if jbool(jobj(ws, "focused")) {
			if name != sway.focused_ws {
				delete(sway.focused_ws)
				sway.focused_ws = strings.clone(name)
			}
			if output != sway.focused_output {
				delete(sway.focused_output)
				sway.focused_output = strings.clone(output)
			}
		}
	}
	sway.focused_ws_seq += 1
}

// Count the real windows on every workspace (our placeholders don't count).
sway_refresh_tree :: proc() {
	reply, ok := sway_request(IPC_GET_TREE, "")
	if !ok {return}
	v, _ := jparse(reply)
	counts := make(map[string]int, 32, context.temp_allocator)
	count_views :: proc(n: json.Value) -> int {
		c := 0
		for k in ([]string{"nodes", "floating_nodes"}) {
			for child in jarr(jobj(n, k)) {
				if jobj(child, "pid") != nil {
					if jstr(jobj(child, "app_id")) != PLACEHOLDER_APP_ID {c += 1}
				} else {
					c += count_views(child)
				}
			}
		}
		return c
	}
	at := make(map[string]string, 8, context.temp_allocator)
	find_placeholders :: proc(n: json.Value, ws: string, at: ^map[string]string) {
		for k in ([]string{"nodes", "floating_nodes"}) {
			for child in jarr(jobj(n, k)) {
				if jstr(jobj(child, "app_id")) == PLACEHOLDER_APP_ID {
					at[jstr(jobj(child, "name"))] = ws
				} else {
					find_placeholders(child, ws, at)
				}
			}
		}
	}
	walk :: proc(n: json.Value, counts: ^map[string]int, at: ^map[string]string) {
		if jstr(jobj(n, "type")) == "workspace" {
			name := jstr(jobj(n, "name"))
			counts[name] = count_views(n)
			find_placeholders(n, name, at)
			return
		}
		for child in jarr(jobj(n, "nodes")) {walk(child, counts, at)}
	}
	walk(v, &counts, &at)
	sync.guard(&sway.mu)
	for k in sway.ws_windows {delete(k)}
	clear(&sway.ws_windows)
	for k, c in counts {sway.ws_windows[strings.clone(k)] = c}
	for k, w in sway.placeholder_at {
		delete(k)
		delete(w)
	}
	clear(&sway.placeholder_at)
	for k, w in at {sway.placeholder_at[strings.clone(k)] = strings.clone(w)}
	sway.tree_seq += 1
}

@(private = "file")
Event_Kind :: enum {
	Workspace,
	Other, // output / input
	Tree,  // windows appeared, disappeared or moved
	Reload, // sway re-read its config (client.* colours back to the config's)
}

@(private = "file")
classify :: proc(type: u32, payload: string) -> bit_set[Event_Kind] {
	switch type {
	case EVENT_WORKSPACE:
		v, _ := jparse(payload)
		if jstr(jobj(v, "change")) == "reload" {return {.Workspace, .Tree, .Reload}}
		return {.Workspace, .Tree}
	case EVENT_WINDOW:
		v, _ := jparse(payload)
		switch jstr(jobj(v, "change")) {
		// "focus": a mouse-drag swap may only show up as focus changes.
		case "new", "close", "move", "floating", "focus": return {.Tree}
		}
		return {}
	}
	return {.Other}
}

@(private = "file")
refresh :: proc() {
	outs_json, ok1 := sway_request(IPC_GET_OUTPUTS, "")
	inputs_json, ok2 := sway_request(IPC_GET_INPUTS, "")
	if !ok1 || !ok2 {return}
	ov, _ := jparse(outs_json)
	iv, _ := jparse(inputs_json)

	sync.guard(&sway.mu)
	for o in sway.outputs {
		delete(o.name); delete(o.make); delete(o.model); delete(o.transform)
	}
	clear(&sway.outputs)
	for o in jarr(ov) {
		rect := jobj(o, "rect")
		mode := jobj(o, "current_mode")
		so := Sway_Output {
			name      = strings.clone(jstr(jobj(o, "name"))),
			make      = strings.clone(jstr(jobj(o, "make"))),
			model     = strings.clone(jstr(jobj(o, "model"))),
			active    = jbool(jobj(o, "active")),
			focused   = jbool(jobj(o, "focused")),
			x         = i32(jint(jobj(rect, "x"))),
			y         = i32(jint(jobj(rect, "y"))),
			w         = i32(jint(jobj(rect, "width"))),
			h         = i32(jint(jobj(rect, "height"))),
			mode_w    = i32(jint(jobj(mode, "width"))),
			mode_h    = i32(jint(jobj(mode, "height"))),
			refresh   = f32(jint(jobj(mode, "refresh"))) / 1000,
			scale     = f32(jfloat(jobj(o, "scale"), 1)),
			transform = strings.clone(jstr(jobj(o, "transform"), "normal")),
		}
		append(&sway.outputs, so)
	}

	// Keyboard layouts: take the keyboard with the most layouts (they're usually all equal).
	best: json.Value
	best_n := 0
	for kb in jarr(iv) {
		if jstr(jobj(kb, "type")) != "keyboard" {continue}
		n := len(jarr(jobj(kb, "xkb_layout_names")))
		if n > best_n {
			best, best_n = kb, n
		}
	}
	for l in sway.layouts {delete(l)}
	clear(&sway.layouts)
	for name in jarr(jobj(best, "xkb_layout_names")) {
		append(&sway.layouts, strings.clone(jstr(name)))
	}
	sway.active_layout = int(jint(jobj(best, "xkb_active_layout_index")))
	sway.ok = true
}

sway_switch_layout :: proc(index: int) {
	sway_command(fmt.tprintf("input type:keyboard xkb_switch_layout %d", index))
}

// Swallow events that are already queued so a burst causes one refresh.
@(private = "file")
drain_events :: proc(fd: posix.FD) -> (kinds: bit_set[Event_Kind]) {
	for {
		pfd := posix.pollfd{fd = fd, events = {.IN}}
		if posix.poll(&pfd, 1, 0) <= 0 {return}
		type, payload, ok := ipc_read(fd)
		if !ok {return}
		kinds += classify(type, payload)
	}
}

// One-off read of the outputs (and keyboard layouts), for the CLI and setup.
sway_load_outputs :: proc() -> bool {
	if os.get_env("SWAYSOCK", context.temp_allocator) == "" {return false}
	refresh()
	sync.guard(&sway.mu)
	return sway.ok
}

sway_start :: proc() {
	if os.get_env("SWAYSOCK", context.temp_allocator) == "" {
		log.warn("SWAYSOCK not set: display layout and keyboard layouts unavailable")
		return
	}
	refresh()
	thread.create_and_start(proc() {
		for {
			fd := sway_connect()
			if fd < 0 {
				time.sleep(2 * time.Second)
				continue
			}
			ipc_write(fd, IPC_SUBSCRIBE, `["output", "input", "workspace", "window"]`)
			sway_refresh_workspaces()
			sway_refresh_tree()
			theme_sway_reapply() // a restarted daemon or sway: the saved mode's decorations
			for {
				type, payload, ok := ipc_read(fd)
				if !ok {break}
				if type & 0x80000000 != 0 {
					kinds := classify(type, payload)
					if kinds == {} {
						free_all(context.temp_allocator)
						continue // e.g. a window title changed
					}
					// Right away: the titlebars show the config's colours until then.
					if .Reload in kinds {theme_sway_reapply()}
					// Events come in bursts (e.g. one per input device); coalesce.
					time.sleep(50 * time.Millisecond)
					more := drain_events(fd)
					if .Reload in more && .Reload not_in kinds {theme_sway_reapply()}
					kinds += more
					if .Workspace in kinds {sway_refresh_workspaces()}
					if .Tree in kinds {sway_refresh_tree()}
					if .Other in kinds {
						refresh()
						audio_refresh_async() // HDMI port -> connector mapping may have changed
					}
					wake_main() // the time tracker follows workspace focus even when hidden
				}
				free_all(context.temp_allocator)
			}
			posix.close(fd)
			time.sleep(time.Second)
		}
	})
}

// A connection of its own subscribed to `events` (a JSON list), for a poll
// loop that reads it with sway_read_event. -1 when sway isn't there.
sway_subscribe :: proc(events: string) -> posix.FD {
	fd := sway_connect()
	if fd < 0 {return -1}
	if !ipc_write(fd, IPC_SUBSCRIBE, events) {
		posix.close(fd)
		return -1
	}
	if _, reply, ok := ipc_read(fd); !ok || !strings.contains(reply, "true") {
		posix.close(fd)
		return -1
	}
	return fd
}

// One message from a sway_subscribe connection (call when it's readable).
sway_read_event :: proc(fd: posix.FD) -> (type: u32, payload: string, ok: bool) {
	return ipc_read(fd)
}
