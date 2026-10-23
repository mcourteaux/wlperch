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

Sway_State :: struct {
	mu:            sync.Mutex,
	ok:            bool,
	outputs:       [dynamic]Sway_Output,
	layouts:       [dynamic]string,
	active_layout: int,
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
drain_events :: proc(fd: posix.FD) {
	for {
		pfd := posix.pollfd{fd = fd, events = {.IN}}
		if posix.poll(&pfd, 1, 0) <= 0 {return}
		if _, _, ok := ipc_read(fd); !ok {return}
	}
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
			ipc_write(fd, IPC_SUBSCRIBE, `["output", "input"]`)
			for {
				type, _, ok := ipc_read(fd)
				if !ok {break}
				if type & 0x80000000 != 0 {
					// Events come in bursts (e.g. one per input device); coalesce.
					time.sleep(50 * time.Millisecond)
					drain_events(fd)
					refresh()
					audio_refresh_async() // HDMI port -> connector mapping may have changed
					wake_ui()
				}
				free_all(context.temp_allocator)
			}
			posix.close(fd)
			time.sleep(time.Second)
		}
	})
}
