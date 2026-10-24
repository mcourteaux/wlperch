// The bar's audio module: the default output's volume and mute, live.
//
// It runs the daemon's audio code (audio.odin) in the bar process: one
// long-lived `pactl subscribe` re-reads the devices on events (no polling),
// and volume changes go through its applier thread, which keeps at most one
// pactl call running and only the latest value pending, so a fast scroll
// never spawns a process per tick. "Refresh audio" and "Restart audio" are
// the daemon's own (`wlperch audio refresh|restart`), run here when there's
// no daemon.
package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

@(private = "file")
Bar_Audio :: struct {
	started:   bool,
	read:      bool, // the devices were read once (refresher thread sets it)
	sig:       string, // what the module and its menu show, to redraw only on change
	// The last volume we asked for: fast scroll steps build on it, not on a
	// value read back while the earlier steps are still being applied.
	target:    int,
	target_of: string,
	target_at: time.Tick,
	// Right-click menu: sink names by row id.
	sinks:     [dynamic]string,
	click:     Bar_Click,
}
@(private = "file") baud: Bar_Audio

@(private = "file") TARGET_FRESH :: 800 * time.Millisecond

@(private = "file") MENU_MUTE :: 1
@(private = "file") MENU_MIC :: 2
@(private = "file") MENU_REFRESH :: 3
@(private = "file") MENU_RESTART :: 4
@(private = "file") MENU_SETTINGS :: 5
@(private = "file") MENU_SINK0 :: 100

// Start reading audio when the module is on the bar (also after a config change).
bar_audio_maybe_start :: proc() {
	if baud.started || .Audio not_in bar_mods_used() {return}
	baud.started = true
	audio_safety_poll = 0 // events only
	audio_on_change = audio_changed
	audio_start()
}

// Refresher thread: wake the bar only when something it shows changed.
@(private = "file")
audio_changed :: proc() {
	s := signature()
	sync.atomic_store(&baud.read, true)
	if s == baud.sig {
		delete(s)
		return
	}
	old := baud.sig
	baud.sig = s
	delete(old)
	b := u8(1)
	posix.write(bar_wake_w, &b, 1)
}

@(private = "file")
signature :: proc() -> string {
	sync.guard(&audio.mu)
	b := strings.builder_make()
	fmt.sbprintf(&b, "%v %v|", audio.ok, audio.fixing)
	for d in audio.sinks {fmt.sbprintf(&b, "%s %s %s %d %v %v|", d.name, d.label, d.sublabel, pct(d.volume), d.mute, d.is_default)}
	for d in audio.sources {
		if d.is_default {fmt.sbprintf(&b, "%s %s %v|", d.name, d.label, d.mute)}
	}
	return strings.to_string(b)
}

@(private = "file")
pct :: proc(v: f32) -> int {return int(math.round(v * 100))}

// Caller holds audio.mu.
@(private = "file")
default_dev :: proc(is_sink: bool) -> ^Audio_Device {
	if !audio.ok {return nil} // (the lists are what was read last)
	for &d in (is_sink ? audio.sinks : audio.sources) {if d.is_default {return &d}}
	return nil
}

@(private = "file")
dev_title :: proc(d: ^Audio_Device) -> string {
	if d.sublabel == "" {return d.label}
	return fmt.tprintf("%s, %s", d.label, d.sublabel)
}

// The module (bar_build holds bar_data.mu; audio.mu nests inside it).
bar_audio_item :: proc() -> (it: Bar_Item, ok: bool) {
	if !sync.atomic_load(&baud.read) {return}
	sync.guard(&audio.mu)
	p := &bar_pal
	it = module_item(.Audio)
	if !audio.ok {
		// No server (pactl fails): the menu's "Restart audio" is what's wanted.
		bar_seg(&it, ICON_VOLUME_OFF, p.faint)
		it.tooltip = "Audio server unavailable\nRight click: restart audio"
		return it, true
	}
	sink := default_dev(true)
	if sink == nil {
		bar_seg(&it, ICON_VOLUME_OFF, p.faint)
		it.tooltip = "No audio output\nRight click: menu"
		return it, true
	}
	v := pct(sink.volume)
	icon := ICON_VOLUME_HIGH
	switch {
	case sink.mute: icon = ICON_VOLUME_OFF
	case v == 0:    icon = ICON_VOLUME_OFF
	case v < 34:    icon = ICON_VOLUME_LOW
	case v < 67:    icon = ICON_VOLUME_MED
	}
	if sink.mute {
		it.bg, it.bg_alpha = p.red, 0.14
		bar_seg(&it, icon, p.red)
		bar_seg(&it, fmt.tprintf(" %d%%", v), p.faint, tnum = true)
	} else {
		col := v > 100 ? p.orange : p.soft
		bar_seg(&it, icon, col)
		bar_seg(&it, fmt.tprintf(" %d%%", v), col, tnum = true)
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, dev_title(sink))
	fmt.sbprintf(&b, "\nVolume %d%%%s", v, sink.mute ? " · muted" : "")
	if src := default_dev(false); src != nil {
		fmt.sbprintf(&b, "\nMicrophone %s · %s", src.mute ? "muted" : fmt.tprintf("on (%d%%)", pct(src.volume)), src.label)
	} else {
		strings.write_string(&b, "\nNo microphone")
	}
	if audio.fixing == .Refreshing {strings.write_string(&b, "\nRefreshing audio…")}
	if audio.fixing == .Restarting {strings.write_string(&b, "\nRestarting PipeWire…")}
	strings.write_string(&b, "\nScroll: volume · middle click: mute · right click: menu")
	it.tooltip = strings.to_string(b)
	return it, true
}

bar_audio_toggle_mute :: proc() {
	name: string
	{
		sync.guard(&audio.mu)
		d := default_dev(true)
		if d == nil {return}
		name = strings.clone(d.name, context.temp_allocator)
	}
	audio_toggle_mute(name, true)
}

// steps > 0: scrolled down (quieter). Never above 100 %; a volume already
// above it (set elsewhere) only goes down.
bar_audio_scroll :: proc(steps: int) {
	name: string
	cur: int
	{
		sync.guard(&audio.mu)
		d := default_dev(true)
		if d == nil {return}
		name = strings.clone(d.name, context.temp_allocator)
		cur = pct(d.volume)
	}
	if baud.target_of == name && time.tick_since(baud.target_at) < TARGET_FRESH {cur = baud.target}
	next := bar_volume_step(cur, steps, bar_cfg.volume_step)
	if next == cur {return}
	baud.target = next
	baud.target_at = time.tick_now()
	if baud.target_of != name {
		delete(baud.target_of)
		baud.target_of = strings.clone(name)
	}
	audio_set_volume(name, true, f32(next) / 100)
}

// The volume after `steps` scroll steps (> 0: down) of `step` percent, from `cur`.
bar_volume_step :: proc(cur, steps, step: int) -> int {
	if steps < 0 {
		if cur >= 100 {return cur}
		return min(cur + step * -steps, 100)
	}
	return max(cur - step * steps, 0)
}

// ---- Right-click menu --------------------------------------------------------------------

@(private = "file")
node :: proc(id: i32, label: string, sublabel := "", glyph := "", enabled := true) -> Menu_Node {
	return Menu_Node {
		id = id, label = strings.clone(label), sublabel = strings.clone(sublabel), glyph = glyph,
		enabled = enabled, visible = true,
	}
}

// The menu's tree (freed by menu_free).
bar_audio_menu :: proc(ck: Bar_Click) -> (root: Menu_Node) {
	baud.click = ck
	for s in baud.sinks {delete(s)}
	clear(&baud.sinks)
	root.visible = true
	sync.guard(&audio.mu)
	add :: proc(root: ^Menu_Node, n: Menu_Node) {append(&root.children, n)}
	sep :: proc(root: ^Menu_Node) {append(&root.children, Menu_Node{visible = true, separator = true})}
	if sink := default_dev(true); sink != nil {
		add(&root, sink.mute ? node(MENU_MUTE, "Unmute", glyph = ICON_VOLUME_HIGH) : node(MENU_MUTE, "Mute", glyph = ICON_VOLUME_OFF))
	}
	if src := default_dev(false); src != nil {
		add(&root, src.mute ? node(MENU_MIC, "Unmute microphone", src.label, ICON_MIC) : node(MENU_MIC, "Mute microphone", src.label, ICON_MIC_OFF))
	}
	if audio.ok && len(audio.sinks) > 0 {
		sep(&root)
		add(&root, node(0, "Output", enabled = false))
		for &d, i in audio.sinks {
			n := node(i32(MENU_SINK0 + i), d.label, d.sublabel, d.icon) // (icons are constants)
			n.toggle = strings.clone("radio")
			n.toggle_state = d.is_default ? 1 : 0
			add(&root, n)
			append(&baud.sinks, strings.clone(d.name))
		}
	}
	sep(&root)
	busy := audio.fixing != .None
	add(&root, node(MENU_REFRESH, audio.fixing == .Refreshing ? "Refreshing audio…" : "Refresh audio",
		"Switches the output's card to another profile and back", ICON_REFRESH, !busy))
	add(&root, node(MENU_RESTART, audio.fixing == .Restarting ? "Restarting audio…" : "Restart audio",
		"Restarts PipeWire, WirePlumber and pipewire-pulse", ICON_POWER, !busy))
	sep(&root)
	_, pavu := find_program("pavucontrol")
	add(&root, node(MENU_SETTINGS, "Sound settings…", pavu ? "pavucontrol" : "", ICON_COG))
	return
}

bar_audio_menu_activate :: proc(id: i32) {
	switch id {
	case MENU_MUTE:
		bar_audio_toggle_mute()
	case MENU_MIC:
		name: string
		{
			sync.guard(&audio.mu)
			d := default_dev(false)
			if d == nil {return}
			name = strings.clone(d.name, context.temp_allocator)
		}
		audio_toggle_mute(name, false)
	case MENU_REFRESH, MENU_RESTART:
		cmd := id == MENU_REFRESH ? "audio refresh" : "audio restart"
		// The daemon's (it shows a toast when its panel is open); without one, ours.
		if reply, ok := ipc_query(cmd); ok {
			if strings.trim_space(reply) != "ok" {log.warnf("wlperch bar: %s: %s", cmd, strings.trim_space(reply))}
		} else {
			msg: string
			if id == MENU_REFRESH {msg, _ = audio_bounce_profile()} else {msg, _ = audio_restart()}
			log.infof("wlperch bar: %s", msg)
		}
	case MENU_SETTINGS:
		if exe, ok := find_program("pavucontrol"); ok {
			launch_detached({exe})
		} else {
			bar_toggle_panel("audio", baud.click)
		}
	case:
		i := int(id) - MENU_SINK0
		if i >= 0 && i < len(baud.sinks) {audio_set_default(baud.sinks[i], true)}
	}
}
