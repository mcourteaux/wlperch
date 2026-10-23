// The bar's tray: StatusNotifierItem over the session bus.
//
// We try to be the StatusNotifierWatcher (org.kde.StatusNotifierWatcher,
// queued: when another watcher such as waybar's goes away we take over and
// apps register again) and are always a host: when someone else is the
// watcher we read its item list and follow its signals. Items are fetched
// with async GetAll calls, so a hung app never stalls the bar. Menus come
// from com.canonical.dbusmenu (GetLayout / Event).
package main

import "core:c"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:sys/posix"
import "core:time"

@(private = "file") WATCHER :: "org.kde.StatusNotifierWatcher"
@(private = "file") WATCHER_PATH :: "/StatusNotifierWatcher"
@(private = "file") ITEM_IFACE :: "org.kde.StatusNotifierItem"
@(private = "file") MENU_IFACE :: "com.canonical.dbusmenu"

Tray_Item :: struct {
	id:          string, // bus + path, as watchers list it
	bus, path:   string,
	serial:      uintptr, // for async replies: the item may be gone by then
	status:      string, // Active | Passive | NeedsAttention
	title:       string,
	tooltip:     string,
	menu:        string, // dbusmenu object path ("" = none)
	is_menu:     bool,   // left click opens the menu
	icon:        ^Notif_Icon,
	att_icon:    ^Notif_Icon,
	slot:        ^Sd_Bus_Slot,
	refetch:     bool,
	loaded:      bool,
}

Tray :: struct {
	bus:      ^Sd_Bus,
	watcher:  bool, // we own org.kde.StatusNotifierWatcher
	items:    [dynamic]^Tray_Item,
	serial:   uintptr,
	changed:  bool,
	on_media: proc(), // an MPRIS player changed
}
tray: Tray

tray_find :: proc(id: string) -> (^Tray_Item, int) {
	for it, i in tray.items {if it.id == id {return it, i}}
	return nil, -1
}

@(private = "file")
find_serial :: proc(serial: uintptr) -> ^Tray_Item {
	for it in tray.items {if it.serial == serial {return it}}
	return nil
}

@(private = "file")
split_id :: proc(id: string) -> (bus, path: string) {
	if i := strings.index_byte(id, '/'); i > 0 {return id[:i], id[i:]}
	return id, "/StatusNotifierItem"
}

tray_start :: proc() {
	if sd_bus_open_user(&tray.bus) < 0 {
		log.warn("tray: no session bus")
		tray.bus = nil
		return
	}
	sd_bus_set_method_call_timeout(tray.bus, 500_000)
	sd_bus_add_object(tray.bus, nil, WATCHER_PATH, watcher_message, nil)
	sd_bus_add_match(tray.bus, nil, "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'", on_name_owner, nil)
	sd_bus_add_match(tray.bus, nil, "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameAcquired'", on_name_acquired, nil)
	sd_bus_add_match(tray.bus, nil, "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameLost'", on_name_acquired, nil)
	sd_bus_add_match(tray.bus, nil, "type='signal',interface='org.kde.StatusNotifierWatcher',member='StatusNotifierItemRegistered'", on_ext_item, nil)
	sd_bus_add_match(tray.bus, nil, "type='signal',interface='org.kde.StatusNotifierWatcher',member='StatusNotifierItemUnregistered'", on_ext_item, nil)
	sd_bus_add_match(tray.bus, nil, "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='/org/mpris/MediaPlayer2'", on_media_signal, nil)

	host := fmt.ctprintf("org.kde.StatusNotifierHost-%d", posix.getpid())
	sd_bus_request_name(tray.bus, host, 0)
	r := sd_bus_request_name(tray.bus, WATCHER, SD_BUS_NAME_QUEUE)
	if r > 0 {
		tray.watcher = true
		log.info("tray: serving org.kde.StatusNotifierWatcher")
	} else {
		log.info("tray: another program is the StatusNotifierWatcher; showing its items")
		use_external_watcher()
	}
	sd_bus_flush(tray.bus)
}

// Someone else is the watcher: register as a host and take its item list.
@(private = "file")
use_external_watcher :: proc() {
	host := fmt.ctprintf("org.kde.StatusNotifierHost-%d", posix.getpid())
	err: Sd_Bus_Error
	sd_bus_call_method(tray.bus, WATCHER, WATCHER_PATH, WATCHER, "RegisterStatusNotifierHost", &err, nil, "s", host)
	sd_bus_error_free(&err)
	reply: ^Sd_Bus_Message
	err = {}
	r := sd_bus_call_method(tray.bus, WATCHER, WATCHER_PATH, "org.freedesktop.DBus.Properties", "Get", &err, &reply, "ss", cstring(WATCHER), cstring("RegisteredStatusNotifierItems"))
	sd_bus_error_free(&err)
	if r < 0 {return}
	defer sd_bus_message_unref(reply)
	if sd_bus_message_enter_container(reply, 'v', "as") < 0 {return}
	strv: [^]cstring
	if sd_bus_message_read_strv(reply, &strv) >= 0 && strv != nil {
		for i := 0; strv[i] != nil; i += 1 {
			bus, path := split_id(string(strv[i]))
			tray_add(bus, path)
			c_free(rawptr(strv[i]))
		}
		c_free(strv)
	}
}

tray_fd :: proc() -> (posix.FD, posix.Poll_Event) {
	if tray.bus == nil {return -1, {}}
	return posix.FD(sd_bus_get_fd(tray.bus)), transmute(posix.Poll_Event)i16(sd_bus_get_events(tray.bus))
}

tray_timeout :: proc() -> time.Duration {
	if tray.bus == nil {return -1}
	usec: u64
	if sd_bus_get_timeout(tray.bus, &usec) <= 0 || usec == max(u64) {return -1}
	ts: posix.timespec
	posix.clock_gettime(.MONOTONIC, &ts)
	now := u64(ts.tv_sec) * 1_000_000 + u64(ts.tv_nsec) / 1000
	return usec > now ? time.Duration(usec - now) * time.Microsecond : 0
}

tray_process :: proc() {
	if tray.bus == nil {return}
	for sd_bus_process(tray.bus, nil) > 0 {}
	for it in tray.items {
		if it.refetch {
			it.refetch = false
			fetch(it)
		}
	}
	sd_bus_flush(tray.bus)
}

tray_add :: proc(bus, path: string) {
	id := strings.concatenate({bus, path}, context.temp_allocator)
	if it, _ := tray_find(id); it != nil {return}
	tray.serial += 1
	it := new(Tray_Item)
	it.id = strings.clone(id)
	it.bus = strings.clone(bus)
	it.path = strings.clone(path)
	it.serial = tray.serial
	it.status = strings.clone("Active")
	match := fmt.ctprintf("type='signal',sender='%s',path='%s',interface='%s'", bus, path, ITEM_IFACE)
	sd_bus_add_match(tray.bus, &it.slot, match, on_item_signal, rawptr(it.serial))
	append(&tray.items, it)
	fetch(it)
	if tray.watcher {
		sd_bus_emit_signal(tray.bus, WATCHER_PATH, WATCHER, "StatusNotifierItemRegistered", "s", strings.clone_to_cstring(id, context.temp_allocator))
	}
	log.debugf("tray: + %s", id)
}

tray_remove :: proc(i: int) {
	it := tray.items[i]
	log.debugf("tray: - %s", it.id)
	if tray.watcher {
		sd_bus_emit_signal(tray.bus, WATCHER_PATH, WATCHER, "StatusNotifierItemUnregistered", "s", strings.clone_to_cstring(it.id, context.temp_allocator))
	}
	if it.slot != nil {sd_bus_slot_unref(it.slot)}
	delete(it.id); delete(it.bus); delete(it.path); delete(it.status)
	delete(it.title); delete(it.tooltip); delete(it.menu)
	free(it)
	ordered_remove(&tray.items, i)
	tray.changed = true
}

@(private = "file")
fetch :: proc(it: ^Tray_Item) {
	sd_bus_call_method_async(tray.bus, nil, strings.clone_to_cstring(it.bus, context.temp_allocator), strings.clone_to_cstring(it.path, context.temp_allocator),
		"org.freedesktop.DBus.Properties", "GetAll", on_props, rawptr(it.serial), "s", cstring(ITEM_IFACE))
}

// ---- Signals -----------------------------------------------------------------------

@(private = "file")
on_name_owner :: proc "c" (m: ^Sd_Bus_Message, userdata: rawptr, ret_error: ^Sd_Bus_Error) -> c.int {
	context = g_bar_ctx
	name, old, new_owner: cstring
	if sd_bus_message_read(m, "sss", &name, &old, &new_owner) < 0 {return 0}
	if string(new_owner) != "" {return 0}
	for i := len(tray.items) - 1; i >= 0; i -= 1 {
		if tray.items[i].bus == string(name) {tray_remove(i)}
	}
	return 0
}

@(private = "file")
on_name_acquired :: proc "c" (m: ^Sd_Bus_Message, userdata: rawptr, ret_error: ^Sd_Bus_Error) -> c.int {
	context = g_bar_ctx
	name: cstring
	if sd_bus_message_read(m, "s", &name) < 0 || string(name) != WATCHER {return 0}
	acquired := sd_bus_message_is_signal(m, "org.freedesktop.DBus", "NameAcquired") > 0
	if acquired && !tray.watcher {
		tray.watcher = true
		log.info("tray: now serving org.kde.StatusNotifierWatcher")
		sd_bus_emit_signal(tray.bus, WATCHER_PATH, WATCHER, "StatusNotifierHostRegistered", "")
	} else if !acquired && tray.watcher {
		tray.watcher = false
	}
	return 0
}

// Another watcher's item list changed.
@(private = "file")
on_ext_item :: proc "c" (m: ^Sd_Bus_Message, userdata: rawptr, ret_error: ^Sd_Bus_Error) -> c.int {
	context = g_bar_ctx
	if tray.watcher {return 0} // our own signals
	s: cstring
	if sd_bus_message_read(m, "s", &s) < 0 {return 0}
	bus, path := split_id(string(s))
	if sd_bus_message_is_signal(m, WATCHER, "StatusNotifierItemRegistered") > 0 {
		tray_add(bus, path)
	} else if _, i := tray_find(strings.concatenate({bus, path}, context.temp_allocator)); i >= 0 {
		tray_remove(i)
	}
	return 0
}

@(private = "file")
on_item_signal :: proc "c" (m: ^Sd_Bus_Message, userdata: rawptr, ret_error: ^Sd_Bus_Error) -> c.int {
	context = g_bar_ctx
	// NewIcon, NewStatus, NewToolTip, NewTitle…: read everything again (batched).
	if it := find_serial(uintptr(userdata)); it != nil {it.refetch = true}
	return 0
}

@(private = "file")
on_media_signal :: proc "c" (m: ^Sd_Bus_Message, userdata: rawptr, ret_error: ^Sd_Bus_Error) -> c.int {
	context = g_bar_ctx
	if tray.on_media != nil {tray.on_media()}
	return 0
}

// ---- Item properties -----------------------------------------------------------------

@(private = "file")
read_str :: proc(m: ^Sd_Bus_Message, type: u8) -> string {
	s: cstring
	if sd_bus_message_read_basic(m, type, &s) < 0 || s == nil {return ""}
	return string(s)
}

// The best of an a(iiay) icon list (ARGB32, network byte order).
@(private = "file")
read_pixmap :: proc(m: ^Sd_Bus_Message) -> ^Notif_Icon {
	if sd_bus_message_enter_container(m, 'a', "(iiay)") < 0 {return nil}
	best: []u8
	bw, bh: i32
	for sd_bus_message_enter_container(m, 'r', "iiay") > 0 {
		w, h: i32
		sd_bus_message_read(m, "ii", &w, &h)
		ptr: rawptr
		size: c.size_t
		if sd_bus_message_read_array(m, 'y', &ptr, &size) >= 0 && w > 0 && h > 0 && int(size) >= int(w * h * 4) {
			// Closest to the thumbnail size, preferring larger.
			score :: proc(w: i32) -> i32 {return w >= ICON_PX ? w - ICON_PX : (ICON_PX - w) * 4}
			if best == nil || score(w) < score(bw) {
				best = ([^]u8)(ptr)[:w * h * 4]
				bw, bh = w, h
			}
		}
		sd_bus_message_exit_container(m)
	}
	sd_bus_message_exit_container(m)
	if best == nil {return nil}
	rgba := make([]u8, len(best), context.temp_allocator)
	for i := 0; i < len(best); i += 4 {
		rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3] = best[i + 1], best[i + 2], best[i + 3], best[i]
	}
	return icon_from_image_data(bw, bh, bw * 4, true, 4, rgba)
}

@(private = "file")
resolve_icon :: proc(name, theme_path: string) -> ^Notif_Icon {
	if name == "" {return nil}
	if theme_path != "" && !strings.has_prefix(name, "/") {
		for sub in ([]string{"", "/hicolor/scalable/apps", "/hicolor/48x48/apps", "/hicolor/32x32/apps", "/hicolor/24x24/apps", "/hicolor/22x22/apps", "/hicolor/16x16/apps"}) {
			for ext in ([]string{".svg", ".png"}) {
				p := strings.concatenate({theme_path, sub, "/", name, ext}, context.temp_allocator)
				if posix.access(strings.clone_to_cstring(p, context.temp_allocator), {.R_OK}) == .OK {
					if ic := icon_resolve(p); ic != nil {return ic}
				}
			}
		}
	}
	return icon_resolve(name)
}

@(private = "file")
on_props :: proc "c" (m: ^Sd_Bus_Message, userdata: rawptr, ret_error: ^Sd_Bus_Error) -> c.int {
	context = g_bar_ctx
	it := find_serial(uintptr(userdata))
	if it == nil {return 0}
	if sd_bus_message_is_method_error(m, nil) > 0 {
		log.debugf("tray: %s: GetAll failed", it.id)
		return 0
	}
	icon_name, att_name, theme_path: string
	pix, att_pix: ^Notif_Icon
	status := "Active"
	title, tip, menu: string
	is_menu := false
	if sd_bus_message_enter_container(m, 'a', "{sv}") < 0 {return 0}
	for sd_bus_message_enter_container(m, 'e', "sv") > 0 {
		key := strings.clone(read_str(m, 's'), context.temp_allocator)
		t: u8
		contents: cstring
		sd_bus_message_peek_type(m, &t, &contents)
		cs := string(contents)
		if sd_bus_message_enter_container(m, 'v', contents) < 0 {
			sd_bus_message_exit_container(m)
			continue
		}
		handled := true
		switch {
		case key == "Status" && cs == "s":            status = strings.clone(read_str(m, 's'), context.temp_allocator)
		case key == "Title" && cs == "s":             title = strings.clone(read_str(m, 's'), context.temp_allocator)
		case key == "IconName" && cs == "s":          icon_name = strings.clone(read_str(m, 's'), context.temp_allocator)
		case key == "AttentionIconName" && cs == "s": att_name = strings.clone(read_str(m, 's'), context.temp_allocator)
		case key == "IconThemePath" && cs == "s":     theme_path = strings.clone(read_str(m, 's'), context.temp_allocator)
		case key == "Menu" && cs == "o":              menu = strings.clone(read_str(m, 'o'), context.temp_allocator)
		case key == "ItemIsMenu" && cs == "b":
			b: b32
			sd_bus_message_read_basic(m, 'b', &b)
			is_menu = bool(b)
		case key == "IconPixmap" && cs == "a(iiay)":          pix = read_pixmap(m)
		case key == "AttentionIconPixmap" && cs == "a(iiay)": att_pix = read_pixmap(m)
		case key == "ToolTip" && cs == "(sa(iiay)ss)":
			if sd_bus_message_enter_container(m, 'r', "sa(iiay)ss") >= 0 {
				read_str(m, 's')
				sd_bus_message_skip(m, "a(iiay)")
				t1 := read_str(m, 's')
				t2 := read_str(m, 's')
				tip = strings.trim_space(strings.concatenate({t1, t2 != "" && t1 != "" ? "\n" : "", t2}, context.temp_allocator))
				sd_bus_message_exit_container(m)
			}
		case:
			handled = false
		}
		if !handled {sd_bus_message_skip(m, contents)}
		sd_bus_message_exit_container(m) // v
		sd_bus_message_exit_container(m) // e
	}
	sd_bus_message_exit_container(m)

	icon := resolve_icon(icon_name, theme_path)
	if icon == nil {icon = pix}
	att := resolve_icon(att_name, theme_path)
	if att == nil {att = att_pix}
	set :: proc(dst: ^string, v: string) -> bool {
		if dst^ == v {return false}
		delete(dst^)
		dst^ = strings.clone(v)
		return true
	}
	changed := !it.loaded
	changed |= set(&it.status, status)
	changed |= set(&it.title, title)
	changed |= set(&it.tooltip, tip)
	changed |= set(&it.menu, menu == "/" ? "" : menu)
	changed |= it.icon != icon || it.att_icon != att || it.is_menu != is_menu
	it.icon, it.att_icon, it.is_menu = icon, att, is_menu
	it.loaded = true
	if changed {tray.changed = true}
	return 0
}

// ---- Actions ----------------------------------------------------------------------------

@(private = "file")
Pending_Activate :: struct {
	serial: uintptr,
	fallback: proc(it: ^Tray_Item),
}
@(private = "file") pending_activate: Pending_Activate

// Left click: Activate, or the menu when the item is one (or can't be activated).
tray_activate :: proc(it: ^Tray_Item, x, y: i32, open_menu: proc(it: ^Tray_Item)) {
	if it.is_menu && it.menu != "" {
		open_menu(it)
		return
	}
	pending_activate = {it.serial, open_menu}
	sd_bus_call_method_async(tray.bus, nil, strings.clone_to_cstring(it.bus, context.temp_allocator), strings.clone_to_cstring(it.path, context.temp_allocator),
		ITEM_IFACE, "Activate", on_activate_reply, rawptr(it.serial), "ii", c.int(x), c.int(y))
	sd_bus_flush(tray.bus)
}

@(private = "file")
on_activate_reply :: proc "c" (m: ^Sd_Bus_Message, userdata: rawptr, ret_error: ^Sd_Bus_Error) -> c.int {
	context = g_bar_ctx
	if sd_bus_message_is_method_error(m, nil) <= 0 {return 0}
	it := find_serial(uintptr(userdata))
	if it != nil && it.menu != "" && pending_activate.serial == it.serial && pending_activate.fallback != nil {
		pending_activate.fallback(it)
	}
	return 0
}

tray_secondary :: proc(it: ^Tray_Item, x, y: i32) {
	sd_bus_call_method_async(tray.bus, nil, strings.clone_to_cstring(it.bus, context.temp_allocator), strings.clone_to_cstring(it.path, context.temp_allocator),
		ITEM_IFACE, "SecondaryActivate", nil, nil, "ii", c.int(x), c.int(y))
	sd_bus_flush(tray.bus)
}

tray_scroll :: proc(it: ^Tray_Item, delta: i32, horizontal: bool) {
	sd_bus_call_method_async(tray.bus, nil, strings.clone_to_cstring(it.bus, context.temp_allocator), strings.clone_to_cstring(it.path, context.temp_allocator),
		ITEM_IFACE, "Scroll", nil, nil, "is", c.int(delta), cstring(horizontal ? "horizontal" : "vertical"))
	sd_bus_flush(tray.bus)
}

// ---- dbusmenu ------------------------------------------------------------------------------

Menu_Node :: struct {
	id:           i32,
	label:        string,
	icon:         string,
	enabled:      bool,
	visible:      bool,
	separator:    bool,
	toggle:       string, // "" | checkmark | radio
	toggle_state: i32,
	children:     [dynamic]Menu_Node,
}

menu_free :: proc(n: ^Menu_Node) {
	delete(n.label)
	delete(n.icon)
	delete(n.toggle)
	for &ch in n.children {menu_free(&ch)}
	delete(n.children)
}

// "_File" -> "File" ("__" is a literal underscore).
@(private = "file")
strip_mnemonic :: proc(s: string) -> string {
	b := strings.builder_make()
	skip := false
	for i := 0; i < len(s); i += 1 {
		if s[i] == '_' && !skip {
			if i + 1 < len(s) && s[i + 1] == '_' {
				strings.write_byte(&b, '_')
				i += 1
			}
			continue
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

@(private = "file")
read_node :: proc(m: ^Sd_Bus_Message, n: ^Menu_Node) -> bool {
	if sd_bus_message_enter_container(m, 'r', "ia{sv}av") <= 0 {return false}
	n.enabled, n.visible = true, true
	sd_bus_message_read_basic(m, 'i', &n.id)
	if sd_bus_message_enter_container(m, 'a', "{sv}") >= 0 {
		for sd_bus_message_enter_container(m, 'e', "sv") > 0 {
			key := strings.clone(read_str(m, 's'), context.temp_allocator)
			t: u8
			contents: cstring
			sd_bus_message_peek_type(m, &t, &contents)
			cs := string(contents)
			if sd_bus_message_enter_container(m, 'v', contents) >= 0 {
				handled := true
				switch {
				case key == "label" && cs == "s":        n.label = strip_mnemonic(read_str(m, 's'))
				case key == "icon-name" && cs == "s":    n.icon = strings.clone(read_str(m, 's'))
				case key == "type" && cs == "s":         n.separator = read_str(m, 's') == "separator"
				case key == "toggle-type" && cs == "s":  n.toggle = strings.clone(read_str(m, 's'))
				case key == "enabled" && cs == "b":
					b: b32
					sd_bus_message_read_basic(m, 'b', &b)
					n.enabled = bool(b)
				case key == "visible" && cs == "b":
					b: b32
					sd_bus_message_read_basic(m, 'b', &b)
					n.visible = bool(b)
				case key == "toggle-state" && cs == "i":
					sd_bus_message_read_basic(m, 'i', &n.toggle_state)
				case:
					handled = false
				}
				if !handled {sd_bus_message_skip(m, contents)}
				sd_bus_message_exit_container(m)
			}
			sd_bus_message_exit_container(m)
		}
		sd_bus_message_exit_container(m)
	}
	if sd_bus_message_enter_container(m, 'a', "v") >= 0 {
		for sd_bus_message_enter_container(m, 'v', "(ia{sv}av)") > 0 {
			child: Menu_Node
			if read_node(m, &child) {append(&n.children, child)}
			sd_bus_message_exit_container(m)
		}
		sd_bus_message_exit_container(m)
	}
	sd_bus_message_exit_container(m)
	return true
}

// The item's whole menu (synchronous, with the bus timeout).
tray_menu_layout :: proc(it: ^Tray_Item) -> (root: Menu_Node, ok: bool) {
	if it.menu == "" {return}
	dest := strings.clone_to_cstring(it.bus, context.temp_allocator)
	path := strings.clone_to_cstring(it.menu, context.temp_allocator)
	err: Sd_Bus_Error
	sd_bus_call_method(tray.bus, dest, path, MENU_IFACE, "AboutToShow", &err, nil, "i", c.int(0))
	sd_bus_error_free(&err)
	reply: ^Sd_Bus_Message
	err = {}
	r := sd_bus_call_method(tray.bus, dest, path, MENU_IFACE, "GetLayout", &err, &reply, "iias", c.int(0), c.int(-1), c.uint(0))
	sd_bus_error_free(&err)
	if r < 0 {return}
	defer sd_bus_message_unref(reply)
	rev: u32
	sd_bus_message_read_basic(reply, 'u', &rev)
	ok = read_node(reply, &root)
	return
}

tray_menu_event :: proc(it: ^Tray_Item, id: i32) {
	ts := u32(time.to_unix_seconds(time.now()))
	sd_bus_call_method_async(tray.bus, nil, strings.clone_to_cstring(it.bus, context.temp_allocator), strings.clone_to_cstring(it.menu, context.temp_allocator),
		MENU_IFACE, "Event", nil, nil, "isvu", c.int(id), cstring("clicked"), cstring("i"), c.int(0), c.uint(ts))
	sd_bus_flush(tray.bus)
}

// ---- Being the watcher -------------------------------------------------------------------------

@(private = "file")
INTROSPECT :: `<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
 <interface name="org.kde.StatusNotifierWatcher">
  <method name="RegisterStatusNotifierItem"><arg name="service" type="s" direction="in"/></method>
  <method name="RegisterStatusNotifierHost"><arg name="service" type="s" direction="in"/></method>
  <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
  <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
  <property name="ProtocolVersion" type="i" access="read"/>
  <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
  <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
  <signal name="StatusNotifierHostRegistered"/>
 </interface>
 <interface name="org.freedesktop.DBus.Properties">
  <method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
  <method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
 </interface>
 <interface name="org.freedesktop.DBus.Introspectable">
  <method name="Introspect"><arg type="s" direction="out"/></method>
 </interface>
</node>
`

@(private = "file")
append_prop :: proc(r: ^Sd_Bus_Message, name: string) -> bool {
	switch name {
	case "RegisteredStatusNotifierItems":
		sd_bus_message_open_container(r, 'v', "as")
		ids := make([]cstring, len(tray.items) + 1, context.temp_allocator)
		for it, i in tray.items {ids[i] = strings.clone_to_cstring(it.id, context.temp_allocator)}
		sd_bus_message_append_strv(r, raw_data(ids))
		sd_bus_message_close_container(r)
	case "IsStatusNotifierHostRegistered":
		sd_bus_message_open_container(r, 'v', "b")
		sd_bus_message_append(r, "b", c.int(1))
		sd_bus_message_close_container(r)
	case "ProtocolVersion":
		sd_bus_message_open_container(r, 'v', "i")
		sd_bus_message_append(r, "i", c.int(0))
		sd_bus_message_close_container(r)
	case:
		return false
	}
	return true
}

@(private = "file")
watcher_message :: proc "c" (m: ^Sd_Bus_Message, userdata: rawptr, ret_error: ^Sd_Bus_Error) -> c.int {
	context = g_bar_ctx
	switch {
	case sd_bus_message_is_method_call(m, WATCHER, "RegisterStatusNotifierItem") > 0:
		s: cstring
		if sd_bus_message_read(m, "s", &s) < 0 {return 0}
		svc := strings.clone(string(s), context.temp_allocator)
		bus, path := svc, "/StatusNotifierItem"
		if strings.has_prefix(svc, "/") {
			// Ayatana/libappindicator: an object path on the caller's connection.
			bus, path = strings.clone(string(sd_bus_message_get_sender(m)), context.temp_allocator), svc
		} else if i := strings.index_byte(svc, '/'); i > 0 {
			bus, path = svc[:i], svc[i:]
		}
		sd_bus_reply_method_return(m, "")
		tray_add(bus, path)
		return 1
	case sd_bus_message_is_method_call(m, WATCHER, "RegisterStatusNotifierHost") > 0:
		sd_bus_reply_method_return(m, "")
		sd_bus_emit_signal(tray.bus, WATCHER_PATH, WATCHER, "StatusNotifierHostRegistered", "")
		return 1
	case sd_bus_message_is_method_call(m, "org.freedesktop.DBus.Properties", "Get") > 0:
		iface, prop: cstring
		sd_bus_message_read(m, "ss", &iface, &prop)
		reply: ^Sd_Bus_Message
		if sd_bus_message_new_method_return(m, &reply) < 0 {return 0}
		defer sd_bus_message_unref(reply)
		if !append_prop(reply, string(prop)) {
			sd_bus_reply_method_errorf(m, "org.freedesktop.DBus.Error.UnknownProperty", "no property %s", prop)
			return 1
		}
		sd_bus_send(tray.bus, reply, nil)
		return 1
	case sd_bus_message_is_method_call(m, "org.freedesktop.DBus.Properties", "GetAll") > 0:
		reply: ^Sd_Bus_Message
		if sd_bus_message_new_method_return(m, &reply) < 0 {return 0}
		defer sd_bus_message_unref(reply)
		sd_bus_message_open_container(reply, 'a', "{sv}")
		for name in ([]string{"RegisteredStatusNotifierItems", "IsStatusNotifierHostRegistered", "ProtocolVersion"}) {
			sd_bus_message_open_container(reply, 'e', "sv")
			sd_bus_message_append(reply, "s", strings.clone_to_cstring(name, context.temp_allocator))
			append_prop(reply, name)
			sd_bus_message_close_container(reply)
		}
		sd_bus_message_close_container(reply)
		sd_bus_send(tray.bus, reply, nil)
		return 1
	case sd_bus_message_is_method_call(m, "org.freedesktop.DBus.Introspectable", "Introspect") > 0:
		sd_bus_reply_method_return(m, "s", cstring(INTROSPECT))
		return 1
	}
	return 0
}
