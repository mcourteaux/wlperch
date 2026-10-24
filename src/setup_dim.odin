// `wlperch setup`: the rest of the screen dims while the window is open
// ([setup] dim_background, on by default).
//
// The window is an ordinary xdg toplevel, and layer-shell surfaces stack
// either below all windows or above them, never in between. So the dim is a
// layer surface on the TOP layer of every output (over the other windows and
// the bar) with a hole where the window's card is: four bands of a
// single-pixel buffer around the hole, scaled by wp_viewporter, plus the
// card's four rounded corners (one small shm buffer, mirrored with buffer
// transforms). Its input region leaves out the card and the resize strip
// around it, so the window works as before; a click on the dim closes setup,
// like Escape (clicks never fall through to the dimmed apps).
//
// The surfaces belong to this process: a crash or kill -9 takes the dim
// along (unlike, say, changing other windows' opacity over IPC).
//
// Where the window is comes from sway's tree (no Wayland client can know
// its own position). sway sends no events while a floating window is
// dragged, so the tree is polled at frame rate while a move or resize is
// going on (one we started, until the pointer comes back to us; a modifier
// drag while Super / Alt is held; the compositor's resizing state) and for a
// moment after the last change; window / workspace / output events and a
// slow poll catch the rest. Nothing is committed while nothing changes.
//
// The dim shows only while the window floats, is visible and has focus:
// tiled (or fullscreen) it is part of the layout the user arranged, and
// when another window takes focus the user has moved on. It fades in and
// out (frame callbacks pace the fade).
package main

import "core:encoding/ini"
import "core:encoding/json"
import "core:log"
import "core:math"
import "core:sync"
import "core:sys/posix"
import "core:time"

import "wl"

@(private = "file") DIM_FADE :: 150 * time.Millisecond   // a full fade (shorter for part of one)
@(private = "file") DIM_FAST :: 16 * time.Millisecond    // tree polls while the window moves
@(private = "file") DIM_SLOW :: 1000 * time.Millisecond  // otherwise (moves no event tells us about)
@(private = "file") DIM_SETTLE :: 1500 * time.Millisecond // keep polling fast this long after a change
@(private = "file") DIM_WATCHDOG :: 100 * time.Millisecond // frame callbacks stop on a disabled output
@(private = "file") DIM_LIGHT :: 0.75                     // light theme: a softer dim

Dim_Rect :: struct {
	x, y, w, h: i32,
}

// The dim's pieces on an output of w×h around `hole` (output-local, may reach
// past the edges): bands above, below, left and right of it, then its four
// corners (top-left, top-right, bottom-left, bottom-right) when rounded. No
// hole on this output: the first band covers it all. Zero-sized = not shown.
// A corner that doesn't fit on the output is left out (the rest of the card
// is on another output).
dim_layout :: proc(w, h: i32, hole: Dim_Rect, has_hole: bool, radius: i32) -> (parts: [8]Dim_Rect) {
	if !has_hole || hole.w <= 0 || hole.h <= 0 || hole.x >= w || hole.y >= h || hole.x + hole.w <= 0 || hole.y + hole.h <= 0 {
		parts[0] = {0, 0, w, h}
		return
	}
	x0, y0 := clamp(hole.x, 0, w), clamp(hole.y, 0, h)
	x1, y1 := clamp(hole.x + hole.w, 0, w), clamp(hole.y + hole.h, 0, h)
	parts[0] = {0, 0, w, y0}
	parts[1] = {0, y1, w, h - y1}
	parts[2] = {0, y0, x0, y1 - y0}
	parts[3] = {x1, y0, w - x1, y1 - y0}
	r := min(radius, hole.w / 2, hole.h / 2)
	if r > 0 {
		corners := [4][2]i32 {
			{hole.x, hole.y},
			{hole.x + hole.w - r, hole.y},
			{hole.x, hole.y + hole.h - r},
			{hole.x + hole.w - r, hole.y + hole.h - r},
		}
		for c, i in corners {
			if c.x >= 0 && c.y >= 0 && c.x + r <= w && c.y + r <= h {parts[4 + i] = {c.x, c.y, r, r}}
		}
	}
	for &p in parts {
		if p.w <= 0 || p.h <= 0 {p = {}}
	}
	return
}

// Opacity (0..1) of the dim at full strength.
dim_alpha :: proc(strength: int, light: bool) -> f32 {
	a := f32(strength) / 100
	return light ? a * DIM_LIGHT : a
}

@(private = "file")
Dim_Part :: struct {
	surf:  ^wl.Surface,
	sub:   ^wl.Subsurface,
	vp:    ^wl.Wp_Viewport,
	shown: Dim_Rect, // as committed (w == 0: no buffer)
	buf:   ^wl.Buffer, // the buffer it shows
}

@(private = "file")
Dim_Out :: struct {
	output:     ^wl.Output,
	root:       ^wl.Surface, // transparent, full output; takes the clicks
	layer:      ^wl.Zwlr_Layer_Surface_V1,
	vp:         ^wl.Wp_Viewport,
	clear_buf:  ^wl.Buffer,
	parts:      [8]Dim_Part,
	configured: bool,
	closed:     bool,
	w, h:       i32,
	frame_cb:   ^wl.Callback,
	frame_at:   time.Tick,
	// What is on screen.
	drawn:      bool,
	root_size:  [2]i32,
	a8:         u32, // dim opacity, 0..255
	input_hole: Dim_Rect,
	band_buf:   ^wl.Buffer,
	corner_buf: ^wl.Buffer,
	corner_key: [3]i32, // a8, pixel size, scale of corner_buf
}

@(private = "file")
dim: struct {
	enabled:     bool,
	strength:    int,
	ok:          bool, // the compositor has what it takes
	ev_fd:       posix.FD,
	outs:        [dynamic]^Dim_Out,
	pid:         i64,
	// The window in sway's tree.
	found:       bool,
	floating:    bool,
	focused:     bool,
	visible:     bool,
	fullscreen:  bool,
	card:        Dim_Rect, // layout coordinates
	tree_dirty:  bool,
	polled_at:   time.Tick,
	changed_at:  time.Tick,
	// Fade.
	want:        bool,
	from:        f32,
	fade_at:     time.Tick,
	closing:     bool,
	fast:        bool, // following a move (for the log)
} = {ev_fd = -1}

// [setup] dim_background / dim_strength from config.ini (also after the
// Settings tab changed them: applies at once).
setup_dim_load_config :: proc() {
	defaults, _ := ini.load_map_from_string(DEFAULT_CONFIG, context.temp_allocator)
	path := config_path()
	defer delete(path)
	m, _, ok := ini.load_map_from_path(path, context.temp_allocator)
	if !ok {m = defaults}
	enabled, bok := parse_bool_value(config_value(m, defaults, "setup", "dim_background"))
	if !bok {enabled = true}
	strength := parse_int_lim(config_value(m, defaults, "setup", "dim_strength"), LIM_SETUP_DIM)
	if enabled != dim.enabled || strength != dim.strength {
		log.debugf("setup dim: %s, %d %%", enabled ? "on" : "off", strength)
	}
	dim.enabled, dim.strength = enabled, strength
	dim.tree_dirty = true
}

setup_dim_init :: proc() {
	dim.ok = plat.layer_shell != nil && plat.viewporter != nil && plat.single_pixel != nil && plat.subcompositor != nil && plat.shm != nil
	dim.pid = i64(posix.getpid())
	setup_dim_load_config()
	if !sway_load_outputs() {dim.ok = false} // no sway: nowhere to learn where the window is
	if !dim.ok {
		log.debug("setup dim: unavailable (no sway or missing protocols)")
		return
	}
	dim.ev_fd = sway_subscribe(`["window", "workspace", "output"]`)
	dim.tree_dirty = true
}

// For the poll set (-1: none).
setup_dim_fd :: proc() -> posix.FD {return dim.ev_fd}

// sway events arrived on setup_dim_fd.
setup_dim_on_event :: proc() {
	for {
		pfd := posix.pollfd{fd = dim.ev_fd, events = {.IN}}
		if posix.poll(&pfd, 1, 0) <= 0 {return}
		type, payload, ok := sway_read_event(dim.ev_fd)
		if !ok {
			// sway went away: the slow poll is all that's left.
			posix.close(dim.ev_fd)
			dim.ev_fd = -1
			return
		}
		switch type {
		case EVENT_WINDOW:
			v, _ := jparse(payload)
			switch jstr(jobj(v, "change")) {
			case "title", "mark", "urgent":
			case:
				dim.tree_dirty = true
			}
		case EVENT_WORKSPACE:
			dim.tree_dirty = true
		case:
			sway_load_outputs() // output layout
			dim.tree_dirty = true
		}
	}
}

// Esc, the close button or a click on the dim: fade out, then the window goes.
setup_dim_close :: proc() {dim.closing = true}

// Something is still on screen (the fade-out).
setup_dim_busy :: proc() -> bool {return len(dim.outs) > 0}

// A click on the dim (any output) closes setup.
setup_dim_on_button :: proc(surface: ^wl.Surface, button, state: u32) -> bool {
	if surface == nil {return false}
	for o in dim.outs {
		if surface != o.root {continue}
		if state == wl.POINTER_BUTTON_STATE_PRESSED && !dim.closing {
			log.debug("setup dim: clicked, closing")
			plat.closed = true
		}
		return true
	}
	return false
}

@(private = "file")
level_now :: proc(now: time.Tick) -> f32 {
	target: f32 = dim.want ? 1 : 0
	dur := time.Duration(f64(DIM_FADE) * f64(abs(target - dim.from)))
	if dur <= 0 {return target}
	t := f32(time.duration_seconds(time.tick_diff(dim.fade_at, now)) / time.duration_seconds(dur))
	if t >= 1 {return target}
	u := 1 - clamp(t, 0, 1)
	e := 1 - u * u * u // ease-out
	return dim.from + (target - dim.from) * e
}

@(private = "file")
fast_follow :: proc(now: time.Tick) -> bool {
	return plat.win_grab || plat.win.resizing || (plat.mods_held && plat.keyboard_focus) || (dim.changed_at != {} && time.tick_diff(dim.changed_at, now) < DIM_SETTLE)
}

// ms until setup_dim_tick has something to do (-1: nothing).
setup_dim_timeout :: proc() -> int {
	if !dim.ok {return -1}
	now := time.tick_now()
	target: f32 = dim.want ? 1 : 0
	if len(dim.outs) > 0 && level_now(now) != target {return 4} // fading (frame callbacks pace it)
	if !dim.enabled && len(dim.outs) == 0 {return -1}
	if dim.tree_dirty {return 0}
	every := fast_follow(now) ? DIM_FAST : DIM_SLOW
	left := every - time.tick_diff(dim.polled_at, now)
	return max(int(time.duration_milliseconds(left)) + 1, 0)
}

// Where the window is, from sway's tree.
@(private = "file")
poll_tree :: proc(now: time.Tick) {
	dim.polled_at = now
	dim.tree_dirty = false
	reply, ok := sway_request(IPC_GET_TREE, "")
	if !ok {
		dim.found = false
		return
	}
	v, _ := jparse(reply)
	Hit :: struct {
		node:     json.Value,
		floating: bool,
		found:    bool,
	}
	walk :: proc(n: json.Value, floating: bool, pid: i64, hit: ^Hit) {
		if hit.found {return}
		if jint(jobj(n, "pid"), -1) == pid && jstr(jobj(n, "app_id")) == "wlperch-setup" {
			hit^ = {n, floating, true}
			return
		}
		for child in jarr(jobj(n, "nodes")) {walk(child, floating, pid, hit)}
		for child in jarr(jobj(n, "floating_nodes")) {walk(child, true, pid, hit)}
	}
	hit: Hit
	walk(v, false, dim.pid, &hit)
	card := dim.card // gone from the tree (closing): the hole stays where the window was
	if hit.found {
		r, wr := jobj(hit.node, "rect"), jobj(hit.node, "window_rect")
		card = {i32(jint(jobj(r, "x"))), i32(jint(jobj(r, "y"))), i32(jint(jobj(r, "width"))), i32(jint(jobj(r, "height")))}
		if plat.win.margin > 0 {
			// Our own frame: the card is the window geometry (sway draws no border).
			card = {card.x + i32(jint(jobj(wr, "x"))), card.y + i32(jint(jobj(wr, "y"))), i32(jint(jobj(wr, "width"))), i32(jint(jobj(wr, "height")))}
		}
	}
	floating, focused := hit.floating, jbool(jobj(hit.node, "focused"))
	visible, fullscreen := jbool(jobj(hit.node, "visible")), jint(jobj(hit.node, "fullscreen_mode")) != 0
	if hit.found != dim.found || card != dim.card || floating != dim.floating || focused != dim.focused || visible != dim.visible || fullscreen != dim.fullscreen {
		dim.changed_at = now
	}
	dim.found, dim.card, dim.floating, dim.focused, dim.visible, dim.fullscreen = hit.found, card, floating, focused, visible, fullscreen
}

// From the setup loop, every iteration: follows the window, fades, commits
// what changed (nothing when nothing did).
setup_dim_tick :: proc() {
	if !dim.ok {return}
	now := time.tick_now()
	if dim.enabled || len(dim.outs) > 0 {
		fast := fast_follow(now)
		if fast != dim.fast {
			log.debugf("setup dim: following %s", fast ? "at frame rate" : "slowly")
			dim.fast = fast
		}
		if dim.tree_dirty || time.tick_diff(dim.polled_at, now) >= (fast ? DIM_FAST : DIM_SLOW) {poll_tree(now)}
	}
	want := dim.enabled && !dim.closing && plat.configured && dim.found && dim.floating && dim.visible && dim.focused && !dim.fullscreen
	if want != dim.want {
		dim.from = len(dim.outs) > 0 ? level_now(now) : 0
		dim.want = want
		dim.fade_at = now
		log.debugf("setup dim: %s", want ? "in" : "out")
	}
	if want {
		// The fade starts with the first frame on screen, not with the
		// request (the surfaces take a moment to be configured).
		drawn := false
		for o in dim.outs {if o.drawn {drawn = true}}
		if !drawn {dim.from, dim.fade_at = 0, now}
	}
	level := level_now(now)
	if !want && level <= 0 {
		for o in dim.outs {destroy_out(o)}
		clear(&dim.outs)
		return
	}
	sync_outputs()
	for o in dim.outs {
		if !o.configured || o.closed || o.w <= 0 || o.h <= 0 {continue}
		if o.frame_cb != nil && time.tick_diff(o.frame_at, now) < DIM_WATCHDOG {continue}
		render_out(o, level)
	}
}

// ---- Surfaces --------------------------------------------------------------------------------

@(private = "file")
layer_listener := wl.Zwlr_Layer_Surface_V1_Listener {
	configure = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1, serial, width, height: u32) {
		o := (^Dim_Out)(data)
		wl.zwlr_layer_surface_v1_ack_configure(self, serial)
		o.w, o.h = i32(width), i32(height)
		o.configured = true
	},
	closed = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1) {
		(^Dim_Out)(data).closed = true
	},
}

@(private = "file")
frame_listener := wl.Callback_Listener {
	done = proc "c" (data: rawptr, self: ^wl.Callback, t: u32) {
		o := (^Dim_Out)(data)
		wl.callback_destroy(self)
		if o.frame_cb == self {o.frame_cb = nil}
	},
}

// One dim per output, as plat.outputs comes and goes.
@(private = "file")
sync_outputs :: proc() {
	for i := len(dim.outs) - 1; i >= 0; i -= 1 {
		o := dim.outs[i]
		present := false
		for po in plat.outputs {if po.output == o.output {present = true}}
		if !present || o.closed {
			destroy_out(o)
			ordered_remove(&dim.outs, i)
		}
	}
	for po in plat.outputs {
		have := false
		for o in dim.outs {if o.output == po.output {have = true}}
		if !have {append(&dim.outs, create_out(po.output))}
	}
}

@(private = "file")
CORNER_TRANSFORM := [4]i32{wl.OUTPUT_TRANSFORM_NORMAL, wl.OUTPUT_TRANSFORM_FLIPPED, wl.OUTPUT_TRANSFORM_FLIPPED_180, wl.OUTPUT_TRANSFORM_180}

@(private = "file")
create_out :: proc(output: ^wl.Output) -> ^Dim_Out {
	o := new(Dim_Out)
	o.output = output
	o.root = wl.compositor_create_surface(plat.compositor)
	o.layer = wl.zwlr_layer_shell_v1_get_layer_surface(plat.layer_shell, o.root, output, wl.ZWLR_LAYER_SHELL_V1_LAYER_TOP, "wlperch-setup-dim")
	wl.zwlr_layer_surface_v1_add_listener(o.layer, &layer_listener, o)
	wl.zwlr_layer_surface_v1_set_anchor(o.layer, wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT)
	wl.zwlr_layer_surface_v1_set_exclusive_zone(o.layer, -1) // over the bar too
	wl.zwlr_layer_surface_v1_set_keyboard_interactivity(o.layer, wl.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE)
	wl.zwlr_layer_surface_v1_set_size(o.layer, 0, 0)
	o.vp = wl.wp_viewporter_get_viewport(plat.viewporter, o.root)
	for &p, i in o.parts {
		p.surf = wl.compositor_create_surface(plat.compositor)
		p.sub = wl.subcompositor_get_subsurface(plat.subcompositor, p.surf, o.root) // synced: one commit of the root applies all
		p.vp = wl.wp_viewporter_get_viewport(plat.viewporter, p.surf)
		r := wl.compositor_create_region(plat.compositor)
		wl.surface_set_input_region(p.surf, r) // the root alone takes clicks
		wl.region_destroy(r)
		if i >= 4 {wl.surface_set_buffer_transform(p.surf, CORNER_TRANSFORM[i - 4])}
	}
	wl.surface_commit(o.root)
	return o
}

@(private = "file")
destroy_out :: proc(o: ^Dim_Out) {
	if o.frame_cb != nil {wl.callback_destroy(o.frame_cb)}
	for p in o.parts {
		wl.wp_viewport_destroy(p.vp)
		wl.subsurface_destroy(p.sub)
		wl.surface_destroy(p.surf)
	}
	wl.wp_viewport_destroy(o.vp)
	wl.zwlr_layer_surface_v1_destroy(o.layer)
	wl.surface_destroy(o.root)
	// Ours to destroy once the surfaces are gone (wl_buffer.destroy is fine
	// while the compositor still shows it: the contents never change).
	for b in ([]^wl.Buffer{o.clear_buf, o.band_buf, o.corner_buf}) {if b != nil {wl.buffer_destroy(b)}}
	free(o)
}

@(private = "file")
out_info :: proc(o: ^Dim_Out) -> (origin: [2]i32, scale: i32, found: bool) {
	scale = 1
	conn := ""
	for po in plat.outputs {
		if po.output == o.output {
			scale = max(po.scale, 1)
			conn = po.conn
		}
	}
	if conn == "" {return}
	sync.guard(&sway.mu)
	for so in sway.outputs {
		if so.name == conn && so.active {return {so.x, so.y}, scale, true}
	}
	return
}

// Commits this output's dim at `level` if anything about it changed.
@(private = "file")
render_out :: proc(o: ^Dim_Out, level: f32) {
	origin, scale, known := out_info(o)
	rounded := plat.win.margin > 0
	hole := Dim_Rect{dim.card.x - origin.x, dim.card.y - origin.y, dim.card.w, dim.card.h}
	has_hole := known && dim.card.w > 0
	layout := dim_layout(o.w, o.h, hole, has_hole, rounded ? WIN_RADIUS : 0)
	// Clicks reach the window on its card and on the resize strip around it.
	input_hole: Dim_Rect
	if has_hole {
		g: i32 = rounded ? WIN_GRAB_OUT : 0
		input_hole = {hole.x - g, hole.y - g, hole.w + 2 * g, hole.h + 2 * g}
	}
	a8 := u32(clamp(level * dim_alpha(dim.strength, theme_light), 0, 1) * 255 + 0.5)
	same := o.drawn && a8 == o.a8 && input_hole == o.input_hole && o.root_size == {o.w, o.h}
	for p, i in o.parts {if p.shown != layout[i] {same = false}}
	if same {return}

	old_band, old_corner: ^wl.Buffer
	if o.band_buf == nil || a8 != o.a8 {
		old_band = o.band_buf
		// Premultiplied black: only alpha.
		o.band_buf = wl.wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(plat.single_pixel, 0, 0, 0, a8 * 0x01010101)
	}
	r := layout[4].w | layout[5].w | layout[6].w | layout[7].w // all corners are alike
	key := [3]i32{i32(a8), r, scale}
	if r > 0 && (o.corner_buf == nil || key != o.corner_key) {
		old_corner = o.corner_buf
		o.corner_buf = corner_buffer(r, scale, f32(a8) / 255)
		o.corner_key = key
	}
	for &p, i in o.parts {
		want := layout[i]
		buf := i < 4 ? o.band_buf : o.corner_buf
		if want.w == 0 {
			if p.shown.w == 0 {continue}
			wl.surface_attach(p.surf, nil, 0, 0)
			p.buf = nil
		} else {
			if want.x != p.shown.x || want.y != p.shown.y || p.shown.w == 0 {wl.subsurface_set_position(p.sub, want.x, want.y)}
			if want.w != p.shown.w || want.h != p.shown.h {wl.wp_viewport_set_destination(p.vp, want.w, want.h)}
			if buf != p.buf || p.shown.w == 0 {
				wl.surface_attach(p.surf, buf, 0, 0)
				wl.surface_damage_buffer(p.surf, 0, 0, max(i32), max(i32))
				p.buf = buf
			}
		}
		p.shown = want
		wl.surface_commit(p.surf)
	}
	if o.clear_buf == nil {
		o.clear_buf = wl.wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(plat.single_pixel, 0, 0, 0, 0)
		wl.surface_attach(o.root, o.clear_buf, 0, 0)
		wl.surface_damage_buffer(o.root, 0, 0, 1, 1)
	}
	if o.root_size != {o.w, o.h} {
		wl.wp_viewport_set_destination(o.vp, o.w, o.h)
		o.root_size = {o.w, o.h}
	}
	if input_hole != o.input_hole || !o.drawn {
		region := wl.compositor_create_region(plat.compositor)
		wl.region_add(region, 0, 0, o.w, o.h)
		if input_hole.w > 0 {wl.region_subtract(region, input_hole.x, input_hole.y, input_hole.w, input_hole.h)}
		wl.surface_set_input_region(o.root, region)
		wl.region_destroy(region)
		o.input_hole = input_hole
	}
	if o.frame_cb == nil {
		o.frame_cb = wl.surface_frame(o.root)
		wl.callback_add_listener(o.frame_cb, &frame_listener, o)
	}
	o.frame_at = time.tick_now()
	wl.surface_commit(o.root)
	o.a8, o.drawn = a8, true
	// Replaced: the compositor keeps what it shows.
	if old_band != nil {wl.buffer_destroy(old_band)}
	if old_corner != nil {wl.buffer_destroy(old_corner)}
}

// The dim around one rounded corner of the hole (top-left; the others are
// mirrored by their surfaces' buffer transforms): r×r logical, at `scale`.
@(private = "file")
corner_buffer :: proc(r, scale: i32, alpha: f32) -> ^wl.Buffer {
	n := int(r * scale)
	b, ok := bar_buffer_new(n, n, f32(scale))
	if !ok {return nil}
	c := f32(n) // the arc's centre: the piece's inner corner
	for y in 0 ..< n {
		for x in 0 ..< n {
			dx, dy := c - (f32(x) + 0.5), c - (f32(y) + 0.5)
			outside := clamp(math.sqrt(dx * dx + dy * dy) - c + 0.5, 0, 1)
			b.cv.px[y * n + x] = u32(alpha * outside * 255 + 0.5) << 24
		}
	}
	posix.munmap(b.mem, uint(b.size))
	pool := wl.shm_create_pool(plat.shm, i32(b.fd), i32(b.size))
	buf := wl.shm_pool_create_buffer(pool, 0, i32(n), i32(n), i32(n * 4), wl.SHM_FORMAT_ARGB8888)
	wl.shm_pool_destroy(pool)
	posix.close(posix.FD(b.fd))
	return buf
}
