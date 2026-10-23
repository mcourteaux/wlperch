// Wayland platform layer: connection, globals, seat input, the layer-shell
// popup surface and its EGL/OpenGL context. Input is forwarded to Dear ImGui.
package main

import "base:runtime"
import "core:c"
import "core:log"
import "core:strings"
import "core:sys/posix"
import "core:time"

import im "third_party:odin-imgui"
import egl "vendor:egl"
import gl "vendor:OpenGL"

import "wl"
import "xkb"

Output_Info :: struct {
	output: ^wl.Output,
	name:   u32,
	scale:  i32,
	conn:   string, // connector name, e.g. "DP-1" (wl_output v4)
}

Platform :: struct {
	display:          ^wl.Display,
	registry:         ^wl.Registry,
	compositor:       ^wl.Compositor,
	layer_shell:      ^wl.Zwlr_Layer_Shell_V1,
	cursor_shape_mgr: ^wl.Wp_Cursor_Shape_Manager_V1,
	viewporter:       ^wl.Wp_Viewporter,
	single_pixel:     ^wl.Wp_Single_Pixel_Buffer_Manager_V1,
	seat:             ^wl.Seat,
	pointer:          ^wl.Pointer,
	keyboard:         ^wl.Keyboard,
	cursor_device:    ^wl.Wp_Cursor_Shape_Device_V1,
	outputs:          [dynamic]Output_Info,
	compositor_ver:   u32,

	// Popup surface (only exists while shown)
	surface:          ^wl.Surface,
	layer_surface:    ^wl.Zwlr_Layer_Surface_V1,
	egl_window:       ^wl.Egl_Window,
	egl_surface:      egl.Surface,
	configured:       bool,
	width, height:    i32, // logical size of the surface
	want_height:      i32,
	scale:            i32,
	preferred_scale:  bool, // compositor sends preferred_buffer_scale
	frame_cb:         ^wl.Callback,
	frame_pending:    bool,
	input_rect:       [4]i32,

	// Transparent full-output surface below the popup: clicking it closes the popup.
	catcher:          ^wl.Surface,
	catcher_layer:    ^wl.Zwlr_Layer_Surface_V1,
	catcher_viewport: ^wl.Wp_Viewport,
	catcher_buffer:   ^wl.Buffer,
	pointer_surface:  ^wl.Surface,

	egl_display:      egl.Display,
	egl_config:       egl.Config,
	egl_context:      egl.Context,
	gl_ready:         bool,

	// Input state
	pointer_serial:   u32,
	pointer_inside:   bool,
	cursor:           im.MouseCursor,
	xkb_ctx:          ^xkb.Context,
	xkb_keymap:       ^xkb.Keymap,
	xkb_state:        ^xkb.State,
	repeat_rate:      i32,
	repeat_delay:     i32,
	repeat_key:       u32,
	repeat_at:        time.Tick,
	keyboard_focus:   bool,
	had_focus:        bool,

	// Events for the app
	closed:           bool, // compositor closed our surface
	focus_lost:       bool,
	outside_click:    bool,
	redraw:           int, // number of frames we still want to render
}

plat: Platform
@(private = "file")
g_ctx: runtime.Context

// ---------------------------------------------------------------------------
// Registry

@(private = "file")
registry_listener := wl.Registry_Listener {
	global = proc "c" (data: rawptr, registry: ^wl.Registry, name: u32, iface: cstring, version: u32) {
		context = g_ctx
		switch iface {
		case "wl_compositor":
			plat.compositor_ver = min(version, 6)
			plat.compositor = cast(^wl.Compositor)wl.registry_bind(registry, name, &wl.compositor_interface, plat.compositor_ver)
		case "zwlr_layer_shell_v1":
			plat.layer_shell = cast(^wl.Zwlr_Layer_Shell_V1)wl.registry_bind(registry, name, &wl.zwlr_layer_shell_v1_interface, min(version, 4))
		case "wp_viewporter":
			plat.viewporter = cast(^wl.Wp_Viewporter)wl.registry_bind(registry, name, &wl.wp_viewporter_interface, 1)
		case "wp_single_pixel_buffer_manager_v1":
			plat.single_pixel = cast(^wl.Wp_Single_Pixel_Buffer_Manager_V1)wl.registry_bind(registry, name, &wl.wp_single_pixel_buffer_manager_v1_interface, 1)
		case "wp_cursor_shape_manager_v1":
			plat.cursor_shape_mgr = cast(^wl.Wp_Cursor_Shape_Manager_V1)wl.registry_bind(registry, name, &wl.wp_cursor_shape_manager_v1_interface, 1)
		case "wl_seat":
			if plat.seat == nil {
				plat.seat = cast(^wl.Seat)wl.registry_bind(registry, name, &wl.seat_interface, min(version, 7))
				wl.seat_add_listener(plat.seat, &seat_listener, nil)
			}
		case "wl_output":
			out := cast(^wl.Output)wl.registry_bind(registry, name, &wl.output_interface, min(version, 4))
			append(&plat.outputs, Output_Info{output = out, name = name, scale = 1})
			wl.output_add_listener(out, &output_listener, rawptr(uintptr(name)))
		}
	},
	global_remove = proc "c" (data: rawptr, registry: ^wl.Registry, name: u32) {
		context = g_ctx
		for o, i in plat.outputs {
			if o.name == name {
				wl.output_destroy(o.output)
				unordered_remove(&plat.outputs, i)
				break
			}
		}
	},
}

@(private = "file")
find_output :: proc(name: u32) -> ^Output_Info {
	for &o in plat.outputs {if o.name == name {return &o}}
	return nil
}

@(private = "file")
output_listener := wl.Output_Listener {
	geometry = proc "c" (data: rawptr, self: ^wl.Output, x, y, pw, ph, subpixel: i32, make, model: cstring, transform: i32) {},
	mode = proc "c" (data: rawptr, self: ^wl.Output, flags: u32, w, h, refresh: i32) {},
	done = proc "c" (data: rawptr, self: ^wl.Output) {},
	scale = proc "c" (data: rawptr, self: ^wl.Output, factor: i32) {
		context = g_ctx
		if o := find_output(u32(uintptr(data))); o != nil {o.scale = factor}
	},
	name = proc "c" (data: rawptr, self: ^wl.Output, name: cstring) {
		context = g_ctx
		if o := find_output(u32(uintptr(data))); o != nil {o.conn = strings.clone_from_cstring(name)}
	},
	description = proc "c" (data: rawptr, self: ^wl.Output, description: cstring) {},
}

// ---------------------------------------------------------------------------
// Seat

@(private = "file")
seat_listener := wl.Seat_Listener {
	capabilities = proc "c" (data: rawptr, seat: ^wl.Seat, caps: u32) {
		context = g_ctx
		has_pointer := caps & wl.SEAT_CAPABILITY_POINTER != 0
		has_keyboard := caps & wl.SEAT_CAPABILITY_KEYBOARD != 0
		if has_pointer && plat.pointer == nil {
			plat.pointer = wl.seat_get_pointer(seat)
			wl.pointer_add_listener(plat.pointer, &pointer_listener, nil)
			if plat.cursor_shape_mgr != nil {
				plat.cursor_device = wl.wp_cursor_shape_manager_v1_get_pointer(plat.cursor_shape_mgr, plat.pointer)
			}
		} else if !has_pointer && plat.pointer != nil {
			if plat.cursor_device != nil {wl.wp_cursor_shape_device_v1_destroy(plat.cursor_device)}
			wl.pointer_release(plat.pointer)
			plat.pointer, plat.cursor_device = nil, nil
		}
		if has_keyboard && plat.keyboard == nil {
			plat.keyboard = wl.seat_get_keyboard(seat)
			wl.keyboard_add_listener(plat.keyboard, &keyboard_listener, nil)
		} else if !has_keyboard && plat.keyboard != nil {
			wl.keyboard_release(plat.keyboard)
			plat.keyboard = nil
		}
	},
	name = proc "c" (data: rawptr, seat: ^wl.Seat, name: cstring) {},
}

@(private = "file")
apply_cursor :: proc() {
	if plat.cursor_device == nil || !plat.pointer_inside {return}
	shape: u32 = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT
	#partial switch plat.cursor {
	case .Hand:       shape = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER
	case .TextInput:  shape = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT
	case .ResizeAll:  shape = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ALL_SCROLL
	case .ResizeEW:   shape = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_EW_RESIZE
	case .ResizeNS:   shape = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NS_RESIZE
	case .ResizeNESW: shape = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NESW_RESIZE
	case .ResizeNWSE: shape = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NWSE_RESIZE
	case .NotAllowed: shape = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NOT_ALLOWED
	case .Wait:       shape = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_WAIT
	case .Progress:   shape = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_PROGRESS
	}
	wl.wp_cursor_shape_device_v1_set_shape(plat.cursor_device, plat.pointer_serial, shape)
}

platform_set_cursor :: proc(c: im.MouseCursor) {
	if c == plat.cursor {return}
	plat.cursor = c
	apply_cursor()
}

@(private = "file")
pointer_listener := wl.Pointer_Listener {
	enter = proc "c" (data: rawptr, self: ^wl.Pointer, serial: u32, surface: ^wl.Surface, x, y: wl.Fixed) {
		context = g_ctx
		plat.pointer_serial = serial
		plat.pointer_surface = surface
		if surface != plat.surface {
			if plat.cursor_device != nil {
				wl.wp_cursor_shape_device_v1_set_shape(plat.cursor_device, serial, wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT)
			}
			return
		}
		plat.pointer_inside = true
		plat.cursor = .Arrow
		apply_cursor()
		im.IO_AddMousePosEvent(im.GetIO(), f32(wl.fixed_to_f64(x)), f32(wl.fixed_to_f64(y)))
		request_redraw()
	},
	leave = proc "c" (data: rawptr, self: ^wl.Pointer, serial: u32, surface: ^wl.Surface) {
		context = g_ctx
		was_popup := plat.pointer_surface == plat.surface
		plat.pointer_surface = nil
		if !was_popup {return}
		plat.pointer_inside = false
		im.IO_AddMousePosEvent(im.GetIO(), -max(f32), -max(f32))
		request_redraw()
	},
	motion = proc "c" (data: rawptr, self: ^wl.Pointer, t: u32, x, y: wl.Fixed) {
		context = g_ctx
		if plat.pointer_surface != plat.surface {return}
		im.IO_AddMousePosEvent(im.GetIO(), f32(wl.fixed_to_f64(x)), f32(wl.fixed_to_f64(y)))
		request_redraw()
	},
	button = proc "c" (data: rawptr, self: ^wl.Pointer, serial, t, button, state: u32) {
		context = g_ctx
		if plat.pointer_surface != plat.surface {
			if plat.pointer_surface != nil && plat.pointer_surface == plat.catcher && state == wl.POINTER_BUTTON_STATE_PRESSED {
				plat.outside_click = true
			}
			return
		}
		b: i32 = -1
		switch button {
		case 0x110: b = 0 // BTN_LEFT
		case 0x111: b = 1 // BTN_RIGHT
		case 0x112: b = 2 // BTN_MIDDLE
		}
		if b >= 0 {
			im.IO_AddMouseButtonEvent(im.GetIO(), b, state == wl.POINTER_BUTTON_STATE_PRESSED)
		}
		request_redraw()
	},
	axis = proc "c" (data: rawptr, self: ^wl.Pointer, t: u32, axis: u32, value: wl.Fixed) {
		context = g_ctx
		if plat.pointer_surface != plat.surface {return}
		v := f32(wl.fixed_to_f64(value)) / 15.0
		if axis == wl.POINTER_AXIS_VERTICAL_SCROLL {
			im.IO_AddMouseWheelEvent(im.GetIO(), 0, -v)
		} else {
			im.IO_AddMouseWheelEvent(im.GetIO(), -v, 0)
		}
		request_redraw()
	},
	frame = proc "c" (data: rawptr, self: ^wl.Pointer) {},
	axis_source = proc "c" (data: rawptr, self: ^wl.Pointer, axis_source: u32) {},
	axis_stop = proc "c" (data: rawptr, self: ^wl.Pointer, t: u32, axis: u32) {},
	axis_discrete = proc "c" (data: rawptr, self: ^wl.Pointer, axis: u32, discrete: i32) {},
	axis_value120 = proc "c" (data: rawptr, self: ^wl.Pointer, axis: u32, value120: i32) {},
	axis_relative_direction = proc "c" (data: rawptr, self: ^wl.Pointer, axis: u32, direction: u32) {},
}

// ---------------------------------------------------------------------------
// Keyboard

@(private = "file")
keysym_to_imgui :: proc(sym: u32) -> im.Key {
	switch sym {
	case xkb.KEY_Tab, xkb.KEY_ISO_Left_Tab: return .Tab
	case xkb.KEY_Left:      return .LeftArrow
	case xkb.KEY_Right:     return .RightArrow
	case xkb.KEY_Up:        return .UpArrow
	case xkb.KEY_Down:      return .DownArrow
	case xkb.KEY_Page_Up:   return .PageUp
	case xkb.KEY_Page_Down: return .PageDown
	case xkb.KEY_Home:      return .Home
	case xkb.KEY_End:       return .End
	case xkb.KEY_Delete:    return .Delete
	case xkb.KEY_BackSpace: return .Backspace
	case xkb.KEY_Return:    return .Enter
	case xkb.KEY_KP_Enter:  return .KeypadEnter
	case xkb.KEY_Escape:    return .Escape
	case xkb.KEY_space:     return .Space
	case xkb.KEY_Shift_L:   return .LeftShift
	case xkb.KEY_Shift_R:   return .RightShift
	case xkb.KEY_Control_L: return .LeftCtrl
	case xkb.KEY_Control_R: return .RightCtrl
	case xkb.KEY_Alt_L:     return .LeftAlt
	case xkb.KEY_Alt_R:     return .RightAlt
	case xkb.KEY_Super_L:   return .LeftSuper
	case xkb.KEY_Super_R:   return .RightSuper
	case xkb.KEY_a:         return .A
	case xkb.KEY_c:         return .C
	case xkb.KEY_v:         return .V
	case xkb.KEY_x:         return .X
	case xkb.KEY_z:         return .Z
	}
	return .None
}

// Called on press and on key repeat.
@(private = "file")
key_press :: proc(key: u32, repeat: bool) {
	io := im.GetIO()
	code := key + 8
	sym := xkb.state_key_get_one_sym(plat.xkb_state, code)
	if k := keysym_to_imgui(sym); k != .None {
		im.IO_AddKeyEvent(io, k, true)
		if repeat {im.IO_AddKeyEvent(io, k, false)}
	}
	// Text input (skip when ctrl is held so shortcuts don't type).
	ctrl := xkb.state_mod_name_is_active(plat.xkb_state, xkb.MOD_NAME_CTRL, xkb.STATE_MODS_EFFECTIVE) > 0
	if !ctrl {
		buf: [16]u8
		n := xkb.state_key_get_utf8(plat.xkb_state, code, &buf[0], len(buf))
		if n > 0 && buf[0] >= 0x20 && buf[0] != 0x7f {
			im.IO_AddInputCharactersUTF8(io, cstring(&buf[0]))
		}
	}
}

@(private = "file")
keyboard_listener := wl.Keyboard_Listener {
	keymap = proc "c" (data: rawptr, self: ^wl.Keyboard, format: u32, fd: i32, size: u32) {
		context = g_ctx
		defer posix.close(posix.FD(fd))
		if format != wl.KEYBOARD_KEYMAP_FORMAT_XKB_V1 {return}
		mem := posix.mmap(nil, uint(size), {.READ}, {.PRIVATE}, posix.FD(fd), 0)
		if mem == posix.MAP_FAILED {return}
		defer posix.munmap(mem, uint(size))
		if plat.xkb_ctx == nil {plat.xkb_ctx = xkb.context_new(xkb.CONTEXT_NO_FLAGS)}
		keymap := xkb.keymap_new_from_string(plat.xkb_ctx, cstring(mem), xkb.KEYMAP_FORMAT_TEXT_V1, xkb.KEYMAP_COMPILE_NO_FLAGS)
		if keymap == nil {return}
		if plat.xkb_state != nil {xkb.state_unref(plat.xkb_state)}
		if plat.xkb_keymap != nil {xkb.keymap_unref(plat.xkb_keymap)}
		plat.xkb_keymap = keymap
		plat.xkb_state = xkb.state_new(keymap)
	},
	enter = proc "c" (data: rawptr, self: ^wl.Keyboard, serial: u32, surface: ^wl.Surface, keys: ^wl.Array) {
		context = g_ctx
		plat.keyboard_focus = true
		plat.had_focus = true
		im.IO_AddFocusEvent(im.GetIO(), true)
		request_redraw()
	},
	leave = proc "c" (data: rawptr, self: ^wl.Keyboard, serial: u32, surface: ^wl.Surface) {
		context = g_ctx
		plat.keyboard_focus = false
		plat.repeat_key = 0
		if plat.had_focus {plat.focus_lost = true}
		im.IO_AddFocusEvent(im.GetIO(), false)
		request_redraw()
	},
	key = proc "c" (data: rawptr, self: ^wl.Keyboard, serial, t, key, state: u32) {
		context = g_ctx
		if plat.xkb_state == nil {return}
		if state == wl.KEYBOARD_KEY_STATE_PRESSED {
			key_press(key, false)
			if plat.repeat_rate > 0 && xkb.keymap_key_repeats(plat.xkb_keymap, key + 8) != 0 {
				plat.repeat_key = key
				plat.repeat_at = time.tick_add(time.tick_now(), time.Duration(plat.repeat_delay) * time.Millisecond)
			}
		} else {
			sym := xkb.state_key_get_one_sym(plat.xkb_state, key + 8)
			if k := keysym_to_imgui(sym); k != .None {
				im.IO_AddKeyEvent(im.GetIO(), k, false)
			}
			if plat.repeat_key == key {plat.repeat_key = 0}
		}
		request_redraw()
	},
	modifiers = proc "c" (data: rawptr, self: ^wl.Keyboard, serial, depressed, latched, locked, group: u32) {
		context = g_ctx
		if plat.xkb_state == nil {return}
		xkb.state_update_mask(plat.xkb_state, depressed, latched, locked, 0, 0, group)
		io := im.GetIO()
		active :: proc(name: cstring) -> bool {
			return xkb.state_mod_name_is_active(plat.xkb_state, name, xkb.STATE_MODS_EFFECTIVE) > 0
		}
		im.IO_AddKeyEvent(io, .ImGuiMod_Ctrl, active(xkb.MOD_NAME_CTRL))
		im.IO_AddKeyEvent(io, .ImGuiMod_Shift, active(xkb.MOD_NAME_SHIFT))
		im.IO_AddKeyEvent(io, .ImGuiMod_Alt, active(xkb.MOD_NAME_ALT))
		im.IO_AddKeyEvent(io, .ImGuiMod_Super, active(xkb.MOD_NAME_LOGO))
	},
	repeat_info = proc "c" (data: rawptr, self: ^wl.Keyboard, rate, delay: i32) {
		plat.repeat_rate = rate
		plat.repeat_delay = delay
	},
}

// Returns the time until the next key repeat is due (or -1 if none) and fires
// repeats that are due.
platform_key_repeat :: proc() -> time.Duration {
	if plat.repeat_key == 0 || plat.repeat_rate <= 0 {return -1}
	now := time.tick_now()
	interval := time.Second / time.Duration(plat.repeat_rate)
	for time.tick_diff(plat.repeat_at, now) >= 0 {
		key_press(plat.repeat_key, true)
		plat.repeat_at = time.tick_add(plat.repeat_at, interval)
		request_redraw()
	}
	return time.tick_diff(now, plat.repeat_at)
}

// ---------------------------------------------------------------------------
// Popup surface

@(private = "file")
surface_listener := wl.Surface_Listener {
	enter = proc "c" (data: rawptr, self: ^wl.Surface, output: ^wl.Output) {
		context = g_ctx
		if plat.preferred_scale {return}
		for o in plat.outputs {
			if o.output == output && o.scale != plat.scale {
				plat.scale = max(o.scale, 1)
				resize_buffers()
			}
		}
	},
	leave = proc "c" (data: rawptr, self: ^wl.Surface, output: ^wl.Output) {},
	preferred_buffer_scale = proc "c" (data: rawptr, self: ^wl.Surface, factor: i32) {
		context = g_ctx
		plat.preferred_scale = true
		if factor != plat.scale {
			plat.scale = max(factor, 1)
			resize_buffers()
		}
	},
	preferred_buffer_transform = proc "c" (data: rawptr, self: ^wl.Surface, transform: u32) {},
}

@(private = "file")
layer_surface_listener := wl.Zwlr_Layer_Surface_V1_Listener {
	configure = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1, serial, width, height: u32) {
		context = g_ctx
		log.debugf("layer configure %dx%d", width, height)
		wl.zwlr_layer_surface_v1_ack_configure(self, serial)
		if width > 0 {plat.width = i32(width)}
		if height > 0 {plat.height = i32(height)}
		plat.configured = true
		resize_buffers()
		request_redraw()
	},
	closed = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1) {
		context = g_ctx
		plat.closed = true
	},
}

@(private = "file")
catcher_listener := wl.Zwlr_Layer_Surface_V1_Listener {
	configure = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1, serial, width, height: u32) {
		wl.zwlr_layer_surface_v1_ack_configure(self, serial)
		if plat.catcher_viewport != nil && width > 0 && height > 0 {
			wl.wp_viewport_set_destination(plat.catcher_viewport, i32(width), i32(height))
		}
		wl.surface_attach(plat.catcher, plat.catcher_buffer, 0, 0)
		wl.surface_damage_buffer(plat.catcher, 0, 0, 1, 1)
		wl.surface_commit(plat.catcher)
	},
	closed = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1) {
		plat.closed = true
	},
}

@(private = "file")
catcher_create :: proc(output: ^wl.Output) {
	if plat.viewporter == nil || plat.single_pixel == nil {return}
	plat.catcher = wl.compositor_create_surface(plat.compositor)
	plat.catcher_buffer = wl.wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(plat.single_pixel, 0, 0, 0, 0)
	plat.catcher_viewport = wl.wp_viewporter_get_viewport(plat.viewporter, plat.catcher)
	plat.catcher_layer = wl.zwlr_layer_shell_v1_get_layer_surface(plat.layer_shell, plat.catcher, output, wl.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "wlwidgets-backdrop")
	wl.zwlr_layer_surface_v1_add_listener(plat.catcher_layer, &catcher_listener, nil)
	wl.zwlr_layer_surface_v1_set_anchor(plat.catcher_layer, wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT)
	wl.zwlr_layer_surface_v1_set_exclusive_zone(plat.catcher_layer, -1)
	wl.zwlr_layer_surface_v1_set_keyboard_interactivity(plat.catcher_layer, wl.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE)
	wl.surface_commit(plat.catcher)
}

@(private = "file")
catcher_destroy :: proc() {
	if plat.catcher == nil {return}
	wl.zwlr_layer_surface_v1_destroy(plat.catcher_layer)
	wl.wp_viewport_destroy(plat.catcher_viewport)
	wl.surface_destroy(plat.catcher)
	wl.buffer_destroy(plat.catcher_buffer)
	plat.catcher, plat.catcher_layer, plat.catcher_viewport, plat.catcher_buffer = nil, nil, nil, nil
}

@(private = "file")
frame_listener := wl.Callback_Listener {
	done = proc "c" (data: rawptr, self: ^wl.Callback, t: u32) {
		wl.callback_destroy(self)
		plat.frame_cb = nil
		plat.frame_pending = false
	},
}

@(private = "file")
resize_buffers :: proc() {
	if plat.surface == nil {return}
	wl.surface_set_buffer_scale(plat.surface, plat.scale)
	if plat.egl_window != nil {
		wl.egl_window_resize(plat.egl_window, plat.width * plat.scale, plat.height * plat.scale, 0, 0)
	}
	request_redraw()
}

request_redraw :: proc "contextless" (frames := 3) {
	plat.redraw = max(plat.redraw, frames)
}

platform_init :: proc() -> bool {
	g_ctx = context
	plat.scale = 1
	plat.repeat_rate = 25
	plat.repeat_delay = 600

	plat.display = wl.display_connect(nil)
	if plat.display == nil {
		log.error("cannot connect to wayland display")
		return false
	}
	plat.registry = wl.display_get_registry(plat.display)
	wl.registry_add_listener(plat.registry, &registry_listener, nil)
	wl.display_roundtrip(plat.display)
	wl.display_roundtrip(plat.display) // seat capabilities + output info
	if plat.compositor == nil || plat.layer_shell == nil {
		log.error("compositor lacks wl_compositor or zwlr_layer_shell_v1")
		return false
	}

	// EGL
	plat.egl_display = egl.GetPlatformDisplay(.WAYLAND_KHR, plat.display, nil)
	if plat.egl_display == nil {
		log.error("eglGetPlatformDisplay failed")
		return false
	}
	major, minor: i32
	if !egl.Initialize(plat.egl_display, &major, &minor) {
		log.error("eglInitialize failed")
		return false
	}
	egl.BindAPI(egl.OPENGL_API)
	cfg_attribs := []i32 {
		egl.SURFACE_TYPE, egl.WINDOW_BIT,
		egl.RENDERABLE_TYPE, egl.OPENGL_BIT,
		egl.RED_SIZE, 8, egl.GREEN_SIZE, 8, egl.BLUE_SIZE, 8, egl.ALPHA_SIZE, 8,
		egl.NONE,
	}
	n: i32
	if !egl.ChooseConfig(plat.egl_display, &cfg_attribs[0], &plat.egl_config, 1, &n) || n == 0 {
		log.error("eglChooseConfig failed")
		return false
	}
	ctx_attribs := []i32 {
		egl.CONTEXT_MAJOR_VERSION, 3,
		egl.CONTEXT_MINOR_VERSION, 3,
		egl.CONTEXT_OPENGL_PROFILE_MASK, egl.CONTEXT_OPENGL_CORE_PROFILE_BIT,
		egl.NONE,
	}
	plat.egl_context = egl.CreateContext(plat.egl_display, plat.egl_config, egl.NO_CONTEXT, &ctx_attribs[0])
	if plat.egl_context == nil {
		log.error("eglCreateContext failed")
		return false
	}
	return true
}

Popup_Placement :: struct {
	anchor:     u32,
	margin:     [4]i32, // top right bottom left
	layer:      u32,
	output:     string, // connector name; "" = compositor's choice (focused)
}

platform_show :: proc(placement: Popup_Placement, width, height: i32) -> bool {
	if plat.surface != nil {return true}
	plat.configured = false
	plat.closed = false
	plat.focus_lost = false
	plat.outside_click = false
	plat.had_focus = false
	plat.width, plat.height = width, height
	plat.want_height = height

	plat.surface = wl.compositor_create_surface(plat.compositor)
	wl.surface_add_listener(plat.surface, &surface_listener, nil)

	output: ^wl.Output
	for o in plat.outputs {
		if placement.output != "" && o.conn == placement.output {output = o.output}
	}
	if output != nil {
		for o in plat.outputs {if o.output == output {plat.scale = max(o.scale, 1)}}
	} else if !plat.preferred_scale {
		// Best guess until the surface enters an output.
		plat.scale = 1
		for o in plat.outputs {plat.scale = max(plat.scale, o.scale)}
	}

	// The backdrop must be created first so it stacks below the popup.
	catcher_create(output)

	plat.layer_surface = wl.zwlr_layer_shell_v1_get_layer_surface(plat.layer_shell, plat.surface, output, placement.layer, "wlwidgets")
	wl.zwlr_layer_surface_v1_add_listener(plat.layer_surface, &layer_surface_listener, nil)
	wl.zwlr_layer_surface_v1_set_size(plat.layer_surface, u32(width), u32(height))
	wl.zwlr_layer_surface_v1_set_anchor(plat.layer_surface, placement.anchor)
	m := placement.margin
	wl.zwlr_layer_surface_v1_set_margin(plat.layer_surface, m[0], m[1], m[2], m[3])
	wl.zwlr_layer_surface_v1_set_exclusive_zone(plat.layer_surface, 0) // stay clear of bars
	wl.zwlr_layer_surface_v1_set_keyboard_interactivity(plat.layer_surface, wl.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE)
	wl.surface_set_buffer_scale(plat.surface, plat.scale)
	wl.surface_commit(plat.surface)

	for !plat.configured && !plat.closed {
		if wl.display_dispatch(plat.display) < 0 {return false}
	}
	if plat.closed {
		platform_hide()
		return false
	}

	plat.egl_window = wl.egl_window_create(plat.surface, plat.width * plat.scale, plat.height * plat.scale)
	plat.egl_surface = egl.CreateWindowSurface(plat.egl_display, plat.egl_config, egl.NativeWindowType(plat.egl_window), nil)
	if plat.egl_surface == nil {
		log.error("eglCreateWindowSurface failed")
		platform_hide()
		return false
	}
	egl.MakeCurrent(plat.egl_display, plat.egl_surface, plat.egl_surface, plat.egl_context)
	egl.SwapInterval(plat.egl_display, 0)
	if !plat.gl_ready {
		gl.load_up_to(3, 3, egl.gl_set_proc_address)
		plat.gl_ready = true
	}
	plat.input_rect = {}
	request_redraw()
	return true
}

platform_hide :: proc() {
	if plat.surface == nil {return}
	if plat.egl_surface != nil {
		egl.MakeCurrent(plat.egl_display, egl.NO_SURFACE, egl.NO_SURFACE, plat.egl_context)
		egl.DestroySurface(plat.egl_display, plat.egl_surface)
		plat.egl_surface = nil
	}
	if plat.egl_window != nil {
		wl.egl_window_destroy(plat.egl_window)
		plat.egl_window = nil
	}
	if plat.frame_cb != nil {
		wl.callback_destroy(plat.frame_cb)
		plat.frame_cb = nil
	}
	wl.zwlr_layer_surface_v1_destroy(plat.layer_surface)
	wl.surface_destroy(plat.surface)
	catcher_destroy()
	plat.layer_surface, plat.surface = nil, nil
	plat.frame_pending = false
	plat.pointer_inside = false
	plat.keyboard_focus = false
	plat.repeat_key = 0
	wl.display_flush(plat.display)
}

platform_visible :: proc() -> bool {
	return plat.surface != nil && plat.configured
}

// Ask the compositor for a new surface height (content changed size).
platform_request_height :: proc(h: i32) {
	if plat.layer_surface == nil || h == plat.want_height {return}
	plat.want_height = h
	wl.zwlr_layer_surface_v1_set_size(plat.layer_surface, u32(plat.width), u32(h))
	wl.surface_commit(plat.surface)
}

// Only the panel (not the transparent shadow margin) should take input.
platform_set_input_rect :: proc(x, y, w, h: i32) {
	r := [4]i32{x, y, w, h}
	if plat.surface == nil || r == plat.input_rect {return}
	plat.input_rect = r
	region := wl.compositor_create_region(plat.compositor)
	wl.region_add(region, x, y, w, h)
	wl.surface_set_input_region(plat.surface, region)
	wl.region_destroy(region)
}

platform_can_render :: proc() -> bool {
	return platform_visible() && !plat.frame_pending && plat.egl_surface != nil
}

platform_begin_frame :: proc() {
	io := im.GetIO()
	io.DisplaySize = {f32(plat.width), f32(plat.height)}
	io.DisplayFramebufferScale = {f32(plat.scale), f32(plat.scale)}
}

platform_end_frame :: proc() {
	plat.frame_cb = wl.surface_frame(plat.surface)
	wl.callback_add_listener(plat.frame_cb, &frame_listener, nil)
	plat.frame_pending = true
	if !egl.SwapBuffers(plat.egl_display, plat.egl_surface) {
		log.errorf("eglSwapBuffers failed: 0x%x", egl.GetError())
	}
}

platform_fd :: proc() -> posix.FD {
	return posix.FD(wl.display_get_fd(plat.display))
}

_ :: c
