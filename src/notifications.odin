// Notification server (org.freedesktop.Notifications on the session bus):
// popups on screen, a history for the notification center, do not disturb.
// Runs entirely on the main thread: the bus fd is part of the main poll.
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

NOTIFY_NAME :: "org.freedesktop.Notifications"
NOTIFY_PATH :: "/org/freedesktop/Notifications"
NOTIFY_HISTORY_DAYS :: 7
NOTIFY_HISTORY_MAX :: 300

Notif_Action :: struct {
	key, label: string,
}

Close_Reason :: enum u32 {
	Expired   = 1,
	Dismissed = 2,
	Closed    = 3, // CloseNotification call
	Undefined = 4,
}

Notification :: struct {
	id:        u32,
	at:        i64, // unix seconds
	app:       string,
	summary:   string,
	body:      string, // markup stripped
	desktop:   string, // desktop-entry hint
	tag:       string, // x-canonical-private-synchronous / x-dunst-stack-tag
	icon:      ^Notif_Icon,
	urgency:   u8, // 0 low, 1 normal, 2 critical
	value:     i32, // progress 0..100, -1 = none
	actions:   [dynamic]Notif_Action,
	transient: bool, // never stored in the history
	resident:  bool, // stays open when an action is invoked
	read:      bool,
	// Open = the app may still close it / receive actions.
	open:      bool,
	popup:     bool, // wants a popup (false under do not disturb)
	timeout:   time.Duration, // 0 = until dismissed
	expires:   time.Tick, // set once the popup is on screen
	hover:     bool, // pointer on the popup: the timer refills instead of running out
	rev:       int, // content revision (popups redraw when it changes)
	// Over a fullscreen game with no other monitor (critical ones and OSDs
	// only): a short look, then it waits for the game to leave fullscreen.
	glimpse:   bool, // on screen for GLIMPSE at most; timeout is shortened
	glimpse_timeout: time.Duration, // its own timeout, back when the game goes
	glimpsed:  bool, // had its look; waits like the others
}

Notifs :: struct {
	bus:      ^Sd_Bus,
	owner:    bool, // we own org.freedesktop.Notifications
	was_away: bool, // plat.away as last seen by notifications_tick
	other:    string, // who does, when it's not us
	next_id:  u32,
	list:     [dynamic]^Notification, // oldest first
	dnd:      bool,
	dirty:    bool,
	dirty_at: time.Tick,
	version:  int, // bumped on every change (the center redraws)
	path:     string,
	fs_seq:   int, // fullscreen_seq() last placed for
	fs_mode:  Fullscreen_Mode,
	held:     bool, // every output is covered: popups wait (notify_popups_layout)
}
notifs: Notifs

// ---- Store ----------------------------------------------------------------------

notif_find :: proc(id: u32) -> (^Notification, int) {
	for n, i in notifs.list {if n.id == id {return n, i}}
	return nil, -1
}

@(private = "file")
notif_free :: proc(n: ^Notification) {
	delete(n.app); delete(n.summary); delete(n.body); delete(n.desktop); delete(n.tag)
	for a in n.actions {delete(a.key); delete(a.label)}
	delete(n.actions)
	free(n)
}

@(private = "file")
changed :: proc() {
	notifs.version += 1
	if !notifs.dirty {notifs.dirty_at = time.tick_now()}
	notifs.dirty = true
	notify_popups_layout()
	request_redraw()
}

notif_unread :: proc() -> int {
	n := 0
	for x in notifs.list {if !x.read && !x.transient {n += 1}}
	return n
}

// Close an open notification: tells the app, drops it from the screen and,
// for transient ones, from the history.
notif_close :: proc(id: u32, reason: Close_Reason) {
	n, i := notif_find(id)
	if n == nil {return}
	if n.open {
		n.open = false
		n.popup = false
		emit_closed(id, reason)
	}
	if n.transient {
		ordered_remove(&notifs.list, i)
		notif_free(n)
	}
	changed()
}

notif_invoke :: proc(id: u32, key: string) {
	n, _ := notif_find(id)
	if n == nil {return}
	n.read = true
	if n.open && notifs.bus != nil {
		k := strings.clone_to_cstring(key, context.temp_allocator)
		sd_bus_emit_signal(notifs.bus, NOTIFY_PATH, NOTIFY_NAME, "ActionInvoked", "us", id, k)
	}
	// Apps can't raise their own window on Wayland without an activation
	// token; focusing it from here covers the common "click to open" case.
	if key == "default" || len(n.actions) == 0 {focus_app(n)}
	if !n.resident {notif_close(id, .Dismissed)} else {changed()}
}

focus_app :: proc(n: ^Notification) {
	name := n.desktop != "" ? n.desktop : n.app
	if name == "" {return}
	// Desktop entries look like org.gnome.Nautilus or firefox; app_ids match either.
	short := name[strings.last_index_byte(name, '.') + 1:]
	re := fmt.tprintf("(?i)^(%s|%s)$", regex_quote(name), regex_quote(short))
	sway_command(fmt.tprintf(`[app_id="%s"] focus`, re))
	sway_command(fmt.tprintf(`[class="%s"] focus`, re))
}

@(private = "file")
regex_quote :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		if strings.contains_rune(`\.^$*+?()[]{}|"`, r) {strings.write_byte(&b, '\\')}
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}

notif_remove :: proc(id: u32) {
	n, i := notif_find(id)
	if n == nil {return}
	if n.open {
		n.open = false
		emit_closed(id, .Dismissed)
	}
	ordered_remove(&notifs.list, i)
	notif_free(n)
	changed()
}

notif_clear_all :: proc() {
	for i := len(notifs.list) - 1; i >= 0; i -= 1 {
		n := notifs.list[i]
		if n.open {emit_closed(n.id, .Dismissed)}
		notif_free(n)
	}
	clear(&notifs.list)
	changed()
}

notif_mark_all_read :: proc() {
	any := false
	for n in notifs.list {
		if !n.read {n.read = true; any = true}
	}
	if any {changed()}
}

notif_set_dnd :: proc(on: bool) {
	notifs.dnd = on
	if !on {
		// Held notifications don't pop up all at once afterwards: they're in
		// the center, unread.
	} else {
		for n in notifs.list {if n.popup && n.urgency < 2 && !n.transient {n.popup = false}}
	}
	changed()
}

// ---- Markup ---------------------------------------------------------------------

// Bodies may carry a small markup subset (<b>, <i>, <a href>, <img>) and
// entities. We show plain text.
strip_markup :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		ch := s[i]
		if ch == '<' {
			end := strings.index_byte(s[i:], '>')
			if end < 0 {strings.write_string(&b, s[i:]); break}
			tag := strings.to_lower(s[i + 1:i + end], context.temp_allocator)
			if strings.has_prefix(tag, "br") {strings.write_byte(&b, '\n')}
			i += end + 1
			continue
		}
		if ch == '&' {
			end := strings.index_byte(s[i:], ';')
			if end > 0 && end < 10 {
				ent := s[i + 1:i + end]
				r: rune = -1
				switch ent {
				case "amp":  r = '&'
				case "lt":   r = '<'
				case "gt":   r = '>'
				case "quot": r = '"'
				case "apos": r = '\''
				case "nbsp": r = ' '
				case:
					if len(ent) > 1 && ent[0] == '#' {
						v: int
						ok: bool
						if ent[1] == 'x' {v, ok = strconv.parse_int(ent[2:], 16)} else {v, ok = strconv.parse_int(ent[1:], 10)}
						if ok {r = rune(v)}
					}
				}
				if r >= 0 {
					strings.write_rune(&b, r)
					i += end + 1
					continue
				}
			}
		}
		strings.write_byte(&b, ch)
		i += 1
	}
	return strings.trim_space(strings.to_string(b))
}

// ---- D-Bus ----------------------------------------------------------------------

@(private = "file")
emit_closed :: proc(id: u32, reason: Close_Reason) {
	if notifs.bus == nil {return}
	sd_bus_emit_signal(notifs.bus, NOTIFY_PATH, NOTIFY_NAME, "NotificationClosed", "uu", id, u32(reason))
}

@(private = "file")
INTROSPECT_XML :: `<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
 <interface name="org.freedesktop.Notifications">
  <method name="Notify">
   <arg name="app_name" type="s" direction="in"/><arg name="replaces_id" type="u" direction="in"/>
   <arg name="app_icon" type="s" direction="in"/><arg name="summary" type="s" direction="in"/>
   <arg name="body" type="s" direction="in"/><arg name="actions" type="as" direction="in"/>
   <arg name="hints" type="a{sv}" direction="in"/><arg name="expire_timeout" type="i" direction="in"/>
   <arg name="id" type="u" direction="out"/>
  </method>
  <method name="CloseNotification"><arg name="id" type="u" direction="in"/></method>
  <method name="GetCapabilities"><arg name="capabilities" type="as" direction="out"/></method>
  <method name="GetServerInformation">
   <arg name="name" type="s" direction="out"/><arg name="vendor" type="s" direction="out"/>
   <arg name="version" type="s" direction="out"/><arg name="spec_version" type="s" direction="out"/>
  </method>
  <signal name="NotificationClosed"><arg name="id" type="u"/><arg name="reason" type="u"/></signal>
  <signal name="ActionInvoked"><arg name="id" type="u"/><arg name="action_key" type="s"/></signal>
 </interface>
 <interface name="org.freedesktop.DBus.Introspectable">
  <method name="Introspect"><arg name="xml" type="s" direction="out"/></method>
 </interface>
</node>
`

@(private = "file")
g_ctx_notify: runtime.Context

@(private = "file")
on_message :: proc "c" (m: ^Sd_Bus_Message, userdata: rawptr, ret_error: ^Sd_Bus_Error) -> c.int {
	context = g_ctx_notify
	switch {
	case sd_bus_message_is_method_call(m, NOTIFY_NAME, "Notify") > 0:
		id := handle_notify(m)
		if id == 0 {
			sd_bus_reply_method_errorf(m, "org.freedesktop.DBus.Error.InvalidArgs", "malformed Notify call")
		} else {
			sd_bus_reply_method_return(m, "u", id)
		}
		return 1
	case sd_bus_message_is_method_call(m, NOTIFY_NAME, "CloseNotification") > 0:
		id: u32
		sd_bus_message_read(m, "u", &id)
		notif_close(id, .Closed)
		sd_bus_reply_method_return(m, "")
		return 1
	case sd_bus_message_is_method_call(m, NOTIFY_NAME, "GetCapabilities") > 0:
		caps := [?]cstring{"actions", "body", "body-markup", "icon-static", "persistence", "x-canonical-private-synchronous", "x-dunst-stack-tag", nil}
		reply: ^Sd_Bus_Message
		if sd_bus_message_new_method_return(m, &reply) >= 0 {
			sd_bus_message_append_strv(reply, &caps[0])
			sd_bus_send(notifs.bus, reply, nil)
			sd_bus_message_unref(reply)
		}
		return 1
	case sd_bus_message_is_method_call(m, NOTIFY_NAME, "GetServerInformation") > 0:
		sd_bus_reply_method_return(m, "ssss", cstring("wlperch"), cstring("wlperch"), cstring("1"), cstring("1.2"))
		return 1
	case sd_bus_message_is_method_call(m, "org.freedesktop.DBus.Introspectable", "Introspect") > 0:
		sd_bus_reply_method_return(m, "s", cstring(INTROSPECT_XML))
		return 1
	}
	return 0
}

@(private = "file")
on_name_signal :: proc "c" (m: ^Sd_Bus_Message, userdata: rawptr, ret_error: ^Sd_Bus_Error) -> c.int {
	context = g_ctx_notify
	name: cstring
	if sd_bus_message_read(m, "s", &name) < 0 || string(name) != NOTIFY_NAME {return 0}
	acquired := sd_bus_message_is_signal(m, "org.freedesktop.DBus", "NameAcquired") > 0
	if acquired != notifs.owner {
		notifs.owner = acquired
		log.infof("notifications: %s %s", acquired ? "now serving" : "lost", NOTIFY_NAME)
		if acquired {delete(notifs.other); notifs.other = ""}
		changed()
	}
	return 0
}

@(private = "file")
read_string :: proc(m: ^Sd_Bus_Message) -> (string, bool) {
	s: cstring
	if sd_bus_message_read_basic(m, 's', &s) < 0 {return "", false}
	return string(s), true
}

// Parse a Notify call and add/replace the notification. Returns its id (0 = error).
@(private = "file")
handle_notify :: proc(m: ^Sd_Bus_Message) -> u32 {
	app, icon_name, summary, body: cstring
	replaces: u32
	if sd_bus_message_read(m, "susss", &app, &replaces, &icon_name, &summary, &body) < 0 {return 0}

	actions: [dynamic]Notif_Action
	strv: [^]cstring
	if sd_bus_message_read_strv(m, &strv) < 0 {return 0}
	if strv != nil {
		for i := 0; strv[i] != nil; i += 2 {
			if strv[i + 1] == nil {c_free(rawptr(strv[i])); break}
			append(&actions, Notif_Action{strings.clone(string(strv[i])), strings.clone(string(strv[i + 1]))})
			c_free(rawptr(strv[i]))
			c_free(rawptr(strv[i + 1]))
		}
		c_free(strv)
	}

	urgency: u8 = 1
	value: i32 = -1
	desktop, tag, image_path: string
	transient, resident: bool
	image: ^Notif_Icon
	if sd_bus_message_enter_container(m, 'a', "{sv}") < 0 {return 0}
	for sd_bus_message_enter_container(m, 'e', "sv") > 0 {
		key, _ := read_string(m)
		t: u8
		contents: cstring
		sd_bus_message_peek_type(m, &t, &contents)
		handled := false
		if sd_bus_message_enter_container(m, 'v', contents) >= 0 {
			cs := string(contents)
			switch key {
			case "urgency":
				if cs == "y" {sd_bus_message_read_basic(m, 'y', &urgency); handled = true}
			case "value":
				if cs == "i" {sd_bus_message_read_basic(m, 'i', &value); handled = true}
				if cs == "u" {v: u32; sd_bus_message_read_basic(m, 'u', &v); value = i32(v); handled = true}
			case "desktop-entry":
				if cs == "s" {s, _ := read_string(m); desktop = strings.clone(s, context.temp_allocator); handled = true}
			case "x-canonical-private-synchronous", "x-dunst-stack-tag", "synchronous", "private-synchronous":
				if cs == "s" {s, _ := read_string(m); tag = strings.clone(s, context.temp_allocator); handled = true}
			case "image-path", "image_path":
				if cs == "s" {s, _ := read_string(m); image_path = strings.clone(s, context.temp_allocator); handled = true}
			case "transient":
				if cs == "b" {b: b32; sd_bus_message_read_basic(m, 'b', &b); transient = bool(b); handled = true}
			case "resident":
				if cs == "b" {b: b32; sd_bus_message_read_basic(m, 'b', &b); resident = bool(b); handled = true}
			case "image-data", "image_data", "icon_data":
				if cs == "(iiibiiay)" && sd_bus_message_enter_container(m, 'r', "iiibiiay") >= 0 {
					w, h, stride, bits, channels: i32
					alpha: b32
					sd_bus_message_read(m, "iiibii", &w, &h, &stride, &alpha, &bits, &channels)
					ptr: rawptr
					size: c.size_t
					if sd_bus_message_read_array(m, 'y', &ptr, &size) >= 0 && bits == 8 && image == nil {
						image = icon_from_image_data(w, h, stride, bool(alpha), channels, ([^]u8)(ptr)[:size])
					}
					sd_bus_message_exit_container(m)
					handled = true
				}
			}
			if !handled {sd_bus_message_skip(m, contents)}
			sd_bus_message_exit_container(m)
		}
		sd_bus_message_exit_container(m)
	}
	sd_bus_message_exit_container(m)
	expire: i32 = -1
	sd_bus_message_read(m, "i", &expire)

	if image == nil {image = icon_resolve(image_path, string(icon_name))}
	if image == nil {image = icon_resolve_desktop(desktop)}
	if image == nil && desktop != "" {image = icon_resolve(desktop)}
	if image == nil {image = icon_resolve(strings.to_lower(string(app), context.temp_allocator))}

	// Replace: by id, or by stack tag from the same app (volume/brightness OSDs).
	n: ^Notification
	if replaces != 0 {n, _ = notif_find(replaces)}
	if n == nil && tag != "" {
		for x in notifs.list {
			if x.open && x.tag == tag && x.app == string(app) {n = x; break}
		}
	}
	if n != nil {
		// Moves to the newest position.
		_, i := notif_find(n.id)
		ordered_remove(&notifs.list, i)
		delete(n.app); delete(n.summary); delete(n.body); delete(n.desktop); delete(n.tag)
		for a in n.actions {delete(a.key); delete(a.label)}
		delete(n.actions)
		id := n.id
		n^ = {}
		n.id = id
	} else {
		n = new(Notification)
		notifs.next_id += 1
		if notifs.next_id == 0 {notifs.next_id = 1}
		n.id = notifs.next_id
	}
	n.at = time.to_unix_seconds(time.now())
	n.app = strings.clone(string(app))
	n.summary = strip_markup(string(summary))
	n.body = strip_markup(string(body))
	n.desktop = strings.clone(desktop)
	n.tag = strings.clone(tag)
	n.icon = image
	n.urgency = min(urgency, 2)
	n.value = value
	n.actions = actions
	// Volume/brightness indicators (a replace tag plus a value) are on-screen
	// only, like dunst's OSD stack: they don't fill the history.
	n.transient = transient || (tag != "" && value >= 0)
	n.resident = resident
	n.open = true
	n.popup = !notifs.dnd || n.urgency == 2 || (tag != "" && value >= 0) // OSDs answer something you just did
	switch {
	case expire == 0:      n.timeout = 0
	case expire > 0:       n.timeout = time.Duration(expire) * time.Millisecond
	case n.urgency == 2:   n.timeout = 0
	case n.urgency == 0:   n.timeout = 5 * time.Second
	case:                  n.timeout = 8 * time.Second
	}
	n.rev = notifs.version + 1
	append(&notifs.list, n)
	prune()
	log.debugf("notification %d from %q: %q", n.id, n.app, n.summary)
	changed()
	return n.id
}

// An entry of wlperch's own (the low-memory warning) in the history: no
// popup (the caller shows its own), unread.
notif_log_local :: proc(app, summary, body: string, urgency: u8) {
	n := new(Notification)
	notifs.next_id += 1
	if notifs.next_id == 0 {notifs.next_id = 1}
	n.id = notifs.next_id
	n.at = time.to_unix_seconds(time.now())
	n.app = strings.clone(app)
	n.summary = strings.clone(summary)
	n.body = strings.clone(body)
	n.urgency = min(urgency, 2)
	n.value = -1
	n.rev = notifs.version + 1
	append(&notifs.list, n)
	prune()
	changed()
}

// Older than the history window, or over the size cap: dropped (open ones stay).
@(private = "file")
prune :: proc() {
	cutoff := time.to_unix_seconds(time.now()) - NOTIFY_HISTORY_DAYS * 86400
	stored := 0
	for n in notifs.list {if !n.transient {stored += 1}}
	for i := 0; i < len(notifs.list); {
		n := notifs.list[i]
		if !n.open && (n.at < cutoff || stored > NOTIFY_HISTORY_MAX) {
			if !n.transient {stored -= 1}
			ordered_remove(&notifs.list, i)
			notif_free(n)
			continue
		}
		i += 1
	}
}

// ---- Lifecycle --------------------------------------------------------------------

notifications_start :: proc() {
	notifs.path = strings.concatenate({data_dir(), "/notifications.bin"})
	notifications_load()
	if !config.notifications {return}
	if config.notif_hold_idle > 0 {platform_watch_away(config.notif_hold_idle)}
	g_ctx_notify = context
	if r := sd_bus_open_user(&notifs.bus); r < 0 {
		log.warnf("notifications: no session bus (%d)", r)
		notifs.bus = nil
		return
	}
	sd_bus_add_object(notifs.bus, nil, NOTIFY_PATH, on_message, nil)
	sd_bus_add_match(notifs.bus, nil, "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameAcquired'", on_name_signal, nil)
	sd_bus_add_match(notifs.bus, nil, "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameLost'", on_name_signal, nil)
	// Queue up: if another daemon (dunst, mako) has the name we take over as
	// soon as it goes away.
	r := sd_bus_request_name(notifs.bus, NOTIFY_NAME, SD_BUS_NAME_QUEUE)
	if r > 0 {
		notifs.owner = true
	} else if r == 0 || r == -17 /* EEXIST: queued */ {
		notifs.other = notification_owner()
		log.infof("notifications: %s is handled by %s; waiting for it to go away", NOTIFY_NAME, notifs.other != "" ? notifs.other : "another daemon")
	} else {
		log.warnf("notifications: request_name failed (%d)", r)
	}
	sd_bus_flush(notifs.bus)
}

// The process that currently serves notifications, if any (for the UI).
notification_owner :: proc() -> string {
	out, ok := run({"busctl", "--user", "status", NOTIFY_NAME}, 2 * time.Second, context.temp_allocator)
	if !ok {return ""}
	text := out
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "Comm=") {return strings.clone(strings.trim_space(line[5:]))}
	}
	return ""
}

notifications_shutdown :: proc() {
	notifications_save()
	if notifs.bus != nil {
		sd_bus_flush_close_unref(notifs.bus)
		notifs.bus = nil
	}
}

notifications_fd :: proc() -> (fd: i32, events: i16) {
	if notifs.bus == nil {return -1, 0}
	return i32(sd_bus_get_fd(notifs.bus)), i16(sd_bus_get_events(notifs.bus))
}

// How long the main loop may sleep: bus timeouts, popup expiry, saving.
notifications_timeout :: proc() -> time.Duration {
	best := time.Duration(-1)
	pick :: proc(best: ^time.Duration, d: time.Duration) {
		d := max(d, 0)
		if best^ < 0 || d < best^ {best^ = d}
	}
	if notifs.bus != nil {
		usec: u64
		if sd_bus_get_timeout(notifs.bus, &usec) > 0 && usec != max(u64) {
			// Absolute CLOCK_MONOTONIC time.
			ts: posix.timespec
			posix.clock_gettime(.MONOTONIC, &ts)
			now := u64(ts.tv_sec) * 1_000_000 + u64(ts.tv_nsec) / 1000
			pick(&best, usec > now ? time.Duration(usec - now) * time.Microsecond : 0)
		}
	}
	for n in notifs.list {
		if n.popup && n.expires != {} && !n.hover && !plat.away {pick(&best, time.tick_diff(time.tick_now(), n.expires))}
	}
	if f := notify_popups_next_frame(); f >= 0 {pick(&best, f)}
	if notifs.dirty {pick(&best, 2 * time.Second - time.tick_since(notifs.dirty_at))}
	return best
}

// Called every main-loop iteration (after poll).
notifications_tick :: proc() {
	if notifs.bus != nil {
		for {
			r := sd_bus_process(notifs.bus, nil)
			if r <= 0 {break}
		}
		sd_bus_flush(notifs.bus)
	}
	// A fullscreen game came or went (or moved): popups re-place.
	if s := fullscreen_seq(); s != notifs.fs_seq || config.notif_fullscreen != notifs.fs_mode {
		if s != notifs.fs_seq {fullscreen_log()}
		notifs.fs_seq, notifs.fs_mode = s, config.notif_fullscreen
		notify_popups_layout()
		request_redraw() // the center's "popups held" line
	}
	now := time.tick_now()
	// Away (no input for a while): popups don't time out unseen. Back again:
	// each one gets its full time to be read.
	if plat.away != notifs.was_away {
		notifs.was_away = plat.away
		if !plat.away {
			for n in notifs.list {
				if n.popup && n.expires != {} && n.timeout > 0 {n.expires = time.tick_add(now, n.timeout)}
			}
		}
	}
	for i := len(notifs.list) - 1; i >= 0; i -= 1 {
		n := notifs.list[i]
		if n.popup && n.expires != {} && !n.hover && !plat.away && time.tick_diff(n.expires, now) >= 0 {
			// The popup goes; the notification stays in the center (unread),
			// like dunst's history. Transient ones are gone for good.
			if n.glimpse && !n.transient {
				// Its look over the game is over: it waits for the game to go.
				n.glimpsed = true
				n.expires = {}
				changed()
				continue
			}
			n.popup = false
			n.expires = {}
			if n.transient {
				notif_close(n.id, .Expired)
			} else {
				changed()
			}
		}
	}
	notify_popups_tick()
	if notifs.dirty && time.tick_since(notifs.dirty_at) >= 2 * time.Second {notifications_save()}
	if notifs.bus != nil {sd_bus_flush(notifs.bus)}
}

// Popups on screen: the GPU-release re-exec waits for them.
notifications_busy :: proc() -> bool {
	for n in notifs.list {if n.popup {return true}}
	return false
}

// ---- History file ---------------------------------------------------------------
// Binary: "WLN1", next_id, dnd, icons (key, rounded, ICON_PX² pixels), then
// entries (id, time, urgency, read, value, icon key, app, summary, body,
// desktop). Rewritten whole; only the last NOTIFY_HISTORY_DAYS are kept.

NOTIFY_MAGIC :: 0x314e4c57 // "WLN1"

@(private = "file")
put :: proc(b: ^[dynamic]u8, v: $T) {
	v := v
	append(b, ..([^]u8)(&v)[:size_of(T)])
}

@(private = "file")
put_str :: proc(b: ^[dynamic]u8, s: string) {
	s := s[:min(len(s), 65535)]
	put(b, u16(len(s)))
	append(b, ..transmute([]u8)s)
}

notifications_encode :: proc(list: []^Notification, next_id: u32, dnd: bool, allocator := context.allocator) -> []u8 {
	b := make([dynamic]u8, allocator)
	put(&b, u32(NOTIFY_MAGIC))
	put(&b, next_id)
	put(&b, u8(dnd))
	icons := make(map[u64]^Notif_Icon, 16, context.temp_allocator)
	for n in list {if !n.transient && n.icon != nil {icons[n.icon.key] = n.icon}}
	put(&b, u32(len(icons)))
	for key, ic in icons {
		put(&b, key)
		put(&b, u8(ic.rounded))
		append(&b, ..([^]u8)(raw_data(ic.px))[:ICON_PX * ICON_PX * 4])
	}
	count := 0
	for n in list {if !n.transient {count += 1}}
	put(&b, u32(count))
	for n in list {
		if n.transient {continue}
		put(&b, n.id)
		put(&b, n.at)
		put(&b, n.urgency)
		put(&b, u8(n.read))
		put(&b, n.value)
		put(&b, n.icon != nil ? n.icon.key : 0)
		put_str(&b, n.app)
		put_str(&b, n.summary)
		put_str(&b, n.body)
		put_str(&b, n.desktop)
	}
	return b[:]
}

@(private = "file")
Reader :: struct {
	data: []u8,
	pos:  int,
	ok:   bool,
}

@(private = "file")
get :: proc(r: ^Reader, $T: typeid) -> T {
	if !r.ok || r.pos + size_of(T) > len(r.data) {r.ok = false; return {}}
	v: T
	copy(([^]u8)(&v)[:size_of(T)], r.data[r.pos:])
	r.pos += size_of(T)
	return v
}

@(private = "file")
get_str :: proc(r: ^Reader) -> string {
	n := int(get(r, u16))
	if !r.ok || r.pos + n > len(r.data) {r.ok = false; return ""}
	s := strings.clone(string(r.data[r.pos:r.pos + n]))
	r.pos += n
	return s
}

// Decode a history file. Entries older than `cutoff` are skipped; a damaged
// tail keeps whatever came before it.
notifications_decode :: proc(data: []u8, cutoff: i64) -> (list: [dynamic]^Notification, next_id: u32, dnd: bool) {
	r := Reader{data = data, ok = true}
	if get(&r, u32) != NOTIFY_MAGIC {return}
	next_id = get(&r, u32)
	dnd = get(&r, u8) != 0
	n_icons := int(get(&r, u32))
	icons := make(map[u64]^Notif_Icon, 16, context.temp_allocator)
	for _ in 0 ..< n_icons {
		key := get(&r, u64)
		rounded := get(&r, u8) != 0
		sz := ICON_PX * ICON_PX * 4
		if !r.ok || r.pos + sz > len(r.data) {r.ok = false; break}
		px := make([]u32, ICON_PX * ICON_PX)
		copy(([^]u8)(raw_data(px))[:sz], r.data[r.pos:])
		r.pos += sz
		icons[key] = icon_from_pixels(key, px, rounded)
	}
	n_entries := int(get(&r, u32))
	for _ in 0 ..< n_entries {
		if !r.ok {break}
		n := new(Notification)
		n.id = get(&r, u32)
		n.at = get(&r, i64)
		n.urgency = get(&r, u8)
		n.read = get(&r, u8) != 0
		n.value = get(&r, i32)
		key := get(&r, u64)
		n.app = get_str(&r)
		n.summary = get_str(&r)
		n.body = get_str(&r)
		n.desktop = get_str(&r)
		if !r.ok || n.at < cutoff {
			notif_free(n)
			continue
		}
		n.icon = icons[key]
		append(&list, n)
	}
	return
}

notifications_load :: proc() {
	data, err := os.read_entire_file(notifs.path, context.temp_allocator)
	if err != nil {return}
	cutoff := time.to_unix_seconds(time.now()) - NOTIFY_HISTORY_DAYS * 86400
	list, next_id, dnd := notifications_decode(data, cutoff)
	for n in list {append(&notifs.list, n)}
	delete(list)
	notifs.next_id = max(notifs.next_id, next_id)
	notifs.dnd = dnd
}

notifications_save :: proc() {
	notifs.dirty = false
	if notifs.path == "" {return}
	prune()
	data := notifications_encode(notifs.list[:], notifs.next_id, notifs.dnd, context.temp_allocator)
	os.make_directory_all(data_dir())
	tmp := strings.concatenate({notifs.path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, data); err != nil {
		log.warnf("notifications: cannot write %s: %v", tmp, err)
		return
	}
	os.rename(tmp, notifs.path)
}
