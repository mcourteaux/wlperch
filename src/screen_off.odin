// Monitors off after a long idle: [lock] screen_off_seconds after the last
// input the daemon powers off every monitor that is on, and the next input
// powers those back on. Like the idle countdown it asks the compositor
// (ext-idle-notify-v1) when there was no input for that long, so idle
// inhibitors (a playing video) keep the screens on, and it runs whether or
// not the screen is locked.
//
// Only monitors it turned off itself are turned back on: ones the lock
// screen's "screens off" button or the user powered off stay off (the lock
// screen wakes its own, after its grace period). Which ones it owns is kept
// in $XDG_RUNTIME_DIR/wlperch-screens-off, so a re-exec or a crash of the
// daemon while they're off doesn't leave them dark: the next image picks
// the file up and wakes them at the next input.
package main

import "core:log"
import "core:os"
import "core:strings"
import "core:time"

import "wl"

// A monitor as sway reports it, for the power decision.
Out_Power :: struct {
	name:          string,
	active, power: bool,
}

// The monitors to power off: enabled and on.
screens_to_power_off :: proc(outs: []Out_Power, allocator := context.temp_allocator) -> []string {
	names := make([dynamic]string, allocator)
	for o in outs {if o.active && o.power {append(&names, o.name)}}
	return names[:]
}

// The sway command that powers `names` on or off ("" for none).
screen_power_command :: proc(names: []string, on: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	for n, i in names {
		if i > 0 {strings.write_string(&b, "; ")}
		strings.write_string(&b, "output \"")
		strings.write_string(&b, sway_quote(n))
		strings.write_string(&b, on ? "\" power on" : "\" power off")
	}
	return strings.to_string(b)
}

@(private = "file")
SHORT_WATCH :: time.Second // after a re-exec: is the user still away?

@(private = "file")
so: struct {
	note:         ^wl.Ext_Idle_Notification_V1,
	note_timeout: time.Duration,
	note_created: time.Tick,
	known_idle:   time.Tick, // idle since then when note was created ({}: unknown)
	ev_idled:     bool,
	ev_resumed:   bool,
	idled_at:     time.Tick,
	off_at:       time.Tick, // pending power-off ({}: none)
	owned:        [dynamic]string, // monitors we powered off
	idle_start:   time.Tick, // while idle ({}: active or unknown)
}

@(private = "file")
restored_idle: time.Tick

@(private = "file")
note_listener := wl.Ext_Idle_Notification_V1_Listener {
	idled = proc "c" (data: rawptr, self: ^wl.Ext_Idle_Notification_V1) {
		if self != so.note {return}
		so.ev_idled = true
		so.idled_at = time.tick_now()
	},
	resumed = proc "c" (data: rawptr, self: ^wl.Ext_Idle_Notification_V1) {
		if self != so.note {return}
		so.ev_resumed = true
	},
}

@(private = "file")
marker_path :: proc() -> string {
	dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if dir == "" {return ""}
	return strings.concatenate({dir, "/wlperch-screens-off"}, context.temp_allocator)
}

@(private = "file")
save_owned :: proc() {
	path := marker_path()
	if path == "" {return}
	if len(so.owned) == 0 {
		os.remove(path)
		return
	}
	text := strings.concatenate({strings.join(so.owned[:], "\n", context.temp_allocator), "\n"}, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]u8)text)
}

@(private = "file")
clear_owned :: proc() {
	for n in so.owned {delete(n)}
	clear(&so.owned)
}

@(private = "file")
watch :: proc(timeout: time.Duration, known_idle: time.Tick = {}) {
	if so.note != nil {wl.ext_idle_notification_v1_destroy(so.note)}
	so.note = nil
	so.ev_idled, so.ev_resumed = false, false
	so.off_at = {}
	so.idle_start = {}
	if plat.idle_notifier == nil || plat.seat == nil || timeout <= 0 {return}
	so.note_timeout = timeout
	so.note_created = time.tick_now()
	so.known_idle = known_idle
	so.note = wl.ext_idle_notifier_v1_get_idle_notification(plat.idle_notifier, u32(time.duration_milliseconds(timeout)), plat.seat)
	wl.ext_idle_notification_v1_add_listener(so.note, &note_listener, nil)
}

@(private = "file")
full_timeout :: proc() -> time.Duration {return time.Duration(config.lock_screen_off_seconds) * time.Second}

// The monitors as sway has them now.
@(private = "file")
sway_out_power :: proc() -> []Out_Power {
	outs := make([dynamic]Out_Power, context.temp_allocator)
	reply, ok := sway_request(IPC_GET_OUTPUTS, "")
	if !ok {return nil}
	v, jok := jparse(reply)
	if !jok {return nil}
	for o in jarr(v) {
		append(&outs, Out_Power{strings.clone(jstr(jobj(o, "name")), context.temp_allocator), jbool(jobj(o, "active")), jbool(jobj(o, "power"), true)})
	}
	return outs[:]
}

@(private = "file")
power_off :: proc() {
	names := screens_to_power_off(sway_out_power())
	if len(names) == 0 {return} // already dark (the lock screen's button, or by hand)
	if !sway_command(screen_power_command(names, false)) {
		log.warn("screen off: sway refused to power the monitors off")
		return
	}
	for n in names {append(&so.owned, strings.clone(n))}
	save_owned()
	log.infof("screen off: %d monitor(s) off after %d s idle", len(names), config.lock_screen_off_seconds)
}

@(private = "file")
power_on :: proc() {
	if len(so.owned) == 0 {return}
	sway_command(screen_power_command(so.owned[:], true))
	log.infof("screen off: %d monitor(s) back on", len(so.owned))
	clear_owned()
	save_owned()
}

// The time the user went idle, for a re-exec (0: unknown / active).
screen_off_saved :: proc() -> i64 {
	if so.idle_start != {} {return so.idle_start._nsec}
	return 0
}

screen_off_restore :: proc(idle_since_ns: i64) {
	if idle_since_ns > 0 {restored_idle = time.Tick{idle_since_ns}}
}

// After platform_init.
screen_off_init :: proc() {
	// Monitors a previous image powered off and that are still off: ours.
	if path := marker_path(); path != "" {
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
			outs := sway_out_power()
			for line in strings.split_lines(string(data), context.temp_allocator) {
				n := strings.trim_space(line)
				if n == "" {continue}
				for o in outs {if o.name == n && o.active && !o.power {append(&so.owned, strings.clone(n))}}
			}
			save_owned()
		}
	}
	if len(so.owned) > 0 || restored_idle != {} {
		// The user may still be away: a short watch tells, and its `resumed` wakes our monitors.
		watch(SHORT_WATCH, restored_idle)
	} else if config.lock_screen_off_seconds > 0 {
		watch(full_timeout())
	}
	restored_idle = {}
	if config.lock_screen_off_seconds > 0 {log.infof("screen off: after %d s idle", config.lock_screen_off_seconds)}
}

// Main loop.
screen_off_tick :: proc() {
	if so.ev_idled {
		so.ev_idled = false
		start := time.tick_add(so.idled_at, -so.note_timeout)
		// A watch made while the user was already away (no input since): idle since then.
		if so.known_idle != {} && time.tick_diff(so.note_created, start) < 100 * time.Millisecond {start = so.known_idle}
		so.idle_start = start
		if len(so.owned) == 0 && config.lock_screen_off_seconds > 0 {
			so.off_at = time.tick_add(start, full_timeout())
		}
	}
	if so.ev_resumed {
		so.ev_resumed = false
		power_on()
		watch(config.lock_screen_off_seconds > 0 ? full_timeout() : 0)
	}
	if so.off_at != {} && time.tick_diff(so.off_at, time.tick_now()) >= 0 {
		so.off_at = {}
		power_off()
	}
}

// How long the main loop may sleep (-1: no limit).
screen_off_timeout :: proc() -> time.Duration {
	if so.off_at == {} {return -1}
	return max(time.tick_diff(time.tick_now(), so.off_at), 0)
}
