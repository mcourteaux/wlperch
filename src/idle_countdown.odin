// Countdown before the idle lock: [lock] countdown_seconds before the screen
// locks for inactivity, every output dims from its edges inwards and a card
// in the middle counts down in a draining ring. Any input cancels it.
//
// Who locks: swayidle stays in charge (its `timeout N 'wlperch lock -f'`),
// nothing in the sway config changes. The daemon reads N from this
// session's running swayidle (/proc/<pid>/cmdline, or its config file) and
// asks the compositor (ext-idle-notify-v1) to tell it when there was no
// input for N - countdown_seconds. Both timers run in the compositor from
// the same last input and both honour idle inhibitors, so the countdown
// reaches 0 when swayidle locks; if the daemon is gone, the lock still
// happens, just without the countdown. [lock] idle_lock_seconds > 0 makes
// the daemon lock by itself at the end of the countdown instead (for setups
// without an idle lock in swayidle); when swayidle would lock earlier, that
// lock wins and the countdown follows it.
//
// The overlay never takes input: keyboard_interactivity none and empty input
// regions, so the next key or pointer move goes to the app under it (and
// ends the countdown through the idle notification's `resumed`). It is
// software-rendered into shm (like the notification popups): a small
// vignette buffer scaled to the output by the compositor (wp_viewporter),
// with the card as a desynchronised subsurface. Frames are paced by frame
// callbacks only while it animates; when no countdown runs nothing commits.
//
// GPU-release re-exec: a fresh idle notification counts from its creation,
// so a re-exec while the user is away would push the countdown past the
// lock. While a re-exec is pending the daemon watches input with a short
// notification, re-executes in a pause (or while idle) and hands the time of
// the last input over (reexec.odin), and the new image picks up from there.
package main

import "base:runtime"
import "core:log"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

import "wl"

// Process names of screen lockers (comm, at most 15 characters).
@(rodata)
LOCKER_NAMES := [?]string{"wlperch-lock", "swaylock", "gtklock", "waylock", "hyprlock"}

// ---- Finding when swayidle locks (pure, tested) -----------------------------------

// A swayidle command that locks the screen (not a pgrep / pkill check of
// the locker, as in "timeout 60 'pgrep wlperch-lock && output off'").
is_lock_command :: proc(cmd: string) -> bool {
	if strings.contains(cmd, "unlock-session") {return false}
	if strings.contains(cmd, "wlperch lock") || strings.contains(cmd, "lock-session") {return true}
	if strings.contains(cmd, "pgrep") || strings.contains(cmd, "pkill") || strings.contains(cmd, "killall") {return false}
	for n in LOCKER_NAMES[1:] {
		if strings.contains(cmd, n) {return true}
	}
	return false
}

// swayidle's arguments (without argv[0]): the shortest `timeout N <lock
// command>`. `events`: any event at all (without, swayidle reads its config
// file: `conf`, or the default one).
swayidle_lock_timeout :: proc(args: []string) -> (secs: int, found: bool, events: bool, conf: string) {
	i := 0
	for i < len(args) {
		switch args[i] {
		case "-C", "-S":
			if args[i] == "-C" && i + 1 < len(args) {conf = args[i + 1]}
			i += 2
		case "timeout":
			events = true
			if i + 2 < len(args) {
				if n, ok := strconv.parse_int(args[i + 1]); ok && n > 0 && is_lock_command(args[i + 2]) {
					if !found || n < secs {secs = n}
					found = true
				}
			}
			i += 3
			if i < len(args) && args[i] == "resume" {i += 2}
		case "before-sleep", "after-resume", "lock", "unlock", "idlehint":
			events = true
			i += 2
		case:
			i += 1
		}
	}
	return
}

// Shell-like words of a swayidle config file: quotes, backslashes and
// # comments; newlines separate words like spaces do.
shell_words :: proc(text: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	b := strings.builder_make(allocator)
	in_word := false
	quote: u8 = 0
	flush :: proc(out: ^[dynamic]string, b: ^strings.Builder, in_word: ^bool, allocator: runtime.Allocator) {
		if in_word^ {append(out, strings.clone(strings.to_string(b^), allocator))}
		strings.builder_reset(b)
		in_word^ = false
	}
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if quote != 0 {
			switch {
			case c == quote:
				quote = 0
			case c == '\\' && quote == '"' && i + 1 < len(text):
				i += 1
				strings.write_byte(&b, text[i])
			case:
				strings.write_byte(&b, c)
			}
			continue
		}
		switch c {
		case '\'', '"':
			quote = c
			in_word = true
		case '\\':
			if i + 1 < len(text) {
				i += 1
				if text[i] != '\n' {
					strings.write_byte(&b, text[i])
					in_word = true
				}
			}
		case ' ', '\t', '\n', '\r':
			flush(&out, &b, &in_word, allocator)
		case '#':
			if in_word {
				strings.write_byte(&b, c)
			} else {
				for i + 1 < len(text) && text[i + 1] != '\n' {i += 1}
			}
		case:
			strings.write_byte(&b, c)
			in_word = true
		}
	}
	flush(&out, &b, &in_word, allocator)
	return out[:]
}

// When the screen locks for inactivity (seconds after the last input) and
// whether wlperch locks it itself at the end of the countdown.
Countdown_Plan :: struct {
	lock_after: int, // 0: no idle lock known, no countdown
	length:     int, // countdown seconds, fitted into lock_after
	self_lock:  bool,
}

COUNTDOWN_MIN :: 3 // shorter than this isn't worth showing

// swayidle_secs: swayidle's lock timeout (0 = none found); own: [lock]
// idle_lock_seconds; countdown: [lock] countdown_seconds.
countdown_plan :: proc(swayidle_secs, own, countdown: int) -> Countdown_Plan {
	p: Countdown_Plan
	switch {
	case own > 0 && (swayidle_secs <= 0 || own < swayidle_secs):
		p.lock_after, p.self_lock = own, true
	case swayidle_secs > 0:
		p.lock_after = swayidle_secs
	}
	if p.lock_after > 0 && countdown > 0 {
		// Leave at least a few seconds of idleness before it shows.
		p.length = min(countdown, p.lock_after - 5)
		if p.length < COUNTDOWN_MIN {p.length = 0}
	}
	return p
}

// ---- This session's processes ---------------------------------------------------------

@(private = "file")
read_small :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return "", false}
	return string(data), true
}

// Started in this Wayland session (another sway may run for the same user).
@(private = "file")
same_session :: proc(pid: string, display: string) -> bool {
	if display == "" {return true}
	env, ok := read_small(strings.concatenate({"/proc/", pid, "/environ"}, context.temp_allocator))
	if !ok {return false}
	want := strings.concatenate({"WAYLAND_DISPLAY=", display}, context.temp_allocator)
	for kv in strings.split(env, "\x00", context.temp_allocator) {
		if kv == want {return true}
	}
	return false
}

// Whether a screen locker runs in this session, and the lock timeout of
// this session's swayidle (0 = none found).
session_lock_state :: proc() -> (locked: bool, swayidle_secs: int) {
	me := posix.getuid()
	display := os.get_env("WAYLAND_DISPLAY", context.temp_allocator)
	entries, err := os.read_all_directory_by_path("/proc", context.temp_allocator)
	if err != nil {return}
	for e in entries {
		if _, ok := strconv.parse_int(e.name); !ok {continue}
		st: posix.stat_t
		if posix.stat(strings.clone_to_cstring(strings.concatenate({"/proc/", e.name}, context.temp_allocator), context.temp_allocator), &st) != .OK || st.st_uid != me {continue}
		comm, cok := read_small(strings.concatenate({"/proc/", e.name, "/comm"}, context.temp_allocator))
		if !cok {continue}
		comm = strings.trim_space(comm)
		is_locker := false
		for n in LOCKER_NAMES {if comm == n {is_locker = true}}
		if !is_locker && comm != "swayidle" {continue}
		if !same_session(e.name, display) {continue}
		if is_locker {
			locked = true
			continue
		}
		cmdline, ok := read_small(strings.concatenate({"/proc/", e.name, "/cmdline"}, context.temp_allocator))
		if !ok {continue}
		args := strings.split(strings.trim_right(cmdline, "\x00"), "\x00", context.temp_allocator)
		if len(args) > 0 {args = args[1:]}
		secs, found, events, conf := swayidle_lock_timeout(args)
		if !events {
			secs, found = swayidle_config_lock_timeout(conf)
		}
		if found && (swayidle_secs == 0 || secs < swayidle_secs) {swayidle_secs = secs}
	}
	return
}

// swayidle without events on its command line reads them from a file.
@(private = "file")
swayidle_config_lock_timeout :: proc(conf: string) -> (int, bool) {
	paths := make([dynamic]string, context.temp_allocator)
	if conf != "" {
		append(&paths, conf)
	} else {
		if x := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); x != "" {
			append(&paths, strings.concatenate({x, "/swayidle/config"}, context.temp_allocator))
		}
		append(&paths, strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.config/swayidle/config"}, context.temp_allocator))
		append(&paths, "/etc/swayidle/config")
	}
	for p in paths {
		text, ok := read_small(p)
		if !ok {continue}
		secs, found, _, _ := swayidle_lock_timeout(shell_words(text))
		return secs, found
	}
	return 0, false
}

// ---- State ---------------------------------------------------------------------------

@(private = "file") AUX_TIMEOUT :: 2 * time.Second // input watch while a re-exec is pending
@(private = "file") FADE_IN :: 320 * time.Millisecond
@(private = "file") VIG_FADE_IN :: 700 * time.Millisecond
@(private = "file") CANCEL_FADE :: 180 * time.Millisecond
@(private = "file") END_FADE :: 300 * time.Millisecond // the card, ending END_GAP before the deadline
@(private = "file") END_GAP :: 150 * time.Millisecond // the locker's screenshot must not show the card
@(private = "file") END_HOLD :: 2 * time.Second // after the deadline, waiting for the lock
@(private = "file") FRAME_MIN :: 15 * time.Millisecond // at most ~60 fps
@(private = "file") VIG_EVERY :: 66 * time.Millisecond // the vignette changes slowly: ~15 fps
@(private = "file") FRAME_WATCHDOG :: 150 * time.Millisecond // frame callbacks stop when hidden / locked

@(private = "file")
Phase :: enum {
	Off,
	Shown,  // counting down
	Ending, // past the deadline: vignette held, waiting for the lock
	Fading, // cancelled (input) or no lock came: fading out
}

@(private = "file")
Cd_Out :: struct {
	output:     ^wl.Output,
	surf:       ^wl.Surface, // vignette (layer surface)
	layer:      ^wl.Zwlr_Layer_Surface_V1,
	viewport:   ^wl.Wp_Viewport,
	card:       ^wl.Surface, // the card (subsurface)
	sub:        ^wl.Subsurface,
	configured: bool,
	placed:     bool, // subsurface positioned for this size
	closed:     bool,
	w, h:       i32,
	frame_cb:   ^wl.Callback,
	card_shown: bool, // a card buffer is attached
	base:       []u32, // static part of the card at base_scale / base_light
	base_scale: i32,
	base_light: bool,
	base_gen:   int,
	slots:      [2]Cd_Slot, // the card's buffers, reused frame after frame
	slot_w:     int,
	slot_h:     int,
}

// A shm buffer kept mapped: redrawing only the ring into it is far cheaper
// than a fresh buffer (and its page faults) every frame.
@(private = "file")
Cd_Slot :: struct {
	buf:    ^wl.Buffer,
	px:     []u32,
	mem:    rawptr,
	size:   int,
	busy:   bool, // held by the compositor
	gen:    int,  // base_gen of its static part
	opaque: bool, // last drawn at full opacity (only then is a partial redraw valid)
}

@(private = "file")
cd: struct {
	plan:          Countdown_Plan,
	swayidle_secs: int,
	note:          ^wl.Ext_Idle_Notification_V1,
	note_timeout:  time.Duration,
	note_created:  time.Tick,
	known_idle:    time.Tick, // idle since then when note was created ({}: unknown)
	ev_idled:      bool,
	ev_resumed:    bool,
	idled_at:      time.Tick,
	idle_now:      bool,
	idle_start:    time.Tick, // of the current idle period (while idle_now)
	show_at:       time.Tick, // pending show ({}: none)
	detect_at:     time.Tick, // retry finding swayidle ({}: no retry)
	detect_wait:   time.Duration,
	aux:           ^wl.Ext_Idle_Notification_V1,
	aux_idle:      bool,
	aux_idled_at:  time.Tick,
	// The overlay.
	phase:         Phase,
	preview:       bool, // `wlperch countdown-preview`: no idle period, never locks
	start:         time.Tick,
	deadline:      time.Tick,
	fade_at:       time.Tick, // Fading: started then
	fade_card:     f32, // levels when the fade started
	fade_vig:      f32,
	last_frame:    time.Tick,
	last_vig:      time.Tick,
	outs:          [dynamic]^Cd_Out,
	locked_seen:   bool, // the lock screen asked for lockinfo
} = {detect_wait = 5 * time.Second}

// Overlay on screen: the GPU-release re-exec waits.
countdown_busy :: proc() -> bool {return cd.phase != .Off}

// ---- Idle notifications -----------------------------------------------------------------

@(private = "file")
note_listener := wl.Ext_Idle_Notification_V1_Listener {
	idled = proc "c" (data: rawptr, self: ^wl.Ext_Idle_Notification_V1) {
		if self != cd.note {return}
		cd.ev_idled = true
		cd.idled_at = time.tick_now()
	},
	resumed = proc "c" (data: rawptr, self: ^wl.Ext_Idle_Notification_V1) {
		if self != cd.note {return}
		cd.ev_resumed = true
	},
}

@(private = "file")
aux_listener := wl.Ext_Idle_Notification_V1_Listener {
	idled = proc "c" (data: rawptr, self: ^wl.Ext_Idle_Notification_V1) {
		cd.aux_idle = true
		cd.aux_idled_at = time.tick_now()
	},
	resumed = proc "c" (data: rawptr, self: ^wl.Ext_Idle_Notification_V1) {
		cd.aux_idle = false
	},
}

@(private = "file")
watch :: proc(timeout: time.Duration, known_idle: time.Tick = {}) {
	if cd.note != nil {wl.ext_idle_notification_v1_destroy(cd.note)}
	cd.note = nil
	cd.ev_idled, cd.ev_resumed = false, false
	cd.idle_now = false
	cd.show_at = {}
	if plat.idle_notifier == nil || plat.seat == nil || timeout <= 0 {return}
	cd.note_timeout = timeout
	cd.note_created = time.tick_now()
	cd.known_idle = known_idle
	cd.note = wl.ext_idle_notifier_v1_get_idle_notification(plat.idle_notifier, u32(time.duration_milliseconds(timeout)), plat.seat)
	wl.ext_idle_notification_v1_add_listener(cd.note, &note_listener, nil)
}

@(private = "file")
full_timeout :: proc() -> time.Duration {
	return time.Duration(cd.plan.lock_after - cd.plan.length) * time.Second
}

// Re-read swayidle's timeout; true when the plan changed.
@(private = "file")
replan :: proc(swayidle_secs: int) -> bool {
	cd.swayidle_secs = swayidle_secs
	p := countdown_plan(swayidle_secs, config.lock_idle_seconds, config.lock_countdown_seconds)
	changed := p != cd.plan
	cd.plan = p
	if p.length == 0 && config.lock_countdown_seconds > 0 && config.lock_idle_seconds == 0 {
		// swayidle may not be running yet (both are started by sway): look again later.
		if cd.detect_at == {} {cd.detect_at = time.tick_add(time.tick_now(), cd.detect_wait)}
	} else {
		cd.detect_at = {}
		cd.detect_wait = 5 * time.Second
	}
	if changed {
		if p.length > 0 {
			log.infof("idle countdown: %d s before %s locks after %d s idle", p.length, p.self_lock ? "wlperch" : "swayidle", p.lock_after)
		} else {
			log.infof("idle countdown: off (%s)", config.lock_countdown_seconds == 0 ? "countdown_seconds = 0" : "no idle lock found in swayidle")
		}
	}
	return changed
}

// The time the user went idle saved for a re-exec (0: unknown / active).
countdown_saved :: proc() -> i64 {
	switch {
	case cd.idle_now && cd.idle_start != {}:
		return cd.idle_start._nsec
	case cd.aux != nil && cd.aux_idle:
		return time.tick_add(cd.aux_idled_at, -AUX_TIMEOUT)._nsec
	}
	return 0
}

@(private = "file")
restored_idle: time.Tick

countdown_restore :: proc(idle_since_ns: i64) {
	if idle_since_ns > 0 {restored_idle = time.Tick{idle_since_ns}}
}

// After platform_init: find the lock timeout and start watching.
countdown_init :: proc() {
	if config.lock_countdown_seconds <= 0 {return}
	_, secs := session_lock_state()
	replan(secs)
	if cd.plan.length == 0 {return}
	if restored_idle != {} {
		// The user has been away since before the re-exec: a short watch tells
		// whether they still are; the countdown then counts from restored_idle.
		watch(time.Second, restored_idle)
		restored_idle = {}
	} else {
		watch(full_timeout())
	}
}

// The popup was hidden: a GPU-release re-exec will follow. Watch input
// meanwhile so it can happen in a pause and hand the idle start over.
countdown_on_popup_hidden :: proc() {
	if cd.plan.length == 0 || plat.idle_notifier == nil || plat.seat == nil {return}
	if cd.aux != nil {wl.ext_idle_notification_v1_destroy(cd.aux)}
	cd.aux_idle = false
	cd.aux = wl.ext_idle_notifier_v1_get_idle_notification(plat.idle_notifier, u32(time.duration_milliseconds(AUX_TIMEOUT)), plat.seat)
	wl.ext_idle_notification_v1_add_listener(cd.aux, &aux_listener, nil)
}

countdown_on_popup_shown :: proc() {
	if cd.aux != nil {wl.ext_idle_notification_v1_destroy(cd.aux)}
	cd.aux = nil
	cd.aux_idle = false
}

// Whether the GPU-release re-exec must wait: during the countdown, and until
// the user pauses (so the new image knows when they went idle).
countdown_holds_reexec :: proc() -> bool {
	if cd.phase != .Off {return true}
	return cd.aux != nil && !cd.aux_idle
}

// The lock screen asked the daemon for its info: a lock is up.
countdown_on_locked :: proc() {
	cd.locked_seen = true
	if cd.phase != .Off {
		log.debug("idle countdown: locked")
		destroy_overlay()
	}
	cd.show_at = {}
}

// `wlperch countdown-preview [seconds]`: the overlay without an idle
// period; it never locks.
countdown_preview :: proc(secs: int) -> string {
	if cd.phase != .Off {destroy_overlay()}
	n := secs > 0 ? secs : (config.lock_countdown_seconds > 0 ? config.lock_countdown_seconds : 15)
	cd.preview = true
	show(time.tick_add(time.tick_now(), time.Duration(n) * time.Second))
	return cd.phase == .Off ? "no layer shell\n" : "ok\n"
}

// Main loop: idle events, the pending show, the overlay's frames.
countdown_tick :: proc() {
	now := time.tick_now()
	if cd.detect_at != {} && time.tick_diff(cd.detect_at, now) >= 0 {
		cd.detect_at = {}
		cd.detect_wait = min(cd.detect_wait * 2, 5 * time.Minute)
		_, secs := session_lock_state()
		if replan(secs) && cd.plan.length > 0 {watch(full_timeout())}
	}
	if cd.ev_idled {
		cd.ev_idled = false
		on_idled()
	}
	if cd.ev_resumed {
		cd.ev_resumed = false
		on_resumed()
	}
	if cd.show_at != {} && time.tick_diff(cd.show_at, now) >= 0 {
		cd.show_at = {}
		locked, _ := session_lock_state()
		if !locked && cd.idle_now {show(time.tick_add(cd.idle_start, time.Duration(cd.plan.lock_after) * time.Second))}
	}
	if cd.phase != .Off {overlay_tick(now)}
}

@(private = "file")
on_idled :: proc() {
	now := time.tick_now()
	start := time.tick_add(cd.idled_at, -cd.note_timeout)
	// A watch created while the user was already away: idle since then.
	if cd.known_idle != {} && time.tick_diff(cd.note_created, start) < 100 * time.Millisecond {start = cd.known_idle}
	cd.idle_now = true
	cd.idle_start = start
	cd.locked_seen = false
	locked, secs := session_lock_state()
	replan(secs)
	if locked || cd.plan.length == 0 {return}
	show_at := time.tick_add(start, time.Duration(cd.plan.lock_after - cd.plan.length) * time.Second)
	if time.tick_diff(show_at, now) >= 0 {
		show(time.tick_add(start, time.Duration(cd.plan.lock_after) * time.Second))
	} else {
		cd.show_at = show_at // swayidle's timeout grew, or a short watch
	}
}

@(private = "file")
on_resumed :: proc() {
	cd.idle_now = false
	cd.show_at = {}
	if cd.phase == .Shown || cd.phase == .Ending {
		if cd.locked_seen {destroy_overlay()} else {start_fade(time.tick_now())}
	}
	_, secs := session_lock_state()
	replan(secs)
	if cd.plan.length == 0 {
		watch(0)
	} else if cd.note_timeout != full_timeout() || cd.known_idle != {} || cd.note == nil {
		watch(full_timeout())
	}
}

// ---- The overlay ----------------------------------------------------------------------------

@(private = "file") CARD_W :: 300
@(private = "file") CARD_H :: 282
@(private = "file") SH :: 30 // shadow margin around the card
@(private = "file") RADIUS :: 26
@(private = "file") RING_R :: 80
@(private = "file") RING_W :: 9
@(private = "file") RING_CY :: 26 + 88 // from the card's top
@(private = "file") VIG_W :: 128 // vignette buffer width (scaled up by the compositor)

@(private = "file")
layer_listener := wl.Zwlr_Layer_Surface_V1_Listener {
	configure = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1, serial, width, height: u32) {
		o := (^Cd_Out)(data)
		wl.zwlr_layer_surface_v1_ack_configure(self, serial)
		if i32(width) != o.w || i32(height) != o.h {o.placed = false}
		o.w, o.h = i32(width), i32(height)
		o.configured = true
	},
	closed = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1) {
		(^Cd_Out)(data).closed = true
	},
}

@(private = "file")
frame_listener := wl.Callback_Listener {
	done = proc "c" (data: rawptr, self: ^wl.Callback, t: u32) {
		o := (^Cd_Out)(data)
		wl.callback_destroy(self)
		if o.frame_cb == self {o.frame_cb = nil}
	},
}

@(private = "file")
empty_input :: proc(s: ^wl.Surface) {
	r := wl.compositor_create_region(plat.compositor)
	wl.surface_set_input_region(s, r)
	wl.region_destroy(r)
}

@(private = "file")
show :: proc(deadline: time.Tick) {
	if cd.phase != .Off {return}
	if plat.layer_shell == nil || plat.compositor == nil || plat.shm == nil || plat.subcompositor == nil || plat.viewporter == nil {return}
	now := time.tick_now()
	cd.start = now
	cd.deadline = deadline
	cd.phase = .Shown
	cd.last_frame, cd.last_vig = {}, {}
	// Every output: the lock covers them all, and the user may be looking at any.
	for po in plat.outputs {
		o := new(Cd_Out)
		o.output = po.output
		o.surf = wl.compositor_create_surface(plat.compositor)
		o.layer = wl.zwlr_layer_shell_v1_get_layer_surface(plat.layer_shell, o.surf, po.output, wl.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "wlperch-lock-countdown")
		wl.zwlr_layer_surface_v1_add_listener(o.layer, &layer_listener, o)
		wl.zwlr_layer_surface_v1_set_anchor(o.layer, wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT)
		wl.zwlr_layer_surface_v1_set_exclusive_zone(o.layer, -1) // over the bar too
		wl.zwlr_layer_surface_v1_set_keyboard_interactivity(o.layer, 0) // never takes the keyboard
		wl.zwlr_layer_surface_v1_set_size(o.layer, 0, 0)
		o.viewport = wl.wp_viewporter_get_viewport(plat.viewporter, o.surf)
		empty_input(o.surf)
		o.card = wl.compositor_create_surface(plat.compositor)
		o.sub = wl.subcompositor_get_subsurface(plat.subcompositor, o.card, o.surf)
		wl.subsurface_set_desync(o.sub)
		empty_input(o.card)
		wl.surface_commit(o.surf)
		append(&cd.outs, o)
	}
	log.debugf("idle countdown: shown, %.1f s left", time.duration_seconds(time.tick_diff(now, deadline)))
}

@(private = "file")
destroy_out :: proc(o: ^Cd_Out) {
	if o.frame_cb != nil {wl.callback_destroy(o.frame_cb)}
	wl.subsurface_destroy(o.sub)
	wl.surface_destroy(o.card)
	slots_free(o)
	wl.wp_viewport_destroy(o.viewport)
	wl.zwlr_layer_surface_v1_destroy(o.layer)
	wl.surface_destroy(o.surf)
	delete(o.base)
	free(o)
}

@(private = "file")
destroy_overlay :: proc() {
	for o in cd.outs {destroy_out(o)}
	clear(&cd.outs)
	if cd.phase != .Off {log.debug("idle countdown: hidden")}
	cd.phase = .Off
	cd.preview = false
}

// 0..1 ease-out (cubic).
@(private = "file")
ease :: proc(t: f32) -> f32 {
	u := 1 - clamp(t, 0, 1)
	return 1 - u * u * u
}

@(private = "file")
secs_f :: proc(d: time.Duration) -> f32 {return f32(time.duration_seconds(d))}

// Opacity of the card and strength (0..1) of the vignette at `now`.
@(private = "file")
levels :: proc(now: time.Tick) -> (card, vig: f32) {
	switch cd.phase {
	case .Off:
		return 0, 0
	case .Shown:
		since := time.tick_diff(cd.start, now)
		card = ease(secs_f(since) / secs_f(FADE_IN))
		left := time.tick_diff(now, cd.deadline)
		card *= clamp(secs_f(left - END_GAP) / secs_f(END_FADE), 0, 1)
		total := max(secs_f(time.tick_diff(cd.start, cd.deadline)), 0.001)
		p := clamp(secs_f(since) / total, 0, 1)
		vig = (0.35 + 0.65 * p) * ease(secs_f(since) / secs_f(VIG_FADE_IN))
	case .Ending:
		return 0, 1
	case .Fading:
		k := 1 - ease(secs_f(time.tick_diff(cd.fade_at, now)) / secs_f(CANCEL_FADE))
		return cd.fade_card * k, cd.fade_vig * k
	}
	return
}

@(private = "file")
start_fade :: proc(now: time.Tick) {
	cd.fade_card, cd.fade_vig = levels(now)
	cd.fade_at = now
	cd.phase = .Fading
}

@(private = "file")
self_exe :: proc() -> string {
	if target, err := os.read_link("/proc/self/exe", context.temp_allocator); err == nil {
		path := strings.trim_suffix(target, " (deleted)")
		if os.exists(path) {return path}
	}
	return "wlperch"
}

@(private = "file")
overlay_tick :: proc(now: time.Tick) {
	for i := len(cd.outs) - 1; i >= 0; i -= 1 {
		if cd.outs[i].closed {
			destroy_out(cd.outs[i])
			ordered_remove(&cd.outs, i)
		}
	}
	if len(cd.outs) == 0 && cd.phase != .Off {
		destroy_overlay()
		return
	}
	switch cd.phase {
	case .Off:
		return
	case .Shown:
		if time.tick_diff(cd.deadline, now) >= 0 {
			cd.phase = .Ending
			if cd.preview {
				start_fade(now)
			} else if cd.plan.self_lock {
				locked, _ := session_lock_state()
				if !locked {
					ok := launch_detached({self_exe(), "lock", "-f"})
					log.infof("idle countdown: locking%s", ok ? "" : " failed")
				}
			}
		}
	case .Ending:
		if time.tick_diff(time.tick_add(cd.deadline, END_HOLD), now) >= 0 {
			locked, _ := session_lock_state()
			if locked {
				destroy_overlay()
				return
			}
			log.warn("idle countdown: the screen didn't lock")
			start_fade(now)
		}
	case .Fading:
		if time.tick_diff(cd.fade_at, now) >= CANCEL_FADE {
			destroy_overlay()
			return
		}
	}
	if next_frame_in(now) == 0 {render_all(now)}
}

// 0: draw now; > 0: wait that long; -1: nothing to draw (no animation).
@(private = "file")
next_frame_in :: proc(now: time.Tick) -> time.Duration {
	needs := false
	for o in cd.outs {
		if !o.configured {continue}
		if !o.placed {return 0}
		needs = true
	}
	if !needs {return -1}
	if cd.phase == .Ending {
		// The card is gone; the vignette holds still. Unmap the card once.
		for o in cd.outs {if o.card_shown {return 0}}
		return -1
	}
	if cd.last_frame == {} {return 0}
	waiting := false
	for o in cd.outs {if o.frame_cb != nil {waiting = true}}
	since := time.tick_diff(cd.last_frame, now)
	if waiting && since < FRAME_WATCHDOG {return FRAME_WATCHDOG - since}
	if since < FRAME_MIN {return FRAME_MIN - since}
	return 0
}

// How long the main loop may sleep (-1: no limit).
countdown_timeout :: proc() -> time.Duration {
	now := time.tick_now()
	best := time.Duration(-1)
	consider :: proc(best: ^time.Duration, d: time.Duration) {
		d := max(d, 0)
		if best^ < 0 || d < best^ {best^ = d}
	}
	if cd.detect_at != {} {consider(&best, time.tick_diff(now, cd.detect_at))}
	if cd.show_at != {} {consider(&best, time.tick_diff(now, cd.show_at))}
	switch cd.phase {
	case .Off:
	case .Shown:
		consider(&best, time.tick_diff(now, cd.deadline))
	case .Ending:
		consider(&best, time.tick_diff(now, time.tick_add(cd.deadline, END_HOLD)))
	case .Fading:
		consider(&best, CANCEL_FADE - time.tick_diff(cd.fade_at, now))
	}
	if cd.phase != .Off {
		if f := next_frame_in(now); f >= 0 {consider(&best, f)}
	}
	return best
}

@(private = "file")
out_scale :: proc(o: ^Cd_Out) -> i32 {
	for po in plat.outputs {if po.output == o.output {return max(po.scale, 1)}}
	return 1
}

@(private = "file")
render_all :: proc(now: time.Tick) {
	card_a, vig := levels(now)
	vig_due := cd.last_vig == {} || time.tick_diff(cd.last_vig, now) >= VIG_EVERY || cd.phase != .Shown || time.tick_diff(cd.start, now) < VIG_FADE_IN
	for o in cd.outs {
		if !o.configured || o.w <= 0 || o.h <= 0 {continue}
		committed_card := false
		if card_a > 0.002 && cd.phase != .Ending {
			draw_card(o, now, card_a)
			committed_card = true
		} else if o.card_shown {
			wl.surface_attach(o.card, nil, 0, 0)
			wl.surface_commit(o.card)
			o.card_shown = false
		}
		if vig_due || !o.placed {
			if !o.placed {
				cw, ch := i32(CARD_W + 2 * SH), i32(CARD_H + 2 * SH)
				wl.subsurface_set_position(o.sub, (o.w - cw) / 2, (o.h - ch) / 2)
				wl.wp_viewport_set_destination(o.viewport, o.w, o.h)
				o.placed = true
			}
			draw_vignette(o, vig)
			if !committed_card && o.frame_cb == nil {
				o.frame_cb = wl.surface_frame(o.surf)
				wl.callback_add_listener(o.frame_cb, &frame_listener, o)
			}
			wl.surface_commit(o.surf)
		}
	}
	cd.last_frame = now
	if vig_due {cd.last_vig = now}
}

// ---- Drawing --------------------------------------------------------------------------------

@(private = "file")
put :: proc(dst: ^u32, rgb: u32, a: f32) {
	if a <= 0 {return}
	inv := 1 - a
	d := dst^
	na := u32(255 * a + f32((d >> 24) & 0xff) * inv + 0.5)
	nr := u32(f32((rgb >> 16) & 0xff) * a + f32((d >> 16) & 0xff) * inv + 0.5)
	ng := u32(f32((rgb >> 8) & 0xff) * a + f32((d >> 8) & 0xff) * inv + 0.5)
	nb := u32(f32(rgb & 0xff) * a + f32(d & 0xff) * inv + 0.5)
	dst^ = min(na, 255) << 24 | min(nr, 255) << 16 | min(ng, 255) << 8 | min(nb, 255)
}

@(private = "file")
mix :: proc(a, b: u32, t: f32) -> u32 {
	t := clamp(t, 0, 1)
	out: u32
	for sh in ([]u32{16, 8, 0}) {
		x := f32((a >> sh) & 0xff) * (1 - t) + f32((b >> sh) & 0xff) * t
		out |= u32(x + 0.5) << sh
	}
	return out
}

// A stand-in for the clockwise angle from 12 o'clock of the direction
// (u right, v up), in [0, 4): monotonic in the angle, so comparing two is
// like comparing angles, without atan2 (which dominated the frame time).
pseudo_angle :: proc(u, v: f32) -> f32 {
	if u >= 0 {return v >= 0 ? u / max(u + v, 1e-9) : 1 - v / (u - v)}
	return v < 0 ? 2 - u / (-u - v) : 3 + v / (v - u)
}

// A ring arc of radius r (logical, centre line) and width w, from 12 o'clock
// clockwise over `frac` of the circle, with round caps and a soft glow.
@(private = "file")
draw_arc :: proc(cv: ^Bar_Canvas, cx, cy, r, w, frac: f32, rgb: u32, glow: f32 = 0) {
	if frac <= 0 {return}
	s := cv.s
	CX, CY, R, HW, G := cx * s, cy * s, r * s, w * s / 2, glow * s
	ext := HW + G + 1
	end := clamp(frac, 0, 1) * 2 * math.PI
	full := frac >= 1
	ex, ey := CX + R * math.sin(end), CY - R * math.cos(end)
	end_pa := pseudo_angle(math.sin(end), math.cos(end))
	x0, x1 := max(int(CX - R - ext), 0), min(int(CX + R + ext) + 1, cv.w)
	y0, y1 := max(int(CY - R - ext), 0), min(int(CY + R + ext) + 1, cv.h)
	ro, ri := R + ext, max(R - ext, 0)
	for y in y0 ..< y1 {
		py := f32(y) + 0.5 - CY
		if abs(py) > ro {continue}
		// Only the band between the two circles on this row.
		xo := math.sqrt(ro * ro - py * py)
		xi := abs(py) < ri ? math.sqrt(ri * ri - py * py) : 0
		xa, xb := max(int(CX - xo), x0), min(int(CX + xo) + 1, x1)
		for x in xa ..< xb {
			px := f32(x) + 0.5 - CX
			if abs(px) < xi - 1 {continue}
			dist := math.sqrt(px * px + py * py)
			dr := abs(dist - R)
			if dr > ext {continue}
			d := dr
			if !full {
				if pseudo_angle(px, -py) > end_pa {
					// Past the arc: distance to the caps.
					sx, sy := f32(x) + 0.5 - CX, f32(y) + 0.5 - (CY - R)
					qx, qy := f32(x) + 0.5 - ex, f32(y) + 0.5 - ey
					d = min(math.sqrt(sx * sx + sy * sy), math.sqrt(qx * qx + qy * qy))
				}
			}
			p := &cv.px[y * cv.w + x]
			if G > 0 && d > HW - 1 {
				g := clamp(1 - (d - HW) / G, 0, 1)
				put(p, rgb, g * g * 0.28)
			}
			put(p, rgb, clamp(HW + 0.5 - d, 0, 1))
		}
	}
}

@(private = "file")
center_text :: proc(cv: ^Bar_Canvas, f: Bar_Font, px, cx, baseline: f32, s: string, rgb: u32, alpha: f32 = 1) {
	bar_text(cv, f, px, cx - bar_text_width(f, px, s) / 2, baseline, s, rgb, alpha)
}

// The parts that don't change while counting: shadow, card, track, labels.
@(private = "file")
draw_base :: proc(cv: ^Bar_Canvas) {
	card := Bar_Rect{SH, SH, CARD_W, CARD_H}
	bar_shadow(cv, card, RADIUS, SH - 4)
	bar_fill_round(cv, card, RADIUS, C_CARD, 1)
	bar_stroke(cv, card, {RADIUS, RADIUS, RADIUS, RADIUS}, theme_light ? 0x000000 : 0xffffff, theme_light ? 0.08 : 0.07)
	cx, cy := f32(SH + CARD_W / 2), f32(SH + RING_CY)
	draw_arc(cv, cx, cy, RING_R, RING_W, 1, C_TRACK)
	center_text(cv, .Regular, 12.5, cx, cy - 31, "Locking in", C_MUTED)
	center_text(cv, .Regular, 12, cx, cy + 45, "seconds", C_FAINT)
	y := f32(SH + RING_CY + RING_R + RING_W / 2 + 34)
	center_text(cv, .Bold, 15.5, cx, y, "Still there?", C_TEXT)
	center_text(cv, .Regular, 12.5, cx, y + 22, "Move the mouse or press a key to stay.", C_MUTED)
}

// Scale every (premultiplied) pixel: fades the whole card.
@(private = "file")
fade_pixels :: proc(px: []u32, a: f32) {
	k := u32(clamp(a, 0, 1) * 256 + 0.5)
	if k >= 256 {return}
	for &p in px {
		if p == 0 {continue}
		rb := ((p & 0x00ff00ff) * k >> 8) & 0x00ff00ff
		ag := (((p >> 8) & 0x00ff00ff) * k) & 0xff00ff00
		p = rb | ag
	}
}

@(private = "file")
slot_listener := wl.Buffer_Listener {
	release = proc "c" (data: rawptr, self: ^wl.Buffer) {(^Cd_Slot)(data).busy = false},
}

@(private = "file")
slots_free :: proc(o: ^Cd_Out) {
	for &sl in o.slots {
		if sl.buf != nil {wl.buffer_destroy(sl.buf)}
		if sl.mem != nil {posix.munmap(sl.mem, uint(sl.size))}
		sl = {}
	}
	o.slot_w, o.slot_h = 0, 0
}

@(private = "file")
slots_ensure :: proc(o: ^Cd_Out, w, h: int) -> bool {
	if o.slot_w == w && o.slot_h == h {return true}
	slots_free(o)
	size := w * h * 4
	for &sl in o.slots {
		fd, err := linux.memfd_create("wlperch-countdown", {.CLOEXEC})
		if err != .NONE {return false}
		defer linux.close(fd)
		if linux.ftruncate(fd, i64(size)) != .NONE {return false}
		mem := posix.mmap(nil, uint(size), {.READ, .WRITE}, {.SHARED}, posix.FD(fd), 0)
		if mem == posix.MAP_FAILED {return false}
		pool := wl.shm_create_pool(plat.shm, i32(fd), i32(size))
		sl.buf = wl.shm_pool_create_buffer(pool, 0, i32(w), i32(h), i32(w * 4), wl.SHM_FORMAT_ARGB8888)
		wl.shm_pool_destroy(pool)
		wl.buffer_add_listener(sl.buf, &slot_listener, &sl)
		sl.mem, sl.size = mem, size
		sl.px = ([^]u32)(mem)[:w * h]
		sl.gen = -1
	}
	o.slot_w, o.slot_h = w, h
	return true
}

@(private = "file")
draw_card :: proc(o: ^Cd_Out, now: time.Tick, alpha: f32) {
	s := out_scale(o)
	w, h := int(CARD_W + 2 * SH) * int(s), int(CARD_H + 2 * SH) * int(s)
	if o.base == nil || o.base_scale != s || o.base_light != theme_light {
		delete(o.base)
		o.base = make([]u32, w * h)
		cv := Bar_Canvas{px = o.base, w = w, h = h, s = f32(s)}
		draw_base(&cv)
		o.base_scale, o.base_light = s, theme_light
		o.base_gen += 1
	}
	if !slots_ensure(o, w, h) {return}
	sl: ^Cd_Slot
	for &x in o.slots {
		if !x.busy {
			sl = &x
			break
		}
	}
	if sl == nil {return} // both still on screen: skip a frame
	cv := Bar_Canvas{px = sl.px, w = w, h = h, s = f32(s)}

	cx, cy := f32(SH + CARD_W / 2), f32(SH + RING_CY)
	// Only the ring and the number change while fully opaque.
	GLOW :: 7
	ext := f32(RING_R + RING_W / 2 + GLOW + 2)
	rx0, ry0 := max(int((cx - ext) * f32(s)), 0), max(int((cy - ext) * f32(s)), 0)
	rx1, ry1 := min(int((cx + ext) * f32(s)) + 1, w), min(int((cy + ext) * f32(s)) + 1, h)
	partial := alpha >= 1 && sl.opaque && sl.gen == o.base_gen
	if partial {
		for y in ry0 ..< ry1 {copy(sl.px[y * w + rx0:y * w + rx1], o.base[y * w + rx0:y * w + rx1])}
	} else {
		copy(sl.px, o.base)
	}

	left := max(secs_f(time.tick_diff(now, cd.deadline)), 0)
	total := max(secs_f(time.tick_diff(cd.start, cd.deadline)), 0.001)
	// The accent, turning orange for the last three seconds (a quick
	// cross-fade: mixing the two for longer looks muddy).
	col := mix(C_BLUE, C_ORANGE, (3.15 - left) / 0.3)
	draw_arc(&cv, cx, cy, RING_R, RING_W, left / total, col, GLOW)
	n := max(int(math.ceil(left)), 1)
	// Each new number pops in: a little larger and fainter, settling.
	pop := ease((f32(n) - left) / 0.28)
	size := 56 * (1 + 0.12 * (1 - pop))
	center_text(&cv, .Bold, size, cx, cy + 0.36 * size, int_to_string(n), C_TEXT, 0.55 + 0.45 * pop)
	if alpha < 1 {fade_pixels(sl.px, alpha)}
	sl.gen, sl.opaque = o.base_gen, alpha >= 1

	wl.surface_set_buffer_scale(o.card, s)
	wl.surface_attach(o.card, sl.buf, 0, 0)
	if partial {
		wl.surface_damage_buffer(o.card, i32(rx0), i32(ry0), i32(rx1 - rx0), i32(ry1 - ry0))
	} else {
		wl.surface_damage_buffer(o.card, 0, 0, i32(w), i32(h))
	}
	sl.busy = true
	o.frame_cb = wl.surface_frame(o.card)
	wl.callback_add_listener(o.frame_cb, &frame_listener, o)
	wl.surface_commit(o.card)
	o.card_shown = true
}

// The screen dims from its edges in: a small buffer the compositor scales up
// (bilinear, so it stays smooth). Dark theme: towards black; light: a soft fog.
@(private = "file")
draw_vignette :: proc(o: ^Cd_Out, strength: f32) {
	vw := VIG_W
	vh := max(int(f32(VIG_W) * f32(o.h) / f32(o.w) + 0.5), 8)
	b, ok := bar_buffer_new(vw, vh, 1)
	if !ok {return}
	rgb: u32 = theme_light ? 0xdfe3ea : 0x05060a
	peak: f32 = theme_light ? 0.7 : 0.78
	for y in 0 ..< vh {
		ny := (f32(y) + 0.5) / f32(vh) * 2 - 1
		for x in 0 ..< vw {
			nx := (f32(x) + 0.5) / f32(vw) * 2 - 1
			d := math.sqrt(nx * nx + ny * ny) / math.SQRT_TWO
			t := clamp((d - 0.1) / 0.9, 0, 1)
			edge := t * t * (3 - 2 * t)
			a := clamp(strength * peak * (0.2 + 0.8 * edge), 0, 1)
			A := u32(a * 255 + 0.5)
			r := u32(f32((rgb >> 16) & 0xff) * a + 0.5)
			g := u32(f32((rgb >> 8) & 0xff) * a + 0.5)
			bl := u32(f32(rgb & 0xff) * a + 0.5)
			b.cv.px[y * vw + x] = A << 24 | r << 16 | g << 8 | bl
		}
	}
	bar_buffer_attach(&b, plat.shm, o.surf, 1)
}
