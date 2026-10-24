// Minimal libxkbcommon bindings: just what a Wayland client needs to turn
// key events into keysyms and text.
package xkb

import "core:os"
import "core:strings"

foreign import lib "system:xkbcommon"

Context :: struct {}
Keymap :: struct {}
State :: struct {}
Compose_Table :: struct {}
Compose_State :: struct {}

Keysym :: u32
Keycode :: u32
Mod_Mask :: u32
Layout_Index :: u32

CONTEXT_NO_FLAGS :: 0
KEYMAP_FORMAT_TEXT_V1 :: 1
KEYMAP_COMPILE_NO_FLAGS :: 0

STATE_MODS_LOCKED :: 1 << 2
STATE_MODS_EFFECTIVE :: 1 << 3
STATE_LAYOUT_EFFECTIVE :: 1 << 7

MOD_NAME_SHIFT :: "Shift"
MOD_NAME_CTRL :: "Control"
MOD_NAME_ALT :: "Mod1"
MOD_NAME_LOGO :: "Mod4"
MOD_NAME_CAPS :: "Lock"

@(default_calling_convention = "c", link_prefix = "xkb_")
foreign lib {
	context_new :: proc(flags: i32) -> ^Context ---
	context_unref :: proc(ctx: ^Context) ---
	keymap_new_from_string :: proc(ctx: ^Context, str: cstring, format: i32, flags: i32) -> ^Keymap ---
	keymap_unref :: proc(keymap: ^Keymap) ---
	keymap_key_repeats :: proc(keymap: ^Keymap, key: Keycode) -> i32 ---
	state_new :: proc(keymap: ^Keymap) -> ^State ---
	state_unref :: proc(state: ^State) ---
	state_update_mask :: proc(state: ^State, depressed, latched, locked: Mod_Mask, depressed_layout, latched_layout, locked_layout: Layout_Index) -> i32 ---
	state_key_get_one_sym :: proc(state: ^State, key: Keycode) -> Keysym ---
	state_key_get_utf8 :: proc(state: ^State, key: Keycode, buffer: [^]u8, size: uint) -> i32 ---
	state_mod_name_is_active :: proc(state: ^State, name: cstring, type: i32) -> i32 ---
	keymap_num_layouts :: proc(keymap: ^Keymap) -> Layout_Index ---
	keymap_layout_get_name :: proc(keymap: ^Keymap, idx: Layout_Index) -> cstring ---
	state_serialize_layout :: proc(state: ^State, components: i32) -> Layout_Index ---
	keysym_from_name :: proc(name: cstring, flags: i32) -> Keysym ---

	// Compose (dead keys, Multi_key sequences): xkbcommon-compose.h.
	compose_table_new_from_locale :: proc(ctx: ^Context, locale: cstring, flags: i32) -> ^Compose_Table ---
	compose_table_unref :: proc(table: ^Compose_Table) ---
	compose_state_new :: proc(table: ^Compose_Table, flags: i32) -> ^Compose_State ---
	compose_state_unref :: proc(state: ^Compose_State) ---
	compose_state_reset :: proc(state: ^Compose_State) ---
	compose_state_feed :: proc(state: ^Compose_State, keysym: Keysym) -> i32 ---
	compose_state_get_status :: proc(state: ^Compose_State) -> i32 ---
	compose_state_get_utf8 :: proc(state: ^Compose_State, buffer: [^]u8, size: uint) -> i32 ---
}

COMPOSE_COMPILE_NO_FLAGS :: 0
COMPOSE_STATE_NO_FLAGS :: 0
COMPOSE_FEED_IGNORED :: 0
COMPOSE_FEED_ACCEPTED :: 1
COMPOSE_NOTHING :: 0
COMPOSE_COMPOSING :: 1
COMPOSE_COMPOSED :: 2
COMPOSE_CANCELLED :: 3

// Dead-key / compose handling shared by every keyboard path. The table comes
// from the user's locale (LC_ALL, LC_CTYPE, LANG, else "C"); the state is
// recreated with each keymap so a half-typed sequence never survives one.
Compose :: struct {
	table: ^Compose_Table,
	state: ^Compose_State,
}

compose_locale :: proc() -> string {
	for name in ([]string{"LC_ALL", "LC_CTYPE", "LANG"}) {
		if v := os.get_env(name, context.temp_allocator); v != "" {return v}
	}
	return "C"
}

// (Re)creates the compose state, loading the table on first use. Without a
// table (no compose data installed) keys simply pass through.
compose_init :: proc(c: ^Compose, ctx: ^Context) {
	if c.table == nil {
		loc := strings.clone_to_cstring(compose_locale(), context.temp_allocator)
		c.table = compose_table_new_from_locale(ctx, loc, COMPOSE_COMPILE_NO_FLAGS)
		if c.table == nil {return}
	}
	if c.state != nil {compose_state_unref(c.state)}
	c.state = compose_state_new(c.table, COMPOSE_STATE_NO_FLAGS)
}

compose_destroy :: proc(c: ^Compose) {
	if c.state != nil {compose_state_unref(c.state)}
	if c.table != nil {compose_table_unref(c.table)}
	c^ = {}
}

compose_reset :: proc(c: ^Compose) {
	if c.state != nil {compose_state_reset(c.state)}
}

compose_active :: proc(c: ^Compose) -> bool {
	return c.state != nil && compose_state_get_status(c.state) == COMPOSE_COMPOSING
}

Compose_Action :: enum {
	Pass,    // not part of a sequence: handle the key as usual
	Swallow, // eaten by a sequence in progress (or one just cancelled)
	Text,    // a sequence finished: type buf[:n] instead of the key
}

// Feeds one pressed key's keysym. Modifier keys are ignored by the state and
// pass through. On .Text the composed UTF-8 is in buf[:n] (NUL-terminated).
compose_key :: proc(c: ^Compose, sym: Keysym, buf: []u8) -> (action: Compose_Action, n: int) {
	if c.state == nil || compose_state_feed(c.state, sym) == COMPOSE_FEED_IGNORED {return .Pass, 0}
	switch compose_state_get_status(c.state) {
	case COMPOSE_COMPOSING:
		return .Swallow, 0
	case COMPOSE_COMPOSED:
		n = int(compose_state_get_utf8(c.state, raw_data(buf), uint(len(buf))))
		compose_state_reset(c.state)
		if n > 0 && n < len(buf) {return .Text, n}
		return .Swallow, 0
	case COMPOSE_CANCELLED:
		compose_state_reset(c.state)
		return .Swallow, 0
	}
	return .Pass, 0
}

// Keysyms we care about (from xkbcommon-keysyms.h).
KEY_BackSpace :: 0xff08
KEY_Tab :: 0xff09
KEY_ISO_Left_Tab :: 0xfe20
KEY_Return :: 0xff0d
KEY_Escape :: 0xff1b
KEY_Delete :: 0xffff
KEY_Home :: 0xff50
KEY_Left :: 0xff51
KEY_Up :: 0xff52
KEY_Right :: 0xff53
KEY_Down :: 0xff54
KEY_Page_Up :: 0xff55
KEY_Page_Down :: 0xff56
KEY_End :: 0xff57
KEY_KP_Enter :: 0xff8d
KEY_space :: 0x0020
KEY_Shift_L :: 0xffe1
KEY_Shift_R :: 0xffe2
KEY_Control_L :: 0xffe3
KEY_Control_R :: 0xffe4
KEY_Alt_L :: 0xffe9
KEY_Alt_R :: 0xffea
KEY_Super_L :: 0xffeb
KEY_Super_R :: 0xffec
KEY_a :: 0x0061
KEY_c :: 0x0063
KEY_q :: 0x0071
KEY_v :: 0x0076
KEY_x :: 0x0078
KEY_z :: 0x007a
KEY_u :: 0x0075
KEY_Caps_Lock :: 0xffe5
