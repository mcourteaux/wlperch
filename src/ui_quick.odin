// Quick settings: one-click toggles, keyboard layouts and links to the other panels.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

import im "third_party:odin-imgui"

// ---- Do not disturb (dunst) ---------------------------------------------------

Dnd :: struct {
	mu:      sync.Mutex,
	ok:      bool, // dunstctl answered
	paused:  bool,
	pending: bool,
}
dnd: Dnd

@(private = "file")
dunstctl_path :: proc() -> string {
	for dir in strings.split(os.get_env("PATH", context.temp_allocator), ":", context.temp_allocator) {
		p := strings.concatenate({dir, "/dunstctl"}, context.temp_allocator)
		if os.exists(p) {return p}
	}
	return ""
}

dnd_poll_async :: proc() {
	if dunstctl_path() == "" {return}
	thread.create_and_start(proc() {
		out, ok := run({"dunstctl", "is-paused"}, allocator = context.temp_allocator)
		{
			sync.guard(&dnd.mu)
			dnd.ok = ok
			dnd.paused = ok && strings.trim_space(out) == "true"
			dnd.pending = false
		}
		free_all(context.temp_allocator)
		request_redraw()
	}, self_cleanup = true)
}

@(private = "file")
dnd_set :: proc(paused: bool) {
	{
		sync.guard(&dnd.mu)
		dnd.paused = paused
		dnd.pending = true
	}
	run_async({"dunstctl", "set-paused", paused ? "true" : "false"}, dnd_poll_async)
}

@(private = "file")
bluetooth_set_power :: proc(on: bool) {
	{
		sync.guard(&bluetooth.mu)
		bluetooth.powered = on
	}
	run_async({"bluetoothctl", "power", on ? "on" : "off"}, bluetooth_refresh_async)
}

// ---- Tiles --------------------------------------------------------------------

@(private = "file")
TILE_H :: 52

// A toggle tile: icon, label and state; filled with the accent when on.
@(private = "file")
tile :: proc(id, icon, name, state: string, on: bool, accent: u32, w: f32, enabled := true, tooltip := "") -> bool {
	p := im.GetCursorScreenPos()
	clicked := im.InvisibleButton(cstr(id), {w, TILE_H}) && enabled
	hovered := im.IsItemHovered()
	d := dl()
	bg := on ? col32(accent, hovered ? 0.30 : 0.22) : col32(0xffffff, hovered && enabled ? 0.07 : 0.035)
	im.DrawList_AddRectFilled(d, p, {p.x + w, p.y + TILE_H}, bg, 10)
	if hovered {
		if enabled {im.SetMouseCursor(.Hand)}
		if tooltip != "" {tip(tooltip)}
	}
	alpha: f32 = enabled ? 1 : 0.45
	// Icon in a round badge.
	cx, cy := p.x + 26, p.y + TILE_H / 2
	im.DrawList_AddCircleFilled(d, {cx, cy}, 16, on ? col32(accent, alpha) : col32(0xffffff, 0.06 * alpha))
	isz := measure(fonts.ui, 17, icon)
	draw_text(fonts.ui, 17, {cx - isz.x / 2, cy - 9}, on ? col32(0x111318, alpha) : col32(C_MUTED, alpha), icon)
	draw_text(fonts.bold, SZ_BODY, {p.x + 50, p.y + 9}, col32(C_TEXT, alpha), name)
	draw_text(fonts.ui, SZ_SMALL, {p.x + 50, p.y + 28}, col32(on ? accent : C_MUTED, alpha), state)
	return clicked
}

Tile_Def :: struct {
	id, icon, name, state: string,
	on, enabled:           bool,
	accent:                u32,
	tooltip:               string,
	act:                   proc(on: bool),
}

draw_quick :: proc(w: f32) {
	card_begin("quick", w)
	defer card_end()
	card_title(ICON_TUNE, "Quick settings", C_BLUE)
	inner := im.GetContentRegionAvail().x

	tiles: [dynamic]Tile_Def
	tiles.allocator = context.temp_allocator

	{
		_, can := nightlight_command()
		on := nightlight.running
		append(&tiles, Tile_Def{"##q:nl", ICON_NIGHT_LIGHT, "Night light", nightlight.pending ? "…" : on ? "On" : "Off", on, can, C_ORANGE,
			can ? "Warm screen colors after sunset (wlsunset)" : "Waiting for location (needed for sunrise/sunset)",
			proc(on: bool) {nightlight_set(!on); toast(on ? "Night light off" : "Night light on")}})
	}
	{
		sync.guard(&dnd.mu)
		if dnd.ok {
			append(&tiles, Tile_Def{"##q:dnd", dnd.paused ? ICON_BELL_OFF : ICON_BELL, "Do not disturb", dnd.pending ? "…" : dnd.paused ? "Notifications held" : "Off", dnd.paused, true, C_PURPLE,
				"Hold notifications (dunst) until you turn this off", proc(on: bool) {dnd_set(!on)}})
		}
	}
	{
		sync.guard(&bluetooth.mu)
		if bluetooth.ok && bluetooth.adapter {
			connected := 0
			for d in bluetooth.devices {if d.connected {connected += 1}}
			state := !bluetooth.powered ? "Off" : connected == 0 ? "On" : connected == 1 ? "1 device" : fmt.tprintf("%d devices", connected)
			append(&tiles, Tile_Def{"##q:bt", bluetooth.powered ? ICON_BLUETOOTH : ICON_BLUETOOTH_OFF, "Bluetooth", state, bluetooth.powered, true, C_BLUE,
				"Turn the Bluetooth adapter on or off", proc(on: bool) {bluetooth_set_power(!on)}})
		}
	}
	if len(tracker.projects) > 0 {
		append(&tiles, Tile_Def{"##q:lock", ICON_LINK, "Group lock", tracker.lock ? "Monitors together" : "Off", tracker.lock, true, C_TEAL,
			"All monitors enter and leave a project's workspaces together", proc(on: bool) {tracker_set_lock(!on)}})
		append(&tiles, Tile_Def{"##q:keep", ICON_PIN, "Keep workspaces", placeholders.keep ? "Placeholders" : "Off", placeholders.keep, true, C_TEAL,
			"Empty project workspaces get a placeholder window so sway doesn't remove them", proc(on: bool) {placeholders_set_keep(!on)}})
	}

	gap: f32 = 8
	tw := (inner - gap) / 2
	run_act: proc(on: bool)
	run_on: bool
	for t, i in tiles {
		if i % 2 == 1 {im.SameLine(0, gap)}
		if tile(t.id, t.icon, t.name, t.state, t.on, t.accent, tw, t.enabled, t.tooltip) {
			run_act = t.act
			run_on = t.on
		}
	}
	if run_act != nil {run_act(run_on)}

	// Keyboard layouts
	switch_to := -1
	{
		sync.guard(&sway.mu)
		if len(sway.layouts) > 1 {
			im.Dummy({1, 2})
			p := im.GetCursorScreenPos()
			draw_text(fonts.ui, 17, {p.x + 1, p.y + 5}, col32(C_MUTED), ICON_KEYBOARD)
			draw_text(fonts.ui, SZ_BODY, {p.x + 26, p.y + 6}, col32(C_TEXT, 0.9), "Keyboard")
			total: f32 = 4
			for n in sway.layouts {total += measure(fonts.ui, SZ_SMALL + 1, n).x + 24}
			im.SetCursorScreenPos({p.x + inner - total, p.y})
			if i := segmented("##kblayout", sway.layouts[:], sway.active_layout, C_BLUE); i >= 0 && i != sway.active_layout {
				sway.active_layout = i
				switch_to = i
			}
		}
	}
	if switch_to >= 0 {sway_switch_layout(switch_to)}
}
