// Lock screen: `wlperch lock`, a separate process (not the daemon, so its
// re-execs and crashes can't touch it) holding an ext-session-lock-v1 lock.
// One software-rendered surface per output: the focused one gets the clock,
// password field and a status row (unread notification count, what's
// playing, battery); the others just the clock.
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
	pam_service:    string,

	image:          []u32, // decoded [lock] image (0xAARRGGBB), or nil
	img_w, img_h:   int,
}

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
		if wl.output_get_version(o.output) >= 3 {wl.output_release(o.output)} else {wl.output_destroy(o.output)}
		delete(o.bg)
		delete(o.conn)
		free(o)
		ordered_remove(&lk.outputs, i)
	},
}

@(private = "file")
output_listener := wl.Output_Listener {
	geometry = proc "c" (data: rawptr, self: ^wl.Output, x, y, pw, ph, subpixel: i32, make, model: cstring, transform: i32) {},
	mode = proc "c" (data: rawptr, self: ^wl.Output, flags: u32, width, height, refresh: i32) {},
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
		wl.ext_session_lock_surface_v1_ack_configure(self, serial)
		o.w, o.h = i32(width), i32(height)
		o.configured = true
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
	},
}

@(private = "file")
buffer_listener := wl.Buffer_Listener {
	release = proc "c" (data: rawptr, self: ^wl.Buffer) {wl.buffer_destroy(self)},
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
	},
	name = proc "c" (data: rawptr, seat: ^wl.Seat, name: cstring) {},
}

// The pointer is hidden over the lock screen.
@(private = "file")
pointer_listener := wl.Pointer_Listener {
	enter = proc "c" (data: rawptr, self: ^wl.Pointer, serial: u32, surface: ^wl.Surface, x, y: wl.Fixed) {
		wl.pointer_set_cursor(self, serial, nil, 0, 0)
	},
	leave = proc "c" (data: rawptr, self: ^wl.Pointer, serial: u32, surface: ^wl.Surface) {},
	motion = proc "c" (data: rawptr, self: ^wl.Pointer, t: u32, x, y: wl.Fixed) {},
	button = proc "c" (data: rawptr, self: ^wl.Pointer, serial, t, button, state: u32) {},
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
	if o := primary_output(); o != nil {o.dirty = true}
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

@(private = "file")
key_press :: proc(key: u32) {
	code := key + 8
	sym := xkb.state_key_get_one_sym(lk.xkb_state, code)
	ctrl := xkb.state_mod_name_is_active(lk.xkb_state, xkb.MOD_NAME_CTRL, xkb.STATE_MODS_EFFECTIVE) > 0
	primary_dirty()
	if lk.auth == .Checking {return}
	switch sym {
	case xkb.KEY_Return, xkb.KEY_KP_Enter:
		submit()
		return
	case xkb.KEY_Escape:
		clear_password()
		return
	case xkb.KEY_BackSpace:
		if ctrl {
			clear_password()
		} else if lk.pw_len > 0 {
			_, sz := utf8.decode_last_rune(lk.pw[:lk.pw_len])
			mem.zero_explicit(&lk.pw[lk.pw_len - sz], sz)
			lk.pw_len -= sz
		}
		return
	}
	if ctrl {
		if sym == xkb.KEY_u {clear_password()}
		return
	}
	buf: [16]u8
	n := int(xkb.state_key_get_utf8(lk.xkb_state, code, &buf[0], len(buf)))
	if n > 0 && buf[0] >= 0x20 && buf[0] != 0x7f && lk.pw_len + n < len(lk.pw) {
		copy(lk.pw[lk.pw_len:], buf[:n])
		lk.pw_len += n
		if lk.auth == .Wrong {lk.auth = .Idle}
	}
	mem.zero_explicit(&buf[0], len(buf))
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
		update_layout()
	},
	enter = proc "c" (data: rawptr, self: ^wl.Keyboard, serial: u32, surface: ^wl.Surface, keys: ^wl.Array) {},
	leave = proc "c" (data: rawptr, self: ^wl.Keyboard, serial: u32, surface: ^wl.Surface) {
		lk.repeat_key = 0
	},
	key = proc "c" (data: rawptr, self: ^wl.Keyboard, serial, t, key, state: u32) {
		context = g_lock_ctx
		if lk.xkb_state == nil {return}
		if state == wl.KEYBOARD_KEY_STATE_PRESSED {
			key_press(key)
			// Only Backspace repeats: a held letter must not type a password.
			sym := xkb.state_key_get_one_sym(lk.xkb_state, key + 8)
			if sym == xkb.KEY_BackSpace && lk.repeat_rate > 0 {
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
		if reply, ok := ipc_query("lockinfo"); ok {
			for line in strings.split_lines(reply, context.temp_allocator) {
				k, _, v := strings.partition(line, " ")
				switch k {
				case "unread":  unread = strconv.parse_int(v) or_else -1
				case "dnd":     dnd = v == "1"
				case "apps":    apps = v
				case "weather": weather_s = v
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
				info.playing != playing || info.battery != bat || info.charging != charging || info.weather != weather_s
			if changed {
				delete(info.apps); delete(info.media); delete(info.weather)
				info.unread, info.dnd, info.playing, info.battery, info.charging = unread, dnd, playing, bat, charging
				info.apps = strings.clone(apps)
				info.media = strings.clone(media_s)
				info.weather = strings.clone(weather_s)
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

// Solid colour with a soft vignette, or the configured picture (cover-fit,
// optionally blurred by sampling a smaller copy), darkened by dim.
@(private = "file")
build_background :: proc(o: ^Lock_Output, bw, bh: i32) {
	delete(o.bg)
	o.bg = make([]u32, int(bw * bh))
	o.bg_w, o.bg_h = bw, bh
	W, H := int(bw), int(bh)
	if lk.image != nil {
		// Source rectangle that covers the output with the image's aspect.
		iw, ih := f32(lk.img_w), f32(lk.img_h)
		sc := max(f32(W) / iw, f32(H) / ih)
		ox, oy := (iw - f32(W) / sc) / 2, (ih - f32(H) / sc) / 2
		// Blur: sample a copy this many times smaller, bilinearly upscaled.
		div := max(1, config.lock_blur)
		sw, sh := max(W / div, 1), max(H / div, 1)
		small := make([]u32, sw * sh, context.temp_allocator)
		for y in 0 ..< sh {
			for x in 0 ..< sw {
				// Box-average the image area this small pixel covers.
				ax := ox + f32(x) * f32(W) / f32(sw) / sc
				ay := oy + f32(y) * f32(H) / f32(sh) / sc
				bx := ox + f32(x + 1) * f32(W) / f32(sw) / sc
				by := oy + f32(y + 1) * f32(H) / f32(sh) / sc
				step := max(int((bx - ax) / 4), 1)
				r, g, b, n: u32
				for yy := int(ay); yy < max(int(by), int(ay) + 1); yy += step {
					for xx := int(ax); xx < max(int(bx), int(ax) + 1); xx += step {
						p := lk.image[clamp(yy, 0, lk.img_h - 1) * lk.img_w + clamp(xx, 0, lk.img_w - 1)]
						r += (p >> 16) & 0xff; g += (p >> 8) & 0xff; b += p & 0xff; n += 1
					}
				}
				small[y * sw + x] = (r / n) << 16 | (g / n) << 8 | (b / n)
			}
		}
		k := 1 - config.lock_dim
		for y in 0 ..< H {
			fy := clamp((f32(y) + 0.5) * f32(sh) / f32(H) - 0.5, 0, f32(sh - 1))
			y0 := int(fy); y1 := min(y0 + 1, sh - 1); ty := fy - f32(y0)
			for x in 0 ..< W {
				fx := clamp((f32(x) + 0.5) * f32(sw) / f32(W) - 0.5, 0, f32(sw - 1))
				x0 := int(fx); x1 := min(x0 + 1, sw - 1); tx := fx - f32(x0)
				a, b, c, d := small[y0 * sw + x0], small[y0 * sw + x1], small[y1 * sw + x0], small[y1 * sw + x1]
				ch :: proc(a, b, c, d: u32, sh: u32, tx, ty: f32) -> f32 {
					fa, fb := f32((a >> sh) & 0xff), f32((b >> sh) & 0xff)
					fc, fd := f32((c >> sh) & 0xff), f32((d >> sh) & 0xff)
					return (fa * (1 - tx) + fb * tx) * (1 - ty) + (fc * (1 - tx) + fd * tx) * ty
				}
				r := u32(ch(a, b, c, d, 16, tx, ty) * k)
				g := u32(ch(a, b, c, d, 8, tx, ty) * k)
				bb := u32(ch(a, b, c, d, 0, tx, ty) * k)
				o.bg[y * W + x] = 0xff000000 | r << 16 | g << 8 | bb
			}
		}
		return
	}
	c := config.lock_background
	cr, cg, cb := f32((c >> 16) & 0xff), f32((c >> 8) & 0xff), f32(c & 0xff)
	for y in 0 ..< H {
		dy := (f32(y) / f32(H) - 0.45) * 1.6
		for x in 0 ..< W {
			dx := f32(x) / f32(W) - 0.5
			v := 1.12 - 0.45 * (dx * dx + dy * dy) // lighter behind the clock
			o.bg[y * W + x] = 0xff000000 | u32(min(cr * v, 255)) << 16 | u32(min(cg * v, 255)) << 8 | u32(min(cb * v, 255))
		}
	}
}

@(private = "file")
primary_output :: proc() -> ^Lock_Output {
	for o in lk.outputs {if o.conn == lk.primary && o.configured {return o}}
	for o in lk.outputs {if o.configured {return o}}
	return nil
}

@(private = "file")
draw_ui :: proc(cv: ^Cv, W, H: f32, full: bool) {
	now := time.now()
	r, ok := clock_read(local_region, now)
	if !ok {return}
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
	text_c(cv, &soft_regular, 132, W / 2, cy, clock, 0xffffff, 0.96)
	text_c(cv, &soft_regular, 24, W / 2, cy + 50, date, 0xd6dbe6, 0.9)
	if !full {return}

	// Password field.
	px, py := W / 2 - PILL_W / 2, cy + 98
	ring := u32(0xffffff)
	ring_a := f32(0.22)
	switch lk.auth {
	case .Checking: ring, ring_a = C_BLUE, 0.95
	case .Wrong:    ring, ring_a = C_RED, 0.95
	case .Idle:     if lk.caps {ring, ring_a = C_YELLOW, 0.8}
	}
	round_rect(cv, px, py, PILL_W, PILL_H, PILL_H / 2, 0xffffff, 0.08)
	round_rect(cv, px, py, PILL_W, PILL_H, PILL_H / 2, ring, ring_a, 1.5)
	text(cv, &soft_regular, 20, px + 18, py + PILL_H / 2 + 7, ICON_LOCK, 0xffffff, 0.55)
	n := utf8.rune_count(lk.pw[:lk.pw_len])
	if lk.auth == .Checking {
		text_c(cv, &soft_regular, 16, W / 2, py + PILL_H / 2 + 6, "Checking…", C_BLUE)
	} else if n == 0 {
		text_c(cv, &soft_regular, 16, W / 2, py + PILL_H / 2 + 6, "Type your password", 0xffffff, 0.42)
	} else {
		DOT :: 14
		max_dots := int((PILL_W - 100) / DOT)
		shown := min(n, max_dots)
		x0 := W / 2 - f32(shown - 1) * DOT / 2
		for i in 0 ..< shown {
			round_rect(cv, x0 + f32(i) * DOT - 4.5, py + PILL_H / 2 - 4.5, 9, 9, 4.5, 0xffffff, 0.9)
		}
	}

	// One line under the field: what went wrong, else PAM's info, else Caps Lock.
	msg, col := "", u32(0)
	wait := time.tick_diff(time.tick_now(), lk.retry_at)
	switch {
	case wait > 0 && lk.auth != .Checking:
		msg, col = fmt.tprintf("Wrong password · try again in %d s", int(math.ceil(time.duration_seconds(wait)))), C_RED
	case lk.auth == .Wrong:
		msg, col = lk.fails > 1 ? fmt.tprintf("Wrong password (%d attempts)", lk.fails) : "Wrong password", C_RED
	case lk.auth == .Checking && info.pam_msg != "":
		msg, col = info.pam_msg, 0xd6dbe6
	case lk.caps:
		msg, col = fmt.tprintf("%s  Caps Lock is on", ICON_CAPS), C_YELLOW
	}
	if msg != "" {text_c(cv, &soft_regular, 15, W / 2, py + PILL_H + 30, msg, col)}
	if lk.layout != "" {
		text_c(cv, &soft_regular, 13, W / 2, py + PILL_H + (msg != "" ? 54 : 30), fmt.tprintf("%s  %s", ICON_KEYBOARD, lk.layout), 0xffffff, 0.5)
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
		text(cv, &soft_regular, SZ, x, base, it.label, 0xffffff, 0.8)
		x += text_w(cv, &soft_regular, SZ, it.label)
	}
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
	draw_ui(&cv, f32(o.w), f32(o.h), o == primary_output())
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
}

// ---- Main ----------------------------------------------------------------------------

@(private = "file")
focused_output_name :: proc() -> string {
	reply, ok := sway_request(3, "") // GET_OUTPUTS
	if !ok {return ""}
	v, jok := jparse(reply)
	if !jok {return ""}
	for o in jarr(v) {
		if jbool(jobj(o, "focused")) {return strings.clone(jstr(jobj(o, "name")))}
	}
	return ""
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

LOCK_USAGE :: `usage: wlperch lock [-f|--daemonize]
  Lock the session (ext-session-lock-v1) until the password is entered.
  -f  fork once the screen is locked (for swayidle's before-sleep)
`

// `wlperch lock`: returns the exit code. 0 only after a successful unlock
// (or, with --daemonize, in the parent once locked).
lock_main :: proc(args: []string) -> int {
	daemonize := false
	for a in args {
		switch a {
		case "-f", "--daemonize": daemonize = true
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
	load_image(config.lock_image)
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

	fds: [2]posix.FD
	posix.pipe(&fds)
	lk.wake_r, lk.wake_w = fds[0], fds[1]
	set_cloexec_nonblock(lk.wake_r)
	set_cloexec_nonblock(lk.wake_w)
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

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
		pfds := [2]posix.pollfd{{fd = posix.FD(wl.display_get_fd(d)), events = {.IN}}, {fd = lk.wake_r, events = {.IN}}}
		if posix.poll(&pfds[0], 2, i32(timeout)) < 0 {
			wl.display_cancel_read(d)
			continue
		}
		if .IN in pfds[0].revents {wl.display_read_events(d)} else {wl.display_cancel_read(d)}
		if pfds[0].revents & {.HUP, .ERR} != {} || wl.display_dispatch_pending(d) < 0 {
			// No unlock: the compositor keeps the session locked.
			log.error("lock: lost the Wayland connection")
			return 1
		}
		if lk.finished {
			// The compositor ended the lock (or refused it).
			return lk.locked ? 0 : 1
		}

		if .IN in pfds[1].revents {
			buf: [64]u8
			for {
				n := posix.read(lk.wake_r, &buf[0], len(buf))
				if n <= 0 {break}
				for b in buf[:n] {
					switch b {
					case 'y':
						if lk.locked {
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
			for o in lk.outputs {o.dirty = true}
		}

		if lk.repeat_key != 0 && lk.repeat_rate > 0 {
			interval := time.Second / time.Duration(lk.repeat_rate)
			for time.tick_diff(lk.repeat_at, time.tick_now()) >= 0 {
				key_press(lk.repeat_key)
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
		for o in lk.outputs {
			if o.dirty && o.configured && !o.frame_pending && o.surface != nil {render(o)}
		}
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
