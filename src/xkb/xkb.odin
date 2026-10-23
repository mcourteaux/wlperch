// Minimal libxkbcommon bindings: just what a Wayland client needs to turn
// key events into keysyms and text.
package xkb

foreign import lib "system:xkbcommon"

Context :: struct {}
Keymap :: struct {}
State :: struct {}

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
