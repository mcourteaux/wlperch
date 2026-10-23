// vptr: drive a virtual pointer for UI testing on wlroots compositors.
//
// usage: vptr <x> <y> <layout_w> <layout_h> [move|click|right|scroll:<n>] [hold_ms]
//
// Coordinates are absolute in the compositor's layout space. The pointer device
// exists only while this tool runs, so `hold_ms` keeps it alive (e.g. to take a
// screenshot of a hover state).
package vptr

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import wl "../../src/wl"

manager: ^wl.Zwlr_Virtual_Pointer_Manager_V1
seat: ^wl.Seat

registry_listener := wl.Registry_Listener {
	global = proc "c" (data: rawptr, registry: ^wl.Registry, name: u32, iface: cstring, version: u32) {
		switch iface {
		case "zwlr_virtual_pointer_manager_v1":
			manager = cast(^wl.Zwlr_Virtual_Pointer_Manager_V1)wl.registry_bind(registry, name, &wl.zwlr_virtual_pointer_manager_v1_interface, 1)
		case "wl_seat":
			if seat == nil {seat = cast(^wl.Seat)wl.registry_bind(registry, name, &wl.seat_interface, 1)}
		}
	},
	global_remove = proc "c" (data: rawptr, registry: ^wl.Registry, name: u32) {},
}

now_ms :: proc() -> u32 {
	return u32(time.to_unix_nanoseconds(time.now()) / 1_000_000)
}

main :: proc() {
	if len(os.args) < 5 {
		fmt.eprintln("usage: vptr <x> <y> <layout_w> <layout_h> [move|click|right|scroll:<n>] [hold_ms]")
		os.exit(2)
	}
	x := u32(strconv.parse_int(os.args[1]) or_else 0)
	y := u32(strconv.parse_int(os.args[2]) or_else 0)
	w := u32(strconv.parse_int(os.args[3]) or_else 1)
	h := u32(strconv.parse_int(os.args[4]) or_else 1)
	action := len(os.args) > 5 ? os.args[5] : "click"
	hold := len(os.args) > 6 ? strconv.parse_int(os.args[6]) or_else 0 : 0

	display := wl.display_connect(nil)
	if display == nil {
		fmt.eprintln("vptr: no wayland display")
		os.exit(1)
	}
	registry := wl.display_get_registry(display)
	wl.registry_add_listener(registry, &registry_listener, nil)
	wl.display_roundtrip(display)
	if manager == nil {
		fmt.eprintln("vptr: compositor lacks zwlr_virtual_pointer_manager_v1")
		os.exit(1)
	}
	ptr := wl.zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, seat)
	wl.display_roundtrip(display)
	time.sleep(80 * time.Millisecond) // let the compositor attach the device

	// Wiggle so the compositor definitely re-evaluates focus at the target.
	wl.zwlr_virtual_pointer_v1_motion_absolute(ptr, now_ms(), max(x, 1) - 1, y, w, h)
	wl.zwlr_virtual_pointer_v1_frame(ptr)
	wl.display_roundtrip(display)
	time.sleep(30 * time.Millisecond)
	wl.zwlr_virtual_pointer_v1_motion_absolute(ptr, now_ms(), x, y, w, h)
	wl.zwlr_virtual_pointer_v1_frame(ptr)
	wl.display_roundtrip(display)
	time.sleep(120 * time.Millisecond)

	BTN_LEFT :: 0x110
	BTN_RIGHT :: 0x111
	press :: proc(display: ^wl.Display, ptr: ^wl.Zwlr_Virtual_Pointer_V1, button: u32) {
		wl.zwlr_virtual_pointer_v1_button(ptr, now_ms(), button, wl.POINTER_BUTTON_STATE_PRESSED)
		wl.zwlr_virtual_pointer_v1_frame(ptr)
		wl.display_roundtrip(display)
		time.sleep(60 * time.Millisecond)
		wl.zwlr_virtual_pointer_v1_button(ptr, now_ms(), button, wl.POINTER_BUTTON_STATE_RELEASED)
		wl.zwlr_virtual_pointer_v1_frame(ptr)
		wl.display_roundtrip(display)
	}

	switch {
	case action == "click":
		press(display, ptr, BTN_LEFT)
	case action == "right":
		press(display, ptr, BTN_RIGHT)
	case strings.has_prefix(action, "scroll:"):
		n := strconv.parse_int(action[7:]) or_else 1
		wl.zwlr_virtual_pointer_v1_axis_source(ptr, wl.POINTER_AXIS_SOURCE_WHEEL)
		wl.zwlr_virtual_pointer_v1_axis_discrete(ptr, now_ms(), wl.POINTER_AXIS_VERTICAL_SCROLL, wl.fixed_from_f64(f64(n) * 15), i32(n))
		wl.zwlr_virtual_pointer_v1_frame(ptr)
		wl.display_roundtrip(display)
	}
	if hold > 0 {time.sleep(time.Duration(hold) * time.Millisecond)}
	wl.zwlr_virtual_pointer_v1_destroy(ptr)
	wl.display_roundtrip(display)
	wl.display_disconnect(display)
}
