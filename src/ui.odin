// The popup's content.
package main

import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"
import "core:time"
import "core:time/datetime"

import im "third_party:odin-imgui"

SHADOW :: 34 // transparent margin around the panel for the drop shadow
// The margin the popup's size and position were designed around. Anything
// beyond it is taken out of the layer margins, so a bigger shadow doesn't
// move or shrink the panel.
SHADOW_BASE :: 16
SHADOW_OFFSET_Y :: 5 // light comes from slightly above
COL_GAP :: 12

hide_requested: bool

UI :: struct {
	toast:         string,
	toast_until:   time.Tick,
	nightlight_at: time.Tick,
	shown_frames:  int,
	panel_min:     Vec2, // panel rectangle this frame (surface coordinates)
	panel_max:     Vec2,
	overlay_bottom: f32, // lowest edge of any tooltip this frame (the surface grows to fit)
}
ui: UI

toast :: proc(msg: string) {
	delete(ui.toast)
	ui.toast = strings.clone(msg)
	ui.toast_until = time.tick_add(time.tick_now(), 1600 * time.Millisecond)
	request_redraw()
}

services_start :: proc() {
	clocks_init()
	log.debugf("  clocks: rss %d kB", rss_kb())
	sysmon_start()
	log.debugf("  sysmon: rss %d kB", rss_kb())
	sway_start()
	audio_start()
	weather_start()
	network_start()
	bluetooth_start()
	storage_start()
	procs_start()
	sensors_start()
	github_start()
	ssh_start()
	update_start()
	displays_scan()
	log.debugf("  rest: rss %d kB", rss_kb())
}

on_show :: proc() {
	ui.shown_frames = 0
	perf_view.back, perf_view.frozen = 0, {} // reopened: live again (zoom kept)
	weather_on_show()
	media_refresh_async()
	network_on_show()
	bluetooth_refresh_async()
	storage_on_show()
	github_on_show()
	ssh_on_show()
	nightlight_poll()
	dnd_poll_async()
	displays_scan()
}

on_hide :: proc() {
	storage_on_hide()
	launcher_save_sum()
}

draw_ui :: proc() -> f32 {
	io := im.GetIO()
	ui.shown_frames += 1

	// Refresh cheap local state periodically while visible.
	if time.tick_since(ui.nightlight_at) > 2 * time.Second {
		ui.nightlight_at = time.tick_now()
		nightlight_poll()
		dnd_poll_async()
	}

	if im.IsKeyPressed(.Escape, false) && !time_rename_escape() {
		hide_requested = true
	}

	panel_w := io.DisplaySize.x - SHADOW * 2
	// The surface may be taller than the panel while a tooltip needs room.
	panel_h := (cur_panel().last_panel_h > 0 ? cur_panel().last_panel_h : io.DisplaySize.y - SHADOW * 2)
	panel_h = min(panel_h, io.DisplaySize.y - SHADOW * 2)
	panel_pos := Vec2{SHADOW, SHADOW - 4 - (1 - open_progress()) * 8}
	ui.panel_min = panel_pos
	ui.panel_max = panel_pos + Vec2{panel_w, panel_h}
	ui.overlay_bottom = 0

	draw_shadow(panel_pos, {panel_w, panel_h})

	im.SetNextWindowPos(panel_pos)
	im.SetNextWindowSize({panel_w, panel_h})
	im.PushStyleColorImVec4(.WindowBg, rgba(C_BG))
	im.PushStyleColor(.Border, window_border_color(0.07))
	im.PushStyleVar(.WindowBorderSize, 1)
	im.PushStyleVar(.WindowRounding, 18)
	im.PushStyleVarImVec2(.WindowPadding, {16, 16})
	im.Begin("wlperch", nil, {.NoTitleBar, .NoResize, .NoMove, .NoCollapse, .NoSavedSettings})
	im.PopStyleVar(3)
	im.PopStyleColor(2)

	platform_set_input_rect(i32(panel_pos.x), i32(panel_pos.y), i32(panel_w), i32(panel_h))

	content_w := im.GetContentRegionAvail().x
	panel := cur_panel()
	ncols := len(panel.columns)
	col_w := (content_w - COL_GAP * f32(ncols - 1)) / f32(ncols)

	if panel.bare {
		// Just the modules (the bar's audio popup): no header, no tabs.
	} else if panel.header {
		draw_header(content_w)
		im.Dummy({1, 4})
	} else if panel.title != "" {
		draw_title_row(panel.title, content_w)
	}

	im.PushStyleVarImVec2(.ItemSpacing, {COL_GAP, COL_GAP})
	for col, ci in panel.columns {
		if ci > 0 {im.SameLine()}
		im.BeginGroup()
		for mod in col {module_find(mod)(col_w)}
		im.EndGroup()
	}
	im.PopStyleVar()

	content_bottom := im.GetCursorPosY() - im.GetStyle().ItemSpacing.y + 16

	draw_toast(panel_pos, {panel_w, panel_h})
	im.End()

	h := content_bottom + SHADOW * 2
	// Never taller than the screen we're on.
	max_h: f32 = 1400
	{
		sync.guard(&sway.mu)
		for o in sway.outputs {
			on_it := plat.on_output != "" ? o.name == plat.on_output : o.focused
			if on_it {max_h = f32(o.h) - 40}
		}
	}
	if config.max_height > 0 {max_h = min(max_h, f32(config.max_height))}
	h = min(h, max_h)
	panel.last_panel_h = h - SHADOW * 2
	// Tooltips below the panel need surface area too (transparent, no input).
	if ui.overlay_bottom > 0 {h = min(max(h, ui.overlay_bottom + 12), max_h + 400)}
	panel.last_height = i32(h)
	return h
}

// Soft drop shadow: stacked rounded rects whose alphas add up to a smooth,
// roughly gaussian falloff. Offset a little downwards but wide enough to
// still show above the panel.
draw_shadow :: proc(pos, size: Vec2, spread: f32 = SHADOW - 2, offset_y: f32 = SHADOW_OFFSET_Y, radius: f32 = 18) {
	d := im.GetBackgroundDrawList()
	layers :: 30
	for i in 0 ..< layers {
		t := f32(i) / layers
		e := spread * (t + 1.0 / layers)
		a := 0.030 * (1 - t) * (1 - t) * (1 - t * 0.5)
		y := offset_y * (1 - t * 0.6)
		im.DrawList_AddRectFilled(d, {pos.x - e, pos.y - e + y}, {pos.x + size.x + e, pos.y + size.y + e + y}, col32(0x000000, a), radius + e)
	}
}

draw_toast :: proc(pos, size: Vec2) {
	if ui.toast == "" || time.tick_diff(time.tick_now(), ui.toast_until) <= 0 {return}
	d := im.GetForegroundDrawList()
	sz := measure(fonts.bold, SZ_BODY, ui.toast)
	w := sz.x + 50
	p := Vec2{pos.x + (size.x - w) / 2, pos.y + size.y - 56}
	im.DrawList_AddRectFilled(d, {p.x, p.y + 3}, {p.x + w, p.y + 39}, col32(0x000000, 0.45), 18)
	im.DrawList_AddRectFilled(d, p, {p.x + w, p.y + 36}, col32(C_CARD_HI), 18)
	im.DrawList_AddRect(d, p, {p.x + w, p.y + 36}, col32(C_OVERLAY, 0.08), 18)
	b, e := str_range(ICON_CHECK)
	im.DrawList_AddTextImFontPtr(d, fonts.ui, 16, {p.x + 16, p.y + 9}, col32(C_GREEN), b, e)
	b, e = str_range(ui.toast)
	im.DrawList_AddTextImFontPtr(d, fonts.bold, SZ_BODY, {p.x + 38, p.y + 9}, col32(C_TEXT), b, e)
}

// ---- Header -----------------------------------------------------------------

draw_header :: proc(width: f32) {
	now := time.now()
	p := im.GetCursorScreenPos()
	r, ok := clock_read(local_region, now)
	if ok {
		dt := r.dt
		hour := int(dt.hour)
		hm := config.clock_24h ? fmt.tprintf("%02d:%02d", hour, dt.minute) : fmt.tprintf("%d:%02d", (hour + 11) % 12 + 1, dt.minute)
		hsz := measure(fonts.bold, 40, hm)
		draw_text(fonts.bold, 40, {p.x, p.y - 4}, col32(C_TEXT), hm)
		// Seconds share the big time's baseline (digits sit on the baseline).
		_, big_base := glyph_ink_y(fonts.bold, 40, '0')
		_, small_base := glyph_ink_y(fonts.mono, 16, '0')
		draw_text(fonts.mono, 16, {p.x + hsz.x + 6, p.y - 4 + big_base - small_base}, col32(C_MUTED), fmt.tprintf("%02d", dt.second))
		if !config.clock_24h {
			draw_text(fonts.bold, 13, {p.x + hsz.x + 6, p.y + 4}, col32(C_MUTED), hour < 12 ? "AM" : "PM")
		}
		date := fmt.tprintf("%s, %d %s %d", WEEKDAYS[weekday_of(dt)], dt.day, MONTHS[dt.month - 1], dt.year)
		draw_text(fonts.ui, SZ_BODY, {p.x + 1, p.y + 44}, col32(C_MUTED), date)
	}

	right := p.x + width
	y := p.y + 4

	// Restart: picks up a newly installed binary and config changes.
	im.SetCursorScreenPos({right - 28, y - 3})
	if icon_button("##restart", ICON_REFRESH, C_MUTED, 28, tooltip = "Restart wlperch (new build, config)") {
		restart_requested = true
	}
	im.SetCursorScreenPos({right - 60, y - 3})
	if icon_button("##setup", ICON_COG, C_MUTED, 28, tooltip = "Setup: install / configure components") {
		setup_launch()
		hide_requested = true
	}
	im.SetCursorScreenPos({right - 92, y - 3})
	if icon_button("##lock", ICON_LOCK, C_MUTED, 28, tooltip = "Lock the screen") {
		// Hide first: the lock may capture the screen for its background.
		hide_requested = true
		launch_detached({"sh", "-c", `sleep 0.25; exec "$0" lock`, self_exe()})
	}
	im.SetCursorScreenPos({right - 124, y - 3})
	if icon_button("##lockoff", ICON_MONITOR_OFF, C_MUTED, 28, tooltip = "Lock and turn the monitors off\na key or the mouse turns them back on") {
		hide_requested = true
		launch_detached({"sh", "-c", `sleep 0.25; exec "$0" lock --screen-off`, self_exe()})
	}
	// Updates: checks GitHub when clicked; green with a dot when a release
	// is waiting, and then a click installs it.
	ucol, utip, uhi := update_button_info()
	upos := Vec2{right - 156, y - 3}
	im.SetCursorScreenPos(upos)
	if icon_button("##update", uhi && ucol == C_BLUE ? ICON_DOWNLOADING : ICON_UPDATE, ucol, 28, uhi, utip) {
		if update_available() {update_install_async()} else {update_check_async()}
	}
	if uhi && ucol == C_GREEN {im.DrawList_AddCircleFilled(dl(), upos + {23, 5}, 3.5, col32(C_GREEN))}

	// Panel tabs under the buttons, clear of the date.
	date_w: f32 = ok ? measure(fonts.ui, SZ_BODY, "Wednesday, 30 September 2026").x + 24 : 0
	panel_tabs(right, p.y + 32, width - date_w)

	im.SetCursorScreenPos(p)
	im.Dummy({width, 66})
}

// Tabs for every panel, right-aligned at `right`; icons only when the
// labels don't fit in `max_w`. Hidden when there's a single panel.
panel_tabs :: proc(right, y, max_w: f32) {
	// Panels with "tab = false" (e.g. the calculator, opened by a key binding)
	// only get a tab while they're open.
	shown := make([dynamic]int, context.temp_allocator)
	for p, i in panels {
		if p.tab || i == current_panel {append(&shown, i)}
	}
	if len(shown) < 2 {return}
	h: f32 = 28
	names := make([]string, len(panels), context.temp_allocator)
	widths := make([]f32, len(panels), context.temp_allocator)
	full: f32 = 4
	for i in shown {
		p := panels[i]
		names[i] = p.title
		if names[i] == "" && p.name != "" {names[i] = strings.concatenate({strings.to_upper(p.name[:1], context.temp_allocator), p.name[1:]}, context.temp_allocator)}
		widths[i] = measure(fonts.ui, SZ_SMALL + 1, names[i]).x + 44
		full += widths[i]
	}
	labels := full <= max_w
	total: f32 = 4
	for i in shown {
		if !labels {widths[i] = 34}
		total += widths[i]
	}
	if total > max_w {return}
	d := dl()
	x0 := right - total
	im.DrawList_AddRectFilled(d, {x0, y}, {right, y + h + 4}, col32(C_CARD_HI), 10)
	target := -1
	x := x0 + 2
	for i in shown {
		p := panels[i]
		w := widths[i]
		im.SetCursorScreenPos({x, y + 2})
		if im.InvisibleButton(cstr(fmt.tprintf("##tab:%s", p.name)), {w, h}) && i != current_panel {target = i}
		hovered := im.IsItemHovered()
		active := i == current_panel
		if hovered && !active {
			im.SetMouseCursor(.Hand)
			if !labels {tip(names[i])}
		}
		if active {
			im.DrawList_AddRectFilled(d, {x, y + 2}, {x + w, y + 2 + h}, col32(C_BLUE, 0.9), 8)
		} else if hovered {
			im.DrawList_AddRectFilled(d, {x, y + 2}, {x + w, y + 2 + h}, col32(C_OVERLAY, 0.06), 8)
		}
		fg := active ? col32(0x11131a) : col32(hovered ? C_TEXT : C_MUTED)
		icon := panel_icon(p)
		if labels {
			draw_text(fonts.ui, 15, {x + 12, y + 7}, fg, icon)
			draw_text(fonts.ui, SZ_SMALL + 1, {x + 32, y + 8}, active ? fg : col32(C_TEXT, hovered ? 1 : 0.85), names[i])
		} else {
			isz := measure(fonts.ui, 15, icon)
			draw_text(fonts.ui, 15, {x + (w - isz.x) / 2, y + 7}, fg, icon)
		}
		// Unread notifications: a dot on the bell.
		if !active && len(p.columns) > 0 && len(p.columns[0]) > 0 && p.columns[0][0] == "notifications" && notif_unread() > 0 {
			dx := labels ? x + 25 : x + w / 2 + 7
			im.DrawList_AddCircleFilled(d, {dx, y + 9}, 3.5, col32(C_PURPLE))
		}
		x += w
	}
	if target >= 0 {switch_panel(target)}
}

// Compact header for panels without the big clock: title, time, restart.
draw_title_row :: proc(title: string, width: f32) {
	p := im.GetCursorScreenPos()
	draw_text(fonts.bold, 22, {p.x, p.y}, col32(C_TEXT), title)
	if r, ok := clock_read(local_region, time.now()); ok {
		hour := int(r.dt.hour)
		tm := config.clock_24h ? fmt.tprintf("%02d:%02d", hour, r.dt.minute) : fmt.tprintf("%d:%02d %s", (hour + 11) % 12 + 1, r.dt.minute, hour < 12 ? "AM" : "PM")
		tsz := measure(fonts.mono, 16, tm)
		draw_text(fonts.mono, 16, {p.x + width - tsz.x, p.y + 5}, col32(C_MUTED), tm)
		im.SetCursorScreenPos({p.x + width - tsz.x - 40, p.y + 1})
		if icon_button("##restart", ICON_REFRESH, C_MUTED, 28, tooltip = "Restart wlperch (new build, config)") {
			restart_requested = true
		}
		im.SetCursorScreenPos({p.x + width - tsz.x - 72, p.y + 1})
		if icon_button("##setup", ICON_COG, C_MUTED, 28, tooltip = "Setup: install / configure components") {
			setup_launch()
			hide_requested = true
		}
		title_w := measure(fonts.bold, 22, title).x + 16
		panel_tabs(p.x + width - tsz.x - 80, p.y - 1, width - tsz.x - 80 - title_w)
	}
	im.SetCursorScreenPos(p)
	im.Dummy({width, 34})
}

// ---- Audio ------------------------------------------------------------------

Audio_Action :: struct {
	kind:  enum {None, Default_Sink, Default_Source, Mute_Sink, Mute_Source, Volume_Sink, Volume_Source, Profile, Hdmi},
	name:  string,
	name2: string,
	value: f32,
}

draw_audio :: proc(w: f32) {
	card_begin("audio", w)
	defer card_end()
	tp := im.GetCursorScreenPos()
	card_title(ICON_SPEAKER, "Audio", C_BLUE)
	{
		// Fix buttons, top right of the card.
		after := im.GetCursorScreenPos()
		cw := im.GetContentRegionAvail().x
		fixing: Audio_Fix
		{
			sync.guard(&audio.mu)
			fixing = audio.fixing
		}
		if fixing != .None {
			msg := fixing == .Refreshing ? "refreshing…" : "restarting…"
			msz := measure(fonts.ui, SZ_SMALL, msg)
			draw_text(fonts.ui, SZ_SMALL, {tp.x + cw - msz.x, tp.y + 3}, col32(C_ORANGE), msg)
			request_redraw(1)
		} else {
			im.SetCursorScreenPos({tp.x + cw - 58, tp.y - 5})
			if icon_button("##audiorefresh", ICON_REFRESH, C_MUTED, 26, tooltip = "Refresh audio\nswitches the output's card to another profile and back") {
				msg, _ := audio_bounce_profile()
				toast(msg)
			}
			im.SetCursorScreenPos({tp.x + cw - 28, tp.y - 5})
			if icon_button("##audiorestart", ICON_POWER, C_MUTED, 26, tooltip = "Restart audio\nrestarts PipeWire, WirePlumber and pipewire-pulse") {
				msg, _ := audio_restart()
				toast(msg)
			}
		}
		im.SetCursorScreenPos(after)
	}

	act: Audio_Action
	sync.mutex_lock(&audio.mu)
	if !audio.ok {
		sync.mutex_unlock(&audio.mu)
		label(fonts.ui, SZ_BODY, col32(C_MUTED), "Audio server unavailable")
		return
	}

	sub_heading("Output")
	default_sink: ^Audio_Device
	for &d in audio.sinks {
		if d.is_default {default_sink = &d}
		if device_row(fmt.tprintf("sink:%s", d.name), d.icon, d.label, d.sublabel, d.is_default, C_BLUE) && !d.is_default {
			act = {kind = .Default_Sink, name = strings.clone(d.name, context.temp_allocator)}
		}
	}
	// Other HDMI/DP outputs of the same card: selecting one switches the card profile.
	for c in audio.cards {
		for p in c.profiles {
			if p.active || !p.available || !strings.has_prefix(p.name, "output:hdmi-stereo") {continue}
			title := p.monitor != "" ? p.monitor : p.label
			hdmi := strings.trim_suffix(strings.trim_prefix(p.label, "Digital Stereo ("), ")")
			sub := p.connector != "" ? fmt.tprintf("%s · %s", hdmi, p.connector) : hdmi
			if device_row(fmt.tprintf("prof:%s:%s", c.name, p.name), ICON_MONITOR, title, sub, false, C_BLUE, dim = true) {
				act = {kind = .Hdmi, name = strings.clone(c.name, context.temp_allocator), name2 = strings.clone(p.name, context.temp_allocator)}
			}
		}
	}
	if default_sink != nil {
		if a, ok := volume_row("sinkvol", default_sink, true); ok {act = a}
	}

	sub_heading("Input")
	default_source: ^Audio_Device
	if len(audio.sources) == 0 {
		label(fonts.ui, SZ_SMALL, col32(C_FAINT), "No input devices")
	}
	for &d in audio.sources {
		if d.is_default {default_source = &d}
		if device_row(fmt.tprintf("src:%s", d.name), d.icon, d.label, d.sublabel, d.is_default, C_TEAL) && !d.is_default {
			act = {kind = .Default_Source, name = strings.clone(d.name, context.temp_allocator)}
		}
	}
	if default_source != nil {
		if a, ok := volume_row("srcvol", default_source, false); ok {act = a}
	}

	// Card profiles (e.g. which HDMI/DP port of the GPU carries audio).
	for c in audio.cards {
		sub_heading(fmt.tprintf("Profile · %s", short_card_name(c.label)))
		if prof, ok := profile_combo(c); ok {
			act = {kind = .Profile, name = strings.clone(c.name, context.temp_allocator), name2 = strings.clone(prof, context.temp_allocator)}
		}
	}
	sync.mutex_unlock(&audio.mu)

	switch act.kind {
	case .None:
	case .Default_Sink:   audio_set_default(act.name, true)
	case .Default_Source: audio_set_default(act.name, false)
	case .Mute_Sink:      audio_toggle_mute(act.name, true)
	case .Mute_Source:    audio_toggle_mute(act.name, false)
	case .Volume_Sink:    audio_set_volume(act.name, true, act.value)
	case .Volume_Source:  audio_set_volume(act.name, false, act.value)
	case .Profile:        audio_set_profile(act.name, act.name2)
	case .Hdmi:
		audio_switch_output_profile(act.name, act.name2)
		toast("Switching audio output…")
	}
}

short_card_name :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "High Definition Audio Controller", "HD Audio", context.temp_allocator)
	return r
}

volume_row :: proc(id: string, d: ^Audio_Device, is_sink: bool) -> (act: Audio_Action, ok: bool) {
	im.Dummy({1, 0})
	icon: string
	if is_sink {
		icon = d.mute ? ICON_VOLUME_OFF : d.volume < 0.34 ? ICON_VOLUME_LOW : d.volume < 0.67 ? ICON_VOLUME_MED : ICON_VOLUME_HIGH
	} else {
		icon = d.mute ? ICON_MIC_OFF : ICON_MIC
	}
	accent: u32 = is_sink ? C_BLUE : C_TEAL
	start := im.GetCursorScreenPos()
	avail := im.GetContentRegionAvail().x
	if icon_button(fmt.tprintf("%s:mute", id), icon, d.mute ? C_RED : C_TEXT, 28, d.mute, d.mute ? "Unmute" : "Mute") {
		act = {kind = is_sink ? .Mute_Sink : .Mute_Source, name = strings.clone(d.name, context.temp_allocator)}
		ok = true
	}
	pct := fmt.tprintf("%d%%", int(d.volume * 100 + 0.5))
	im.SetCursorScreenPos({start.x + 38, start.y + 3})
	v := d.volume
	if slider(fmt.tprintf("%s:slider", id), &v, 1.5, d.mute ? C_FAINT : accent, avail - 38 - 52) {
		act = {kind = is_sink ? .Volume_Sink : .Volume_Source, name = strings.clone(d.name, context.temp_allocator), value = v}
		ok = true
	}
	psz := measure(fonts.mono, SZ_BODY, pct)
	draw_text(fonts.mono, SZ_BODY, {start.x + avail - psz.x, start.y + 5}, col32(d.mute ? C_MUTED : C_TEXT), pct)
	im.SetCursorScreenPos(start)
	im.Dummy({avail, 28})
	return
}

profile_combo :: proc(c: Audio_Card) -> (chosen: string, ok: bool) {
	preview := "—"
	for p in c.profiles {
		if p.active {preview = profile_text(p)}
	}
	im.SetNextItemWidth(-1)
	im.PushStyleVarImVec2(.FramePadding, {10, 7})
	im.PushStyleVarImVec2(.WindowPadding, {6, 6})
	im.PushStyleVarImVec2(.ItemSpacing, {6, 2})
	if im.BeginCombo(cstr(fmt.tprintf("##profile:%s", c.name)), cstr(preview), {.HeightLarge}) {
		for p in c.profiles {
			txt := profile_text(p)
			if !p.available {im.PushStyleColorImVec4(.Text, rgba(C_MUTED, 0.7))}
			if im.Selectable(cstr(fmt.tprintf("%s%s##%s", txt, p.available ? "" : "  (unplugged)", p.name)), p.active) && !p.active {
				chosen, ok = p.name, true
			}
			if !p.available {im.PopStyleColor()}
		}
		im.EndCombo()
	}
	im.PopStyleVar(3)
	return
}

profile_text :: proc(p: Audio_Profile) -> string {
	s := p.label
	if p.monitor != "" {
		s = fmt.tprintf("%s — %s", s, p.monitor)
		if p.connector != "" {s = fmt.tprintf("%s (%s)", s, p.connector)}
	}
	return s
}

// ---- Displays ---------------------------------------------------------------

draw_displays :: proc(w: f32) {
	card_begin("displays", w)
	defer card_end()

	rects: [dynamic]Layout_Rect
	rects.allocator = context.temp_allocator
	{
		sync.guard(&sway.mu)
		for o in sway.outputs {
			if !o.active {continue}
			detail := fmt.tprintf("%d×%d", o.mode_w, o.mode_h)
			if o.refresh > 0 {detail = fmt.tprintf("%s · %.0fHz", detail, o.refresh)}
			if o.scale != 1 {detail = fmt.tprintf("%s · %.2gx", detail, o.scale)}
			if o.transform != "normal" {detail = fmt.tprintf("%s · %s°", detail, o.transform)}
			append(&rects, Layout_Rect{name = strings.clone(o.name, context.temp_allocator), x = f32(o.x), y = f32(o.y), w = f32(o.w), h = f32(o.h), focused = o.focused, detail = detail})
		}
	}
	card_title(ICON_MONITORS, "Displays", C_PURPLE, fmt.tprintf("%d active", len(rects)))

	inner := im.GetContentRegionAvail().x
	p := im.GetCursorScreenPos()
	h: f32 = 104
	im.DrawList_AddRectFilled(dl(), p, {p.x + inner, p.y + h}, col32(C_WELL), 10)
	draw_layout(rects[:], {p.x + 10, p.y + 10}, {inner - 20, h - 20}, accent = C_PURPLE)
	im.Dummy({inner, h})

	if len(displays.presets) == 0 {
		label(fonts.ui, SZ_SMALL, col32(C_FAINT), "No presets: run \"wlperch display save <name>\" or add [display.<name>] to the config")
		return
	}
	sub_heading("Preset")
	active := displays_active_preset()
	preview := active >= 0 ? displays.presets[active].label : "Custom layout"
	im.SetNextItemWidth(-1)
	im.PushStyleVarImVec2(.FramePadding, {10, 7})
	im.PushStyleVarImVec2(.WindowPadding, {6, 6})
	im.PushStyleVarImVec2(.ItemSpacing, {6, 4})
	if im.BeginCombo("##preset", cstr(preview), {.HeightLarge}) {
		for pr, i in displays.presets {
			pw: f32 = 72
			ph: f32 = 30
			row_p := im.GetCursorScreenPos()
			full_w := im.GetContentRegionAvail().x
			if im.Selectable(cstr(fmt.tprintf("##preset%d", i)), i == active, {}, {full_w, ph + 6}) {
				displays_apply(i)
				toast(fmt.tprintf("Applying \"%s\"", pr.label))
			}
			prects: [dynamic]Layout_Rect
			prects.allocator = context.temp_allocator
			for o in pr.outputs {
				if !o.enabled {continue}
				x, y, ow, oh := preset_output_rect(o)
				append(&prects, Layout_Rect{name = o.name, x = x, y = y, w = ow, h = oh})
			}
			im.DrawList_AddRectFilled(dl(), {row_p.x + 4, row_p.y + 3}, {row_p.x + 4 + pw, row_p.y + 3 + ph}, col32(C_WELL), 5)
			draw_layout(prects[:], {row_p.x + 7, row_p.y + 6}, {pw - 6, ph - 6}, compact = true, accent = C_PURPLE)
			draw_text(i == active ? fonts.bold : fonts.ui, SZ_BODY, {row_p.x + pw + 16, row_p.y + 3}, col32(C_TEXT), pr.label)
			names: [dynamic]string
			names.allocator = context.temp_allocator
			for o in pr.outputs {if o.enabled {append(&names, o.name)}}
			draw_text(fonts.ui, SZ_SMALL, {row_p.x + pw + 16, row_p.y + 20}, col32(C_MUTED), fmt.tprintf("%s · %s", pr.key, strings.join(names[:], " + ", context.temp_allocator)))
			if i == active {
				draw_text(fonts.ui, 16, {row_p.x + full_w - 24, row_p.y + 10}, col32(C_PURPLE), ICON_CHECK)
			}
		}
		im.EndCombo()
	}
	im.PopStyleVar(3)
}

// ---- Weather ----------------------------------------------------------------

draw_weather :: proc(w: f32) {
	card_begin("weather", w)
	defer card_end()
	sync.guard(&weather.mu)
	title_icon := ICON_W_PARTLY
	if weather.ok {title_icon, _ = weather_desc(weather.code, weather.is_day)}
	card_title(title_icon, "Weather", C_YELLOW, weather.place)

	inner := im.GetContentRegionAvail().x
	if !weather.ok {
		msg := weather.error != "" ? weather.error : "Loading forecast…"
		label(fonts.ui, SZ_BODY, col32(C_MUTED), msg)
		return
	}
	unit := config.units == "imperial" ? "°F" : "°C"
	wind_unit := config.units == "imperial" ? "mph" : "km/h"

	p := im.GetCursorScreenPos()
	icon, desc := weather_desc(weather.code, weather.is_day)
	icol := weather_color(weather.code, weather.is_day)
	draw_text(fonts.ui, 46, {p.x - 2, p.y - 4}, col32(icol), icon)
	temp := fmt.tprintf("%.0f°", weather.temp)
	tsz := measure(fonts.bold, 38, temp)
	draw_text(fonts.bold, 38, {p.x + 56, p.y - 4}, col32(C_TEXT), temp)
	draw_text(fonts.bold, SZ_BODY, {p.x + 62 + tsz.x, p.y + 2}, col32(C_TEXT), desc)
	draw_text(fonts.ui, SZ_SMALL, {p.x + 62 + tsz.x, p.y + 21}, col32(C_MUTED), fmt.tprintf("Feels like %.0f%s", weather.feels, unit))

	hilo := fmt.tprintf("%s %.0f°  %s %.0f°", "\U000F005D", weather.hi, "\U000F0045", weather.lo)
	hsz := measure(fonts.bold, SZ_BODY, hilo)
	draw_text(fonts.bold, SZ_BODY, {p.x + inner - hsz.x, p.y + 2}, col32(C_TEXT), hilo)
	rain := fmt.tprintf("%s %d%%", ICON_UMBRELLA, weather.precip_prob)
	if weather.precip_sum > 0 {rain = fmt.tprintf("%s · %.1f mm", rain, weather.precip_sum)}
	rsz := measure(fonts.ui, SZ_SMALL, rain)
	draw_text(fonts.ui, SZ_SMALL, {p.x + inner - rsz.x, p.y + 21}, col32(C_CYAN), rain)
	im.Dummy({inner, 46})

	stats := fmt.tprintf("%s %.0f %s     %s %d%%     %s %s     %s %s", ICON_WIND, weather.wind, wind_unit, ICON_WATER, weather.humidity, ICON_SUNRISE, weather.sunrise, ICON_SUNSET, weather.sunset)
	label(fonts.ui, SZ_SMALL, col32(C_MUTED), stats)
	im.Dummy({1, 2})

	// Hourly strip: next 24h every 3 hours.
	cols := 8
	cw := inner / f32(cols)
	sp := im.GetCursorScreenPos()
	sh: f32 = 74
	im.DrawList_AddRectFilled(dl(), sp, {sp.x + inner, sp.y + sh}, col32(C_WELL), 10)
	for i in 0 ..< cols {
		idx := i * 3
		if idx >= len(weather.hours) {break}
		hr := weather.hours[idx]
		cx := sp.x + cw * (f32(i) + 0.5)
		hl := i == 0 ? "Now" : config.clock_24h ? fmt.tprintf("%02d", hr.hour) : fmt.tprintf("%d%s", (hr.hour + 11) % 12 + 1, hr.hour < 12 ? "a" : "p")
		hsz2 := measure(fonts.ui, SZ_SMALL, hl)
		draw_text(fonts.ui, SZ_SMALL, {cx - hsz2.x / 2, sp.y + 6}, col32(i == 0 ? C_TEXT : C_MUTED), hl)
		hicon, _ := weather_desc(hr.code, hr.is_day)
		isz := measure(fonts.ui, 20, hicon)
		draw_text(fonts.ui, 20, {cx - isz.x / 2, sp.y + 22}, col32(weather_color(hr.code, hr.is_day)), hicon)
		t := fmt.tprintf("%.0f°", hr.temp)
		tsz2 := measure(fonts.bold, SZ_SMALL + 1, t)
		draw_text(fonts.bold, SZ_SMALL + 1, {cx - tsz2.x / 2, sp.y + 44}, col32(C_TEXT), t)
		if hr.precip >= 10 {
			pr := fmt.tprintf("%d%%", hr.precip)
			psz := measure(fonts.ui, 10.5, pr)
			draw_text(fonts.ui, 10.5, {cx - psz.x / 2, sp.y + 59}, col32(C_CYAN, 0.9), pr)
		}
	}
	im.Dummy({inner, sh})
}

// ---- Clocks -----------------------------------------------------------------

draw_clocks :: proc(w: f32) {
	if len(clocks) == 0 {return}
	card_begin("clocks", w)
	defer card_end()
	card_title(ICON_EARTH, "World clocks", C_TEAL)

	inner := im.GetContentRegionAvail().x
	now := time.now()
	local, lok := clock_read(local_region, now)
	for c in clocks {
		p := im.GetCursorScreenPos()
		h: f32 = 34
		r, ok := clock_read(c.region, now)
		if !c.ok || !ok {
			draw_text(fonts.ui, SZ_BODY, {p.x, p.y + 8}, col32(C_MUTED), fmt.tprintf("%s (unknown zone)", c.label))
			im.Dummy({inner, h})
			continue
		}
		is_local := c.region == local_region
		if is_local {
			im.DrawList_AddRectFilled(dl(), {p.x - 6, p.y}, {p.x + inner + 6, p.y + h}, col32(C_TEAL, 0.09), 8)
		}
		hour := int(r.dt.hour)
		day := hour >= 7 && hour < 19
		draw_text(fonts.ui, 16, {p.x + 2, p.y + 8}, col32(day ? C_YELLOW : C_PURPLE, 0.9), day ? ICON_W_SUNNY : ICON_W_NIGHT)
		draw_text(is_local ? fonts.bold : fonts.ui, SZ_BODY, {p.x + 28, p.y + 1}, col32(C_TEXT), c.label)
		sub := format_offset(r.offset_min)
		if r.abbrev != "" && !strings.has_prefix(r.abbrev, "+") && !strings.has_prefix(r.abbrev, "-") && r.abbrev != "UTC" {
			sub = fmt.tprintf("%s · %s", r.abbrev, sub)
		}
		if lok && !is_local {
			diff := r.offset_min - local.offset_min
			if diff != 0 {
				sign := diff > 0 ? "+" : "−"
				d := abs(diff)
				rel := d % 60 == 0 ? fmt.tprintf("%s%dh", sign, d / 60) : fmt.tprintf("%s%d:%02dh", sign, d / 60, d % 60)
				sub = fmt.tprintf("%s · %s", sub, rel)
			}
		}
		draw_text(fonts.ui, SZ_SMALL, {p.x + 28, p.y + 18}, col32(C_MUTED), sub)

		tm := config.clock_24h ? fmt.tprintf("%02d:%02d", hour, r.dt.minute) : fmt.tprintf("%d:%02d %s", (hour + 11) % 12 + 1, r.dt.minute, hour < 12 ? "AM" : "PM")
		tsz := measure(fonts.mono, 19, tm)
		draw_text(fonts.mono, 19, {p.x + inner - tsz.x, p.y + 6}, col32(is_local ? C_TEAL : C_TEXT), tm)
		if lok {
			dd := day_diff(r.dt, local.dt)
			if dd != 0 {
				badge := dd > 0 ? "tomorrow" : "yesterday"
				bsz := measure(fonts.ui, 11, badge)
				bx := p.x + inner - tsz.x - bsz.x - 20
				bc: u32 = dd > 0 ? C_ORANGE : C_PURPLE
				im.DrawList_AddRectFilled(dl(), {bx, p.y + 9}, {bx + bsz.x + 10, p.y + 25}, col32(bc, 0.16), 8)
				draw_text(fonts.ui, 11, {bx + 5, p.y + 10}, col32(bc), badge)
			}
		}
		im.Dummy({inner, h})
	}
}

day_diff :: proc(a, b: datetime.DateTime) -> int {
	if a.year != b.year {return a.year > b.year ? 1 : -1}
	if a.month != b.month {return a.month > b.month ? 1 : -1}
	if a.day != b.day {return a.day > b.day ? 1 : -1}
	return 0
}

// ---- Network ----------------------------------------------------------------

draw_network :: proc(w: f32) {
	card_begin("network", w)
	defer card_end()
	card_title(ICON_IP_NETWORK, "Network", C_CYAN, "click to copy")

	copy_text: string
	{
		sync.guard(&network.mu)
		pub := network.public_ok ? network.public_ip : network.public_err ? "unavailable" : "looking up…"
		if ip_row("pub", ICON_WEB, "Public", pub, true, network.public_ok) {copy_text = strings.clone(pub, context.temp_allocator)}
		for a in network.addrs {
			icon := a.wifi ? ICON_WIFI : ICON_ETHERNET
			txt := fmt.tprintf("%s/%d", a.addr, a.prefix)
			if ip_row(fmt.tprintf("%s:%s", a.iface, a.addr), icon, a.iface, txt, a.primary, true, a.v6) {
				copy_text = strings.clone(a.addr, context.temp_allocator)
			}
		}
	}
	if copy_text != "" {
		copy_to_clipboard(copy_text)
		toast(fmt.tprintf("Copied %s", copy_text))
	}
}

ip_row :: proc(id, icon, name, value: string, highlight, copyable: bool, small := false) -> bool {
	inner := im.GetContentRegionAvail().x
	p := im.GetCursorScreenPos()
	h: f32 = 28
	clicked := im.InvisibleButton(cstr(id), {inner, h}) && copyable
	hovered := im.IsItemHovered()
	d := dl()
	if hovered && copyable {
		im.SetMouseCursor(.Hand)
		im.DrawList_AddRectFilled(d, {p.x - 6, p.y}, {p.x + inner + 6, p.y + h}, col32(C_OVERLAY, 0.05), 7)
	}
	draw_text(fonts.ui, 16, {p.x, p.y + 5}, col32(highlight ? C_CYAN : C_MUTED), icon)
	draw_text(highlight ? fonts.bold : fonts.ui, SZ_BODY, {p.x + 26, p.y + 5}, col32(C_TEXT, 0.9), name)
	vsize: f32 = small ? SZ_SMALL : SZ_BODY
	right: f32 = (hovered && copyable) ? 24 : 0
	vsz := measure(fonts.mono, vsize, value)
	vx := max(p.x + inner - right - vsz.x, p.x + 110)
	im.DrawList_PushClipRect(d, {p.x + 100, p.y}, {p.x + inner - right, p.y + h}, true)
	draw_text(fonts.mono, vsize, {vx, p.y + (h - vsize) / 2 - 1}, col32(copyable ? C_TEXT : C_MUTED), value)
	im.DrawList_PopClipRect(d)
	if hovered && copyable {
		draw_text(fonts.ui, 15, {p.x + inner - 17, p.y + 6}, col32(C_CYAN), ICON_COPY)
	}
	return clicked
}

// ---- Bluetooth --------------------------------------------------------------

draw_bluetooth :: proc(w: f32) {
	// No BlueZ or no adapter: no Bluetooth support, so no card at all.
	{
		sync.guard(&bluetooth.mu)
		if !bluetooth.ok || !bluetooth.adapter {return}
	}
	card_begin("bluetooth", w)
	defer card_end()

	act_addr: string
	act_connect: bool
	sync.mutex_lock(&bluetooth.mu)
	connected := 0
	for d in bluetooth.devices {if d.connected {connected += 1}}
	right := bluetooth.powered ? fmt.tprintf("%d connected", connected) : "off"
	card_title(ICON_BLUETOOTH, "Bluetooth", C_BLUE, right)

	inner := im.GetContentRegionAvail().x
	switch {
	case !bluetooth.powered:
		label(fonts.ui, SZ_BODY, col32(C_MUTED), "Bluetooth is powered off")
	case len(bluetooth.devices) == 0:
		label(fonts.ui, SZ_BODY, col32(C_MUTED), "No paired devices")
	}
	shown_disconnected := 0
	for d in bluetooth.devices {
		if !d.connected {
			if shown_disconnected == 0 && connected > 0 {sub_heading("Paired")}
			shown_disconnected += 1
		}
		p := im.GetCursorScreenPos()
		h: f32 = 32
		busy := bluetooth.busy == d.address
		clicked := im.InvisibleButton(cstr(fmt.tprintf("bt:%s", d.address)), {inner, h})
		hovered := im.IsItemHovered()
		dd := dl()
		if hovered {
			im.SetMouseCursor(.Hand)
			im.DrawList_AddRectFilled(dd, {p.x - 6, p.y}, {p.x + inner + 6, p.y + h}, col32(C_OVERLAY, 0.05), 7)
			tip(d.connected ? fmt.tprintf("Disconnect %s", d.name) : fmt.tprintf("Connect %s", d.name))
		}
		if clicked && !busy {
			act_addr = strings.clone(d.address, context.temp_allocator)
			act_connect = !d.connected
		}
		alpha: f32 = d.connected ? 1 : 0.5
		draw_text(fonts.ui, 18, {p.x, p.y + 6}, col32(d.connected ? C_BLUE : C_MUTED, alpha), bt_icon(d.icon))
		draw_text(d.connected ? fonts.bold : fonts.ui, SZ_BODY, {p.x + 28, p.y + 7}, col32(C_TEXT, alpha), d.name)
		if busy {
			dots := strings.repeat(".", int(im.GetTime() * 3) % 4, context.temp_allocator)
			s := fmt.tprintf("%s%s", d.connected ? "disconnecting" : "connecting", dots)
			ssz := measure(fonts.ui, SZ_SMALL, "disconnecting...")
			draw_text(fonts.ui, SZ_SMALL, {p.x + inner - ssz.x, p.y + 9}, col32(C_MUTED), s)
			request_redraw(2)
		} else if d.connected {
			icon, col := battery_glyph(d.battery, d.charging)
			if d.battery >= 0 {
				pct := fmt.tprintf("%d%%", d.battery)
				psz := measure(fonts.mono, SZ_BODY, pct)
				bar_w: f32 = 54
				x := p.x + inner - psz.x
				draw_text(fonts.mono, SZ_BODY, {x, p.y + 7}, col32(C_TEXT), pct)
				bx := x - bar_w - 10
				im.SetCursorScreenPos({bx, p.y + 13})
				usage_bar(f32(d.battery) / 100, col32(col), {bar_w, 6})
				draw_text(fonts.ui, 16, {bx - 22, p.y + 7}, col32(col), icon)
			} else {
				s := "connected"
				ssz := measure(fonts.ui, SZ_SMALL, s)
				draw_text(fonts.ui, SZ_SMALL, {p.x + inner - ssz.x, p.y + 9}, col32(C_MUTED), s)
			}
		}
		im.SetCursorScreenPos(p)
		im.Dummy({inner, h})
	}
	sync.mutex_unlock(&bluetooth.mu)
	if act_addr != "" {
		bluetooth_toggle_connection(act_addr, act_connect)
	}
}
