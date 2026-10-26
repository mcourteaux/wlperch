// Lock screen: `wlperch lock`, a separate process (not the daemon, so its
// re-execs and crashes can't touch it) holding an ext-session-lock-v1 lock.
// One software-rendered surface per output: the focused one gets the clock,
// password field and a status row (unread notification count, what's
// playing, battery) with connected Bluetooth devices above it; the others
// just the clock.
//
// Every output's first frame is drawn (in parallel) before the lock is
// requested and committed from the lock surface's configure event, so the
// black sway shows between `locked` and the first commit lasts no frame.
//
// It draws only when something changes (the minute, a key, info, the
// theme), except while the frosted background's blur grows
// ([lock] blur_animate_ms): then every frame callback brings a new frame
// until the static picture is reached.
//
// The lock is only ever released after PAM accepted the password. Every
// error path exits without unlocking; the compositor then keeps the session
// locked (in sway another `wlperch lock` can take over the abandoned lock).
package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import stbi "vendor:stb/image"

import "wl"
import "xkb"

// Test builds only (-define:WLPERCH_LOCK_TEST_AUTH=true, never set by build.sh):
// with WLPERCH_LOCK_TEST=1 the password is checked against LOCK_TEST_PASSWORD
// instead of PAM, so UI tests never need a real password.
LOCK_TEST_AUTH :: #config(WLPERCH_LOCK_TEST_AUTH, false)
LOCK_TEST_PASSWORD :: "wlperch-test"

@(private = "file") ICON_CAPS :: "\U000F0632" // md-apple_keyboard_caps
@(private = "file") PILL_W :: 340
@(private = "file") PILL_H :: 50
@(private = "file") FAIL_FREE :: 3 // wrong attempts before the wait grows

@(private = "file")
Lock_Output :: struct {
	output:        ^wl.Output,
	name:          u32,
	conn:          string,
	scale:         i32,
	ready:         bool, // got the output's first "done"
	surface:       ^wl.Surface,
	lsurf:         ^wl.Ext_Session_Lock_Surface_V1,
	w, h:          i32,
	configured:    bool,
	dirty:         bool,
	frame_pending: bool,
	bg:            []u32, // background at buffer size
	bg_w, bg_h:    i32,
	transform:     i32,
	blur:          Blur_Image, // background_mode = blur: the screen before locking
	committed:     bool, // a buffer was committed (timing log)
	mode_w:        i32, // current mode (pixels, untransformed)
	mode_h:        i32,
	refresh:       i32, // current mode, mHz (0: unknown)
	pre:           Prerender,
	// [lock] blur_animate_ms: the growing blur (see lock_blur_anim.odin)
	anim_src:      Blur_Anim_Source, // the start, until the animation takes it
	anim:          ^Blur_Anim, // while animating (the worker's, once it runs)
	anim_bufs:     [ANIM_BUFS]Anim_Buffer, // frame buffers while animating
	aw:            ^Anim_Worker, // draws the frames
	gang:          ^Blur_Gang, // ...on this many threads
	anim_ready:    int, // anim_bufs index of a drawn frame waiting for its commit, or -1
	anim_final:    bool, // the last frame was asked for
	anim_last:     time.Tick, // last buffer commit
	anim_commit_t: f64, // ...on the animation clock (ms)
	anim_frames:   int, // timing log
	anim_iv:       [3]f64, // commit intervals: min, sum, max
}

// A full-size shm buffer kept mapped while the blur animates (a new one per
// frame would fault in ~20 MB of fresh pages each time).
@(private = "file")
Anim_Buffer :: struct {
	buffer: ^wl.Buffer,
	px:     []u32,
	w, h:   i32,
	fd:     linux.Fd, // until the wl_buffer is made
	busy:   bool, // attached, not released yet
}

// The first frame, drawn before the lock is requested at the size the lock
// surface is expected to get, and committed straight from its configure
// event: sway shows black from `locked` until each lock surface commits.
@(private = "file")
Prerender :: struct {
	w, h:   i32, // logical size it was drawn for
	scale:  i32,
	full:   bool, // drawn with the password field (primary output)
	tint:   u32, // frost_tint, for the animation's frame 0
	mix:    f32,
	px:     []u32, // shm mapping, while drawing
	fd:     linux.Fd,
	ok:     bool,
	anim:   bool, // drawn into anim_bufs[0]: the growing blur's first frame
	ui:     Lock_UI,
	buffer: ^wl.Buffer, // nil once used or dropped
}

@(private = "file")
Auth_State :: enum {Idle, Checking, Wrong}

@(private = "file")
Lock_Info :: struct {
	mu:       sync.Mutex,
	unread:   int, // -1: daemon not running
	dnd:      bool,
	apps:     string,
	media:    string,
	playing:  bool,
	battery:  int, // -1: none
	charging: bool,
	weather:  string,
	pam_msg:  string, // e.g. a fingerprint prompt
	bt:       string, // the daemon's "bt" lines (see bluetooth_lock_lines)
}

@(private = "file")
Locker :: struct {
	display:        ^wl.Display,
	compositor:     ^wl.Compositor,
	shm:            ^wl.Shm,
	seat:           ^wl.Seat,
	keyboard:       ^wl.Keyboard,
	pointer:        ^wl.Pointer,
	manager:        ^wl.Ext_Session_Lock_Manager_V1,
	lock:           ^wl.Ext_Session_Lock_V1,
	outputs:        [dynamic]^Lock_Output,
	locked:         bool,
	finished:       bool,
	primary:        string, // connector that gets the full UI

	xkb_ctx:        ^xkb.Context,
	xkb_keymap:     ^xkb.Keymap,
	xkb_state:      ^xkb.State,
	compose:        xkb.Compose,
	repeat_rate:    i32,
	repeat_delay:   i32,
	repeat_key:     u32,
	repeat_at:      time.Tick,
	caps:           bool,
	layout:         string, // shown when the keymap has several layouts

	pw:             [512]u8,
	pw_len:         int,
	auth:           Auth_State,
	fails:          int,
	retry_at:       time.Tick, // Enter is ignored until then after repeated failures
	wrong_at:       time.Tick,

	wake_r, wake_w: posix.FD, // worker threads -> main loop
	daemon_w:       posix.FD, // --daemonize: tell the parent we're locked
	// --screen-off: monitors powered off once locked, back on at the first
	// key press or pointer movement (sway doesn't do that by itself).
	screen_off:     bool,
	screens_off:    bool,
	screens_woken:  bool, // a key was pressed (set from the keyboard callback)
	ptr_pressed:    bool, // a pointer button was pressed
	ptr_moved:      f32, // pointer travel since the monitors went off (px)
	ptr_last:       [2]f32,
	ptr_have:       bool, // ptr_last is valid
	off_at:         time.Tick,
	off_done:       bool,
	pam_service:    string,

	image:          []u32, // decoded [lock] image (0xAARRGGBB), or nil
	img_w, img_h:   int,
	lock_at:        time.Tick, // when lock() was sent (timing log)
	rects:          map[string][2]i32, // sway's logical output sizes, by connector
	animate:        bool, // grow the blur ([lock] blur_animate_ms, not with -f)
	anim_start:     time.Tick, // the animation clock's zero: first frame callback
	anim_started:   bool,
	loop_max:       f64, // timing log: longest main-loop pass while animating (ms)
}

// Milliseconds since lock() was sent, for the WLPERCH_DEBUG timing log.
@(private = "file")
since_lock :: proc() -> f64 {return time.duration_milliseconds(time.tick_since(lk.lock_at))}

@(private = "file") lk: Locker
@(private = "file") info: Lock_Info

// Handed from the main loop to the auth thread; zeroed as soon as it's checked.
@(private = "file") auth_mu: sync.Mutex
@(private = "file") auth_sema: sync.Sema
@(private = "file") auth_pw: [512]u8
@(private = "file") auth_len: int

@(private = "file") g_lock_ctx: runtime.Context

@(private = "file")
wake :: proc "contextless" (b: u8) {
	v := b
	posix.write(lk.wake_w, &v, 1)
}

// ---- Wayland --------------------------------------------------------------------

@(private = "file")
find_output :: proc(name: u32) -> (^Lock_Output, int) {
	for o, i in lk.outputs {if o.name == name {return o, i}}
	return nil, -1
}

@(private = "file")
registry_listener := wl.Registry_Listener {
	global = proc "c" (data: rawptr, registry: ^wl.Registry, name: u32, iface: cstring, version: u32) {
		context = g_lock_ctx
		switch iface {
		case "wl_compositor":
			lk.compositor = cast(^wl.Compositor)wl.registry_bind(registry, name, &wl.compositor_interface, min(version, 4))
		case "wl_shm":
			lk.shm = cast(^wl.Shm)wl.registry_bind(registry, name, &wl.shm_interface, 1)
		case "ext_session_lock_manager_v1":
			lk.manager = cast(^wl.Ext_Session_Lock_Manager_V1)wl.registry_bind(registry, name, &wl.ext_session_lock_manager_v1_interface, 1)
		case "wl_seat":
			if lk.seat == nil {
				lk.seat = cast(^wl.Seat)wl.registry_bind(registry, name, &wl.seat_interface, min(version, 5))
				wl.seat_add_listener(lk.seat, &seat_listener, nil)
			}
		case "ext_image_copy_capture_manager_v1", "ext_output_image_capture_source_manager_v1", "zwlr_screencopy_manager_v1":
			// Only bound (and used) with the blurred-screenshot background.
			if config.lock_mode == .Blur {capture_bind(registry, name, iface, version)}
		case "wl_output":
			o := new(Lock_Output)
			o.name = name
			o.scale = 1
			o.output = cast(^wl.Output)wl.registry_bind(registry, name, &wl.output_interface, min(version, 4))
			wl.output_add_listener(o.output, &output_listener, o)
			append(&lk.outputs, o)
		}
	},
	global_remove = proc "c" (data: rawptr, registry: ^wl.Registry, name: u32) {
		context = g_lock_ctx
		o, i := find_output(name)
		if o == nil {return}
		if o.lsurf != nil {wl.ext_session_lock_surface_v1_destroy(o.lsurf)}
		if o.surface != nil {wl.surface_destroy(o.surface)}
		if o.pre.buffer != nil {wl.buffer_destroy(o.pre.buffer)}
		anim_end(o)
		if wl.output_get_version(o.output) >= 3 {wl.output_release(o.output)} else {wl.output_destroy(o.output)}
		delete(o.bg)
		delete(o.blur.px)
		delete(o.conn)
		free(o)
		ordered_remove(&lk.outputs, i)
	},
}

@(private = "file")
output_listener := wl.Output_Listener {
	geometry = proc "c" (data: rawptr, self: ^wl.Output, x, y, pw, ph, subpixel: i32, make, model: cstring, transform: i32) {
		(^Lock_Output)(data).transform = transform
	},
	mode = proc "c" (data: rawptr, self: ^wl.Output, flags: u32, width, height, refresh: i32) {
		if flags & wl.OUTPUT_MODE_CURRENT == 0 {return}
		o := (^Lock_Output)(data)
		o.mode_w, o.mode_h, o.refresh = width, height, refresh
	},
	done = proc "c" (data: rawptr, self: ^wl.Output) {
		context = g_lock_ctx
		o := (^Lock_Output)(data)
		o.ready = true
		// Outputs plugged in while locked get their surface here.
		if lk.lock != nil && o.surface == nil {create_lock_surface(o)}
		o.dirty = true
	},
	scale = proc "c" (data: rawptr, self: ^wl.Output, factor: i32) {
		o := (^Lock_Output)(data)
		o.scale = max(factor, 1)
	},
	name = proc "c" (data: rawptr, self: ^wl.Output, name: cstring) {
		context = g_lock_ctx
		o := (^Lock_Output)(data)
		delete(o.conn)
		o.conn = strings.clone(string(name))
	},
	description = proc "c" (data: rawptr, self: ^wl.Output, description: cstring) {},
}

@(private = "file")
lock_listener := wl.Ext_Session_Lock_V1_Listener {
	locked = proc "c" (data: rawptr, self: ^wl.Ext_Session_Lock_V1) {
		context = g_lock_ctx
		lk.locked = true
		log.info("session locked")
		// [ssh] forget_on_lock: here, not in the daemon, so it happens
		// whether or not the daemon runs.
		if config.ssh_forget_on_lock {ssh_forget_all_async("screen locked")}
		log.debugf("lock: timing: locked at +%.1f ms", since_lock())
		if lk.daemon_w >= 0 {
			b := u8(1)
			posix.write(lk.daemon_w, &b, 1)
			posix.close(lk.daemon_w)
			lk.daemon_w = -1
		}
	},
	finished = proc "c" (data: rawptr, self: ^wl.Ext_Session_Lock_V1) {
		context = g_lock_ctx
		lk.finished = true
	},
}

@(private = "file")
lock_surface_listener := wl.Ext_Session_Lock_Surface_V1_Listener {
	configure = proc "c" (data: rawptr, self: ^wl.Ext_Session_Lock_Surface_V1, serial, width, height: u32) {
		context = g_lock_ctx
		o := (^Lock_Output)(data)
		if !o.committed {log.debugf("lock: timing: configure %s %dx%d at +%.1f ms", o.conn, width, height, since_lock())}
		wl.ext_session_lock_surface_v1_ack_configure(self, serial)
		o.w, o.h = i32(width), i32(height)
		o.configured = true
		if commit_prerender(o) {return}
		o.dirty = true
		o.frame_pending = false // the next commit must carry a buffer of the new size
	},
}

@(private = "file")
frame_listener := wl.Callback_Listener {
	done = proc "c" (data: rawptr, self: ^wl.Callback, t: u32) {
		o := (^Lock_Output)(data)
		o.frame_pending = false
		wl.callback_destroy(self)
		// The first frame (pre-rendered) is on screen: the growing blur starts.
		if lk.animate && !lk.anim_started {
			lk.anim_started = true
			lk.anim_start = time.tick_now()
		}
	},
}

@(private = "file")
buffer_listener := wl.Buffer_Listener {
	release = proc "c" (data: rawptr, self: ^wl.Buffer) {wl.buffer_destroy(self)},
}

@(private = "file")
anim_buffer_listener := wl.Buffer_Listener {
	release = proc "c" (data: rawptr, self: ^wl.Buffer) {(^Anim_Buffer)(data).busy = false},
}

@(private = "file")
create_lock_surface :: proc(o: ^Lock_Output) {
	o.surface = wl.compositor_create_surface(lk.compositor)
	o.lsurf = wl.ext_session_lock_v1_get_lock_surface(lk.lock, o.surface, o.output)
	wl.ext_session_lock_surface_v1_add_listener(o.lsurf, &lock_surface_listener, o)
}

@(private = "file")
seat_listener := wl.Seat_Listener {
	capabilities = proc "c" (data: rawptr, seat: ^wl.Seat, caps: u32) {
		context = g_lock_ctx
		if caps & wl.SEAT_CAPABILITY_KEYBOARD != 0 && lk.keyboard == nil {
			lk.keyboard = wl.seat_get_keyboard(seat)
			wl.keyboard_add_listener(lk.keyboard, &keyboard_listener, nil)
		}
		if caps & wl.SEAT_CAPABILITY_POINTER != 0 && lk.pointer == nil {
			lk.pointer = wl.seat_get_pointer(seat)
			wl.pointer_add_listener(lk.pointer, &pointer_listener, nil)
		}
		// wlroots makes the old objects inert once the last device is gone:
		// drop them so a replugged (or virtual) keyboard gets a fresh one.
		if caps & wl.SEAT_CAPABILITY_KEYBOARD == 0 && lk.keyboard != nil {
			if wl.keyboard_get_version(lk.keyboard) >= 3 {wl.keyboard_release(lk.keyboard)} else {wl.keyboard_destroy(lk.keyboard)}
			lk.keyboard = nil
			lk.repeat_key = 0
		}
		if caps & wl.SEAT_CAPABILITY_POINTER == 0 && lk.pointer != nil {
			if wl.pointer_get_version(lk.pointer) >= 3 {wl.pointer_release(lk.pointer)} else {wl.pointer_destroy(lk.pointer)}
			lk.pointer = nil
		}
	},
	name = proc "c" (data: rawptr, seat: ^wl.Seat, name: cstring) {},
}

// The pointer is hidden over the lock screen.
@(private = "file")
pointer_listener := wl.Pointer_Listener {
	enter = proc "c" (data: rawptr, self: ^wl.Pointer, serial: u32, surface: ^wl.Surface, x, y: wl.Fixed) {
		wl.pointer_set_cursor(self, serial, nil, 0, 0)
		// The travel counts from where the pointer entered: entering itself
		// (sway re-sends it when outputs change) is no movement.
		lk.ptr_last, lk.ptr_have = {f32(x) / 256, f32(y) / 256}, true
	},
	leave = proc "c" (data: rawptr, self: ^wl.Pointer, serial: u32, surface: ^wl.Surface) {},
	// --screen-off: only real movement wakes the monitors; sway re-sends the
	// pointer position when outputs power off, and a mouse can report a
	// stray sub-pixel tick (see screen_power_step).
	motion = proc "c" (data: rawptr, self: ^wl.Pointer, t: u32, x, y: wl.Fixed) {
		p := [2]f32{f32(x) / 256, f32(y) / 256}
		if lk.ptr_have {lk.ptr_moved += abs(p.x - lk.ptr_last.x) + abs(p.y - lk.ptr_last.y)}
		lk.ptr_last, lk.ptr_have = p, true
	},
	button = proc "c" (data: rawptr, self: ^wl.Pointer, serial, t, button, state: u32) {
		if state == wl.POINTER_BUTTON_STATE_PRESSED {lk.ptr_pressed = true}
	},
	axis = proc "c" (data: rawptr, self: ^wl.Pointer, t: u32, axis: u32, value: wl.Fixed) {},
	frame = proc "c" (data: rawptr, self: ^wl.Pointer) {},
	axis_source = proc "c" (data: rawptr, self: ^wl.Pointer, axis_source: u32) {},
	axis_stop = proc "c" (data: rawptr, self: ^wl.Pointer, t: u32, axis: u32) {},
	axis_discrete = proc "c" (data: rawptr, self: ^wl.Pointer, axis: u32, discrete: i32) {},
	axis_value120 = proc "c" (data: rawptr, self: ^wl.Pointer, axis: u32, value120: i32) {},
	axis_relative_direction = proc "c" (data: rawptr, self: ^wl.Pointer, axis: u32, direction: u32) {},
}

// ---- Keyboard / password -----------------------------------------------------------

@(private = "file")
primary_dirty :: proc() {
	if config.lock_all_monitors {
		for o in lk.outputs {o.dirty = true}
	} else if o := primary_output(); o != nil {o.dirty = true}
}

@(private = "file")
clear_password :: proc() {
	mem.zero_explicit(&lk.pw[0], len(lk.pw))
	lk.pw_len = 0
}

@(private = "file")
submit :: proc() {
	if lk.pw_len == 0 || lk.auth == .Checking {return}
	if time.tick_diff(time.tick_now(), lk.retry_at) > 0 {return}
	sync.guard(&auth_mu)
	copy(auth_pw[:], lk.pw[:lk.pw_len])
	auth_len = lk.pw_len
	clear_password()
	lk.auth = .Checking
	sync.sema_post(&auth_sema)
}

// Returns false when compose swallowed the key (dead key, or the key that
// finished/cancelled a sequence), so it must not repeat.
@(private = "file")
key_press :: proc(key: u32, repeat := false) -> bool {
	code := key + 8
	sym := xkb.state_key_get_one_sym(lk.xkb_state, code)
	ctrl := xkb.state_mod_name_is_active(lk.xkb_state, xkb.MOD_NAME_CTRL, xkb.STATE_MODS_EFFECTIVE) > 0
	primary_dirty()
	if lk.auth == .Checking {return true}
	// Dead keys (AZERTY ^ then e -> ê). Escape/Enter/Backspace while composing
	// only cancel the sequence. The composed text is password material: it is
	// copied in and wiped, never logged.
	if ctrl {
		xkb.compose_reset(&lk.compose)
	} else if !repeat {
		buf: [64]u8
		defer mem.zero_explicit(&buf[0], len(buf))
		switch action, n := xkb.compose_key(&lk.compose, sym, buf[:]); action {
		case .Pass:
		case .Swallow:
			return false
		case .Text:
			add_password_text(buf[:n])
			return false
		}
	}
	switch sym {
	case xkb.KEY_Return, xkb.KEY_KP_Enter:
		submit()
		return true
	case xkb.KEY_Escape:
		clear_password()
		return true
	case xkb.KEY_BackSpace:
		if ctrl {
			clear_password()
		} else if lk.pw_len > 0 {
			_, sz := utf8.decode_last_rune(lk.pw[:lk.pw_len])
			mem.zero_explicit(&lk.pw[lk.pw_len - sz], sz)
			lk.pw_len -= sz
		}
		return true
	}
	if ctrl {
		if sym == xkb.KEY_u {clear_password()}
		return true
	}
	buf: [16]u8
	n := int(xkb.state_key_get_utf8(lk.xkb_state, code, &buf[0], len(buf)))
	if n > 0 {add_password_text(buf[:n])}
	mem.zero_explicit(&buf[0], len(buf))
	return true
}

@(private = "file")
add_password_text :: proc(text: []u8) {
	n := len(text)
	if n > 0 && text[0] >= 0x20 && text[0] != 0x7f && lk.pw_len + n < len(lk.pw) {
		copy(lk.pw[lk.pw_len:], text)
		lk.pw_len += n
		if lk.auth == .Wrong {lk.auth = .Idle}
	}
}

// Caps Lock and the active layout's name (when the keymap has several).
// Returns true when either changed.
@(private = "file")
update_layout :: proc() -> bool {
	caps := xkb.state_mod_name_is_active(lk.xkb_state, xkb.MOD_NAME_CAPS, xkb.STATE_MODS_LOCKED) > 0
	name: cstring
	if xkb.keymap_num_layouts(lk.xkb_keymap) > 1 {
		name = xkb.keymap_layout_get_name(lk.xkb_keymap, xkb.state_serialize_layout(lk.xkb_state, xkb.STATE_LAYOUT_EFFECTIVE))
	}
	if caps == lk.caps && string(name) == lk.layout {return false}
	lk.caps = caps
	delete(lk.layout)
	lk.layout = name != nil ? strings.clone(string(name)) : ""
	return true
}

@(private = "file")
keyboard_listener := wl.Keyboard_Listener {
	keymap = proc "c" (data: rawptr, self: ^wl.Keyboard, format: u32, fd: i32, size: u32) {
		context = g_lock_ctx
		defer posix.close(posix.FD(fd))
		if format != wl.KEYBOARD_KEYMAP_FORMAT_XKB_V1 {return}
		m := posix.mmap(nil, uint(size), {.READ}, {.PRIVATE}, posix.FD(fd), 0)
		if m == posix.MAP_FAILED {return}
		defer posix.munmap(m, uint(size))
		if lk.xkb_ctx == nil {lk.xkb_ctx = xkb.context_new(xkb.CONTEXT_NO_FLAGS)}
		keymap := xkb.keymap_new_from_string(lk.xkb_ctx, cstring(m), xkb.KEYMAP_FORMAT_TEXT_V1, xkb.KEYMAP_COMPILE_NO_FLAGS)
		if keymap == nil {return}
		if lk.xkb_state != nil {xkb.state_unref(lk.xkb_state)}
		if lk.xkb_keymap != nil {xkb.keymap_unref(lk.xkb_keymap)}
		lk.xkb_keymap = keymap
		lk.xkb_state = xkb.state_new(keymap)
		xkb.compose_init(&lk.compose, lk.xkb_ctx)
		update_layout()
	},
	enter = proc "c" (data: rawptr, self: ^wl.Keyboard, serial: u32, surface: ^wl.Surface, keys: ^wl.Array) {},
	leave = proc "c" (data: rawptr, self: ^wl.Keyboard, serial: u32, surface: ^wl.Surface) {
		context = g_lock_ctx
		lk.repeat_key = 0
		xkb.compose_reset(&lk.compose)
	},
	key = proc "c" (data: rawptr, self: ^wl.Keyboard, serial, t, key, state: u32) {
		context = g_lock_ctx
		if lk.xkb_state == nil {return}
		if state == wl.KEYBOARD_KEY_STATE_PRESSED {lk.screens_woken = true}
		if state == wl.KEYBOARD_KEY_STATE_PRESSED {
			eaten := !key_press(key)
			// Only Backspace repeats: a held letter must not type a password.
			sym := xkb.state_key_get_one_sym(lk.xkb_state, key + 8)
			if eaten {
				lk.repeat_key = 0
			} else if sym == xkb.KEY_BackSpace && lk.repeat_rate > 0 {
				lk.repeat_key = key
				lk.repeat_at = time.tick_add(time.tick_now(), time.Duration(lk.repeat_delay) * time.Millisecond)
			}
		} else if lk.repeat_key == key {
			lk.repeat_key = 0
		}
	},
	modifiers = proc "c" (data: rawptr, self: ^wl.Keyboard, serial, depressed, latched, locked, group: u32) {
		context = g_lock_ctx
		if lk.xkb_state == nil {return}
		xkb.state_update_mask(lk.xkb_state, depressed, latched, locked, 0, 0, group)
		if update_layout() {primary_dirty()}
	},
	repeat_info = proc "c" (data: rawptr, self: ^wl.Keyboard, rate, delay: i32) {
		lk.repeat_rate = rate
		lk.repeat_delay = delay
	},
}

// ---- Workers -----------------------------------------------------------------------

@(private = "file")
check_password :: proc(pw: []u8) -> bool {
	when LOCK_TEST_AUTH {
		if os.get_env("WLPERCH_LOCK_TEST", context.temp_allocator) == "1" {
			time.sleep(300 * time.Millisecond) // like a real check, so "Checking…" shows
			return string(pw) == LOCK_TEST_PASSWORD
		}
	}
	return pam_check_password(lk.pam_service, pw, proc(msg: string) {
		sync.guard(&info.mu)
		delete(info.pam_msg)
		info.pam_msg = strings.clone(msg)
		wake('i')
	})
}

@(private = "file")
auth_thread :: proc() {
	local: [512]u8
	for {
		sync.sema_wait(&auth_sema)
		n: int
		{
			sync.guard(&auth_mu)
			n = auth_len
			copy(local[:], auth_pw[:n])
			mem.zero_explicit(&auth_pw[0], len(auth_pw))
			auth_len = 0
		}
		ok := check_password(local[:n])
		mem.zero_explicit(&local[0], len(local))
		free_all(context.temp_allocator)
		wake(ok ? 'y' : 'n')
	}
}

// Notification count and weather from the daemon (when it runs); the
// playing track over MPRIS and the battery from sysfs ourselves.
@(private = "file")
info_thread :: proc() {
	bus := config.lock_media ? media_open_bus() : nil
	last_playing: string
	for {
		unread, dnd := -1, false
		apps, weather_s: string
		bt := strings.builder_make(context.temp_allocator)
		if reply, ok := ipc_query("lockinfo"); ok {
			for line in strings.split_lines(reply, context.temp_allocator) {
				k, _, v := strings.partition(line, " ")
				switch k {
				case "unread":  unread = strconv.parse_int(v) or_else -1
				case "dnd":     dnd = v == "1"
				case "apps":    apps = v
				case "weather": weather_s = v
				case "bt":      if config.lock_bluetooth {fmt.sbprintln(&bt, v)}
				}
			}
		}
		media_s: string
		playing := false
		if bus != nil {
			players := media_scan(bus)
			for p in players {
				if p.status == .Playing && p.bus_name != last_playing {
					delete(last_playing)
					last_playing = strings.clone(p.bus_name)
				}
			}
			if i := media_pick(players[:], "", last_playing); i >= 0 && players[i].status != .Stopped {
				p := players[i]
				track := p.title != "" ? p.title : p.identity
				if p.artist != "" && p.title != "" {track = fmt.tprintf("%s — %s", p.artist, p.title)}
				media_s = strings.clone(clip(track, 48), context.temp_allocator) // players are freed below
				playing = p.status == .Playing
			}
			for &p in players {media_player_free(&p)}
			delete(players)
		}
		bat, charging := read_battery()
		{
			sync.guard(&info.mu)
			changed := info.unread != unread || info.dnd != dnd || info.apps != apps || info.media != media_s ||
				info.playing != playing || info.battery != bat || info.charging != charging || info.weather != weather_s ||
				info.bt != strings.to_string(bt)
			if changed {
				delete(info.apps); delete(info.media); delete(info.weather); delete(info.bt)
				info.unread, info.dnd, info.playing, info.battery, info.charging = unread, dnd, playing, bat, charging
				info.apps = strings.clone(apps)
				info.media = strings.clone(media_s)
				info.weather = strings.clone(weather_s)
				info.bt = strings.clone(strings.to_string(bt))
				wake('i')
			}
		}
		free_all(context.temp_allocator)
		time.sleep(2 * time.Second)
	}
}

// System battery (not a mouse or headset): percent and charging, or -1.
@(private = "file")
read_battery :: proc() -> (pct: int, charging: bool) {
	pct = -1
	dir := "/sys/class/power_supply"
	fd, err := os.open(dir)
	if err != nil {return}
	defer os.close(fd)
	entries, _ := os.read_dir(fd, -1, context.temp_allocator)
	read :: proc(path: string) -> string {
		data, err := os.read_entire_file(path, context.temp_allocator)
		return err == nil ? strings.trim_space(string(data)) : ""
	}
	for e in entries {
		base := fmt.tprintf("%s/%s", dir, e.name)
		if read(fmt.tprintf("%s/type", base)) != "Battery" {continue}
		if read(fmt.tprintf("%s/scope", base)) == "Device" {continue}
		v, ok := strconv.parse_int(read(fmt.tprintf("%s/capacity", base)))
		if !ok {continue}
		st := read(fmt.tprintf("%s/status", base))
		return v, st == "Charging" || st == "Full"
	}
	return
}

// Daemon side of the "lockinfo" query: counts and app names only, never
// notification text.
lock_info_reply :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "unread %d\ndnd %d\n", notifs.owner ? notif_unread() : -1, int(notifs.dnd))
	apps: [dynamic]string
	apps.allocator = context.temp_allocator
	#reverse for n in notifs.list {
		if n.read || n.transient || n.app == "" || len(apps) == 3 {continue}
		seen := false
		for a in apps {if a == n.app {seen = true}}
		if !seen {append(&apps, clip(n.app, 20))}
	}
	if len(apps) > 0 {
		strings.write_string(&b, "apps ")
		for a, i in apps {
			if i > 0 {strings.write_string(&b, ", ")}
			for r in a {if r != '\n' {strings.write_rune(&b, r)}}
		}
		strings.write_byte(&b, '\n')
	}
	{
		sync.guard(&weather.mu)
		if weather.ok {
			icon, _ := weather_desc(weather.code, weather.is_day)
			fmt.sbprintf(&b, "weather %s %.0f°\n", icon, weather.temp)
		}
	}
	bluetooth_lock_lines(&b)
	return strings.to_string(b)
}

// ---- Drawing ------------------------------------------------------------------------

@(private = "file")
Cv :: struct {
	px:   []u32,
	w, h: int,
	s:    f32,
}

@(private = "file")
blend :: proc(dst: ^u32, rgb: u32, a: f32) {
	if a <= 0 {return}
	inv := 1 - a
	d := dst^
	nr := u32(f32((rgb >> 16) & 0xff) * a + f32((d >> 16) & 0xff) * inv + 0.5)
	ng := u32(f32((rgb >> 8) & 0xff) * a + f32((d >> 8) & 0xff) * inv + 0.5)
	nb := u32(f32(rgb & 0xff) * a + f32(d & 0xff) * inv + 0.5)
	dst^ = 0xff000000 | min(nr, 255) << 16 | min(ng, 255) << 8 | min(nb, 255)
}

// Anti-aliased rounded rectangle (logical coordinates), filled or as a ring.
@(private = "file")
round_rect :: proc(cv: ^Cv, x, y, w, h, radius: f32, rgb: u32, alpha: f32, ring: f32 = 0) {
	s := cv.s
	rx, ry, rw, rh, rr := x * s, y * s, w * s, h * s, radius * s
	x0, y0 := max(int(rx) - 1, 0), max(int(ry) - 1, 0)
	x1, y1 := min(int(math.ceil(rx + rw)) + 1, cv.w), min(int(math.ceil(ry + rh)) + 1, cv.h)
	for py in y0 ..< y1 {
		for px in x0 ..< x1 {
			fx, fy := f32(px) + 0.5, f32(py) + 0.5
			cx := clamp(fx, rx + rr, rx + rw - rr)
			cy := clamp(fy, ry + rr, ry + rh - rr)
			dx, dy := fx - cx, fy - cy
			d := math.sqrt(dx * dx + dy * dy) - rr
			cov := clamp(0.5 - d, 0, 1)
			if ring > 0 {cov = min(cov, clamp(d + ring * s + 0.5, 0, 1))}
			if cov > 0 {blend(&cv.px[py * cv.w + px], rgb, cov * alpha)}
		}
	}
}

@(private = "file")
text_w :: proc(cv: ^Cv, f: ^Soft_Font, size: f32, s: string) -> f32 {
	return soft_text_width(f, size * cv.s, s) / cv.s
}

@(private = "file")
text :: proc(cv: ^Cv, f: ^Soft_Font, size, x, baseline: f32, s: string, rgb: u32, alpha: f32 = 1) {
	soft_draw_text(cv.px, cv.w, cv.h, f, size * cv.s, x * cv.s, baseline * cv.s, s, rgb, alpha)
}

@(private = "file")
text_c :: proc(cv: ^Cv, f: ^Soft_Font, size, cx, baseline: f32, s: string, rgb: u32, alpha: f32 = 1) {
	text(cv, f, size, cx - text_w(cv, f, size, s) / 2, baseline, s, rgb, alpha)
}

// The frosted screenshot's tint toward the theme's background colour. ~1/3
// at the default dim: the screen shows through, the clock stays readable.
// (0.3 + dim made a dark desktop look like a plain background.)
@(private = "file")
frost_tint :: proc() -> (tint: u32, mix: f32) {
	return theme_light ? config.lock_background_light : config.lock_background, clamp(0.15 + config.lock_dim * 0.5, 0, 0.9)
}

// Solid colour with a soft vignette, the configured picture (cover-fit,
// optionally blurred by sampling a smaller copy) darkened by dim, or the
// frosted screenshot tinted toward the theme's background colour.
@(private = "file")
build_background :: proc(o: ^Lock_Output, bw, bh: i32) {
	delete(o.bg)
	o.bg = make([]u32, int(bw * bh))
	o.bg_w, o.bg_h = bw, bh
	W, H := int(bw), int(bh)
	if o.blur.px != nil {
		tint, mix := frost_tint()
		blur_draw(o.bg, W, H, o.blur, tint, mix)
		return
	}
	if lk.image != nil {
		// Source rectangle that covers the output with the image's aspect.
		iw, ih := f32(lk.img_w), f32(lk.img_h)
		sc := max(f32(W) / iw, f32(H) / ih)
		ox, oy := (iw - f32(W) / sc) / 2, (ih - f32(H) / sc) / 2
		// Blur: sample a copy this many times smaller, bilinearly upscaled.
		div := max(1, config.lock_blur)
		sw, sh := max(W / div, 1), max(H / div, 1)
		small := make([]u32, sw * sh, context.temp_allocator)
		// Image columns each small pixel covers (box-averaged, at most ~4x4 taps).
		cx0 := make([]int, sw, context.temp_allocator)
		cx1 := make([]int, sw, context.temp_allocator)
		xstep := make([]int, sw, context.temp_allocator)
		for x in 0 ..< sw {
			ax := ox + f32(x) * f32(W) / f32(sw) / sc
			bx := ox + f32(x + 1) * f32(W) / f32(sw) / sc
			cx0[x], cx1[x] = int(ax), max(int(bx), int(ax) + 1)
			xstep[x] = max(int((bx - ax) / 4), 1)
		}
		#no_bounds_check for y in 0 ..< sh { // indices clamped / within sw, sh
			ay := oy + f32(y) * f32(H) / f32(sh) / sc
			by := oy + f32(y + 1) * f32(H) / f32(sh) / sc
			ystep := max(int((by - ay) / 4), 1)
			for x in 0 ..< sw {
				r, g, b, n: u32
				for yy := int(ay); yy < max(int(by), int(ay) + 1); yy += ystep {
					row := lk.image[clamp(yy, 0, lk.img_h - 1) * lk.img_w:]
					for xx := cx0[x]; xx < cx1[x]; xx += xstep[x] {
						p := row[clamp(xx, 0, lk.img_w - 1)]
						r += (p >> 16) & 0xff; g += (p >> 8) & 0xff; b += p & 0xff; n += 1
					}
				}
				if n == 1 {
					small[y * sw + x] = r << 16 | g << 8 | b
				} else {
					inv := 1 / f32(n) // three integer divisions per pixel cost more than the sampling
					small[y * sw + x] = u32(f32(r) * inv + 0.5) << 16 | u32(f32(g) * inv + 0.5) << 8 | u32(f32(b) * inv + 0.5)
				}
			}
		}
		// Dimmed = mixed toward black. (Unblurred: no upscale needed.)
		if sw == W && sh == H {
			kd := u32(clamp(1 - config.lock_dim, 0, 1) * 256)
			for p, i in small {
				o.bg[i] = 0xff000000 | ((p & 0xff00ff) * kd) >> 8 & 0xff00ff | ((p & 0xff00) * kd) >> 8 & 0xff00
			}
		} else {
			blur_draw(o.bg, W, H, {small, sw, sh}, 0, config.lock_dim, grain = false)
		}
		return
	}
	c := theme_light ? config.lock_background_light : config.lock_background
	cr, cg, cb := f32((c >> 16) & 0xff), f32((c >> 8) & 0xff), f32(c & 0xff)
	colv := make([]f32, W, context.temp_allocator)
	for x in 0 ..< W {
		dx := f32(x) / f32(W) - 0.5
		colv[x] = 1.12 - 0.45 * dx * dx // lighter behind the clock
	}
	#no_bounds_check for y in 0 ..< H {
		dy := (f32(y) / f32(H) - 0.45) * 1.6
		rowv := 0.45 * dy * dy
		row := o.bg[y * W:]
		for x in 0 ..< W {
			v := colv[x] - rowv
			row[x] = 0xff000000 | u32(min(cr * v, 255)) << 16 | u32(min(cg * v, 255)) << 8 | u32(min(cb * v, 255))
		}
	}
}

// Whether o shows the password field and status rows ([lock] all_monitors),
// or only the clock.
@(private = "file")
output_full :: proc(o: ^Lock_Output) -> bool {
	return config.lock_all_monitors || o == primary_output()
}

@(private = "file")
primary_output :: proc() -> ^Lock_Output {
	// The focused output keeps the UI even before its surface is configured
	// (what the pre-rendered frames assume).
	for o in lk.outputs {if o.conn == lk.primary && o.surface != nil {return o}}
	for o in lk.outputs {if o.configured {return o}}
	return nil
}

// Everything draw_ui needs from the main loop's state, copied there: frames
// are also drawn on other threads (the pre-render, the animation's workers),
// and the password itself never leaves the main thread (only its length).
@(private = "file")
Lock_UI :: struct {
	now:      time.Time,
	full:     bool, // the password field and status rows (primary output)
	fg, fg2:  u32,
	pw_n:     int, // characters typed
	auth:     Auth_State,
	caps:     bool,
	fails:    int,
	wait:     time.Duration, // left of the retry wait
	layout:   [64]u8,
	layout_n: int,
}

@(private = "file")
lock_ui :: proc(full: bool) -> (u: Lock_UI) {
	u.now = time.now()
	u.full = full
	u.fg, u.fg2 = lock_fg, lock_fg2
	u.pw_n = utf8.rune_count(lk.pw[:lk.pw_len])
	u.auth, u.caps, u.fails = lk.auth, lk.caps, lk.fails
	u.wait = time.tick_diff(time.tick_now(), lk.retry_at)
	u.layout_n = copy(u.layout[:], lk.layout)
	return
}

@(private = "file")
draw_ui :: proc(cv: ^Cv, W, H: f32, ui: ^Lock_UI) {
	r, ok := clock_read(local_region, ui.now)
	if !ok {return}
	full := ui.full
	lock_fg, lock_fg2 := ui.fg, ui.fg2
	hour := int(r.dt.hour)
	clock: string
	if config.clock_24h {
		clock = fmt.tprintf("%02d:%02d", hour, r.dt.minute)
	} else {
		clock = fmt.tprintf("%d:%02d", (hour + 11) % 12 + 1, r.dt.minute)
	}
	date := fmt.tprintf("%s %d %s", WEEKDAYS[weekday_of(r.dt)], r.dt.day, MONTHS[r.dt.month - 1])

	sync.lock(&info.mu)
	defer sync.unlock(&info.mu)
	if full && info.weather != "" {date = fmt.tprintf("%s   ·   %s", date, info.weather)}

	cy := H * 0.40
	text_c(cv, &soft_regular, 132, W / 2, cy, clock, lock_fg, 0.96)
	text_c(cv, &soft_regular, 24, W / 2, cy + 50, date, lock_fg2, 0.9)
	if !full {return}

	// Password field.
	px, py := W / 2 - PILL_W / 2, cy + 98
	ring := lock_fg
	ring_a := f32(0.22)
	switch ui.auth {
	case .Checking: ring, ring_a = C_BLUE, 0.95
	case .Wrong:    ring, ring_a = C_RED, 0.95
	case .Idle:     if ui.caps {ring, ring_a = C_YELLOW, 0.8}
	}
	round_rect(cv, px, py, PILL_W, PILL_H, PILL_H / 2, lock_fg, 0.08)
	round_rect(cv, px, py, PILL_W, PILL_H, PILL_H / 2, ring, ring_a, 1.5)
	text(cv, &soft_regular, 20, px + 18, py + PILL_H / 2 + 7, ICON_LOCK, lock_fg, 0.55)
	n := ui.pw_n
	if ui.auth == .Checking {
		text_c(cv, &soft_regular, 16, W / 2, py + PILL_H / 2 + 6, "Checking…", C_BLUE)
	} else if n == 0 {
		text_c(cv, &soft_regular, 16, W / 2, py + PILL_H / 2 + 6, "Type your password", lock_fg, 0.42)
	} else {
		DOT :: 14
		max_dots := int((PILL_W - 100) / DOT)
		shown := min(n, max_dots)
		x0 := W / 2 - f32(shown - 1) * DOT / 2
		for i in 0 ..< shown {
			round_rect(cv, x0 + f32(i) * DOT - 4.5, py + PILL_H / 2 - 4.5, 9, 9, 4.5, lock_fg, 0.9)
		}
	}

	// One line under the field: what went wrong, else PAM's info, else Caps Lock.
	msg, col := "", u32(0)
	wait := ui.wait
	switch {
	case wait > 0 && ui.auth != .Checking:
		msg, col = fmt.tprintf("Wrong password · try again in %d s", int(math.ceil(time.duration_seconds(wait)))), C_RED
	case ui.auth == .Wrong:
		msg, col = ui.fails > 1 ? fmt.tprintf("Wrong password (%d attempts)", ui.fails) : "Wrong password", C_RED
	case ui.auth == .Checking && info.pam_msg != "":
		msg, col = info.pam_msg, lock_fg2
	case ui.caps:
		msg, col = fmt.tprintf("%s  Caps Lock is on", ICON_CAPS), C_YELLOW
	}
	if msg != "" {text_c(cv, &soft_regular, 15, W / 2, py + PILL_H + 30, msg, col)}
	if layout := string(ui.layout[:ui.layout_n]); layout != "" {
		text_c(cv, &soft_regular, 13, W / 2, py + PILL_H + (msg != "" ? 54 : 30), fmt.tprintf("%s  %s", ICON_KEYBOARD, layout), lock_fg, 0.5)
	}

	// Status row along the bottom.
	Item :: struct {icon, label: string, col: u32}
	items: [dynamic]Item
	items.allocator = context.temp_allocator
	if config.lock_notifications && info.unread > 0 {
		label := fmt.tprintf("%d new notification%s", info.unread, info.unread == 1 ? "" : "s")
		if info.apps != "" {label = fmt.tprintf("%s · %s", label, info.apps)}
		append(&items, Item{info.dnd ? ICON_BELL_OFF : ICON_BELL, label, C_BLUE})
	}
	if config.lock_media && info.media != "" {
		append(&items, Item{info.playing ? ICON_MUSIC : ICON_PAUSE, info.media, info.playing ? C_GREEN : C_MUTED})
	}
	if info.battery >= 0 {
		icon, c := battery_glyph(info.battery, info.charging)
		append(&items, Item{icon, fmt.tprintf("%d%%", info.battery), c})
	}
	draw_bt_row(cv, W, H - 44 - (len(items) > 0 ? 34 : 0), lock_fg)
	if len(items) == 0 {return}
	SZ :: 15
	GAP :: 40
	total: f32
	for it, i in items {
		total += text_w(cv, &soft_regular, SZ + 3, it.icon) + 8 + text_w(cv, &soft_regular, SZ, it.label)
		if i > 0 {total += GAP}
	}
	x := W / 2 - total / 2
	base := H - 44
	for it, i in items {
		if i > 0 {x += GAP}
		text(cv, &soft_regular, SZ + 3, x, base + 1, it.icon, it.col)
		x += text_w(cv, &soft_regular, SZ + 3, it.icon) + 8
		text(cv, &soft_regular, SZ, x, base, it.label, lock_fg, 0.8)
		x += text_w(cv, &soft_regular, SZ, it.label)
	}
}

// One lockinfo "bt" line: battery (-1 unknown), charging, BlueZ icon, name.
Lock_BT :: struct {
	battery:  int,
	charging: bool,
	icon:     string,
	name:     string,
}

lock_bt_parse :: proc(line: string) -> (d: Lock_BT, ok: bool) {
	f := strings.fields(line, context.temp_allocator)
	if len(f) < 3 {return}
	d.battery = clamp(strconv.parse_int(f[0]) or_else -1, -1, 100)
	d.charging = f[1] == "1"
	d.icon = f[2] == "-" ? "" : f[2]
	// The name is everything after the third field, inner spaces kept.
	rest := line
	for _ in 0 ..< 3 {
		_, _, rest = strings.partition(strings.trim_left_space(rest), " ")
	}
	d.name = strings.trim_space(rest)
	if d.name == "" {d.name = "Bluetooth device"}
	return d, true
}

// Connected Bluetooth devices, centred on one line above the status row:
// icon, name, and the battery when known (red at 20 % or less). Devices that
// don't fit become "+N". Caller holds info.mu.
@(private = "file")
draw_bt_row :: proc(cv: ^Cv, W, base: f32, lock_fg: u32) {
	if info.bt == "" {return}
	SZ :: 14
	GAP :: 28
	Dev :: struct {icon, name, bat_icon, bat: string, bat_col: u32, w: f32}
	devs: [dynamic]Dev
	devs.allocator = context.temp_allocator
	lines := info.bt
	for line in strings.split_lines_iterator(&lines) {
		d := lock_bt_parse(line) or_continue
		v := Dev{icon = bt_icon(d.icon), name = clip(d.name, 24)}
		v.w = text_w(cv, &soft_regular, SZ + 2, v.icon) + 6 + text_w(cv, &soft_regular, SZ, v.name)
		if d.battery >= 0 {
			v.bat_icon, v.bat_col = battery_glyph(d.battery, d.charging)
			if !d.charging && d.battery <= 20 {v.bat_col = C_RED}
			v.bat = fmt.tprintf("%d%%", d.battery)
			v.w += 10 + text_w(cv, &soft_regular, SZ + 1, v.bat_icon) + 2 + text_w(cv, &soft_regular, SZ, v.bat)
		}
		append(&devs, v)
	}
	if len(devs) == 0 {return}
	n := len(devs)
	more := ""
	total: f32
	for {
		total = 0
		for d, i in devs {total += d.w + (i > 0 ? GAP : 0)}
		if len(devs) < n {
			more = fmt.tprintf("+%d", n - len(devs))
			total += GAP + text_w(cv, &soft_regular, SZ, more)
		}
		if total <= W - 64 || len(devs) == 1 {break}
		pop(&devs)
	}
	x := W / 2 - total / 2
	for d, i in devs {
		if i > 0 {x += GAP}
		text(cv, &soft_regular, SZ + 2, x, base + 1, d.icon, lock_fg, 0.6)
		x += text_w(cv, &soft_regular, SZ + 2, d.icon) + 6
		text(cv, &soft_regular, SZ, x, base, d.name, lock_fg, 0.7)
		x += text_w(cv, &soft_regular, SZ, d.name)
		if d.bat_icon != "" {
			low := d.bat_col == C_RED
			x += 10
			text(cv, &soft_regular, SZ + 1, x, base + 1, d.bat_icon, d.bat_col)
			x += text_w(cv, &soft_regular, SZ + 1, d.bat_icon) + 2
			text(cv, &soft_regular, SZ, x, base, d.bat, low ? C_RED : lock_fg, low ? 1 : 0.7)
			x += text_w(cv, &soft_regular, SZ, d.bat)
		}
	}
	if more != "" {text(cv, &soft_regular, SZ, x + GAP, base, more, lock_fg, 0.5)}
}

@(private = "file")
render :: proc(o: ^Lock_Output) {
	s := max(o.scale, 1)
	bw, bh := o.w * s, o.h * s
	if bw <= 0 || bh <= 0 {return}
	if o.bg_w != bw || o.bg_h != bh {build_background(o, bw, bh)}
	size := int(bw * bh * 4)
	fd, err := linux.memfd_create("wlperch-lock", {.CLOEXEC})
	if err != .NONE {return}
	defer linux.close(fd)
	if linux.ftruncate(fd, i64(size)) != .NONE {return}
	m := posix.mmap(nil, uint(size), {.READ, .WRITE}, {.SHARED}, posix.FD(fd), 0)
	if m == posix.MAP_FAILED {return}
	cv := Cv{px = ([^]u32)(m)[:bw * bh], w = int(bw), h = int(bh), s = f32(s)}
	copy(cv.px, o.bg)
	ui := lock_ui(output_full(o))
	draw_ui(&cv, f32(o.w), f32(o.h), &ui)
	posix.munmap(m, uint(size))

	pool := wl.shm_create_pool(lk.shm, i32(fd), i32(size))
	buf := wl.shm_pool_create_buffer(pool, 0, bw, bh, bw * 4, wl.SHM_FORMAT_XRGB8888)
	wl.shm_pool_destroy(pool)
	wl.buffer_add_listener(buf, &buffer_listener, nil)
	wl.surface_set_buffer_scale(o.surface, s)
	wl.surface_attach(o.surface, buf, 0, 0)
	wl.surface_damage_buffer(o.surface, 0, 0, bw, bh)
	cb := wl.surface_frame(o.surface)
	wl.callback_add_listener(cb, &frame_listener, o)
	o.frame_pending = true
	o.dirty = false
	wl.surface_commit(o.surface)
	if !o.committed {
		o.committed = true
		log.debugf("lock: timing: first frame on %s committed at +%.1f ms", o.conn, since_lock())
	}
}

// ---- Growing blur ([lock] blur_animate_ms) -------------------------------------------
//
// Each animated output gets a render worker, a thread for the length of the
// animation (plus a Blur_Gang: the steps and the upscale are split over
// three threads). The main loop hands it one job at a time (a free buffer,
// the time on the animation clock the frame will be shown at, a copy of the
// UI state) and keeps dispatching events; the worker blurs a step further,
// draws the frame and wakes the loop, which commits it at the next frame
// callback and hands out the next job right away. So the next frame is drawn
// while the previous one waits for its refresh, every output in parallel;
// the worker spends the rest of that wait blurring on toward the next one.
//
// The clock starts at the first frame callback (the pre-rendered frame is on
// screen); frame 1 is drawn meanwhile, so it follows one refresh later
// without a jump. The static picture the animation converges to (the frosted
// background with its grain) is built on a thread of its own meanwhile; the
// last frame is that picture, after which the output goes back to render().

@(private = "file") ANIM_BUFS :: 2
@(private = "file") ANIM_FRAME_MIN_MS :: 13.0 // ~60 fps at most on faster monitors

@(private = "file")
Anim_Job :: struct {
	final: bool, // the static picture
	buf:   int, // anim_bufs index
	t:     f64, // ms on the animation clock the frame is for
	dt:    f64, // ...and the next one most likely
	tint:  u32,
	mix:   f32,
	light: bool,
	ui:    Lock_UI,
}

@(private = "file")
Anim_Worker :: struct {
	o:             ^Lock_Output,
	worker:        ^thread.Thread,
	go:            sync.Sema, // a job (or quit) was posted
	job:           Anim_Job, // main -> worker while busy
	quit:          bool, // atomic
	done:          bool, // atomic: the job is drawn
	busy:          bool, // main loop: a job is out
	// The static picture, from its own thread (static_sema once it's there).
	static_thread: ^thread.Thread,
	static_tried:  bool,
	static_sema:   sync.Sema,
	static_px:     []u32,
	static_tint:   u32,
	static_mix:    f32,
	static_light:  bool,
	static_ms:     f64,
	// Timing log (written by the worker before `done`).
	jobs:          int,
	wall:          [2]f64, // sum, max (ms)
	first:         [4]f64, // the first frames' (ms)
	cpu:           [2]f64,
}

@(private = "file")
thread_cpu_ms :: proc() -> f64 {
	ts, _ := linux.clock_gettime(.THREAD_CPUTIME_ID)
	return f64(ts.time_sec) * 1000 + f64(ts.time_nsec) / 1e6
}

// Takes over the capture's unblurred copy (blurred to the start strength).
// Runs on the pre-render threads.
@(private = "file")
anim_begin :: proc(o: ^Lock_Output) {
	if o.anim != nil || o.anim_src.img.px == nil {return}
	o.anim = new(Blur_Anim)
	o.anim^ = blur_anim_init(o.anim_src, o.gang)
	o.anim_src = {}
}

// The animation's current picture, upscaled and tinted (no grain), a third
// of the rows on each of the gang's threads.
@(private = "file")
anim_background :: proc(o: ^Lock_Output, px: []u32, W, H: int, tint: u32, mix: f32) {
	Job :: struct {px: []u32, W, H: int, img: Blur_Image, tint: u32, mix: f32}
	j := Job{px, W, H, blur_anim_image(o.anim), tint, mix}
	blur_gang_run(o.gang, &j, proc(data: rawptr, part: int) {
		j := (^Job)(data)
		blur_draw_fast(j.px, j.W, j.H, j.img, j.tint, j.mix, j.H * part / BLUR_GANG, j.H * (part + 1) / BLUR_GANG)
	})
}

// The frame buffers, mapped (on a pre-render thread; the wl_buffers are
// made on the main thread from the fds). Their pages are faulted in by the
// first frames, the rows split over the gang. False: none made.
@(private = "file")
anim_alloc :: proc(o: ^Lock_Output, bw, bh: i32) -> bool {
	size := int(bw) * int(bh) * 4
	for &b, i in o.anim_bufs {
		fd, err := linux.memfd_create("wlperch-lock", {.CLOEXEC})
		m: rawptr
		if err == .NONE {
			err = linux.ftruncate(fd, i64(size))
			if err == .NONE {m, err = linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, fd)}
			if err != .NONE {linux.close(fd)}
		}
		if err != .NONE {
			for &c in o.anim_bufs[:i] {
				posix.munmap(raw_data(c.px), uint(len(c.px) * 4))
				linux.close(c.fd)
				c = {}
			}
			return false
		}
		b = {px = ([^]u32)(m)[:int(bw) * int(bh)], w = bw, h = bh, fd = fd}
	}
	return true
}

// The output's refresh period (ms).
@(private = "file")
anim_refresh :: proc(o: ^Lock_Output) -> f64 {
	return o.refresh > 0 ? 1e6 / f64(o.refresh) : 1000.0 / 60
}

// Ms per frame the animation runs at: the refresh period, or a multiple of
// it that is at least ANIM_FRAME_MIN_MS.
@(private = "file")
anim_interval :: proc(o: ^Lock_Output) -> f64 {
	tick := anim_refresh(o)
	return tick * max(math.ceil(ANIM_FRAME_MIN_MS / tick - 0.01), 1)
}

@(private = "file")
anim_worker :: proc(w: ^Anim_Worker) {
	context.logger = g_lock_ctx.logger
	o := w.o
	dur := f64(max(config.lock_blur_animate_ms, 1))
	for {
		sync.sema_wait(&w.go)
		if sync.atomic_load(&w.quit) {return}
		t0, c0 := time.tick_now(), thread_cpu_ms()
		h0 := o.gang != nil ? sync.atomic_load(&o.gang.cpu_ns) : 0
		j := &w.job
		b := &o.anim_bufs[j.buf]
		W, H := int(b.w), int(b.h)
		if j.final {
			if w.static_thread != nil {sync.sema_wait(&w.static_sema)}
			if w.static_px == nil {w.static_px = make([]u32, W * H); w.static_mix = -1} // no thread for it
			if w.static_tint != j.tint || w.static_mix != j.mix {
				// The theme changed while animating.
				blur_draw(w.static_px, W, H, o.blur, j.tint, j.mix)
				w.static_tint, w.static_mix, w.static_light = j.tint, j.mix, j.light
			}
			copy(b.px, w.static_px)
		} else {
			blur_anim_step(o.anim, blur_anim_sigma_at(o.anim, j.t / dur))
			anim_background(o, b.px, W, H, j.tint, j.mix)
		}
		cv := Cv{px = b.px, w = W, h = H, s = f32(o.pre.scale)}
		draw_ui(&cv, f32(o.pre.w), f32(o.pre.h), &j.ui)
		free_all(context.temp_allocator)
		wall := time.duration_milliseconds(time.tick_since(t0))
		if w.jobs < len(w.first) {w.first[w.jobs] = wall}
		w.jobs += 1
		w.wall = {w.wall[0] + wall, max(w.wall[1], wall)}
		final, t_next := j.final, j.t + j.dt
		sync.atomic_store(&w.done, true) // w.job is the main loop's again
		wake('r')
		// While the frame waits for its refresh: blur on to where the next
		// one will most likely be, so its job is mostly drawing.
		if !final && t_next < dur {blur_anim_step(o.anim, blur_anim_sigma_at(o.anim, t_next / dur))}
		free_all(context.temp_allocator)
		cpu := thread_cpu_ms() - c0
		if o.gang != nil {cpu += f64(sync.atomic_load(&o.gang.cpu_ns) - h0) / 1e6} // and the helpers'
		w.cpu = {w.cpu[0] + cpu, max(w.cpu[1], cpu)}
	}
}

// The exact static background (blur_draw, with grain), for the last frame.
@(private = "file")
anim_static_thread :: proc(w: ^Anim_Worker) {
	t0 := time.tick_now()
	o := w.o
	W, H := int(o.pre.w * o.pre.scale), int(o.pre.h * o.pre.scale)
	w.static_px = make([]u32, W * H)
	blur_draw(w.static_px, W, H, o.blur, w.static_tint, w.static_mix)
	free_all(context.temp_allocator)
	w.static_ms = time.duration_milliseconds(time.tick_since(t0))
	sync.sema_post(&w.static_sema)
}

// Starts an output's worker on frame 1: before the lock is requested, right
// after the pre-render.
@(private = "file")
anim_start :: proc(o: ^Lock_Output) -> bool {
	w := new(Anim_Worker)
	w.o = o
	w.worker = thread.create_and_start_with_poly_data(w, anim_worker)
	if w.worker == nil {
		free(w)
		return false
	}
	o.aw = w
	o.anim_ready = -1
	// The pre-rendered frame shows at the clock's zero, as if committed a
	// refresh before: frame 1 is for one refresh after.
	o.anim_commit_t = -anim_interval(o)
	anim_kick(o)
	return true
}

// Hands the worker the next frame when it's idle and a buffer is free.
@(private = "file")
anim_kick :: proc(o: ^Lock_Output) {
	w := o.aw
	if w == nil || w.busy || o.anim_ready >= 0 || o.anim_final {return}
	buf := -1
	for b, i in o.anim_bufs {if !b.busy && b.buffer != nil {buf = i; break}}
	if buf < 0 {return} // again on the release
	// Committed at the next frame callback, shown a refresh later.
	t := o.anim_commit_t + 2 * anim_interval(o)
	full := o.surface == nil ? o.pre.full : output_full(o)
	tint, mix := frost_tint()
	if !w.static_tried && (o.anim_frames >= 2 || t >= f64(config.lock_blur_animate_ms)) {
		// The static picture, once the first (costlier) frames are out of
		// the way. (Without a thread the last frame builds it.)
		w.static_tried = true
		w.static_tint, w.static_mix, w.static_light = tint, mix, theme_light
		w.static_thread = thread.create_and_start_with_poly_data(w, anim_static_thread)
	}
	w.job = {final = t >= f64(config.lock_blur_animate_ms), buf = buf, t = t, dt = anim_interval(o), tint = tint, mix = mix, light = theme_light, ui = lock_ui(full)}
	if w.job.final {o.dirty = false} // the last frame shows everything up to now
	o.anim_final = w.job.final
	w.busy = true
	sync.sema_post(&w.go)
}

// Every main-loop pass while the output animates: collects the worker's
// frame, commits it at the frame callback, hands out the next.
@(private = "file")
anim_service :: proc(o: ^Lock_Output) {
	w := o.aw
	if w.busy && sync.atomic_load(&w.done) {
		sync.atomic_store(&w.done, false)
		w.busy = false
		o.anim_ready = w.job.buf
	}
	if o.anim_ready >= 0 && lk.anim_started && o.configured && o.surface != nil && !o.frame_pending {
		now := time.tick_now()
		since := time.duration_milliseconds(time.tick_diff(o.anim_last, now))
		if o.anim_frames > 0 && since < ANIM_FRAME_MIN_MS && anim_interval(o) > anim_refresh(o) * 1.5 {
			// A fast monitor: wait for the next frame callback without a
			// new buffer (an empty commit), so it stays near 60 fps.
			cb := wl.surface_frame(o.surface)
			wl.callback_add_listener(cb, &frame_listener, o)
			o.frame_pending = true
			wl.surface_commit(o.surface)
			return
		}
		b := &o.anim_bufs[o.anim_ready]
		b.busy = true
		wl.surface_set_buffer_scale(o.surface, o.pre.scale)
		wl.surface_attach(o.surface, b.buffer, 0, 0)
		wl.surface_damage_buffer(o.surface, 0, 0, b.w, b.h)
		cb := wl.surface_frame(o.surface)
		wl.callback_add_listener(cb, &frame_listener, o)
		o.frame_pending = true
		wl.surface_commit(o.surface)
		if o.anim_frames > 0 {
			o.anim_iv = {o.anim_frames == 1 ? since : min(o.anim_iv[0], since), o.anim_iv[1] + since, max(o.anim_iv[2], since)}
		}
		o.anim_frames += 1
		o.anim_last = now
		o.anim_commit_t = time.duration_milliseconds(time.tick_diff(lk.anim_start, now))
		o.anim_ready = -1
		if o.anim_final {
			anim_finish(o)
			return
		}
	}
	anim_kick(o)
}

// After the last frame's commit: the static picture becomes the output's
// background (unless the theme changed since), and the animation's
// resources go.
@(private = "file")
anim_finish :: proc(o: ^Lock_Output) {
	w := o.aw
	if w.static_px != nil && w.static_light == theme_light {
		delete(o.bg)
		o.bg = w.static_px
		w.static_px = nil
		o.bg_w, o.bg_h = o.pre.w * o.pre.scale, o.pre.h * o.pre.scale
	} else {
		o.bg_w = 0
		o.dirty = true
	}
	anim_end(o)
}

// Stops the worker and frees everything the animation held; afterwards the
// output is drawn by render() like any other. (Destroying the buffer still
// on screen is fine: its pixels are never touched again.)
@(private = "file")
anim_end :: proc(o: ^Lock_Output) {
	if w := o.aw; w != nil {
		sync.atomic_store(&w.quit, true)
		sync.sema_post(&w.go)
		thread.destroy(w.worker)
		if w.static_thread != nil {thread.destroy(w.static_thread)}
		if o.anim_frames > 0 {
			el := time.duration_milliseconds(time.tick_since(lk.anim_start))
			n := f64(max(w.jobs, 1))
			log.debugf("lock: blur animation on %s: %d frames in %.0f ms (%.1f fps), commit interval %.1f/%.1f/%.1f ms (min/avg/max), worker %.1f/%.1f ms per frame (avg/max; frames 1-4: %.1f, %.1f, %.1f, %.1f), CPU %.1f/%.1f ms (all threads), static picture %.1f ms",
				o.conn, o.anim_frames, el, f64(o.anim_frames) * 1000 / max(el, 1), o.anim_iv[0], o.anim_iv[1] / f64(max(o.anim_frames - 1, 1)), o.anim_iv[2],
				w.wall[0] / n, w.wall[1], w.first[0], w.first[1], w.first[2], w.first[3], w.cpu[0] / n, w.cpu[1], w.static_ms)
		}
		delete(w.static_px)
		free(w)
		o.aw = nil
		done := true
		for x in lk.outputs {if x.aw != nil {done = false}}
		if done && lk.loop_max > 0 {log.debugf("lock: longest main-loop pass while animating: %.1f ms", lk.loop_max)}
	}
	if o.anim != nil {
		blur_anim_free(o.anim)
		free(o.anim)
		o.anim = nil
	}
	blur_gang_stop(o.gang)
	o.gang = nil
	delete(o.anim_src.img.px)
	o.anim_src = {}
	for &b in o.anim_bufs {
		if b.buffer != nil {wl.buffer_destroy(b.buffer)} // the compositor keeps its own mapping
		if b.px != nil {posix.munmap(raw_data(b.px), uint(len(b.px) * 4))}
		if b.fd > 0 {linux.close(b.fd)}
		b = {}
	}
	o.anim_ready = -1
	o.anim_final = false
}

// ---- Main ----------------------------------------------------------------------------

// The focused output's name; also records every active output's logical
// size (what its lock surface will be configured to) in lk.rects.
@(private = "file")
focused_output_name :: proc() -> string {
	reply, ok := sway_request(3, "") // GET_OUTPUTS
	if !ok {return ""}
	v, jok := jparse(reply)
	if !jok {return ""}
	focused := ""
	for o in jarr(v) {
		name := jstr(jobj(o, "name"))
		if jbool(jobj(o, "focused")) && focused == "" {focused = strings.clone(name)}
		rect := jobj(o, "rect")
		w, h := i32(jint(jobj(rect, "width"))), i32(jint(jobj(rect, "height")))
		if jbool(jobj(o, "active")) && w > 0 && h > 0 {lk.rects[strings.clone(name)] = {w, h}}
	}
	return focused
}

// ---- Pre-rendered first frame ----------------------------------------------------------

// Draws one output's first frame into a fresh shm file. Runs on its own
// thread (outputs in parallel): only reads shared state, and nothing else
// runs until all are joined.
@(private = "file")
prerender_thread :: proc(o: ^Lock_Output) {
	context.logger = g_lock_ctx.logger
	defer free_all(context.temp_allocator)
	t0 := time.tick_now()
	p := &o.pre
	bw, bh := p.w * p.scale, p.h * p.scale
	// Animated: frame 0 goes into the animation's first buffer (the static
	// background is built meanwhile, for the end).
	if o.anim_src.img.px != nil {
		anim_begin(o)
		ta := time.tick_now()
		if anim_alloc(o, bw, bh) {
			t1 := time.tick_now()
			b := &o.anim_bufs[0]
			anim_background(o, b.px, int(bw), int(bh), p.tint, p.mix)
			cv := Cv{px = b.px, w = int(bw), h = int(bh), s = f32(p.scale)}
			draw_ui(&cv, f32(p.w), f32(p.h), &p.ui)
			p.ok, p.anim = true, true
			log.debugf("lock: pre-rendered %s %dx%d@%d (animated): start %.1f ms, buffers %.1f ms, frame %.1f ms", o.conn, p.w, p.h, p.scale,
				time.duration_milliseconds(time.tick_diff(t0, ta)), time.duration_milliseconds(time.tick_diff(ta, t1)), time.duration_milliseconds(time.tick_since(t1)))
			return
		}
		blur_anim_free(o.anim) // no buffers: the static picture, unanimated
		free(o.anim)
		o.anim = nil
		// (the gang is stopped by anim_end, on the main thread)
	}
	build_background(o, bw, bh)
	t1 := time.tick_now()
	size := int(bw) * int(bh) * 4
	fd, err := linux.memfd_create("wlperch-lock", {.CLOEXEC})
	if err != .NONE {return}
	p.fd = fd
	if linux.ftruncate(fd, i64(size)) != .NONE {return}
	m := posix.mmap(nil, uint(size), {.READ, .WRITE}, {.SHARED}, posix.FD(fd), 0)
	if m == posix.MAP_FAILED {return}
	p.px = ([^]u32)(m)[:bw * bh]
	copy(p.px, o.bg)
	cv := Cv{px = p.px, w = int(bw), h = int(bh), s = f32(p.scale)}
	draw_ui(&cv, f32(p.w), f32(p.h), &p.ui)
	posix.munmap(m, uint(size))
	p.px = nil
	p.ok = true
	log.debugf("lock: pre-rendered %s %dx%d@%d: background %.1f ms, frame %.1f ms", o.conn, p.w, p.h, p.scale,
		time.duration_milliseconds(time.tick_diff(t0, t1)), time.duration_milliseconds(time.tick_since(t1)))
}

// Before locking: every output's first frame, at the size sway reports for it
// (else its mode / scale), drawn in parallel, with its wl_buffer ready.
// Outputs left without one (unknown size, any failure) render on configure.
@(private = "file")
prerender_outputs :: proc() {
	t0 := time.tick_now()
	have_primary := false
	for o in lk.outputs {if o.conn != "" && o.conn == lk.primary {have_primary = true}}
	threads := make([dynamic]^thread.Thread, context.temp_allocator)
	for o, i in lk.outputs {
		p := &o.pre
		p^ = {scale = max(o.scale, 1), fd = -1}
		if !o.ready {continue}
		if r, ok := lk.rects[o.conn]; ok {
			p.w, p.h = r[0], r[1]
		} else {
			// No sway: wl_output's mode, which is exact for integer scales.
			p.w, p.h = o.mode_w / p.scale, o.mode_h / p.scale
			if o.transform & 1 != 0 {p.w, p.h = p.h, p.w}
		}
		when LOCK_TEST_AUTH {
			// Test builds: WLPERCH_LOCK_TEST_PRERENDER=off | skew (a size the configure won't match)
			switch os.get_env("WLPERCH_LOCK_TEST_PRERENDER", context.temp_allocator) {
			case "off":  continue
			case "skew": p.w += 1
			}
		}
		if p.w <= 0 || p.h <= 0 {continue}
		p.full = config.lock_all_monitors || (have_primary ? o.conn == lk.primary : i == 0)
		p.ui = lock_ui(p.full)
		p.tint, p.mix = frost_tint()
		if o.anim_src.img.px != nil {o.gang = blur_gang_start()}
		// Without init_context: the thread gets its own temp allocator.
		if t := thread.create_and_start_with_poly_data(o, prerender_thread); t != nil {
			append(&threads, t)
		} else {
			prerender_thread(o)
		}
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
	n := 0
	for o in lk.outputs {
		p := &o.pre
		if p.ok && p.anim {
			for &b in o.anim_bufs {
				pool := wl.shm_create_pool(lk.shm, i32(b.fd), b.w * b.h * 4)
				b.buffer = wl.shm_pool_create_buffer(pool, 0, b.w, b.h, b.w * 4, wl.SHM_FORMAT_XRGB8888)
				wl.shm_pool_destroy(pool)
				wl.buffer_add_listener(b.buffer, &anim_buffer_listener, &b)
				linux.close(b.fd)
				b.fd = 0
			}
			p.buffer = o.anim_bufs[0].buffer
			// Frame 1 is drawn while the lock is set up.
			if !anim_start(o) {log.warn("lock: no thread for the blur animation")}
			n += 1
		} else if o.gang != nil {
			blur_gang_stop(o.gang) // not animated after all
			o.gang = nil
		}
		if p.ok && !p.anim {
			size := p.w * p.scale * p.h * p.scale * 4
			pool := wl.shm_create_pool(lk.shm, i32(p.fd), size)
			p.buffer = wl.shm_pool_create_buffer(pool, 0, p.w * p.scale, p.h * p.scale, p.w * p.scale * 4, wl.SHM_FORMAT_XRGB8888)
			wl.shm_pool_destroy(pool)
			wl.buffer_add_listener(p.buffer, &buffer_listener, nil)
			n += 1
		}
		if p.fd >= 0 {linux.close(p.fd)}
		p.fd = -1
	}
	log.debugf("lock: pre-rendered %d/%d output(s) in %.1f ms", n, len(lk.outputs), time.duration_milliseconds(time.tick_since(t0)))
}

// From the configure event: commits the pre-rendered frame when it was drawn
// for exactly this size, scale and role. Otherwise drops it (the main loop
// renders) and returns false.
@(private = "file")
commit_prerender :: proc(o: ^Lock_Output) -> bool {
	p := &o.pre
	if p.buffer == nil {return false}
	buf := p.buffer
	p.buffer = nil
	if p.w != o.w || p.h != o.h || p.scale != max(o.scale, 1) || p.full != output_full(o) {
		log.debugf("lock: %s configured %dx%d@%d, pre-rendered %dx%d@%d: rendering again", o.conn, o.w, o.h, o.scale, p.w, p.h, p.scale)
		// Animated: the buffers are the wrong size, the static picture it is.
		if p.anim {anim_end(o)} else {wl.buffer_destroy(buf)}
		return false
	}
	if p.anim {o.anim_bufs[0].busy = true}
	wl.surface_set_buffer_scale(o.surface, p.scale)
	wl.surface_attach(o.surface, buf, 0, 0)
	wl.surface_damage_buffer(o.surface, 0, 0, p.w * p.scale, p.h * p.scale)
	cb := wl.surface_frame(o.surface)
	wl.callback_add_listener(cb, &frame_listener, o)
	o.frame_pending = true
	o.dirty = true // redrawn after this frame: the clock may have moved on, info arrives
	wl.surface_commit(o.surface)
	wl.display_flush(lk.display)
	if !o.committed {
		o.committed = true
		log.debugf("lock: timing: first frame on %s committed at +%.1f ms (pre-rendered)", o.conn, since_lock())
	}
	return true
}

@(private = "file")
load_image :: proc(path: string) {
	if path == "" {return}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	w, h, n: i32
	data := stbi.load(cpath, &w, &h, &n, 4)
	if data == nil {
		log.warnf("lock: cannot read image %s", path)
		return
	}
	defer stbi.image_free(data)
	lk.image = make([]u32, int(w * h))
	lk.img_w, lk.img_h = int(w), int(h)
	for i in 0 ..< int(w * h) {
		p := ([^]u8)(data)[i * 4:]
		lk.image[i] = u32(p[0]) << 16 | u32(p[1]) << 8 | u32(p[2])
	}
}

// background_mode = blur: copy every output and blur it, before locking
// (afterwards only the lock surfaces are visible). Bounded by the capture
// timeout; outputs that fail keep the solid colour.
@(private = "file")
capture_outputs :: proc() {
	t0 := time.tick_now()
	targets := make([]^Capture_Target, len(lk.outputs), context.temp_allocator)
	for o, i in lk.outputs {
		targets[i] = new(Capture_Target, context.temp_allocator)
		targets[i]^ = {output = o.output, transform = o.transform, scale = o.scale, animate = lk.animate, anim_from = config.lock_blur_animate_from}
	}
	n := capture_and_blur(lk.display, lk.shm, targets, config.lock_screenshot_blur)
	for o, i in lk.outputs {
		o.blur = targets[i].result
		if o.blur.px != nil {o.anim_src = targets[i].anim} else {delete(targets[i].anim.img.px)}
	}
	log.infof("lock: screen blurred on %d/%d output(s) in %.1f ms", n, len(targets), time.duration_milliseconds(time.tick_since(t0)))
	free_all(context.temp_allocator)
}

LOCK_USAGE :: `usage: wlperch lock [-f|--daemonize] [--screen-off]
  Lock the session (ext-session-lock-v1) until the password is entered.
  -f            fork once the screen is locked (for swayidle's before-sleep)
  --screen-off  then power the monitors off; a key or the mouse wakes them
`

// --screen-off: power the monitors off a moment after locking (the lock
// screen's first frame is up by then), and on again at the first input.
// Input that arrived before the power-off doesn't count.
SCREEN_OFF_DELAY_MS :: 300
// After the power-off, pointer events are ignored this long (powering
// outputs off can produce some), and then the mouse must travel this far.
SCREEN_WAKE_GRACE :: time.Second
SCREEN_WAKE_TRAVEL :: 10

@(private = "file")
screen_power_step :: proc() {
	if !lk.screen_off || !lk.locked {return}
	if !lk.off_done {
		if time.tick_since(lk.lock_at) < SCREEN_OFF_DELAY_MS * time.Millisecond {return}
		lk.off_done = true
		lk.screens_woken, lk.ptr_pressed, lk.ptr_moved = false, false, 0
		lk.off_at = time.tick_now()
		lk.screens_off = sway_command("output * power off")
		if lk.screens_off {log.info("lock: monitors off")}
		return
	}
	if !lk.screens_off {return}
	if lk.screens_woken { // a key press: always
		screens_on()
		return
	}
	if time.tick_since(lk.off_at) < SCREEN_WAKE_GRACE {
		lk.ptr_pressed, lk.ptr_moved = false, 0
		return
	}
	if lk.ptr_pressed || lk.ptr_moved >= SCREEN_WAKE_TRAVEL {
		log.infof("lock: woken by the pointer (moved %.0f px, button %v)", lk.ptr_moved, lk.ptr_pressed)
		screens_on()
	}
}

@(private = "file")
screens_on :: proc() {
	if !lk.screens_off {return}
	lk.screens_off = false
	sway_command("output * power on")
	log.info("lock: monitors on")
}

// `wlperch lock`: returns the exit code. 0 only after a successful unlock
// (or, with --daemonize, in the parent once locked).
// Text on the lock background: white, or dark on the light theme's background.
@(private = "file") lock_fg: u32 = 0xffffff
@(private = "file") lock_fg2: u32 = 0xd6dbe6

// Light theme: dark text on a light background (or the screenshot frosted
// light), unless the picture (dimmed) is shown.
@(private = "file")
lock_set_theme :: proc(light: bool) {
	light := light && config.lock_mode != .Image
	theme_light = light
	lock_fg, lock_fg2 = light ? PALETTE_LIGHT.text : 0xffffff, light ? PALETTE_LIGHT.muted : 0xd6dbe6
}

lock_main :: proc(args: []string) -> int {
	daemonize := false
	for a in args {
		switch a {
		case "-f", "--daemonize": daemonize = true
		case "--screen-off":      lk.screen_off = true
		case "-h", "--help":
			fmt.print(LOCK_USAGE)
			return 0
		case:
			fmt.eprint(LOCK_USAGE)
			return 2
		}
	}
	g_lock_ctx = context
	lk.daemon_w = -1
	lock_set_theme(theme_mode_load() == .Light)
	lk.repeat_rate, lk.repeat_delay = 25, 600
	if daemonize {
		// The parent returns once the child reports the lock is in place.
		fds: [2]posix.FD
		if posix.pipe(&fds) != .OK {return 1}
		pid := posix.fork()
		if pid < 0 {return 1}
		if pid > 0 {
			posix.close(fds[1])
			b: u8
			n := posix.read(fds[0], &b, 1)
			return n == 1 ? 0 : 1
		}
		posix.close(fds[0])
		posix.setsid()
		lk.daemon_w = fds[1]
	}

	// "wlperch-lock" in ps / pgrep (swayidle setups check for the locker by name).
	name := cstring("wlperch-lock")
	linux.prctl(15, uint(uintptr(rawptr(name))), 0, 0, 0) // PR_SET_NAME

	lk.pam_service = config.lock_pam_service
	if lk.pam_service == "" {lk.pam_service = os.exists("/etc/pam.d/swaylock") ? "swaylock" : "login"}
	when LOCK_TEST_AUTH {
		if os.get_env("WLPERCH_LOCK_TEST", context.temp_allocator) == "1" {
			log.warn("lock: test build, accepting only the test password")
		}
	}
	clocks_init()
	soft_fonts_init()
	if config.lock_mode == .Image {load_image(config.lock_image)}
	lk.primary = focused_output_name()

	lk.display = wl.display_connect(nil)
	if lk.display == nil {
		fmt.eprintln("wlperch lock: cannot connect to the Wayland display")
		return 1
	}
	registry := wl.display_get_registry(lk.display)
	wl.registry_add_listener(registry, &registry_listener, nil)
	wl.display_roundtrip(lk.display)
	wl.display_roundtrip(lk.display) // output names, seat
	if lk.manager == nil || lk.compositor == nil || lk.shm == nil {
		fmt.eprintln("wlperch lock: the compositor doesn't support ext-session-lock-v1")
		return 1
	}
	// The growing blur shows the screen almost sharp for a moment: only when
	// someone locks by hand. Never with -f (swayidle's timeout and
	// before-sleep), so a machine never wakes up to a readable screen.
	lk.animate = config.lock_mode == .Blur && config.lock_blur_animate_ms > 0 && !daemonize && !lk.screen_off
	if config.lock_mode == .Blur {capture_outputs()}
	prerender_outputs()

	fds: [2]posix.FD
	posix.pipe(&fds)
	lk.wake_r, lk.wake_w = fds[0], fds[1]
	set_cloexec_nonblock(lk.wake_r)
	set_cloexec_nonblock(lk.wake_w)
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

	lk.lock_at = time.tick_now()
	lk.anim_start = lk.lock_at
	lk.lock = wl.ext_session_lock_manager_v1_lock(lk.manager)
	wl.ext_session_lock_v1_add_listener(lk.lock, &lock_listener, nil)
	for o in lk.outputs {create_lock_surface(o)}
	wl.display_roundtrip(lk.display)
	if lk.finished && !lk.locked {
		fmt.eprintln("wlperch lock: the session is already locked")
		return 1
	}

	thread.create_and_start(auth_thread)
	thread.create_and_start(info_thread)

	// Follow "wlperch theme" switches while locked (colours only).
	theme_fd := theme_watch_open()
	d := lk.display
	last_sec, last_min := i64(-1), i64(-1)
	for {
		for wl.display_prepare_read(d) != 0 {wl.display_dispatch_pending(d)}
		wl.display_flush(d)

		// Wake for the next minute digit and the retry countdown: once a second.
		now := time.now()
		ns := time.to_unix_nanoseconds(now) % i64(time.Second)
		timeout := int((i64(time.Second) - ns) / i64(time.Millisecond)) + 1
		if lk.repeat_key != 0 {
			left := time.tick_diff(time.tick_now(), lk.repeat_at)
			timeout = min(timeout, max(int(time.duration_milliseconds(left)), 0) + 1)
		}
		if lk.screen_off && lk.locked && !lk.off_done {timeout = min(timeout, SCREEN_OFF_DELAY_MS)}
		pfds := [3]posix.pollfd {
			{fd = posix.FD(wl.display_get_fd(d)), events = {.IN}},
			{fd = lk.wake_r, events = {.IN}},
			{fd = posix.FD(theme_fd), events = {.IN}},
		}
		if posix.poll(&pfds[0], len(pfds), i32(timeout)) < 0 {
			wl.display_cancel_read(d)
			continue
		}
		t_pass := time.tick_now()
		if .IN in pfds[0].revents {wl.display_read_events(d)} else {wl.display_cancel_read(d)}
		if pfds[0].revents & {.HUP, .ERR} != {} || wl.display_dispatch_pending(d) < 0 {
			// No unlock: the compositor keeps the session locked.
			log.error("lock: lost the Wayland connection")
			return 1
		}
		if lk.finished {
			// The compositor ended the lock (or refused it).
			screens_on()
			return lk.locked ? 0 : 1
		}
		screen_power_step()

		if .IN in pfds[1].revents {
			buf: [64]u8
			redraw := false
			for {
				n := posix.read(lk.wake_r, &buf[0], len(buf))
				if n <= 0 {break}
				for b in buf[:n] {
					if b != 'r' {redraw = true} // 'r': an animation frame is drawn
					switch b {
					case 'y':
						if lk.locked {
							screens_on()
							wl.ext_session_lock_v1_unlock_and_destroy(lk.lock)
							wl.display_roundtrip(d)
							log.info("unlocked")
							return 0
						}
						lk.auth = .Idle
					case 'n':
						lk.auth = .Wrong
						lk.fails += 1
						lk.wrong_at = time.tick_now()
						if lk.fails > FAIL_FREE {
							wait := time.Duration(min(1 << uint(lk.fails - FAIL_FREE), 30)) * time.Second
							lk.retry_at = time.tick_add(time.tick_now(), wait)
						}
						sync.guard(&info.mu)
						delete(info.pam_msg)
						info.pam_msg = ""
					}
				}
			}
			if redraw {for o in lk.outputs {o.dirty = true}}
		}
		if theme_fd >= 0 && .IN in pfds[2].revents && theme_watch_changed(theme_fd) {
			was := theme_light
			lock_set_theme(theme_mode_load() == .Light)
			if theme_light != was {
				for o in lk.outputs {
					o.bg_w = 0 // the solid background follows the mode: rebuild it
					o.dirty = true
				}
			}
		}

		if lk.repeat_key != 0 && lk.repeat_rate > 0 {
			interval := time.Second / time.Duration(lk.repeat_rate)
			for time.tick_diff(lk.repeat_at, time.tick_now()) >= 0 {
				key_press(lk.repeat_key, true)
				lk.repeat_at = time.tick_add(lk.repeat_at, interval)
			}
		}

		sec := time.to_unix_seconds(time.now())
		if sec != last_sec {
			last_sec = sec
			// The clock only changes once a minute; the retry countdown every second.
			if sec / 60 != last_min || time.tick_diff(time.tick_now(), lk.retry_at) > -time.Second {
				last_min = sec / 60
				for o in lk.outputs {o.dirty = true}
			}
		}
		// No frame callback yet (outputs off?): the animation starts anyway.
		if lk.animate && !lk.anim_started && since_lock() > 150 {
			lk.anim_started = true
			lk.anim_start = time.tick_now()
		}
		animating := false
		for o in lk.outputs {
			if o.aw != nil {
				animating = true
				anim_service(o) // every frame until it's done, then render()
				continue
			}
			if !o.configured || o.frame_pending || o.surface == nil {continue}
			if o.anim != nil || o.anim_src.img.px != nil {
				// Not animated after all (no worker, no pre-render): the static picture.
				o.bg_w = 0
				render(o)
				anim_end(o)
			} else if o.dirty {
				render(o)
			}
		}
		if animating {lk.loop_max = max(lk.loop_max, time.duration_milliseconds(time.tick_since(t_pass)))}
		free_all(context.temp_allocator)
	}
}

@(private = "file")
clip :: proc(s: string, n: int) -> string {
	i := 0
	for _, off in s {
		if i == n {return strings.concatenate({strings.trim_right_space(s[:off]), "…"}, context.temp_allocator)}
		i += 1
	}
	return s
}
