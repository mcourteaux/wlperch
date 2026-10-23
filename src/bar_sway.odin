// The bar's view of sway: workspaces per output, the binding mode, the
// scratchpad and each output's focused window title. One subscription
// socket feeds the bar's poll loop; on events the state is re-read with
// plain requests (coalesced, so a burst of title changes costs one read).
package main

import "core:encoding/json"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

Bar_Ws :: struct {
	name:    string,
	num:     int, // -1: named
	output:  string,
	focused: bool,
	visible: bool,
	urgent:  bool,
}

Bar_Scratch :: struct {
	app, title: string,
}

Bar_Sway :: struct {
	fd:          posix.FD, // subscription; -1 = not connected
	buf:         [dynamic]u8,
	workspaces:  [dynamic]Bar_Ws,
	mode:        string, // "" = default
	scratch:     [dynamic]Bar_Scratch,
	titles:      map[string]string, // output -> focused window title
	focused_out: string,
	want_ws:     bool,
	want_tree:   bool,
	tree_at:     time.Tick, // last tree read (rate limit)
	retry_at:    time.Tick,
	changed:     bool, // something the bar shows changed
}
bsway: Bar_Sway

@(private = "file") EV_WORKSPACE :: 0x80000000
@(private = "file") EV_OUTPUT :: 0x80000001
@(private = "file") EV_MODE :: 0x80000002
@(private = "file") EV_WINDOW :: 0x80000003
@(private = "file") EV_SHUTDOWN :: 0x80000006
@(private = "file") IPC_GET_BINDING_STATE :: 12
@(private = "file") TREE_MIN_GAP :: 50 * time.Millisecond

@(private = "file")
connect :: proc() -> posix.FD {
	path := posix_getenv("SWAYSOCK")
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

posix_getenv :: proc(name: string) -> string {
	v := posix.getenv(strings.clone_to_cstring(name, context.temp_allocator))
	return v == nil ? "" : string(v)
}

bar_sway_start :: proc() {
	bsway.fd = connect()
	if bsway.fd < 0 {
		bsway.retry_at = time.tick_add(time.tick_now(), 2 * time.Second)
		return
	}
	payload := `["workspace","window","mode","output","shutdown"]`
	hdr: [14]u8
	copy(hdr[:], "i3-ipc")
	(cast(^u32le)&hdr[6])^ = u32le(len(payload))
	(cast(^u32le)&hdr[10])^ = u32le(IPC_SUBSCRIBE)
	posix.send(bsway.fd, &hdr[0], len(hdr), {.NOSIGNAL})
	posix.send(bsway.fd, raw_data(payload), uint(len(payload)), {.NOSIGNAL})
	flags := posix.fcntl(bsway.fd, .GETFL)
	posix.fcntl(bsway.fd, .SETFL, flags | i32(posix.O_NONBLOCK))
	bsway.want_ws, bsway.want_tree = true, true
	if reply, ok := sway_request(IPC_GET_BINDING_STATE, ""); ok {
		if v, vok := jparse(reply); vok {set_mode(jstr(jobj(v, "name")))}
	}
}

@(private = "file")
set_mode :: proc(name: string) {
	m := name == "default" ? "" : name
	if m != bsway.mode {
		delete(bsway.mode)
		bsway.mode = strings.clone(m)
		bsway.changed = true
	}
}

bar_sway_fd :: proc() -> posix.FD {return bsway.fd}

// Read pending events (the socket is readable).
bar_sway_read :: proc() {
	buf: [8192]u8
	for {
		n := posix.recv(bsway.fd, &buf[0], len(buf), {})
		if n > 0 {
			append(&bsway.buf, ..buf[:n])
			continue
		}
		if n == 0 || (n < 0 && posix.errno() != .EAGAIN && posix.errno() != .EWOULDBLOCK) {
			// sway went away (or restarted): try again shortly.
			posix.close(bsway.fd)
			bsway.fd = -1
			clear(&bsway.buf)
			bsway.retry_at = time.tick_add(time.tick_now(), 2 * time.Second)
		}
		break
	}
	for len(bsway.buf) >= 14 {
		size := int((cast(^u32le)&bsway.buf[6])^)
		if len(bsway.buf) < 14 + size {break}
		type := u32((cast(^u32le)&bsway.buf[10])^)
		payload := string(bsway.buf[14:14 + size])
		switch type {
		case EV_WORKSPACE, EV_OUTPUT:
			bsway.want_ws, bsway.want_tree = true, true
		case EV_WINDOW:
			bsway.want_tree = true
			// Urgency is a workspace property but arrives as a window event.
			if strings.contains(payload, `"urgent"`) {bsway.want_ws = true}
		case EV_MODE:
			if v, ok := jparse(payload); ok {set_mode(jstr(jobj(v, "change")))}
		case EV_SHUTDOWN:
		}
		remove_range(&bsway.buf, 0, 14 + size)
	}
}

// How long the poll may sleep for a pending (rate-limited) tree read.
bar_sway_timeout :: proc() -> time.Duration {
	if bsway.fd < 0 {return max(time.tick_diff(time.tick_now(), bsway.retry_at), 0)}
	if bsway.want_tree {return max(TREE_MIN_GAP - time.tick_since(bsway.tree_at), 0)}
	return -1
}

bar_sway_tick :: proc() {
	if bsway.fd < 0 {
		if time.tick_diff(time.tick_now(), bsway.retry_at) <= 0 {bar_sway_start()}
		if bsway.fd < 0 {return}
	}
	if bsway.want_ws {
		bsway.want_ws = false
		read_workspaces()
	}
	if bsway.want_tree && time.tick_since(bsway.tree_at) >= TREE_MIN_GAP {
		bsway.want_tree = false
		bsway.tree_at = time.tick_now()
		read_tree()
	}
}

@(private = "file")
read_workspaces :: proc() {
	reply, ok := sway_request(IPC_GET_WORKSPACES, "")
	if !ok {return}
	v, vok := jparse(reply)
	if !vok {return}
	next: [dynamic]Bar_Ws
	for w in jarr(v) {
		append(&next, Bar_Ws {
			name    = strings.clone(jstr(jobj(w, "name"))),
			num     = int(jint(jobj(w, "num"), -1)),
			output  = strings.clone(jstr(jobj(w, "output"))),
			focused = jbool(jobj(w, "focused")),
			visible = jbool(jobj(w, "visible")),
			urgent  = jbool(jobj(w, "urgent")),
		})
	}
	same := len(next) == len(bsway.workspaces)
	for i in 0 ..< len(next) {
		if !same {break}
		a, b := next[i], bsway.workspaces[i]
		same = a.name == b.name && a.output == b.output && a.focused == b.focused && a.visible == b.visible && a.urgent == b.urgent
	}
	if same {
		free_workspaces(&next)
		return
	}
	free_workspaces(&bsway.workspaces)
	bsway.workspaces = next
	bsway.changed = true
}

@(private = "file")
free_workspaces :: proc(list: ^[dynamic]Bar_Ws) {
	for w in list {
		delete(w.name)
		delete(w.output)
	}
	delete(list^)
}

// The leaf a container's focus stack leads to.
@(private = "file")
focused_leaf :: proc(node: json.Value) -> json.Value {
	n := node
	for depth := 0; depth < 64; depth += 1 {
		focus := jarr(jobj(n, "focus"))
		if len(focus) == 0 {return n}
		want := jint(focus[0])
		next: json.Value
		for list in ([]string{"nodes", "floating_nodes"}) {
			for c in jarr(jobj(n, list)) {
				if jint(jobj(c, "id")) == want {next = c}
			}
		}
		if next == nil {return n}
		n = next
	}
	return n
}

@(private = "file")
read_tree :: proc() {
	reply, ok := sway_request(IPC_GET_TREE, "")
	if !ok {return}
	root, vok := jparse(reply)
	if !vok {return}
	titles: map[string]string
	titles.allocator = context.temp_allocator
	scratch: [dynamic]Bar_Scratch
	scratch.allocator = context.temp_allocator
	focused_out := ""
	for out in jarr(jobj(root, "nodes")) {
		oname := jstr(jobj(out, "name"))
		if oname == "__i3" {
			// The scratchpad: windows (or containers of them) on __i3_scratch.
			for ws in jarr(jobj(out, "nodes")) {
				for c in jarr(jobj(ws, "floating_nodes")) {
					collect_windows(c, &scratch)
				}
			}
			continue
		}
		if jbool(jobj(out, "focused")) {focused_out = oname}
		// The visible workspace is the output's focused child.
		ws := focused_leaf_ws(out)
		if ws == nil {continue}
		leaf := focused_leaf(ws)
		title := ""
		if jstr(jobj(leaf, "type")) == "con" || jstr(jobj(leaf, "type")) == "floating_con" {
			title = jstr(jobj(leaf, "name"))
		}
		titles[oname] = title
		if jbool(jobj(out, "focused")) || jbool(jobj(ws, "focused")) {focused_out = oname}
	}
	changed := len(titles) != len(bsway.titles) || focused_out != bsway.focused_out || len(scratch) != len(bsway.scratch)
	if !changed {
		for k, v in titles {
			if old, has := bsway.titles[k]; !has || old != v {changed = true; break}
		}
	}
	if !changed {
		for s, i in scratch {
			if s.app != bsway.scratch[i].app || s.title != bsway.scratch[i].title {changed = true; break}
		}
	}
	if !changed {return}
	for k, v in bsway.titles {
		delete(k)
		delete(v)
	}
	clear(&bsway.titles)
	for k, v in titles {bsway.titles[strings.clone(k)] = strings.clone(v)}
	for s in bsway.scratch {
		delete(s.app)
		delete(s.title)
	}
	clear(&bsway.scratch)
	for s in scratch {append(&bsway.scratch, Bar_Scratch{strings.clone(s.app), strings.clone(s.title)})}
	delete(bsway.focused_out)
	bsway.focused_out = strings.clone(focused_out)
	bsway.changed = true
}

@(private = "file")
focused_leaf_ws :: proc(out: json.Value) -> json.Value {
	focus := jarr(jobj(out, "focus"))
	if len(focus) == 0 {return nil}
	want := jint(focus[0])
	for ws in jarr(jobj(out, "nodes")) {
		if jint(jobj(ws, "id")) == want {return ws}
	}
	return nil
}

@(private = "file")
collect_windows :: proc(node: json.Value, out: ^[dynamic]Bar_Scratch) {
	kids := 0
	for list in ([]string{"nodes", "floating_nodes"}) {
		for c in jarr(jobj(node, list)) {
			collect_windows(c, out)
			kids += 1
		}
	}
	if kids > 0 {return}
	app := jstr(jobj(node, "app_id"))
	if app == "" {app = jstr(jobj(jobj(node, "window_properties"), "class"))}
	append(out, Bar_Scratch{app, jstr(jobj(node, "name"))})
}

// ---- Workspace groups -------------------------------------------------------------

// One button (a workspace) or one project's workspaces on an output.
Bar_Ws_Group :: struct {
	project: int, // -1: a plain workspace
	ws:      [dynamic]Bar_Ws, // (temp)
}

// The output's workspaces in bar order: numbered ones by number, then each
// project's (in config order, numbers ascending), then other named ones.
bar_ws_groups :: proc(output: string) -> []Bar_Ws_Group {
	out: [dynamic]Bar_Ws_Group
	out.allocator = context.temp_allocator
	mine: [dynamic]Bar_Ws
	mine.allocator = context.temp_allocator
	for w in bsway.workspaces {
		if output == "" || w.output == output {append(&mine, w)}
	}
	rank :: proc(w: Bar_Ws) -> (class, sub: int, name: string) {
		if w.num >= 0 {return 0, w.num, w.name}
		if p := project_for_workspace(w.name); p >= 0 {
			n, _ := strconv.parse_int(w.name[strings.last_index_byte(w.name, ' ') + 1:])
			return 1, p * 10000 + n, w.name
		}
		return 2, 0, w.name
	}
	slice.sort_by(mine[:], proc(a, b: Bar_Ws) -> bool {
		ca, sa, na := rank(a)
		cb, sb, nb := rank(b)
		if ca != cb {return ca < cb}
		if sa != sb {return sa < sb}
		return na < nb
	})
	for w in mine {
		p := w.num >= 0 ? -1 : project_for_workspace(w.name)
		if p >= 0 && len(out) > 0 && out[len(out) - 1].project == p {
			append(&out[len(out) - 1].ws, w)
			continue
		}
		g := Bar_Ws_Group{project = p}
		g.ws.allocator = context.temp_allocator
		append(&g.ws, w)
		append(&out, g)
	}
	return out[:]
}
