// `wlperch askpass <prompt>` (also as wlperch-askpass, or with
// WLPERCH_ASKPASS=1 in the environment): an SSH_ASKPASS program. ssh-add
// runs it with the prompt as its only argument and reads the answer from
// its standard output.
//
// A small centred card on the overlay layer that takes the keyboard: the
// prompt, a password field showing dots, OK / Cancel. OK prints the text
// and a newline and exits 0; Cancel, Escape (or ten minutes) exit 1.
// SSH_ASKPASS_PROMPT=confirm asks yes / no instead (0 = yes, no output),
// "none" only shows the message (OK).
//
// The typed text lives in one fixed buffer, locked in memory where the
// system allows, wiped after writing and on every exit path. It is never
// logged, there is no clipboard, the process can't be dumped or traced
// (PR_SET_DUMPABLE 0). Dead keys and compose sequences work as on the lock
// screen (src/xkb). Software-rendered into shared memory, in the theme's
// colours, like the bar.
package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"

import "wl"
import "xkb"

@(private = "file") CARD_W :: 440
@(private = "file") MARGIN :: 28 // around the card: room for its shadow
@(private = "file") PAD :: 24
@(private = "file") FIELD_H :: 44
@(private = "file") BTN_H :: 34
@(private = "file") GIVE_UP :: 10 * time.Minute

@(private = "file")
Ask_Mode :: enum {Secret, Confirm, Info}

@(private = "file")
Ask_Out :: struct {
	output: ^wl.Output,
	scale:  i32,
}

@(private = "file")
Ask_Button :: struct {
	label:   string,
	result:  int, // exit code when clicked
	primary: bool,
	rect:    Bar_Rect,
}

@(private = "file")
Asker :: struct {
	display:      ^wl.Display,
	compositor:   ^wl.Compositor,
	shm:          ^wl.Shm,
	layer_shell:  ^wl.Zwlr_Layer_Shell_V1,
	seat:         ^wl.Seat,
	keyboard:     ^wl.Keyboard,
	pointer:      ^wl.Pointer,
	cursor_mgr:   ^wl.Wp_Cursor_Shape_Manager_V1,
	cursor_dev:   ^wl.Wp_Cursor_Shape_Device_V1,
	outs:         [dynamic]Ask_Out,
	surface:      ^wl.Surface,
	layer:        ^wl.Zwlr_Layer_Surface_V1,
	configured:   bool,
	closed:       bool,
	dirty:        bool,
	frame_cb:     ^wl.Callback,
	scale:        i32,
	w, h:         i32, // logical surface size

	mode:         Ask_Mode,
	title:        string,
	subtitle:     string,
	body:         [dynamic]string, // wrapped message lines
	error:        string, // from the prompt ("Bad passphrase, try again")
	buttons:      [dynamic]Ask_Button,
	hover:        int, // button under the pointer (-1)
	pressed:      int,
	ptr_x, ptr_y: f32,

	xkb_ctx:      ^xkb.Context,
	xkb_keymap:   ^xkb.Keymap,
	xkb_state:    ^xkb.State,
	compose:      xkb.Compose,
	caps:         bool,
	repeat_rate:  i32,
	repeat_delay: i32,
	repeat_key:   u32,
	repeat_at:    time.Tick,

	result:       int, // -1 while open
}

@(private = "file") ak: Asker
@(private = "file") g_ask_ctx: runtime.Context

// The secret: one buffer, nothing else ever holds it.
@(private = "file") secret: [1024]u8
@(private = "file") secret_len: int

@(private = "file")
wipe :: proc() {
	mem.zero_explicit(&secret[0], len(secret))
	secret_len = 0
}

// ---- The prompt ---------------------------------------------------------------

// Title, the key (~ for $HOME), the message lines, an error: from what
// ssh-add / ssh pass as the prompt.
askpass_parse_prompt :: proc(prompt, home: string, mode_env: string) -> (title, subtitle, body, error: string) {
	p := strings.trim_space(prompt)
	tilde :: proc(s, home: string) -> string {
		if home != "" && strings.has_prefix(s, home) && (len(s) == len(home) || s[len(home)] == '/') {
			return strings.concatenate({"~", s[len(home):]}, context.temp_allocator)
		}
		return s
	}
	key_of :: proc(rest: string) -> string {
		r := strings.trim_suffix(strings.trim_space(rest), ":")
		r = strings.trim_suffix(strings.trim_space(r), "(will confirm each use)")
		return strings.trim_suffix(strings.trim_space(r), ":")
	}
	switch {
	case mode_env == "confirm":
		title = "Allow use of an SSH key?"
		body = p
	case mode_env == "none":
		title = "SSH"
		body = p
	case strings.has_prefix(p, "Enter passphrase for "):
		title = "Unlock SSH key"
		subtitle = tilde(key_of(p[len("Enter passphrase for "):]), home)
		if strings.has_prefix(subtitle, "key ") {subtitle = subtitle[4:]}
		body = "Enter its passphrase."
	case strings.has_prefix(p, "Bad passphrase, try again for "):
		title = "Unlock SSH key"
		subtitle = tilde(key_of(p[len("Bad passphrase, try again for "):]), home)
		body = "Enter its passphrase."
		error = "Wrong passphrase, try again."
	case strings.has_prefix(p, "Enter lock password"):
		title = "SSH agent password"
		body = "The password that locks and unlocks the agent."
	case p == "Again:":
		title = "SSH agent password"
		body = "Type the same password again."
	case:
		title = "SSH"
		body = p
	}
	return
}

// Greedy word wrap into lines no wider than w (logical px).
@(private = "file")
wrap :: proc(text: string, f: Bar_Font, px, w: f32) -> [dynamic]string {
	lines: [dynamic]string
	for para in strings.split_lines(text, context.temp_allocator) {
		cur := ""
		for word in strings.fields(para, context.temp_allocator) {
			try := cur == "" ? word : strings.concatenate({cur, " ", word}, context.temp_allocator)
			if cur != "" && bar_text_width(f, px, try) > w {
				append(&lines, strings.clone(cur))
				cur = word
			} else {
				cur = try
			}
		}
		append(&lines, strings.clone(cur))
	}
	for len(lines) > 0 && lines[len(lines) - 1] == "" {pop(&lines)}
	return lines
}

// ---- Wayland ------------------------------------------------------------------

@(private = "file")
registry_listener := wl.Registry_Listener {
	global = proc "c" (data: rawptr, registry: ^wl.Registry, name: u32, iface: cstring, version: u32) {
		context = g_ask_ctx
		switch iface {
		case "wl_compositor":
			ak.compositor = cast(^wl.Compositor)wl.registry_bind(registry, name, &wl.compositor_interface, min(version, 4))
		case "wl_shm":
			ak.shm = cast(^wl.Shm)wl.registry_bind(registry, name, &wl.shm_interface, 1)
		case "zwlr_layer_shell_v1":
			ak.layer_shell = cast(^wl.Zwlr_Layer_Shell_V1)wl.registry_bind(registry, name, &wl.zwlr_layer_shell_v1_interface, min(version, 3))
		case "wp_cursor_shape_manager_v1":
			ak.cursor_mgr = cast(^wl.Wp_Cursor_Shape_Manager_V1)wl.registry_bind(registry, name, &wl.wp_cursor_shape_manager_v1_interface, 1)
		case "wl_seat":
			if ak.seat == nil {
				ak.seat = cast(^wl.Seat)wl.registry_bind(registry, name, &wl.seat_interface, min(version, 5))
				wl.seat_add_listener(ak.seat, &seat_listener, nil)
			}
		case "wl_output":
			o := cast(^wl.Output)wl.registry_bind(registry, name, &wl.output_interface, min(version, 2))
			append(&ak.outs, Ask_Out{o, 1})
			wl.output_add_listener(o, &output_listener, nil)
		}
	},
	global_remove = proc "c" (data: rawptr, registry: ^wl.Registry, name: u32) {},
}

@(private = "file")
output_listener := wl.Output_Listener {
	geometry = proc "c" (data: rawptr, self: ^wl.Output, x, y, pw, ph, subpixel: i32, make, model: cstring, transform: i32) {},
	mode = proc "c" (data: rawptr, self: ^wl.Output, flags: u32, width, height, refresh: i32) {},
	done = proc "c" (data: rawptr, self: ^wl.Output) {},
	scale = proc "c" (data: rawptr, self: ^wl.Output, factor: i32) {
		for &o in ak.outs {if o.output == self {o.scale = max(factor, 1)}}
	},
	name = proc "c" (data: rawptr, self: ^wl.Output, name: cstring) {},
	description = proc "c" (data: rawptr, self: ^wl.Output, description: cstring) {},
}

@(private = "file")
surface_listener := wl.Surface_Listener {
	enter = proc "c" (data: rawptr, self: ^wl.Surface, output: ^wl.Output) {
		for o in ak.outs {
			if o.output == output && o.scale != ak.scale {
				ak.scale = o.scale
				ak.dirty = true
			}
		}
	},
	leave = proc "c" (data: rawptr, self: ^wl.Surface, output: ^wl.Output) {},
	preferred_buffer_scale = proc "c" (data: rawptr, self: ^wl.Surface, factor: i32) {},
	preferred_buffer_transform = proc "c" (data: rawptr, self: ^wl.Surface, transform: u32) {},
}

@(private = "file")
layer_listener := wl.Zwlr_Layer_Surface_V1_Listener {
	configure = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1, serial, width, height: u32) {
		wl.zwlr_layer_surface_v1_ack_configure(self, serial)
		ak.configured = true
		ak.dirty = true
	},
	closed = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1) {ak.closed = true},
}

@(private = "file")
frame_listener := wl.Callback_Listener {
	done = proc "c" (data: rawptr, self: ^wl.Callback, t: u32) {
		wl.callback_destroy(self)
		if ak.frame_cb == self {ak.frame_cb = nil}
	},
}

@(private = "file")
seat_listener := wl.Seat_Listener {
	capabilities = proc "c" (data: rawptr, seat: ^wl.Seat, caps: u32) {
		context = g_ask_ctx
		if caps & wl.SEAT_CAPABILITY_KEYBOARD != 0 && ak.keyboard == nil {
			ak.keyboard = wl.seat_get_keyboard(seat)
			wl.keyboard_add_listener(ak.keyboard, &keyboard_listener, nil)
		}
		if caps & wl.SEAT_CAPABILITY_POINTER != 0 && ak.pointer == nil {
			ak.pointer = wl.seat_get_pointer(seat)
			wl.pointer_add_listener(ak.pointer, &pointer_listener, nil)
			if ak.cursor_mgr != nil {ak.cursor_dev = wl.wp_cursor_shape_manager_v1_get_pointer(ak.cursor_mgr, ak.pointer)}
		}
		// wlroots makes the old objects inert once the last device is gone:
		// drop them so a replugged (or virtual) keyboard gets a fresh one.
		if caps & wl.SEAT_CAPABILITY_KEYBOARD == 0 && ak.keyboard != nil {
			if wl.keyboard_get_version(ak.keyboard) >= 3 {wl.keyboard_release(ak.keyboard)} else {wl.keyboard_destroy(ak.keyboard)}
			ak.keyboard = nil
			ak.repeat_key = 0
		}
		if caps & wl.SEAT_CAPABILITY_POINTER == 0 && ak.pointer != nil {
			if ak.cursor_dev != nil {wl.wp_cursor_shape_device_v1_destroy(ak.cursor_dev)}
			ak.cursor_dev = nil
			if wl.pointer_get_version(ak.pointer) >= 3 {wl.pointer_release(ak.pointer)} else {wl.pointer_destroy(ak.pointer)}
			ak.pointer = nil
		}
	},
	name = proc "c" (data: rawptr, seat: ^wl.Seat, name: cstring) {},
}

@(private = "file")
button_at :: proc(x, y: f32) -> int {
	for b, i in ak.buttons {if bar_in_rect(b.rect, x, y) {return i}}
	return -1
}

@(private = "file")
pointer_listener := wl.Pointer_Listener {
	enter = proc "c" (data: rawptr, self: ^wl.Pointer, serial: u32, surface: ^wl.Surface, x, y: wl.Fixed) {
		if ak.cursor_dev != nil {wl.wp_cursor_shape_device_v1_set_shape(ak.cursor_dev, serial, wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT)}
		ak.ptr_x, ak.ptr_y = f32(wl.fixed_to_f64(x)), f32(wl.fixed_to_f64(y))
	},
	leave = proc "c" (data: rawptr, self: ^wl.Pointer, serial: u32, surface: ^wl.Surface) {
		if ak.hover >= 0 {ak.dirty = true}
		ak.hover = -1
		ak.pressed = -1
	},
	motion = proc "c" (data: rawptr, self: ^wl.Pointer, t: u32, x, y: wl.Fixed) {
		context = g_ask_ctx
		ak.ptr_x, ak.ptr_y = f32(wl.fixed_to_f64(x)), f32(wl.fixed_to_f64(y))
		if h := button_at(ak.ptr_x, ak.ptr_y); h != ak.hover {
			ak.hover = h
			ak.dirty = true
		}
	},
	button = proc "c" (data: rawptr, self: ^wl.Pointer, serial, t, button, state: u32) {
		context = g_ask_ctx
		BTN_LEFT :: 0x110
		if button != BTN_LEFT {return}
		h := button_at(ak.ptr_x, ak.ptr_y)
		if state == wl.POINTER_BUTTON_STATE_PRESSED {
			ak.pressed = h
		} else {
			if h >= 0 && h == ak.pressed && !(ak.mode == .Secret && ak.buttons[h].primary && secret_len == 0) {ak.result = ak.buttons[h].result}
			ak.pressed = -1
		}
		ak.dirty = true
	},
	axis = proc "c" (data: rawptr, self: ^wl.Pointer, t: u32, axis: u32, value: wl.Fixed) {},
	frame = proc "c" (data: rawptr, self: ^wl.Pointer) {},
	axis_source = proc "c" (data: rawptr, self: ^wl.Pointer, axis_source: u32) {},
	axis_stop = proc "c" (data: rawptr, self: ^wl.Pointer, t: u32, axis: u32) {},
	axis_discrete = proc "c" (data: rawptr, self: ^wl.Pointer, axis: u32, discrete: i32) {},
	axis_value120 = proc "c" (data: rawptr, self: ^wl.Pointer, axis: u32, value120: i32) {},
	axis_relative_direction = proc "c" (data: rawptr, self: ^wl.Pointer, axis: u32, direction: u32) {},
}

// ---- Keyboard -------------------------------------------------------------------

@(private = "file")
add_text :: proc(text: []u8) {
	n := len(text)
	if n == 0 || text[0] < 0x20 || text[0] == 0x7f {return}
	if secret_len + n >= len(secret) {return}
	copy(secret[secret_len:], text)
	secret_len += n
	ak.error = ""
}

// Returns false when compose swallowed the key (it must not repeat).
@(private = "file")
key_press :: proc(key: u32, repeat := false) -> bool {
	code := key + 8
	sym := xkb.state_key_get_one_sym(ak.xkb_state, code)
	ctrl := xkb.state_mod_name_is_active(ak.xkb_state, xkb.MOD_NAME_CTRL, xkb.STATE_MODS_EFFECTIVE) > 0
	ak.dirty = true
	if ctrl {
		xkb.compose_reset(&ak.compose)
	} else if !repeat {
		buf: [64]u8
		defer mem.zero_explicit(&buf[0], len(buf))
		switch action, n := xkb.compose_key(&ak.compose, sym, buf[:]); action {
		case .Pass:
		case .Swallow:
			return false
		case .Text:
			if ak.mode == .Secret {add_text(buf[:n])}
			return false
		}
	}
	switch sym {
	case xkb.KEY_Return, xkb.KEY_KP_Enter:
		if ak.mode == .Secret && secret_len == 0 {return true} // nothing typed yet
		for b in ak.buttons {if b.primary {ak.result = b.result}}
		return true
	case xkb.KEY_Escape:
		ak.result = ak.mode == .Info ? 0 : 1
		return true
	case xkb.KEY_BackSpace:
		if ctrl {
			wipe()
		} else if secret_len > 0 {
			_, sz := utf8.decode_last_rune(secret[:secret_len])
			mem.zero_explicit(&secret[secret_len - sz], sz)
			secret_len -= sz
		}
		return true
	}
	if ctrl {
		if sym == xkb.KEY_u {wipe()}
		return true
	}
	if ak.mode != .Secret {return true}
	buf: [16]u8
	n := int(xkb.state_key_get_utf8(ak.xkb_state, code, &buf[0], len(buf)))
	if n > 0 {add_text(buf[:n])}
	mem.zero_explicit(&buf[0], len(buf))
	return true
}

@(private = "file")
keyboard_listener := wl.Keyboard_Listener {
	keymap = proc "c" (data: rawptr, self: ^wl.Keyboard, format: u32, fd: i32, size: u32) {
		context = g_ask_ctx
		defer posix.close(posix.FD(fd))
		if format != wl.KEYBOARD_KEYMAP_FORMAT_XKB_V1 {return}
		m := posix.mmap(nil, uint(size), {.READ}, {.PRIVATE}, posix.FD(fd), 0)
		if m == posix.MAP_FAILED {return}
		defer posix.munmap(m, uint(size))
		if ak.xkb_ctx == nil {ak.xkb_ctx = xkb.context_new(xkb.CONTEXT_NO_FLAGS)}
		keymap := xkb.keymap_new_from_string(ak.xkb_ctx, cstring(m), xkb.KEYMAP_FORMAT_TEXT_V1, xkb.KEYMAP_COMPILE_NO_FLAGS)
		if keymap == nil {return}
		if ak.xkb_state != nil {xkb.state_unref(ak.xkb_state)}
		if ak.xkb_keymap != nil {xkb.keymap_unref(ak.xkb_keymap)}
		ak.xkb_keymap = keymap
		ak.xkb_state = xkb.state_new(keymap)
		xkb.compose_init(&ak.compose, ak.xkb_ctx)
	},
	enter = proc "c" (data: rawptr, self: ^wl.Keyboard, serial: u32, surface: ^wl.Surface, keys: ^wl.Array) {},
	leave = proc "c" (data: rawptr, self: ^wl.Keyboard, serial: u32, surface: ^wl.Surface) {
		context = g_ask_ctx
		ak.repeat_key = 0
		xkb.compose_reset(&ak.compose)
	},
	key = proc "c" (data: rawptr, self: ^wl.Keyboard, serial, t, key, state: u32) {
		context = g_ask_ctx
		if ak.xkb_state == nil {return}
		if state == wl.KEYBOARD_KEY_STATE_PRESSED {
			eaten := !key_press(key)
			// Only Backspace repeats: a held letter must not type a passphrase.
			sym := xkb.state_key_get_one_sym(ak.xkb_state, key + 8)
			if !eaten && sym == xkb.KEY_BackSpace && ak.repeat_rate > 0 {
				ak.repeat_key = key
				ak.repeat_at = time.tick_add(time.tick_now(), time.Duration(ak.repeat_delay) * time.Millisecond)
			} else {
				ak.repeat_key = 0
			}
		} else if ak.repeat_key == key {
			ak.repeat_key = 0
		}
	},
	modifiers = proc "c" (data: rawptr, self: ^wl.Keyboard, serial, depressed, latched, locked, group: u32) {
		context = g_ask_ctx
		if ak.xkb_state == nil {return}
		xkb.state_update_mask(ak.xkb_state, depressed, latched, locked, 0, 0, group)
		caps := xkb.state_mod_name_is_active(ak.xkb_state, xkb.MOD_NAME_CAPS, xkb.STATE_MODS_LOCKED) > 0
		if caps != ak.caps {
			ak.caps = caps
			ak.dirty = true
		}
	},
	repeat_info = proc "c" (data: rawptr, self: ^wl.Keyboard, rate, delay: i32) {
		ak.repeat_rate = rate
		ak.repeat_delay = delay
	},
}

// ---- Drawing --------------------------------------------------------------------

// The card's layout: content top, field / status / buttons rows.
@(private = "file")
Ask_Layout :: struct {
	card:                    Bar_Rect,
	body_y, field_y, status_y, buttons_y: f32,
}

@(private = "file")
layout :: proc() -> (l: Ask_Layout) {
	x, y := f32(MARGIN), f32(MARGIN)
	cy := y + PAD + (ak.subtitle != "" ? 50 : 44) // under the title / subtitle
	l.body_y = cy
	cy += f32(len(ak.body)) * 20
	if ak.mode == .Secret {
		cy += 8
		l.field_y = cy
		cy += FIELD_H
		l.status_y = cy + 6
		cy += 26
	} else {
		cy += 10
	}
	l.buttons_y = cy
	cy += BTN_H + PAD
	l.card = {x, y, CARD_W, cy - y}
	return
}

@(private = "file")
render :: proc() {
	s := f32(ak.scale)
	b, ok := bar_buffer_new(int(ak.w * ak.scale), int(ak.h * ak.scale), s)
	if !ok {return}
	cv := &b.cv
	l := layout()
	card := l.card
	bar_shadow(cv, card, 16, 20)
	bar_fill_round(cv, card, 16, C_CARD, 1)
	bar_stroke(cv, card, {16, 16, 16, 16}, C_BORDER, 1)
	x0 := card.x + PAD
	inner := card.w - 2 * PAD
	// Badge and title.
	accent := ak.mode == .Confirm ? C_ORANGE : C_YELLOW
	bx, by := x0 + 18, card.y + PAD + 18
	bar_fill_round(cv, {bx - 18, by - 18, 36, 36}, 18, accent, 0.16)
	icon := ak.mode == .Confirm ? ICON_KEY_VARIANT : ICON_KEY
	iw := bar_text_width(.Regular, 19, icon)
	bar_text(cv, .Regular, 19, bx - iw / 2, by + 7, icon, accent)
	tx := x0 + 50
	bar_text(cv, .Bold, 17, tx, card.y + PAD + (ak.subtitle != "" ? 15 : 24), clip_px(ak.title, .Bold, 17, inner - 50), C_TEXT)
	if ak.subtitle != "" {
		bar_text(cv, .Regular, 13, tx, card.y + PAD + 35, clip_px(ak.subtitle, .Regular, 13, inner - 50), C_MUTED)
	}
	for line, i in ak.body {
		bar_text(cv, .Regular, 14, x0, l.body_y + 14 + f32(i) * 20, line, C_TEXT, 0.88)
	}
	if ak.mode == .Secret {
		f := Bar_Rect{x0, l.field_y, inner, FIELD_H}
		ring, ring_a := C_BLUE, f32(0.9)
		if ak.error != "" {ring = C_RED}
		bar_fill_round(cv, f, 10, C_WELL, 1)
		bar_stroke(cv, f, {10, 10, 10, 10}, ring, ring_a)
		bar_text(cv, .Regular, 17, f.x + 14, f.y + FIELD_H / 2 + 6, ICON_LOCK, C_MUTED)
		n := utf8.rune_count(secret[:secret_len])
		DOT :: f32(13)
		max_dots := int((inner - 60) / DOT)
		shown := min(n, max_dots)
		dx := f.x + 44
		for i in 0 ..< shown {
			bar_fill_round(cv, {dx + f32(i) * DOT, f.y + FIELD_H / 2 - 4, 8, 8}, 4, C_TEXT, 0.9)
		}
		// The caret after the dots.
		cx := dx + f32(shown) * DOT + (shown > 0 ? 2 : 0)
		bar_fill(cv, {cx, f.y + 12, 1.5, FIELD_H - 24}, {}, C_BLUE, 0.9)
		if n == 0 {bar_text(cv, .Regular, 14, cx + 8, f.y + FIELD_H / 2 + 5, strings.has_prefix(ak.title, "Unlock") ? "Passphrase" : "Password", C_FAINT)}
		msg, col := "", u32(0)
		switch {
		case ak.error != "": msg, col = fmt.tprintf("%s  %s", ICON_ALERT, ak.error), C_RED
		case ak.caps:        msg, col = fmt.tprintf("%s  Caps Lock is on", ICON_KEYBOARD), C_YELLOW
		}
		if msg != "" {bar_text(cv, .Regular, 13, x0, l.status_y + 13, msg, col)}
	}
	// Buttons, right-aligned; the primary one last.
	bx2 := card.x + card.w - PAD
	#reverse for &btn, i in ak.buttons {
		w := bar_text_width(.Bold, 14, btn.label) + 36
		bx2 -= w
		btn.rect = {bx2, l.buttons_y, w, BTN_H}
		hover := ak.hover == i
		if btn.primary {
			bar_fill_round(cv, btn.rect, 9, accent, hover ? 1 : 0.88)
			bar_text(cv, .Bold, 14, bx2 + 18, l.buttons_y + 22, btn.label, theme_light ? 0xffffff : C_BG)
		} else {
			bar_fill_round(cv, btn.rect, 9, C_OVERLAY, hover ? 0.10 : 0.05)
			bar_text(cv, .Bold, 14, bx2 + 18, l.buttons_y + 22, btn.label, C_TEXT)
		}
		bx2 -= 10
	}
	hint := ak.mode == .Secret ? "Enter · Esc" : ""
	if hint != "" {bar_text(cv, .Regular, 12, x0, l.buttons_y + 22, hint, C_FAINT)}
	bar_buffer_attach(&b, ak.shm, ak.surface, ak.scale)
	ak.frame_cb = wl.surface_frame(ak.surface)
	wl.callback_add_listener(ak.frame_cb, &frame_listener, nil)
	wl.surface_commit(ak.surface)
}

@(private = "file")
clip_px :: proc(s: string, f: Bar_Font, px, w: f32) -> string {
	if bar_text_width(f, px, s) <= w {return s}
	r := s
	for len(r) > 1 && bar_text_width(f, px, strings.concatenate({"…", r}, context.temp_allocator)) > w {
		_, sz := utf8.decode_rune(r)
		r = r[sz:]
	}
	return strings.concatenate({"…", r}, context.temp_allocator)
}

// ---- Main -------------------------------------------------------------------------

@(private = "file")
harden :: proc() {
	PR_SET_DUMPABLE :: 4
	linux.prctl(PR_SET_DUMPABLE, 0, 0, 0, 0)
	// Keep the secret out of swap, where allowed (RLIMIT_MEMLOCK).
	linux.mlock(&secret[0], len(secret))
}

askpass_main :: proc(args: []string) -> int {
	g_ask_ctx = context
	harden()
	defer wipe()
	prompt := len(args) > 0 ? args[0] : "Passphrase:"
	mode_env := os.get_env("SSH_ASKPASS_PROMPT", context.temp_allocator)
	ak.mode = mode_env == "confirm" ? .Confirm : mode_env == "none" ? .Info : .Secret
	ak.result, ak.hover, ak.pressed, ak.scale = -1, -1, -1, 1
	soft_fonts_init()
	bar_set_theme(theme_mode_load() == .Light)
	title, subtitle, body, err := askpass_parse_prompt(prompt, os.get_env("HOME", context.temp_allocator), mode_env)
	// (Temp strings: the loop frees the temp allocator.)
	ak.title, ak.subtitle, ak.error = strings.clone(title), strings.clone(subtitle), strings.clone(err)
	ak.body = wrap(body, .Regular, 14, CARD_W - 2 * PAD)
	switch ak.mode {
	case .Secret:  append(&ak.buttons, Ask_Button{label = "Cancel", result = 1}, Ask_Button{label = strings.has_prefix(title, "Unlock") ? "Unlock" : "OK", result = 0, primary = true})
	case .Confirm: append(&ak.buttons, Ask_Button{label = "Deny", result = 1}, Ask_Button{label = "Allow", result = 0, primary = true})
	case .Info:    append(&ak.buttons, Ask_Button{label = "OK", result = 0, primary = true})
	}

	ak.display = wl.display_connect(nil)
	if ak.display == nil {
		fmt.eprintln("wlperch askpass: cannot connect to the Wayland display")
		return 1
	}
	registry := wl.display_get_registry(ak.display)
	wl.registry_add_listener(registry, &registry_listener, nil)
	wl.display_roundtrip(ak.display)
	wl.display_roundtrip(ak.display) // seat capabilities, output scales
	if ak.compositor == nil || ak.shm == nil || ak.layer_shell == nil {
		fmt.eprintln("wlperch askpass: the compositor lacks wl_shm or zwlr_layer_shell_v1")
		return 1
	}
	for o in ak.outs {ak.scale = max(ak.scale, o.scale)}
	l := layout()
	ak.w, ak.h = i32(l.card.w) + 2 * MARGIN, i32(l.card.h) + 2 * MARGIN
	ak.surface = wl.compositor_create_surface(ak.compositor)
	wl.surface_add_listener(ak.surface, &surface_listener, nil)
	ak.layer = wl.zwlr_layer_shell_v1_get_layer_surface(ak.layer_shell, ak.surface, nil, wl.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "wlperch-askpass")
	wl.zwlr_layer_surface_v1_add_listener(ak.layer, &layer_listener, nil)
	wl.zwlr_layer_surface_v1_set_size(ak.layer, u32(ak.w), u32(ak.h))
	wl.zwlr_layer_surface_v1_set_anchor(ak.layer, 0) // centred
	wl.zwlr_layer_surface_v1_set_keyboard_interactivity(ak.layer, wl.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE)
	wl.surface_commit(ak.surface)

	started := time.tick_now()
	for ak.result < 0 && !ak.closed {
		if ak.configured && ak.dirty && ak.frame_cb == nil {
			ak.dirty = false
			render()
		}
		for wl.display_prepare_read(ak.display) != 0 {wl.display_dispatch_pending(ak.display)}
		wl.display_flush(ak.display)
		timeout := 1000
		if ak.repeat_key != 0 && ak.repeat_rate > 0 {
			timeout = max(int(time.duration_milliseconds(time.tick_diff(time.tick_now(), ak.repeat_at))), 0) + 1
		}
		pfd := posix.pollfd{fd = posix.FD(wl.display_get_fd(ak.display)), events = {.IN}}
		n := posix.poll(&pfd, 1, i32(timeout))
		if n > 0 && .IN in pfd.revents {wl.display_read_events(ak.display)} else {wl.display_cancel_read(ak.display)}
		if .HUP in pfd.revents || .ERR in pfd.revents {break}
		if wl.display_dispatch_pending(ak.display) < 0 {break}
		if ak.repeat_key != 0 && ak.repeat_rate > 0 && time.tick_diff(ak.repeat_at, time.tick_now()) >= 0 {
			key_press(ak.repeat_key, true)
			ak.repeat_at = time.tick_add(time.tick_now(), time.Second / time.Duration(ak.repeat_rate))
		}
		if time.tick_since(started) > GIVE_UP {break}
		free_all(context.temp_allocator)
	}
	result := ak.result < 0 ? 1 : ak.result
	// ssh-add -x asks twice: a cancelled first prompt would only bring up
	// "Again:". Cancel means cancel: stop our ssh-add parent.
	if result != 0 && strings.has_prefix(strings.trim_space(prompt), "Enter lock password") {
		ppid := posix.getppid()
		if comm, err := os.read_entire_file(fmt.tprintf("/proc/%d/comm", ppid), context.temp_allocator); err == nil && strings.trim_space(string(comm)) == "ssh-add" {
			posix.kill(ppid, .SIGTERM)
		}
	}
	// The surface goes first, so nothing of it lingers while ssh-add works.
	wl.zwlr_layer_surface_v1_destroy(ak.layer)
	wl.surface_destroy(ak.surface)
	wl.display_roundtrip(ak.display)
	if result == 0 && ak.mode == .Secret {
		data := secret[:secret_len]
		for len(data) > 0 {
			w := posix.write(posix.STDOUT_FILENO, raw_data(data), uint(len(data)))
			if w <= 0 {break}
			data = data[w:]
		}
		nl := u8('\n')
		posix.write(posix.STDOUT_FILENO, &nl, 1)
	}
	wipe()
	wl.display_disconnect(ak.display)
	return result
}
