// The popup's content.
package main

import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"
import "core:time"
import "core:time/datetime"

import im "third_party:odin-imgui"

SHADOW :: 16 // transparent margin around the panel for the drop shadow
COL_GAP :: 12

last_content_height: i32
hide_requested: bool

UI :: struct {
	toast:         string,
	toast_until:   time.Tick,
	nightlight_at: time.Tick,
	shown_frames:  int,
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
	displays_scan()
	log.debugf("  rest: rss %d kB", rss_kb())
}

on_show :: proc() {
	ui.shown_frames = 0
	weather_on_show()
	network_on_show()
	bluetooth_refresh_async()
	nightlight_poll()
	displays_scan()
}

on_hide :: proc() {}

draw_ui :: proc() -> f32 {
	io := im.GetIO()
	ui.shown_frames += 1

	// Refresh cheap local state periodically while visible.
	if time.tick_since(ui.nightlight_at) > 2 * time.Second {
		ui.nightlight_at = time.tick_now()
		nightlight_poll()
	}

	if im.IsKeyPressed(.Escape, false) {
		hide_requested = true
	}

	panel_w := io.DisplaySize.x - SHADOW * 2
	panel_h := io.DisplaySize.y - SHADOW * 2
	panel_pos := Vec2{SHADOW, SHADOW - 4 - (1 - open_progress()) * 8}

	draw_shadow(panel_pos, {panel_w, panel_h})

	im.SetNextWindowPos(panel_pos)
	im.SetNextWindowSize({panel_w, panel_h})
	im.PushStyleColorImVec4(.WindowBg, rgba(C_BG))
	im.PushStyleColorImVec4(.Border, rgba(0xffffff, 0.07))
	im.PushStyleVar(.WindowBorderSize, 1)
	im.PushStyleVar(.WindowRounding, 18)
	im.PushStyleVarImVec2(.WindowPadding, {16, 16})
	im.Begin("wlwidgets", nil, {.NoTitleBar, .NoResize, .NoMove, .NoCollapse, .NoSavedSettings})
	im.PopStyleVar(3)
	im.PopStyleColor(2)

	platform_set_input_rect(i32(panel_pos.x), i32(panel_pos.y), i32(panel_w), i32(panel_h))

	content_w := im.GetContentRegionAvail().x
	col_w := (content_w - COL_GAP) / 2

	draw_header(content_w)
	im.Dummy({1, 4})

	im.PushStyleVarImVec2(.ItemSpacing, {COL_GAP, COL_GAP})
	im.BeginGroup()
	draw_audio(col_w)
	draw_system(col_w)
	draw_network(col_w)
	im.EndGroup()
	im.SameLine()
	im.BeginGroup()
	draw_weather(col_w)
	draw_clocks(col_w)
	draw_displays(col_w)
	draw_bluetooth(col_w)
	im.EndGroup()
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
	last_content_height = i32(h)
	return h
}

draw_shadow :: proc(pos, size: Vec2) {
	d := im.GetBackgroundDrawList()
	layers :: 14
	for i in 0 ..< layers {
		t := f32(i) / layers
		e := f32(i) + 1
		a := 0.045 * (1 - t) * (1 - t)
		im.DrawList_AddRectFilled(d, {pos.x - e, pos.y - e + 4}, {pos.x + size.x + e, pos.y + size.y + e + 4}, col32(0x000000, a), 18 + e)
	}
}

draw_toast :: proc(pos, size: Vec2) {
	if ui.toast == "" || time.tick_diff(time.tick_now(), ui.toast_until) <= 0 {return}
	d := im.GetForegroundDrawList()
	sz := measure(fonts.bold, SZ_BODY, ui.toast)
	w := sz.x + 50
	p := Vec2{pos.x + (size.x - w) / 2, pos.y + size.y - 56}
	im.DrawList_AddRectFilled(d, {p.x, p.y + 3}, {p.x + w, p.y + 39}, col32(0x000000, 0.45), 18)
	im.DrawList_AddRectFilled(d, p, {p.x + w, p.y + 36}, col32(0x2b3240), 18)
	im.DrawList_AddRect(d, p, {p.x + w, p.y + 36}, col32(0xffffff, 0.08), 18)
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
		draw_text(fonts.mono, 16, {p.x + hsz.x + 6, p.y + 21}, col32(C_MUTED), fmt.tprintf("%02d", dt.second))
		if !config.clock_24h {
			draw_text(fonts.bold, 13, {p.x + hsz.x + 6, p.y + 4}, col32(C_MUTED), hour < 12 ? "AM" : "PM")
		}
		date := fmt.tprintf("%s, %d %s %d", WEEKDAYS[weekday_of(dt)], dt.day, MONTHS[dt.month - 1], dt.year)
		draw_text(fonts.ui, SZ_BODY, {p.x + 1, p.y + 44}, col32(C_MUTED), date)
	}

	right := p.x + width
	y := p.y + 4

	// Night light
	{
		nl_on := nightlight.running
		_, can := nightlight_command()
		lbl := "Night light"
		lsz := measure(fonts.ui, SZ_BODY, lbl)
		sw_x := right - 38
		im.SetCursorScreenPos({sw_x, y})
		if !can {im.BeginDisabled()}
		if toggle_switch("##nightlight", nl_on, C_ORANGE, nightlight.pending) {
			nightlight_set(!nl_on)
			toast(nl_on ? "Night light off" : "Night light on")
		}
		if !can {
			im.EndDisabled()
			if im.IsItemHovered(im.HoveredFlags_AllowWhenDisabled) {tip("Waiting for location (needed for sunrise/sunset)")}
		}
		draw_text(fonts.ui, SZ_BODY, {sw_x - lsz.x - 10, y + 2}, col32(C_TEXT, 0.9), lbl)
		draw_text(fonts.ui, 17, {sw_x - lsz.x - 34, y + 1}, col32(nl_on ? C_ORANGE : C_MUTED), ICON_NIGHT_LIGHT)
	}

	// Keyboard layouts
	switch_to := -1
	{
		sync.guard(&sway.mu)
		if len(sway.layouts) > 1 {
			total: f32 = 4
			for n in sway.layouts {total += measure(fonts.ui, SZ_SMALL + 1, n).x + 24}
			x := right - total
			ky := y + 32
			draw_text(fonts.ui, 17, {x - 26, ky + 5}, col32(C_MUTED), ICON_KEYBOARD)
			im.SetCursorScreenPos({x, ky})
			if i := segmented("##kblayout", sway.layouts[:], sway.active_layout, C_BLUE); i >= 0 && i != sway.active_layout {
				sway.active_layout = i
				switch_to = i
			}
		}
	}
	if switch_to >= 0 {sway_switch_layout(switch_to)}

	im.SetCursorScreenPos(p)
	im.Dummy({width, 66})
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
	card_title(ICON_SPEAKER, "Audio", C_BLUE)

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

// ---- System -----------------------------------------------------------------

@(private = "file")
graph_block :: proc(name, detail: string, value: f32, hist: ^History, n: int, accent: u32, inner: f32) {
	p := im.GetCursorScreenPos()
	draw_text(fonts.bold, SZ_BODY, {p.x, p.y}, col32(C_TEXT), name)
	nsz := measure(fonts.bold, SZ_BODY, name)
	draw_text(fonts.ui, SZ_SMALL, {p.x + nsz.x + 8, p.y + 2}, col32(C_MUTED), detail)
	val := fmt.tprintf("%d%%", int(value + 0.5))
	vsz := measure(fonts.bold, 20, val)
	draw_text(fonts.bold, 20, {p.x + inner - vsz.x, p.y - 4}, col32(accent), val)
	im.Dummy({inner, 20})
	history_graph(hist, n, accent, {inner, 58})
}

draw_system :: proc(w: f32) {
	card_begin("system", w)
	defer card_end()
	card_title(ICON_CHIP, "System", C_GREEN, fmt.tprintf("last %ds", config.history_seconds))

	sync.guard(&sysmon.mu)
	inner := im.GetContentRegionAvail().x
	n := config.history_seconds

	// CPU
	graph_block("CPU", sysmon.cpu_name, sysmon.cpu_now, &sysmon.cpu, n, C_GREEN, inner)
	if sysmon.core_count > 0 {
		p := im.GetCursorScreenPos()
		gap: f32 = 2
		cw := (inner - gap * f32(sysmon.core_count - 1)) / f32(sysmon.core_count)
		ch: f32 = 12
		d := dl()
		for i in 0 ..< sysmon.core_count {
			x := p.x + f32(i) * (cw + gap)
			v := clamp(sysmon.cores[i], 0, 100) / 100
			im.DrawList_AddRectFilled(d, {x, p.y}, {x + cw, p.y + ch}, col32(0x252a34), 2)
			if v > 0.01 {
				im.DrawList_AddRectFilled(d, {x, p.y + ch * (1 - v)}, {x + cw, p.y + ch}, load_color(sysmon.cores[i]), 2)
			}
		}
		im.Dummy({inner, ch})
	}
	cpu_extra := fmt.tprintf("%d threads", sysmon.core_count)
	if sysmon.cpu_temp > 0 {cpu_extra = fmt.tprintf("%s · %.0f°C", cpu_extra, sysmon.cpu_temp)}
	label(fonts.ui, SZ_SMALL, col32(C_MUTED), cpu_extra)
	im.Dummy({1, 4})

	// GPU
	if sysmon.gpu_ok {
		name := strings.trim_prefix(sysmon.gpu_name, "NVIDIA ")
		name = strings.trim_prefix(name, "GeForce ")
		graph_block("GPU", name, sysmon.gpu_now, &sysmon.gpu, n, C_PURPLE, inner)
		if sysmon.vram_total > 0 {
			p := im.GetCursorScreenPos()
			frac := f32(f64(sysmon.vram_used) / f64(sysmon.vram_total))
			txt := fmt.tprintf("VRAM %.1f / %.1f GiB", f64(sysmon.vram_used) / (1 << 30), f64(sysmon.vram_total) / (1 << 30))
			if sysmon.gpu_temp > 0 {txt = fmt.tprintf("%s · %.0f°C", txt, sysmon.gpu_temp)}
			if sysmon.gpu_power > 0 {txt = fmt.tprintf("%s · %.0f W", txt, sysmon.gpu_power)}
			draw_text(fonts.ui, SZ_SMALL, p, col32(C_MUTED), txt)
			im.Dummy({inner, 16})
			usage_bar(frac, col32(C_PURPLE, 0.8), {inner, 4})
		}
		im.Dummy({1, 4})
	}

	// Memory
	if sysmon.mem_total > 0 {
		p := im.GetCursorScreenPos()
		frac := f32(f64(sysmon.mem_used) / f64(sysmon.mem_total))
		warn := memory_warning(sysmon.mem_used, sysmon.mem_total)
		draw_text(fonts.bold, SZ_BODY, p, col32(warn ? C_RED : C_TEXT), "Memory")
		if warn {
			tag := "running low"
			tw := measure(fonts.bold, 11, tag).x
			nx := p.x + measure(fonts.bold, SZ_BODY, "Memory").x + 8
			im.DrawList_AddRectFilled(dl(), {nx, p.y + 1}, {nx + tw + 12, p.y + 18}, col32(C_RED, 0.18), 8)
			draw_text(fonts.bold, 11, {nx + 6, p.y + 2}, col32(C_RED), tag)
		}
		txt := fmt.tprintf("%.1f / %.1f GiB · %d%%", f64(sysmon.mem_used) / (1 << 30), f64(sysmon.mem_total) / (1 << 30), int(frac * 100 + 0.5))
		tsz := measure(fonts.ui, SZ_SMALL, txt)
		draw_text(fonts.ui, SZ_SMALL, {p.x + inner - tsz.x, p.y + 2}, col32(warn ? C_RED : C_MUTED), txt)
		im.Dummy({inner, 18})
		usage_bar(frac, col32(warn ? C_RED : C_CYAN), {inner, 6})
	}
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
	im.DrawList_AddRectFilled(dl(), p, {p.x + inner, p.y + h}, col32(0x12151b), 10)
	draw_layout(rects[:], {p.x + 10, p.y + 10}, {inner - 20, h - 20}, accent = C_PURPLE)
	im.Dummy({inner, h})

	if len(displays.presets) == 0 {
		label(fonts.ui, SZ_SMALL, col32(C_FAINT), "No preset scripts found (see [displays] in config)")
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
			im.DrawList_AddRectFilled(dl(), {row_p.x + 4, row_p.y + 3}, {row_p.x + 4 + pw, row_p.y + 3 + ph}, col32(0x12151b), 5)
			draw_layout(prects[:], {row_p.x + 7, row_p.y + 6}, {pw - 6, ph - 6}, compact = true, accent = C_PURPLE)
			draw_text(i == active ? fonts.bold : fonts.ui, SZ_BODY, {row_p.x + pw + 16, row_p.y + 3}, col32(C_TEXT), pr.label)
			names: [dynamic]string
			names.allocator = context.temp_allocator
			for o in pr.outputs {if o.enabled {append(&names, o.name)}}
			draw_text(fonts.ui, SZ_SMALL, {row_p.x + pw + 16, row_p.y + 20}, col32(C_MUTED), fmt.tprintf("%s · %s", pr.name, strings.join(names[:], " + ", context.temp_allocator)))
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
	im.DrawList_AddRectFilled(dl(), sp, {sp.x + inner, sp.y + sh}, col32(0x12151b), 10)
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
		im.DrawList_AddRectFilled(d, {p.x - 6, p.y}, {p.x + inner + 6, p.y + h}, col32(0xffffff, 0.05), 7)
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
			im.DrawList_AddRectFilled(dd, {p.x - 6, p.y}, {p.x + inner + 6, p.y + h}, col32(0xffffff, 0.05), 7)
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
