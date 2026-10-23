// Hand-written bindings for the non-generated parts of libwayland-client and
// libwayland-egl. Protocol specific code lives in the generated proto_*.odin.
package wl

foreign import lib "system:wayland-client"
foreign import egl_lib "system:wayland-egl"

Proxy :: struct {}
Event_Queue :: struct {}
Egl_Window :: struct {}

Fixed :: distinct i32

Array :: struct {
	size:  uint,
	alloc: uint,
	data:  rawptr,
}

Message :: struct {
	name:      cstring,
	signature: cstring,
	types:     [^]^Interface,
}

Interface :: struct {
	name:         cstring,
	version:      i32,
	method_count: i32,
	methods:      [^]Message,
	event_count:  i32,
	events:       [^]Message,
}

MARSHAL_FLAG_DESTROY :: u32(1)

fixed_to_f64 :: #force_inline proc "contextless" (f: Fixed) -> f64 {
	return f64(f) / 256.0
}

fixed_from_f64 :: #force_inline proc "contextless" (d: f64) -> Fixed {
	return Fixed(i32(d * 256.0))
}

@(default_calling_convention = "c")
foreign lib {
	@(link_name = "wl_display_connect") display_connect :: proc(name: cstring) -> ^Display ---
	@(link_name = "wl_display_disconnect") display_disconnect :: proc(display: ^Display) ---
	@(link_name = "wl_display_get_fd") display_get_fd :: proc(display: ^Display) -> i32 ---
	@(link_name = "wl_display_dispatch") display_dispatch :: proc(display: ^Display) -> i32 ---
	@(link_name = "wl_display_dispatch_pending") display_dispatch_pending :: proc(display: ^Display) -> i32 ---
	@(link_name = "wl_display_roundtrip") display_roundtrip :: proc(display: ^Display) -> i32 ---
	@(link_name = "wl_display_flush") display_flush :: proc(display: ^Display) -> i32 ---
	@(link_name = "wl_display_prepare_read") display_prepare_read :: proc(display: ^Display) -> i32 ---
	@(link_name = "wl_display_read_events") display_read_events :: proc(display: ^Display) -> i32 ---
	@(link_name = "wl_display_cancel_read") display_cancel_read :: proc(display: ^Display) ---
	@(link_name = "wl_display_get_error") display_get_error :: proc(display: ^Display) -> i32 ---

	@(link_name = "wl_proxy_marshal_flags")
	proxy_marshal_flags :: proc(proxy: ^Proxy, opcode: u32, iface: ^Interface, version: u32, flags: u32, #c_vararg args: ..any) -> ^Proxy ---
	@(link_name = "wl_proxy_add_listener") proxy_add_listener :: proc(proxy: ^Proxy, implementation: rawptr, data: rawptr) -> i32 ---
	@(link_name = "wl_proxy_get_version") proxy_get_version :: proc(proxy: ^Proxy) -> u32 ---
	@(link_name = "wl_proxy_destroy") proxy_destroy :: proc(proxy: ^Proxy) ---
	@(link_name = "wl_proxy_set_user_data") proxy_set_user_data :: proc(proxy: ^Proxy, data: rawptr) ---
	@(link_name = "wl_proxy_get_user_data") proxy_get_user_data :: proc(proxy: ^Proxy) -> rawptr ---
}

@(default_calling_convention = "c")
foreign egl_lib {
	@(link_name = "wl_egl_window_create") egl_window_create :: proc(surface: ^Surface, width, height: i32) -> ^Egl_Window ---
	@(link_name = "wl_egl_window_destroy") egl_window_destroy :: proc(window: ^Egl_Window) ---
	@(link_name = "wl_egl_window_resize") egl_window_resize :: proc(window: ^Egl_Window, width, height, dx, dy: i32) ---
}
