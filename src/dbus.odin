// Minimal sd-bus (libsystemd) bindings: enough to serve one object on the
// session bus from the main loop.
package main

import "core:c"

foreign import sdbus "system:systemd"

Sd_Bus :: struct {}
Sd_Bus_Message :: struct {}
Sd_Bus_Slot :: struct {}
Sd_Bus_Error :: struct {
	name:      cstring,
	message:   cstring,
	_need_free: c.int,
}

Sd_Bus_Handler :: #type proc "c" (m: ^Sd_Bus_Message, userdata: rawptr, ret_error: ^Sd_Bus_Error) -> c.int

SD_BUS_NAME_REPLACE_EXISTING :: u64(1) << 0
SD_BUS_NAME_ALLOW_REPLACEMENT :: u64(1) << 1
SD_BUS_NAME_QUEUE :: u64(1) << 2

@(default_calling_convention = "c")
foreign sdbus {
	sd_bus_open_user :: proc(ret: ^^Sd_Bus) -> c.int ---
	sd_bus_flush_close_unref :: proc(bus: ^Sd_Bus) -> ^Sd_Bus ---
	sd_bus_request_name :: proc(bus: ^Sd_Bus, name: cstring, flags: u64) -> c.int ---
	sd_bus_release_name :: proc(bus: ^Sd_Bus, name: cstring) -> c.int ---
	sd_bus_add_object :: proc(bus: ^Sd_Bus, slot: ^^Sd_Bus_Slot, path: cstring, callback: Sd_Bus_Handler, userdata: rawptr) -> c.int ---
	sd_bus_add_match :: proc(bus: ^Sd_Bus, slot: ^^Sd_Bus_Slot, match: cstring, callback: Sd_Bus_Handler, userdata: rawptr) -> c.int ---
	sd_bus_get_fd :: proc(bus: ^Sd_Bus) -> c.int ---
	sd_bus_get_events :: proc(bus: ^Sd_Bus) -> c.int ---
	sd_bus_get_timeout :: proc(bus: ^Sd_Bus, usec: ^u64) -> c.int ---
	sd_bus_process :: proc(bus: ^Sd_Bus, r: ^^Sd_Bus_Message) -> c.int ---
	sd_bus_flush :: proc(bus: ^Sd_Bus) -> c.int ---
	sd_bus_send :: proc(bus: ^Sd_Bus, m: ^Sd_Bus_Message, cookie: ^u64) -> c.int ---
	sd_bus_emit_signal :: proc(bus: ^Sd_Bus, path, iface, member, types: cstring, #c_vararg args: ..any) -> c.int ---

	sd_bus_message_is_method_call :: proc(m: ^Sd_Bus_Message, iface, member: cstring) -> c.int ---
	sd_bus_message_is_signal :: proc(m: ^Sd_Bus_Message, iface, member: cstring) -> c.int ---
	sd_bus_message_get_sender :: proc(m: ^Sd_Bus_Message) -> cstring ---
	sd_bus_message_read :: proc(m: ^Sd_Bus_Message, types: cstring, #c_vararg args: ..any) -> c.int ---
	sd_bus_message_read_basic :: proc(m: ^Sd_Bus_Message, type: u8, p: rawptr) -> c.int ---
	sd_bus_message_read_array :: proc(m: ^Sd_Bus_Message, type: u8, ptr: ^rawptr, size: ^c.size_t) -> c.int ---
	sd_bus_message_read_strv :: proc(m: ^Sd_Bus_Message, ret: ^[^]cstring) -> c.int ---
	sd_bus_message_enter_container :: proc(m: ^Sd_Bus_Message, type: u8, contents: cstring) -> c.int ---
	sd_bus_message_exit_container :: proc(m: ^Sd_Bus_Message) -> c.int ---
	sd_bus_message_peek_type :: proc(m: ^Sd_Bus_Message, type: ^u8, contents: ^cstring) -> c.int ---
	sd_bus_message_skip :: proc(m: ^Sd_Bus_Message, types: cstring) -> c.int ---
	sd_bus_message_new_method_return :: proc(call: ^Sd_Bus_Message, m: ^^Sd_Bus_Message) -> c.int ---
	sd_bus_message_append_strv :: proc(m: ^Sd_Bus_Message, l: [^]cstring) -> c.int ---
	sd_bus_message_unref :: proc(m: ^Sd_Bus_Message) -> ^Sd_Bus_Message ---
	sd_bus_reply_method_return :: proc(call: ^Sd_Bus_Message, types: cstring, #c_vararg args: ..any) -> c.int ---
	sd_bus_reply_method_errorf :: proc(call: ^Sd_Bus_Message, name, format: cstring, #c_vararg args: ..any) -> c.int ---
}

foreign import libc_ "system:c"
@(default_calling_convention = "c")
foreign libc_ {
	@(link_name = "free") c_free :: proc(p: rawptr) ---
}
