// `wlperch bar`: a status bar that replaces waybar. Run it from sway with
//     bar { swaybar_command wlperch-bar }
// (sway then starts it, restarts it on reload and passes "-b bar-0", which
// we ignore; "wlperch setup" can switch a waybar setup over).
//
// It is its own process, not part of the daemon: the daemon re-execs itself
// to hand its GPU memory back, which would make a bar inside it vanish and
// reappear (and every window resize twice); and a crash on either side
// leaves the other running. Nothing here touches the GPU: one layer surface
// per output, software-rendered into shared memory like the notification
// popups, redrawn only when something it shows changes. Data the daemon owns
// (unread notifications) comes over its socket; the rest (sway, MPRIS,
// battery, tray…) the bar reads itself. Panels open from the daemon,
// under the clicked module.
package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

import "wl"

g_bar_ctx: runtime.Context

@(private = "file")
Bar_Hit :: struct {
	mod:      Bar_Mod,
	key:      string,
	x, w:     f32,
	hover:    bool,
	tooltip:  string,
	calendar: bool,
	mono:     bool,
}

@(private = "file")
Bar_Output :: struct {
	output:        ^wl.Output,
	name:          u32,
	conn:          string,
	scale:         i32,
	ready:         bool,
	surface:       ^wl.Surface,
	layer:         ^wl.Zwlr_Layer_Surface_V1,
	w, h:          i32,
	configured:    bool,
	dirty:         bool,
	frame_pending: bool,
	hits:          [dynamic]Bar_Hit,
	ptr_x:         f32, // -1: pointer elsewhere
	hover:         int, // index into hits, -1
}

@(private = "file")
Popup_Kind :: enum {Tooltip, Menu}

@(private = "file")
Menu_Row :: struct {
	y, h:  f32,
	node:  ^Menu_Node,
}

@(private = "file")
Bar_Popup :: struct {
	kind:       Popup_Kind,
	surface:    ^wl.Surface,
	xdg:        ^wl.Xdg_Surface,
	popup:      ^wl.Xdg_Popup,
	w, h:       i32,
	scale:      i32,
	configured: bool,
	dirty:      bool,
	// Tooltip.
	lines:      [dynamic]string,
	mono:       bool,
	calendar:   bool,
	// Menu.
	node:       ^Menu_Node,
	rows:       [dynamic]Menu_Row,
	hover:      int,
	child:      ^Bar_Popup,
	parent:     ^Bar_Popup,
	child_of:   int, // row whose submenu `child` is
}

@(private = "file")
Bar :: struct {
	display:       ^wl.Display,
	compositor:    ^wl.Compositor,
	shm:           ^wl.Shm,
	layer_shell:   ^wl.Zwlr_Layer_Shell_V1,
	wm_base:       ^wl.Xdg_Wm_Base,
	seat:          ^wl.Seat,
	pointer:       ^wl.Pointer,
	cursor_mgr:    ^wl.Wp_Cursor_Shape_Manager_V1,
	cursor_dev:    ^wl.Wp_Cursor_Shape_Device_V1,
	inhibit_mgr:   ^wl.Zwp_Idle_Inhibit_Manager_V1,
	inhibitor:     ^wl.Zwp_Idle_Inhibitor_V1,
	outputs:       [dynamic]^Bar_Output,

	ptr_surface:   ^wl.Surface,
	ptr_x, ptr_y:  f32,
	serial:        u32, // last input serial (popup grabs)
	scroll_acc:    [2]f32,

	tip:           ^Bar_Popup,
	tip_out:       ^Bar_Output,
	tip_hit:       int,
	tip_at:        time.Tick, // show the tooltip then (zero: none pending)

	menu:          ^Bar_Popup, // root of the open tray menu
	menu_tree:     Menu_Node,
	menu_item:     string, // tray item id
	menu_out:      ^Bar_Output,

	wake_r:        posix.FD,
	last_minute:   i64,
}
@(private = "file") bar: Bar

@(private = "file") TOOLTIP_DELAY :: 550 * time.Millisecond
@(private = "file") ROW_H :: f32(28)
@(private = "file") SEP_H :: f32(9)
@(private = "file") MENU_PAD :: f32(6)
@(private = "file") MENU_ICON :: f32(16)

// ---- Wayland ---------------------------------------------------------------------------

@(private = "file")
find_output :: proc(name: u32) -> (^Bar_Output, int) {
	for o, i in bar.outputs {if o.name == name {return o, i}}
	return nil, -1
}

@(private = "file")
output_for_surface :: proc(s: ^wl.Surface) -> ^Bar_Output {
	if s == nil {return nil}
	for o in bar.outputs {if o.surface == s {return o}}
	return nil
}

@(private = "file")
wanted :: proc(conn: string) -> bool {
	if len(bar_cfg.outputs) == 0 {return true}
	for o in bar_cfg.outputs {if o == conn {return true}}
	return false
}

@(private = "file")
registry_listener := wl.Registry_Listener {
	global = proc "c" (data: rawptr, registry: ^wl.Registry, name: u32, iface: cstring, version: u32) {
		context = g_bar_ctx
		switch iface {
		case "wl_compositor":
			bar.compositor = cast(^wl.Compositor)wl.registry_bind(registry, name, &wl.compositor_interface, min(version, 4))
		case "wl_shm":
			bar.shm = cast(^wl.Shm)wl.registry_bind(registry, name, &wl.shm_interface, 1)
		case "zwlr_layer_shell_v1":
			bar.layer_shell = cast(^wl.Zwlr_Layer_Shell_V1)wl.registry_bind(registry, name, &wl.zwlr_layer_shell_v1_interface, min(version, 4))
		case "xdg_wm_base":
			bar.wm_base = cast(^wl.Xdg_Wm_Base)wl.registry_bind(registry, name, &wl.xdg_wm_base_interface, 1)
			wl.xdg_wm_base_add_listener(bar.wm_base, &wm_base_listener, nil)
		case "wp_cursor_shape_manager_v1":
			bar.cursor_mgr = cast(^wl.Wp_Cursor_Shape_Manager_V1)wl.registry_bind(registry, name, &wl.wp_cursor_shape_manager_v1_interface, 1)
		case "zwp_idle_inhibit_manager_v1":
			bar.inhibit_mgr = cast(^wl.Zwp_Idle_Inhibit_Manager_V1)wl.registry_bind(registry, name, &wl.zwp_idle_inhibit_manager_v1_interface, 1)
		case "wl_seat":
			if bar.seat == nil {
				bar.seat = cast(^wl.Seat)wl.registry_bind(registry, name, &wl.seat_interface, min(version, 5))
				wl.seat_add_listener(bar.seat, &seat_listener, nil)
			}
		case "wl_output":
			o := new(Bar_Output)
			o.name = name
			o.scale = 1
			o.ptr_x = -1
			o.hover = -1
			o.output = cast(^wl.Output)wl.registry_bind(registry, name, &wl.output_interface, min(version, 4))
			wl.output_add_listener(o.output, &output_listener, o)
			append(&bar.outputs, o)
		}
	},
	global_remove = proc "c" (data: rawptr, registry: ^wl.Registry, name: u32) {
		context = g_bar_ctx
		o, i := find_output(name)
		if o == nil {return}
		close_popups_on(o)
		destroy_surface(o)
		if wl.output_get_version(o.output) >= 3 {wl.output_release(o.output)} else {wl.output_destroy(o.output)}
		delete(o.conn)
		free_hits(o)
		delete(o.hits)
		free(o)
		ordered_remove(&bar.outputs, i)
	},
}

@(private = "file")
wm_base_listener := wl.Xdg_Wm_Base_Listener {
	ping = proc "c" (data: rawptr, self: ^wl.Xdg_Wm_Base, serial: u32) {wl.xdg_wm_base_pong(self, serial)},
}

@(private = "file")
output_listener := wl.Output_Listener {
	geometry = proc "c" (data: rawptr, self: ^wl.Output, x, y, pw, ph, subpixel: i32, make, model: cstring, transform: i32) {},
	mode = proc "c" (data: rawptr, self: ^wl.Output, flags: u32, width, height, refresh: i32) {},
	done = proc "c" (data: rawptr, self: ^wl.Output) {
		context = g_bar_ctx
		o := (^Bar_Output)(data)
		o.ready = true
		if o.surface == nil && wanted(o.conn) {create_surface(o)}
		o.dirty = true
	},
	scale = proc "c" (data: rawptr, self: ^wl.Output, factor: i32) {
		o := (^Bar_Output)(data)
		o.scale = max(factor, 1)
	},
	name = proc "c" (data: rawptr, self: ^wl.Output, name: cstring) {
		context = g_bar_ctx
		o := (^Bar_Output)(data)
		delete(o.conn)
		o.conn = strings.clone(string(name))
	},
	description = proc "c" (data: rawptr, self: ^wl.Output, description: cstring) {},
}

@(private = "file")
layer_listener := wl.Zwlr_Layer_Surface_V1_Listener {
	configure = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1, serial, width, height: u32) {
		context = g_bar_ctx
		o := (^Bar_Output)(data)
		wl.zwlr_layer_surface_v1_ack_configure(self, serial)
		o.w, o.h = i32(width), i32(height)
		o.configured = true
		o.dirty = true
		o.frame_pending = false
	},
	closed = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1) {
		context = g_bar_ctx
		o := (^Bar_Output)(data)
		close_popups_on(o)
		destroy_surface(o)
	},
}

@(private = "file")
frame_listener := wl.Callback_Listener {
	done = proc "c" (data: rawptr, self: ^wl.Callback, t: u32) {
		o := (^Bar_Output)(data)
		o.frame_pending = false
		wl.callback_destroy(self)
	},
}

@(private = "file")
create_surface :: proc(o: ^Bar_Output) {
	if bar.layer_shell == nil || bar.compositor == nil {return}
	o.surface = wl.compositor_create_surface(bar.compositor)
	o.layer = wl.zwlr_layer_shell_v1_get_layer_surface(bar.layer_shell, o.surface, o.output, wl.ZWLR_LAYER_SHELL_V1_LAYER_TOP, "wlperch-bar")
	wl.zwlr_layer_surface_v1_add_listener(o.layer, &layer_listener, o)
	edge := u32(bar_cfg.bottom ? wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM : wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP)
	wl.zwlr_layer_surface_v1_set_anchor(o.layer, edge | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT)
	wl.zwlr_layer_surface_v1_set_size(o.layer, 0, u32(bar_cfg.height))
	wl.zwlr_layer_surface_v1_set_exclusive_zone(o.layer, bar_cfg.height)
	wl.surface_commit(o.surface)
	update_inhibitor()
}

@(private = "file")
destroy_surface :: proc(o: ^Bar_Output) {
	if o.surface == nil {return}
	if bar.inhibitor != nil && first_surface() == o.surface {
		wl.zwp_idle_inhibitor_v1_destroy(bar.inhibitor)
		bar.inhibitor = nil
	}
	if bar.ptr_surface == o.surface {bar.ptr_surface = nil}
	wl.zwlr_layer_surface_v1_destroy(o.layer)
	wl.surface_destroy(o.surface)
	o.surface, o.layer = nil, nil
	o.configured = false
	update_inhibitor()
}

@(private = "file")
first_surface :: proc() -> ^wl.Surface {
	for o in bar.outputs {if o.surface != nil {return o.surface}}
	return nil
}

// The idle inhibitor lives on a bar surface: sway honours it while that's visible.
@(private = "file")
update_inhibitor :: proc() {
	if bar.inhibit_mgr == nil {return}
	if idle_inhibit_on && bar.inhibitor == nil {
		if s := first_surface(); s != nil {bar.inhibitor = wl.zwp_idle_inhibit_manager_v1_create_inhibitor(bar.inhibit_mgr, s)}
	} else if !idle_inhibit_on && bar.inhibitor != nil {
		wl.zwp_idle_inhibitor_v1_destroy(bar.inhibitor)
		bar.inhibitor = nil
	}
}

@(private = "file")
seat_listener := wl.Seat_Listener {
	capabilities = proc "c" (data: rawptr, seat: ^wl.Seat, caps: u32) {
		context = g_bar_ctx
		if caps & wl.SEAT_CAPABILITY_POINTER != 0 && bar.pointer == nil {
			bar.pointer = wl.seat_get_pointer(seat)
			wl.pointer_add_listener(bar.pointer, &pointer_listener, nil)
			if bar.cursor_mgr != nil {bar.cursor_dev = wl.wp_cursor_shape_manager_v1_get_pointer(bar.cursor_mgr, bar.pointer)}
		} else if caps & wl.SEAT_CAPABILITY_POINTER == 0 && bar.pointer != nil {
			if bar.cursor_dev != nil {wl.wp_cursor_shape_device_v1_destroy(bar.cursor_dev)}
			wl.pointer_release(bar.pointer)
			bar.pointer, bar.cursor_dev = nil, nil
		}
	},
	name = proc "c" (data: rawptr, seat: ^wl.Seat, name: cstring) {},
}

@(private = "file")
pointer_listener := wl.Pointer_Listener {
	enter = proc "c" (data: rawptr, self: ^wl.Pointer, serial: u32, surface: ^wl.Surface, x, y: wl.Fixed) {
		context = g_bar_ctx
		bar.serial = serial
		bar.ptr_surface = surface
		if bar.cursor_dev != nil {wl.wp_cursor_shape_device_v1_set_shape(bar.cursor_dev, serial, wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT)}
		pointer_moved(f32(wl.fixed_to_f64(x)), f32(wl.fixed_to_f64(y)))
	},
	leave = proc "c" (data: rawptr, self: ^wl.Pointer, serial: u32, surface: ^wl.Surface) {
		context = g_bar_ctx
		if o := output_for_surface(surface); o != nil {
			o.ptr_x = -1
			set_hover(o, -1)
		}
		if p := find_popup(surface); p != nil && p.kind == .Menu && p.hover >= 0 && p.child == nil {
			p.hover = -1
			p.dirty = true
		}
		bar.ptr_surface = nil
	},
	motion = proc "c" (data: rawptr, self: ^wl.Pointer, t: u32, x, y: wl.Fixed) {
		context = g_bar_ctx
		pointer_moved(f32(wl.fixed_to_f64(x)), f32(wl.fixed_to_f64(y)))
	},
	button = proc "c" (data: rawptr, self: ^wl.Pointer, serial, t, button, state: u32) {
		context = g_bar_ctx
		bar.serial = serial
		pointer_button(button, state == wl.POINTER_BUTTON_STATE_PRESSED)
	},
	axis = proc "c" (data: rawptr, self: ^wl.Pointer, t: u32, axis: u32, value: wl.Fixed) {
		context = g_bar_ctx
		i := axis == wl.POINTER_AXIS_HORIZONTAL_SCROLL ? 1 : 0
		bar.scroll_acc[i] += f32(wl.fixed_to_f64(value))
		// A wheel click is 15; touchpads send many small steps.
		steps := int(bar.scroll_acc[i] / 15)
		if steps != 0 {
			bar.scroll_acc[i] -= f32(steps) * 15
			pointer_scroll(steps, i == 1)
		}
	},
	frame = proc "c" (data: rawptr, self: ^wl.Pointer) {},
	axis_source = proc "c" (data: rawptr, self: ^wl.Pointer, axis_source: u32) {},
	axis_stop = proc "c" (data: rawptr, self: ^wl.Pointer, t: u32, axis: u32) {
		context = g_bar_ctx
		bar.scroll_acc = {}
	},
	axis_discrete = proc "c" (data: rawptr, self: ^wl.Pointer, axis: u32, discrete: i32) {},
	axis_value120 = proc "c" (data: rawptr, self: ^wl.Pointer, axis: u32, value120: i32) {},
	axis_relative_direction = proc "c" (data: rawptr, self: ^wl.Pointer, axis: u32, direction: u32) {},
}

// ---- Pointer -----------------------------------------------------------------------------

@(private = "file")
hit_at :: proc(o: ^Bar_Output, x: f32) -> int {
	for h, i in o.hits {if x >= h.x && x < h.x + h.w {return i}}
	return -1
}

@(private = "file")
set_hover :: proc(o: ^Bar_Output, i: int) {
	if o.hover == i {return}
	old := o.hover
	o.hover = i
	if (old >= 0 && old < len(o.hits) && o.hits[old].hover) || (i >= 0 && o.hits[i].hover) {o.dirty = true}
	// The tooltip follows the pointer: hide it, start counting for the new item.
	close_tooltip()
	if i >= 0 && (o.hits[i].tooltip != "" || o.hits[i].calendar) {
		bar.tip_out = o
		bar.tip_hit = i
		bar.tip_at = time.tick_add(time.tick_now(), TOOLTIP_DELAY)
	} else {
		bar.tip_at = {}
	}
}

@(private = "file")
pointer_moved :: proc(x, y: f32) {
	bar.ptr_x, bar.ptr_y = x, y
	if o := output_for_surface(bar.ptr_surface); o != nil {
		o.ptr_x = x
		set_hover(o, hit_at(o, x))
		return
	}
	if p := find_popup(bar.ptr_surface); p != nil && p.kind == .Menu {
		row := -1
		for r, i in p.rows {
			if y >= r.y && y < r.y + r.h && !r.node.separator && r.node.enabled {row = i}
		}
		if row != p.hover {
			p.hover = row
			p.dirty = true
			// Submenus open on hover; another row closes the open one.
			if p.child != nil && p.child_of != row {close_popup(p.child)}
			if row >= 0 && len(p.rows[row].node.children) > 0 && p.child == nil {open_submenu(p, row)}
		}
	}
}

@(private = "file")
pointer_button :: proc(button: u32, pressed: bool) {
	if p := find_popup(bar.ptr_surface); p != nil && p.kind == .Menu {
		if pressed || p.hover < 0 {return}
		n := p.rows[p.hover].node
		if len(n.children) > 0 {
			if p.child == nil {open_submenu(p, p.hover)}
			return
		}
		if it, _ := tray_find(bar.menu_item); it != nil {tray_menu_event(it, n.id)}
		close_menu()
		return
	}
	o := output_for_surface(bar.ptr_surface)
	if o == nil || !pressed {return}
	close_tooltip()
	bar.tip_at = {}
	i := hit_at(o, bar.ptr_x)
	if i < 0 {return}
	h := o.hits[i]
	it := Bar_Item{mod = h.mod, key = h.key}
	ck := Bar_Click{output = o.conn, center = h.x + h.w / 2, width = f32(o.w), button = button, serial = bar.serial}
	bar.menu_out = o
	bar_click(&it, ck, proc(t: ^Tray_Item, ck: Bar_Click) {open_menu(t)})
	if h.mod == .Idle {
		update_inhibitor()
		mark_all_dirty()
	} else if h.mod == .Battery {
		mark_all_dirty()
	}
}

@(private = "file")
pointer_scroll :: proc(steps: int, horizontal: bool) {
	o := output_for_surface(bar.ptr_surface)
	if o == nil {return}
	i := hit_at(o, bar.ptr_x)
	if i < 0 {return}
	it := Bar_Item{mod = o.hits[i].mod, key = o.hits[i].key}
	bar_scroll(&it, steps, horizontal, o.conn)
}

@(private = "file")
mark_all_dirty :: proc() {
	for o in bar.outputs {o.dirty = true}
}

// ---- Layout and drawing ------------------------------------------------------------------------

@(private = "file")
item_width :: proc(it: ^Bar_Item) -> f32 {
	w: f32
	for s in it.segs {w += bar_text_width(s.font, s.px, s.text)}
	if it.icon != nil || it.icon_size > 0 {w += it.icon_size}
	return max(w, it.min_w) + 2 * it.pad
}

@(private = "file")
layout :: proc(lay: ^Bar_Layout, W, H: f32) {
	for &it in lay.items {it.w = item_width(&it)}
	span :: proc(lay: ^Bar_Layout, from, to: int) -> f32 {
		t: f32
		for i in from ..< to {t += lay.items[i].w + 2 * lay.items[i].margin + lay.items[i].space[0] + lay.items[i].space[1]}
		return t
	}
	place :: proc(lay: ^Bar_Layout, from, to: int, x0: f32) {
		x := x0
		for i in from ..< to {
			it := &lay.items[i]
			x += it.space[0] + it.margin
			it.x = x
			x += it.w + it.margin + it.space[1]
		}
	}
	e := lay.side_end
	left_w := span(lay, 0, e[0])
	right_w := span(lay, e[1], e[2])
	center_w := span(lay, e[0], e[1])
	// Narrow output: the window title gives way.
	room := W - 20 - right_w - 14
	if left_w + 10 > room {
		for i in 0 ..< e[0] {
			it := &lay.items[i]
			if it.mod != .Window || len(it.segs) == 0 {continue}
			want := it.w - (left_w + 10 - room)
			s := &it.segs[0]
			orig := s.text
			n := 0
			for _ in orig {n += 1}
			for n > 0 && item_width(it) > want {
				n -= 1
				s.text = clip_runes_bar(orig, n)
			}
			it.w = item_width(it)
			left_w = span(lay, 0, e[0])
		}
	}
	place(lay, 0, e[0], 4)
	place(lay, e[0], e[1], (W - center_w) / 2)
	place(lay, e[1], e[2], W - 4 - right_w)
	lay.blocks = {}
	if e[0] > 0 {lay.blocks[0] = {0, 0, left_w + 4 + 6, H}}
	if e[1] > e[0] {lay.blocks[1] = {(W - center_w) / 2 - 8, 0, center_w + 16, H}}
	if e[2] > e[1] {lay.blocks[2] = {W - 4 - right_w - 10, 0, right_w + 14, H}}
}

@(private = "file")
draw_bar :: proc(o: ^Bar_Output, cv: ^Bar_Canvas, lay: ^Bar_Layout) {
	p := &bar_pal
	W, H := f32(o.w), f32(o.h)
	R :: f32(14)
	bottom := bar_cfg.bottom
	// Blocks: rounded on the corner(s) facing the screen.
	for b, i in lay.blocks {
		if b.w <= 0 {continue}
		radii: [4]f32
		switch i {
		case 0: radii = bottom ? {0, R, 0, 0} : {0, 0, R, 0}
		case 1: radii = bottom ? {R, R, 0, 0} : {0, 0, R, R}
		case 2: radii = bottom ? {R, 0, 0, 0} : {0, 0, 0, R}
		}
		bar_fill(cv, b, radii, p.block, p.block_alpha)
		// Edge lines only towards the screen's inside: stretch the outline past its edges.
		e := b
		if bottom {e.h += 2} else {e.y -= 2; e.h += 2}
		if i == 0 {e.x -= 2; e.w += 2}
		if i == 2 {e.w += 2}
		bar_stroke(cv, e, radii, p.edge, p.edge_alpha)
	}
	// Project pills behind their workspaces.
	for g in lay.groups {
		a, z := lay.items[g.first], lay.items[g.last]
		r := Bar_Rect{a.x - 3, 4, z.x + z.w - a.x + 6, H - 8}
		fills := [3]f32{0.10, 0.16, 0.22}
		edges := [3]f32{0.35, 0.6, 0.95}
		bar_fill_round(cv, r, 9, g.color, fills[g.level])
		bar_stroke(cv, r, {9, 9, 9, 9}, g.color, edges[g.level])
	}
	hovered := -1
	if o.ptr_x >= 0 {
		for it, i in lay.items {if o.ptr_x >= it.x && o.ptr_x < it.x + it.w {hovered = i}}
	}
	for &it, i in lay.items {
		r := Bar_Rect{it.x, it.inset, it.w, H - 2 * it.inset}
		rad := min(8, r.h / 2)
		if it.bg_alpha > 0 {bar_fill_round(cv, r, rad, it.bg, it.bg_alpha)}
		if i == hovered && it.hover {bar_fill_round(cv, r, rad, p.hover, it.bg_alpha > 0.5 ? 0.12 : p.hover_alpha)}
		if it.line_alpha > 0 {bar_fill_round(cv, {r.x + 3, r.y + r.h - 2, r.w - 6, 2}, 1, it.line, it.line_alpha)}
		x := it.x + it.pad
		// Centre the content when the item is wider (min width).
		content := item_width(&it) - 2 * it.pad
		if it.min_w > 0 {
			raw: f32
			for s in it.segs {raw += bar_text_width(s.font, s.px, s.text)}
			x += (content - raw) / 2
		}
		if it.icon != nil {
			bar_icon(cv, it.icon, x, (H - it.icon_size) / 2, it.icon_size, it.icon_alpha)
			x += it.icon_size
		}
		for s in it.segs {
			baseline := H / 2 + 0.31 * s.px
			bar_text(cv, s.font, s.px, x, baseline, s.text, s.color, s.alpha)
			x += bar_text_width(s.font, s.px, s.text)
		}
	}
	_ = W
}

@(private = "file")
free_hits :: proc(o: ^Bar_Output) {
	for h in o.hits {
		delete(h.key)
		delete(h.tooltip)
	}
	clear(&o.hits)
}

@(private = "file")
render :: proc(o: ^Bar_Output) {
	if !o.configured || o.w <= 0 || o.h <= 0 || bar.shm == nil {return}
	lay: Bar_Layout
	bar_build(o.conn, &lay)
	layout(&lay, f32(o.w), f32(o.h))
	s := max(o.scale, 1)
	b, ok := bar_buffer_new(int(o.w * s), int(o.h * s), f32(s))
	if !ok {return}
	draw_bar(o, &b.cv, &lay)
	bar_buffer_attach(&b, bar.shm, o.surface, s)
	cb := wl.surface_frame(o.surface)
	wl.callback_add_listener(cb, &frame_listener, o)
	o.frame_pending = true
	wl.surface_commit(o.surface)
	o.dirty = false

	// What the pointer can hit until the next render.
	old_key := ""
	old_mod: Bar_Mod
	if o.hover >= 0 && o.hover < len(o.hits) {
		old_key = strings.clone(o.hits[o.hover].key, context.temp_allocator)
		old_mod = o.hits[o.hover].mod
	}
	free_hits(o)
	for it in lay.items {
		append(&o.hits, Bar_Hit{
			mod = it.mod, key = strings.clone(it.key), x = it.x, w = it.w, hover = it.hover,
			tooltip = strings.clone(it.tooltip), calendar = it.calendar, mono = it.tip_mono,
		})
	}
	for h in o.hits {log.debugf("hit %s %v %q %.0f %.0f", o.conn, h.mod, h.key, h.x, h.w)}
	o.hover = o.ptr_x >= 0 ? hit_at(o, o.ptr_x) : -1
	// An open tooltip whose item changed (or moved away) goes; same item: keep it.
	if bar.tip_out == o && (o.hover < 0 || o.hits[o.hover].mod != old_mod || o.hits[o.hover].key != old_key) {
		close_tooltip()
		bar.tip_at = {}
	}
	if bar.tip_out == o {bar.tip_hit = o.hover}
}

// ---- Popups (tooltips, menus) --------------------------------------------------------------------

@(private = "file") popups: [dynamic]^Bar_Popup

@(private = "file")
find_popup :: proc(s: ^wl.Surface) -> ^Bar_Popup {
	if s == nil {return nil}
	for p in popups {if p.surface == s {return p}}
	return nil
}

@(private = "file")
xdg_surface_listener := wl.Xdg_Surface_Listener {
	configure = proc "c" (data: rawptr, self: ^wl.Xdg_Surface, serial: u32) {
		context = g_bar_ctx
		p := (^Bar_Popup)(data)
		wl.xdg_surface_ack_configure(self, serial)
		p.configured = true
		p.dirty = true
	},
}

@(private = "file")
popup_listener := wl.Xdg_Popup_Listener {
	configure = proc "c" (data: rawptr, self: ^wl.Xdg_Popup, x, y, width, height: i32) {},
	popup_done = proc "c" (data: rawptr, self: ^wl.Xdg_Popup) {
		context = g_bar_ctx
		p := (^Bar_Popup)(data)
		if p.kind == .Menu {close_menu()} else {close_tooltip()}
	},
	repositioned = proc "c" (data: rawptr, self: ^wl.Xdg_Popup, token: u32) {},
}

// A popup next to `anchor` (surface coordinates of the parent).
@(private = "file")
popup_new :: proc(kind: Popup_Kind, w, h: i32, anchor: Bar_Rect, parent_layer: ^wl.Zwlr_Layer_Surface_V1, parent: ^Bar_Popup, scale: i32) -> ^Bar_Popup {
	if bar.wm_base == nil {return nil}
	p := new(Bar_Popup)
	p.kind = kind
	p.w, p.h = w, h
	p.scale = scale
	p.hover = -1
	p.child_of = -1
	p.parent = parent
	p.surface = wl.compositor_create_surface(bar.compositor)
	p.xdg = wl.xdg_wm_base_get_xdg_surface(bar.wm_base, p.surface)
	wl.xdg_surface_add_listener(p.xdg, &xdg_surface_listener, p)
	pos := wl.xdg_wm_base_create_positioner(bar.wm_base)
	wl.xdg_positioner_set_size(pos, w, h)
	wl.xdg_positioner_set_anchor_rect(pos, i32(anchor.x), i32(anchor.y), max(i32(anchor.w), 1), max(i32(anchor.h), 1))
	if parent != nil {
		wl.xdg_positioner_set_anchor(pos, wl.XDG_POSITIONER_ANCHOR_TOP_RIGHT)
		wl.xdg_positioner_set_gravity(pos, wl.XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT)
		wl.xdg_positioner_set_offset(pos, -4, -i32(MENU_PAD))
		wl.xdg_positioner_set_constraint_adjustment(pos, wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X | wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y)
	} else {
		wl.xdg_positioner_set_anchor(pos, bar_cfg.bottom ? wl.XDG_POSITIONER_ANCHOR_TOP : wl.XDG_POSITIONER_ANCHOR_BOTTOM)
		wl.xdg_positioner_set_gravity(pos, bar_cfg.bottom ? wl.XDG_POSITIONER_GRAVITY_TOP : wl.XDG_POSITIONER_GRAVITY_BOTTOM)
		wl.xdg_positioner_set_offset(pos, 0, bar_cfg.bottom ? -4 : 4)
		wl.xdg_positioner_set_constraint_adjustment(pos, wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X | wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y)
	}
	p.popup = wl.xdg_surface_get_popup(p.xdg, parent != nil ? parent.xdg : nil, pos)
	wl.xdg_positioner_destroy(pos)
	wl.xdg_popup_add_listener(p.popup, &popup_listener, p)
	if parent == nil {wl.zwlr_layer_surface_v1_get_popup(parent_layer, p.popup)}
	if kind == .Menu {
		wl.xdg_popup_grab(p.popup, bar.seat, bar.serial)
	} else {
		// Tooltips let the pointer through.
		region := wl.compositor_create_region(bar.compositor)
		wl.surface_set_input_region(p.surface, region)
		wl.region_destroy(region)
	}
	wl.surface_commit(p.surface)
	append(&popups, p)
	return p
}

@(private = "file")
close_popup :: proc(p: ^Bar_Popup) {
	if p == nil {return}
	if p.child != nil {close_popup(p.child)}
	if p.parent != nil && p.parent.child == p {
		p.parent.child = nil
		p.parent.child_of = -1
		p.parent.dirty = true
	}
	if bar.ptr_surface == p.surface {bar.ptr_surface = nil}
	wl.xdg_popup_destroy(p.popup)
	wl.xdg_surface_destroy(p.xdg)
	wl.surface_destroy(p.surface)
	for l in p.lines {delete(l)}
	delete(p.lines)
	delete(p.rows)
	for q, i in popups {
		if q == p {
			ordered_remove(&popups, i)
			break
		}
	}
	free(p)
}

@(private = "file")
close_tooltip :: proc() {
	if bar.tip != nil {
		close_popup(bar.tip)
		bar.tip = nil
	}
}

@(private = "file")
close_menu :: proc() {
	if bar.menu != nil {
		close_popup(bar.menu)
		bar.menu = nil
		menu_free(&bar.menu_tree)
		bar.menu_tree = {}
		delete(bar.menu_item)
		bar.menu_item = ""
	}
}

@(private = "file")
close_popups_on :: proc(o: ^Bar_Output) {
	if bar.tip_out == o {
		close_tooltip()
		bar.tip_out = nil
		bar.tip_at = {}
	}
	if bar.menu_out == o {
		close_menu()
		bar.menu_out = nil
	}
}

@(private = "file") TIP_PX :: f32(13)
@(private = "file") TIP_PAD_X :: f32(11)
@(private = "file") TIP_PAD_Y :: f32(8)
@(private = "file") TIP_LINE :: f32(19)

@(private = "file")
show_tooltip :: proc() {
	bar.tip_at = {}
	o := bar.tip_out
	if o == nil || o.surface == nil || bar.tip_hit < 0 || bar.tip_hit >= len(o.hits) || bar.menu != nil {return}
	h := o.hits[bar.tip_hit]
	lines: [dynamic]string
	mono := false
	calendar := false
	if h.calendar {
		cal, _, _ := bar_calendar(bar_now())
		for l in cal {append(&lines, strings.clone(l))}
		mono, calendar = true, true
	} else {
		for l in strings.split_lines(h.tooltip, context.temp_allocator) {append(&lines, strings.clone(l))}
	}
	if len(lines) == 0 {return}
	font := mono ? Bar_Font.Mono : Bar_Font.Regular
	w: f32
	for l, i in lines {w = max(w, bar_text_width(calendar && i == 0 ? .Bold : font, TIP_PX, l))}
	tw := i32(math.ceil(w + 2 * TIP_PAD_X))
	th := i32(math.ceil(f32(len(lines)) * TIP_LINE + 2 * TIP_PAD_Y))
	p := popup_new(.Tooltip, tw, th, {h.x, 0, h.w, f32(o.h)}, o.layer, nil, o.scale)
	if p == nil {
		for l in lines {delete(l)}
		delete(lines)
		return
	}
	p.lines, p.mono, p.calendar = lines, mono, calendar
	bar.tip = p
}

@(private = "file")
draw_popup_card :: proc(cv: ^Bar_Canvas, w, h: f32) {
	r := Bar_Rect{0, 0, w, h}
	bar_fill_round(cv, r, 9, bar_pal.popup, 0.98)
	bar_stroke(cv, r, {9, 9, 9, 9}, bar_pal.popup_edge, 1)
}

@(private = "file")
render_popup :: proc(p: ^Bar_Popup) {
	s := max(p.scale, 1)
	b, ok := bar_buffer_new(int(p.w * s), int(p.h * s), f32(s))
	if !ok {return}
	cv := &b.cv
	draw_popup_card(cv, f32(p.w), f32(p.h))
	pal := &bar_pal
	switch p.kind {
	case .Tooltip:
		tl, tc := -1, -1
		if p.calendar {_, tl, tc = bar_calendar(bar_now())}
		for l, i in p.lines {
			y := TIP_PAD_Y + f32(i) * TIP_LINE
			baseline := y + TIP_LINE / 2 + 0.31 * TIP_PX
			font := p.mono ? Bar_Font.Mono : Bar_Font.Regular
			col := pal.text
			if p.calendar {
				switch {
				case i == 0:
					font = .Bold
				case i == 1:
					col = pal.muted
				}
				if i == tl {
					cw := bar_text_width(.Mono, TIP_PX, "00 ")
					dw := bar_text_width(.Mono, TIP_PX, "00")
					x := TIP_PAD_X + f32(tc) * cw
					bar_fill_round(cv, {x - 3, y + 1, dw + 6, TIP_LINE - 2}, 5, pal.accent, 1)
				}
			}
			bar_text(cv, font, TIP_PX, TIP_PAD_X, baseline, l, col)
			if p.calendar && i == tl {
				// Today's number again, dark on the highlight.
				cw := bar_text_width(.Mono, TIP_PX, "00 ")
				day := l[tc * 3:min(tc * 3 + 2, len(l))]
				bar_text(cv, .Mono, TIP_PX, TIP_PAD_X + f32(tc) * cw, baseline, day, pal.on_accent)
			}
		}
	case .Menu:
		icon_x, label_x := menu_cols(p.node)
		for r, i in p.rows {
			n := r.node
			if n.separator {
				bar_fill(cv, {8, r.y + r.h / 2, f32(p.w) - 16, 1}, {}, pal.edge, 0.12)
				continue
			}
			if i == p.hover || i == p.child_of {bar_fill_round(cv, {4, r.y, f32(p.w) - 8, r.h}, 6, pal.popup_hi, 1)}
			col := n.enabled ? pal.text : pal.faint
			baseline := r.y + r.h / 2 + 0.31 * 13.5
			switch n.toggle {
			case "checkmark":
				if n.toggle_state == 1 {bar_text(cv, .Regular, 13.5, 12, baseline, "\U000F012C", pal.accent)}
			case "radio":
				bar_text(cv, .Regular, 13.5, 12, baseline, n.toggle_state == 1 ? "\U000F043E" : "\U000F043D", n.toggle_state == 1 ? pal.accent : pal.muted)
			}
			if n.img != nil {bar_icon(cv, n.img, icon_x, r.y + (r.h - MENU_ICON) / 2, MENU_ICON, n.enabled ? 1 : 0.4)}
			bar_text(cv, .Regular, 13.5, label_x, baseline, n.label, col)
			if len(n.children) > 0 {
				bar_text(cv, .Regular, 13.5, f32(p.w) - 22, baseline, "\U000F0142", pal.muted)
			}
		}
	}
	bar_buffer_attach(&b, bar.shm, p.surface, s)
	wl.surface_commit(p.surface)
	p.dirty = false
}

// ---- Tray menus -----------------------------------------------------------------------------------

// Columns: check/radio marks, then icons, each only when some visible entry
// of this (sub)menu has one; the label starts at 34 at the least.
@(private = "file")
menu_cols :: proc(n: ^Menu_Node) -> (icon_x, label_x: f32) {
	toggles, icons: bool
	for &ch in n.children {
		if !ch.visible || ch.separator {continue}
		toggles |= ch.toggle == "checkmark" || ch.toggle == "radio"
		icons |= ch.img != nil
	}
	x := f32(12)
	if toggles {x += 22}
	icon_x = x
	if icons {x += MENU_ICON + 6}
	return icon_x, max(x, 34)
}

@(private = "file")
menu_size :: proc(n: ^Menu_Node) -> (w, h: f32, rows: [dynamic]Menu_Row) {
	y := MENU_PAD
	for &ch in n.children {
		if !ch.visible {continue}
		rh := ch.separator ? SEP_H : ROW_H
		append(&rows, Menu_Row{y = y, h = rh, node = &ch})
		y += rh
		if !ch.separator {w = max(w, bar_text_width(.Regular, 13.5, ch.label))}
	}
	_, label_x := menu_cols(n)
	return max(w + label_x + 36, 170), y + MENU_PAD, rows
}

@(private = "file")
open_menu :: proc(t: ^Tray_Item) {
	close_tooltip()
	close_menu()
	o := bar.menu_out
	if o == nil || o.surface == nil {return}
	root, ok := tray_menu_layout(t)
	if !ok || len(root.children) == 0 {
		menu_free(&root)
		return
	}
	bar.menu_tree = root
	bar.menu_item = strings.clone(t.id)
	w, h, rows := menu_size(&bar.menu_tree)
	anchor := Bar_Rect{0, 0, 1, f32(o.h)}
	for hh in o.hits {if hh.mod == .Tray && hh.key == t.id {anchor = {hh.x, 0, hh.w, f32(o.h)}}}
	p := popup_new(.Menu, i32(w), i32(h), anchor, o.layer, nil, o.scale)
	if p == nil {
		delete(rows)
		close_menu()
		return
	}
	p.node = &bar.menu_tree
	p.rows = rows
	bar.menu = p
}

@(private = "file")
open_submenu :: proc(p: ^Bar_Popup, row: int) {
	n := p.rows[row].node
	w, h, rows := menu_size(n)
	r := p.rows[row]
	c := popup_new(.Menu, i32(w), i32(h), {0, r.y, f32(p.w), r.h}, nil, p, p.scale)
	if c == nil {
		delete(rows)
		return
	}
	c.node = n
	c.rows = rows
	p.child = c
	p.child_of = row
	p.dirty = true
}

// ---- Main ---------------------------------------------------------------------------------------------

@(private = "file")
bar_lock :: proc() -> bool {
	dir := posix_getenv("XDG_RUNTIME_DIR")
	if dir == "" {dir = "/tmp"}
	path := fmt.ctprintf("%s/wlperch-bar-%s.lock", dir, posix_getenv("WAYLAND_DISPLAY"))
	fd := posix.open(path, {.CREAT, .RDWR, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd < 0 {return true}
	// sway's reload starts the new bar while the old one may still be exiting.
	// A bar that doesn't go away (started by hand or by setup, which sway
	// doesn't stop) is asked to quit: the newest bar wins.
	for i in 0 ..< 60 {
		if linux.flock(linux.Fd(fd), {.EX, .NB}) == .NONE {
			posix.ftruncate(fd, 0)
			pid := fmt.tprintf("%d", posix.getpid())
			posix.pwrite(fd, raw_data(pid), len(pid), 0)
			return true
		}
		if i == 10 || i == 40 {
			buf: [16]u8
			n := posix.pread(fd, &buf[0], len(buf), 0)
			old, ok := strconv.parse_int(strings.trim_space(string(buf[:max(n, 0)])))
			// Only a bar: the pid may be stale and reused by something else.
			comm, _ := os.read_entire_file(fmt.tprintf("/proc/%d/comm", old), context.temp_allocator)
			if ok && old > 1 && old != int(posix.getpid()) && strings.trim_space(string(comm)) == "wlperch-bar" {
				fmt.eprintfln("wlperch bar: asking the previous bar (pid %d) to quit", old)
				posix.kill(posix.pid_t(old), i == 10 ? .SIGTERM : .SIGKILL)
			}
		}
		time.sleep(100 * time.Millisecond)
	}
	posix.close(fd)
	return false
}

// Started by sway (-b <bar id>), stderr is sway's: a tty nobody looks at, or
// nothing. Keep it in a log file instead.
@(private = "file")
bar_log_to_file :: proc(args: []string) {
	from_sway := false
	for a in args {if a == "-b" {from_sway = true}}
	if !from_sway && posix.isatty(2) {return}
	dir := posix_getenv("XDG_RUNTIME_DIR")
	if dir == "" {dir = "/tmp"}
	path := fmt.ctprintf("%s/wlperch-bar-%s.log", dir, posix_getenv("WAYLAND_DISPLAY"))
	fd := posix.open(path, {.CREAT, .WRONLY, .TRUNC, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd < 0 {return}
	posix.dup2(fd, 2)
	posix.close(fd)
}

bar_main :: proc(args: []string) -> int {
	g_bar_ctx = context
	bar_log_to_file(args)
	if !bar_lock() {
		fmt.eprintln("wlperch bar: already running on this display")
		return 1
	}
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	// "wlperch-bar" in ps / pkill (setup stops it by that name).
	name := cstring("wlperch-bar")
	linux.prctl(15, uint(uintptr(rawptr(name))), 0, 0, 0) // PR_SET_NAME
	clocks_init()
	sensors_read_only = true
	soft_fonts_init()
	theme_watch_start()

	fds: [2]posix.FD
	posix.pipe(&fds)
	bar.wake_r, bar_wake_w = fds[0], fds[1]
	set_cloexec_nonblock(bar.wake_r)
	set_cloexec_nonblock(bar_wake_w)

	bar.display = wl.display_connect(nil)
	if bar.display == nil {
		fmt.eprintln("wlperch bar: cannot connect to the Wayland display")
		return 1
	}
	registry := wl.display_get_registry(bar.display)
	wl.registry_add_listener(registry, &registry_listener, nil)
	wl.display_roundtrip(bar.display)
	if bar.compositor == nil || bar.layer_shell == nil || bar.shm == nil {
		fmt.eprintln("wlperch bar: the compositor lacks wl_shm or zwlr_layer_shell_v1")
		return 1
	}
	wl.display_roundtrip(bar.display) // output names, scales, done -> surfaces

	bar_sway_start()
	tray.on_media = bar_data_poke
	open_tray_menu_cb = proc(t: ^Tray_Item) {open_menu(t)}
	tray_start()
	bar_data_start()

	for {
		if !bar_iteration() {break}
	}
	return 0
}

// ---- Dark / light ----------------------------------------------------------------------------
// "wlperch theme" (the daemon, or the CLI without one) saves the mode in the
// data dir; watching that dir follows every switch without a signal path.

@(private = "file") theme_fd: linux.Fd = -1

@(private = "file")
theme_watch_start :: proc() {
	bar_set_theme(theme_mode_load() == .Light)
	theme_fd = theme_watch_open()
}

@(private = "file")
theme_watch_read :: proc() {
	if !theme_watch_changed(theme_fd) {return}
	light := theme_mode_load() == .Light
	if light == theme_light {return}
	bar_set_theme(light)
	icons_retint()
	mark_all_dirty()
	for p in popups {p.dirty = true}
}

@(private = "file") pulse_at: time.Tick

// Until the clock text changes.
@(private = "file")
clock_timeout :: proc() -> time.Duration {
	now := time.now()
	ns := time.to_unix_nanoseconds(now)
	period := bar_clock_has_seconds() ? i64(time.Second) : i64(time.Minute)
	return time.Duration(period - ns % period) + time.Millisecond
}

@(private = "file")
bar_iteration :: proc() -> bool {
	d := bar.display
	// Draw what changed.
	if bsway.changed || tray.changed {
		bsway.changed, tray.changed = false, false
		mark_all_dirty()
	}
	minute := time.to_unix_seconds(time.now()) / (bar_clock_has_seconds() ? 1 : 60)
	if minute != bar.last_minute {
		bar.last_minute = minute
		mark_all_dirty()
	}
	// The memory module pulses while it's orange: a few frames a second, only then.
	if bar_mem_pulse_timeout(pulse_at) == 0 {
		pulse_at = time.tick_now()
		mark_all_dirty()
	}
	for o in bar.outputs {
		if o.dirty && o.configured && !o.frame_pending {render(o)}
	}
	for p in popups {
		if p.dirty && p.configured {render_popup(p)}
	}

	for wl.display_prepare_read(d) != 0 {wl.display_dispatch_pending(d)}
	wl.display_flush(d)

	timeout := clock_timeout()
	pick :: proc(t: ^time.Duration, d: time.Duration) {
		if d >= 0 && d < t^ {t^ = d}
	}
	if bar.tip_at != {} {pick(&timeout, max(time.tick_diff(time.tick_now(), bar.tip_at), 0))}
	pick(&timeout, bar_sway_timeout())
	pick(&timeout, tray_timeout())
	pick(&timeout, bar_mem_pulse_timeout(pulse_at))

	sway_fd := bar_sway_fd()
	bus_fd, bus_ev := tray_fd()
	pfds := [5]posix.pollfd {
		{fd = posix.FD(wl.display_get_fd(d)), events = {.IN}},
		{fd = bar.wake_r, events = {.IN}},
		{fd = sway_fd, events = {.IN}},
		{fd = bus_fd, events = bus_ev},
		{fd = posix.FD(theme_fd), events = {.IN}},
	}
	n := posix.poll(&pfds[0], len(pfds), i32(time.duration_milliseconds(timeout)) + 1)
	if n < 0 {
		wl.display_cancel_read(d)
		return posix.errno() == .EINTR
	}
	if .IN in pfds[0].revents {wl.display_read_events(d)} else {wl.display_cancel_read(d)}
	if .HUP in pfds[0].revents || .ERR in pfds[0].revents {
		log.error("wlperch bar: lost the Wayland connection")
		return false
	}
	if wl.display_dispatch_pending(d) < 0 {return false}
	if .IN in pfds[1].revents {
		buf: [64]u8
		for posix.read(bar.wake_r, &buf[0], len(buf)) > 0 {}
		mark_all_dirty()
	}
	if sway_fd >= 0 && pfds[2].revents != {} {bar_sway_read()}
	if theme_fd >= 0 && .IN in pfds[4].revents {theme_watch_read()}
	bar_sway_tick()
	tray_process()
	if bar.tip_at != {} && time.tick_diff(time.tick_now(), bar.tip_at) <= 0 {show_tooltip()}
	free_all(context.temp_allocator)
	return true
}
