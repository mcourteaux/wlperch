// Sensors module: Tuya thermo-hygrometers, air-quality monitors and heaters.
package main

import "core:fmt"
import "core:sync"
import "core:time"

import im "third_party:odin-imgui"

STALE_AFTER :: 3 * 3600 // seconds; sensors normally report every few minutes

@(private = "file")
temp_color :: proc(t: f64) -> u32 {
	switch {
	case t < 17: return C_CYAN
	case t < 19: return 0x9ab8ff
	case t <= 23: return C_TEXT
	case t <= 26: return C_YELLOW
	}
	return C_ORANGE
}

@(private = "file")
humidity_color :: proc(h: f64) -> u32 {
	switch {
	case h < 35: return C_YELLOW // dry
	case h > 70: return C_RED    // mould territory
	case h > 60: return C_ORANGE
	}
	return C_CYAN
}

@(private = "file")
co2_color :: proc(ppm: f64) -> u32 {
	switch {
	case ppm <= 800:  return C_GREEN
	case ppm <= 1200: return C_YELLOW
	}
	return C_RED
}

@(private = "file")
is_stale :: proc(t: f64) -> bool {
	return t > 0 && f64(time.to_unix_seconds(time.now())) - t > STALE_AFTER
}

@(private = "file")
num :: proc(d: ^Sensor_Device, codes: ..string) -> (v: Sensor_Value, ok: bool) {
	for c in codes {
		if x, found := sensor_value(d, c); found && x.is_num {return x, true}
	}
	return {}, false
}

// A small "label value" chip; returns its width.
@(private = "file")
chip :: proc(pos: Vec2, lbl, value: string, col: u32) -> f32 {
	lw := measure(fonts.ui, SZ_SMALL, lbl).x
	vw := measure(fonts.bold, SZ_SMALL + 1, value).x
	w := lw + vw + 22
	im.DrawList_AddRectFilled(dl(), pos, {pos.x + w, pos.y + 22}, col32(0x12151b), 7)
	draw_text(fonts.ui, SZ_SMALL, {pos.x + 8, pos.y + 4}, col32(C_MUTED), lbl)
	draw_text(fonts.bold, SZ_SMALL + 1, {pos.x + 14 + lw, pos.y + 3}, col32(col), value)
	return w
}

@(private = "file")
draw_rooms :: proc(w: f32) {
	any_climate := false
	for d in sensors.devices {if d.kind == .Climate {any_climate = true}}
	if !any_climate {return}
	card_begin("rooms", w)
	defer card_end()
	card_title(ICON_THERMOMETER, "Rooms", C_TEAL)
	inner := im.GetContentRegionAvail().x
	for &d in sensors.devices {
		if d.kind != .Climate {continue}
		p := im.GetCursorScreenPos()
		h: f32 = 44
		im.InvisibleButton(cstr(fmt.tprintf("room:%s", d.id)), {inner, h})
		if im.IsItemHovered() {
			im.DrawList_AddRectFilled(dl(), {p.x - 6, p.y}, {p.x + inner + 6, p.y + h}, col32(0xffffff, 0.04), 8)
			history_tip(&d, d.name, {
				{"va_temperature", "Temperature", "°", C_ORANGE, 1},
				{"temp_current", "Temperature", "°", C_ORANGE, 0},
				{"humidity_value", "Humidity", "%", C_CYAN, 0},
			})
		}
		im.SetCursorScreenPos(p)
		stale := is_stale(d.last_t)
		alpha: f32 = stale ? 0.45 : 1
		draw_text(fonts.bold, SZ_BODY + 1, {p.x, p.y + 4}, col32(C_TEXT, alpha), d.name)
		age := age_text(d.last_t)
		draw_text(fonts.ui, SZ_SMALL, {p.x, p.y + 24}, col32(stale ? C_ORANGE : C_FAINT), stale ? fmt.tprintf("no report for %s", age) : fmt.tprintf("updated %s ago", age) if age != "now" else "updated just now")

		x := p.x + inner
		if b, ok := num(&d, "battery_percentage"); ok {
			icon, col := battery_glyph(int(b.num), false)
			bt := fmt.tprintf("%.0f%%", b.num)
			bw := measure(fonts.ui, SZ_SMALL, bt).x
			draw_text(fonts.ui, SZ_SMALL, {x - bw, p.y + 15}, col32(b.num <= 20 ? C_RED : C_FAINT), bt)
			draw_text(fonts.ui, 15, {x - bw - 19, p.y + 13}, col32(col, b.num <= 20 ? 1 : 0.6), icon)
			x -= bw + 34
		}
		if hv, ok := num(&d, "humidity_value", "va_humidity"); ok {
			ht := fmt.tprintf("%.0f%%", hv.num)
			hw := measure(fonts.bold, 18, ht).x
			draw_text(fonts.bold, 18, {x - hw, p.y + 10}, col32(humidity_color(hv.num), alpha), ht)
			draw_text(fonts.ui, 15, {x - hw - 18, p.y + 13}, col32(humidity_color(hv.num), 0.7 * alpha), ICON_WATER)
			x -= hw + 34
		}
		if tv, ok := num(&d, "va_temperature", "temp_current"); ok {
			tt := fmt.tprintf("%.1f°", tv.num)
			tw := measure(fonts.bold, 24, tt).x
			draw_text(fonts.bold, 24, {x - tw, p.y + 6}, col32(temp_color(tv.num), alpha), tt)
		}
		im.Dummy({inner, h})
	}
}

@(private = "file")
draw_air :: proc(w: f32, d: ^Sensor_Device) {
	card_begin(fmt.tprintf("air:%s", d.id), w)
	defer card_end()
	stale := is_stale(d.last_t)
	card_title(ICON_W_HAZY, fmt.tprintf("Air · %s", d.name), C_GREEN, stale ? fmt.tprintf("no report for %s", age_text(d.last_t)) : age_text(d.last_t))
	inner := im.GetContentRegionAvail().x
	if len(d.values) == 0 {
		no_data_yet(inner)
		return
	}
	p := im.GetCursorScreenPos()
	im.InvisibleButton(cstr(fmt.tprintf("airhover:%s", d.id)), {inner, 44})
	if im.IsItemHovered() {
		history_tip(d, d.name, {
			{"co2_value", "CO₂", " ppm", C_GREEN, 0},
			{"pm25_value", "PM2.5", " µg/m³", C_YELLOW, 0},
			{"temp_current", "Temperature", "°", C_ORANGE, 0},
			{"humidity_value", "Humidity", "%", C_CYAN, 0},
		})
	}
	im.SetCursorScreenPos(p)
	if co2, ok := num(d, "co2_value"); ok {
		v := fmt.tprintf("%.0f", co2.num)
		vw := measure(fonts.bold, 34, v).x
		draw_text(fonts.bold, 34, {p.x, p.y - 4}, col32(co2_color(co2.num), stale ? 0.5 : 1), v)
		draw_text(fonts.ui, SZ_SMALL, {p.x + vw + 8, p.y + 6}, col32(C_MUTED), "ppm CO₂")
		verdict := co2.num <= 800 ? "fresh" : co2.num <= 1200 ? "stuffy — ventilate soon" : "ventilate now"
		draw_text(fonts.ui, SZ_SMALL, {p.x + vw + 8, p.y + 22}, col32(co2_color(co2.num)), verdict)
	}
	// Temperature + humidity on the right.
	x := p.x + inner
	if hv, ok := num(d, "humidity_value"); ok {
		ht := fmt.tprintf("%.0f%%", hv.num)
		hw := measure(fonts.bold, 18, ht).x
		draw_text(fonts.bold, 18, {x - hw, p.y + 6}, col32(humidity_color(hv.num)), ht)
		x -= hw + 16
	}
	if tv, ok := num(d, "temp_current", "va_temperature"); ok {
		tt := fmt.tprintf("%.0f°", tv.num)
		tw := measure(fonts.bold, 18, tt).x
		draw_text(fonts.bold, 18, {x - tw, p.y + 6}, col32(temp_color(tv.num)), tt)
	}
	im.Dummy({inner, 44})

	cp := im.GetCursorScreenPos()
	cx := cp.x
	if v, ok := num(d, "pm25_value"); ok {cx += chip({cx, cp.y}, "PM2.5", fmt.tprintf("%.0f", v.num), v.num <= 15 ? C_GREEN : v.num <= 35 ? C_YELLOW : C_RED) + 6}
	if v, ok := num(d, "pm10"); ok {cx += chip({cx, cp.y}, "PM10", fmt.tprintf("%.0f", v.num), v.num <= 45 ? C_GREEN : v.num <= 100 ? C_YELLOW : C_RED) + 6}
	if v, ok := num(d, "pm1"); ok {cx += chip({cx, cp.y}, "PM1", fmt.tprintf("%.0f", v.num), C_TEXT) + 6}
	if v, ok := num(d, "ch2o_value"); ok {cx += chip({cx, cp.y}, "HCHO", fmt.tprintf("%.3f", v.num), v.num <= 0.08 ? C_GREEN : C_ORANGE) + 6}
	if b, ok := num(d, "battery_percentage"); ok && cx < cp.x + inner - 80 {
		chip({cx, cp.y}, "bat", fmt.tprintf("%.0f%%", b.num), b.num <= 20 ? C_RED : C_MUTED)
	}
	im.Dummy({inner, 22})
}

@(private = "file")
draw_heater :: proc(w: f32, d: ^Sensor_Device) {
	card_begin(fmt.tprintf("heater:%s", d.id), w)
	defer card_end()
	on := false
	if s, ok := sensor_value(d, "switch"); ok {on = s.text == "on"}
	card_title(ICON_LIGHTNING, d.name, C_ORANGE, age_text(d.last_t))
	inner := im.GetContentRegionAvail().x
	if len(d.values) == 0 {
		no_data_yet(inner)
		return
	}
	p := im.GetCursorScreenPos()
	im.InvisibleButton(cstr(fmt.tprintf("heathover:%s", d.id)), {inner, 28})
	if im.IsItemHovered() {
		history_tip(d, d.name, {
			{"temp_current", "Temperature", "°", C_ORANGE, 0},
			{"temp_set", "Target", "°", C_MUTED, 0},
		})
	}
	im.SetCursorScreenPos(p)
	pill := on ? "ON" : "OFF"
	pw := measure(fonts.bold, SZ_SMALL, pill).x + 18
	im.DrawList_AddRectFilled(dl(), {p.x, p.y + 4}, {p.x + pw, p.y + 24}, col32(on ? C_ORANGE : 0x353b48, on ? 0.9 : 1), 10)
	draw_text(fonts.bold, SZ_SMALL, {p.x + 9, p.y + 6}, col32(on ? 0x111318 : C_MUTED), pill)
	x := p.x + pw + 14
	if cur, ok := num(d, "temp_current"); ok {
		t := fmt.tprintf("%.0f°", cur.num)
		draw_text(fonts.bold, 22, {x, p.y}, col32(temp_color(cur.num)), t)
		x += measure(fonts.bold, 22, t).x + 10
	}
	if set, ok := num(d, "temp_set"); ok {
		draw_text(fonts.ui, SZ_SMALL, {x, p.y + 8}, col32(C_MUTED), fmt.tprintf("set to %.0f°", set.num))
	}
	if m, ok := sensor_value(d, "mode"); ok && m.text != "" {
		mw := measure(fonts.ui, SZ_SMALL, m.text).x
		draw_text(fonts.ui, SZ_SMALL, {p.x + inner - mw, p.y + 8}, col32(C_MUTED), m.text)
	}
	im.Dummy({inner, 28})
}

@(private = "file")
no_data_yet :: proc(inner: f32) {
	msg := sensors.watching ? "No data yet — waiting for it to report" : "No data yet (watcher not running)"
	label(fonts.ui, SZ_BODY, col32(C_MUTED), msg)
}

HISTORY_SPAN :: 24 * 3600.0

// Hover tooltip with history graphs for the given codes of a device.
@(private = "file")
history_tip :: proc(d: ^Sensor_Device, title: string, graphs: []struct {
		code, label, unit: string,
		color:             u32,
		decimals:          int,
	}) {
	now := f64(time.to_unix_seconds(time.now()))
	from := now - HISTORY_SPAN
	im.PushStyleVarImVec2(.WindowPadding, {12, 10})
	// Right-aligned inside the panel, just below the pointer.
	TIP_W :: 300 + 24
	im.SetNextWindowPos({ui.panel_max.x - TIP_W - 12, im.GetMousePos().y + 20})
	if im.BeginTooltip() {
		label(fonts.bold, SZ_BODY, col32(C_TEXT), fmt.tprintf("%s — last 24 h", title))
		for g in graphs {
			samples := sensor_history(d.id, g.code, from)
			if len(samples) == 0 {
				if alt, ok := sensor_value(d, g.code); !ok || !alt.is_num {continue}
			}
			label(fonts.ui, SZ_SMALL, col32(g.color), g.label)
			sample_graph(samples, from, now, g.color, g.unit, g.decimals, {300, 70})
		}
		// Time axis labels, aligned to the graphs' edges.
		ap := im.GetCursorScreenPos()
		draw_text(fonts.ui, 10.5, ap, col32(C_FAINT), "24 h ago")
		nw := measure(fonts.ui, 10.5, "now").x
		draw_text(fonts.ui, 10.5, {ap.x + 300 - nw, ap.y}, col32(C_FAINT), "now")
		im.Dummy({300, 14})
		note_overlay()
		im.EndTooltip()
	}
	im.PopStyleVar()
}

draw_sensors :: proc(w: f32) {
	sync.guard(&sensors.mu)
	if !sensors.ok {
		card_begin("sensors", w)
		defer card_end()
		card_title(ICON_THERMOMETER, "Sensors", C_TEAL)
		msg := sensors.error != "" ? sensors.error : fmt.tprintf("Set [sensors] dir in the config (now: %s)", config.sensors_dir)
		label(fonts.ui, SZ_BODY, col32(C_MUTED), msg)
		return
	}
	draw_rooms(w)
	for &d in sensors.devices {
		if d.kind == .Air {draw_air(w, &d)}
	}
	for &d in sensors.devices {
		if d.kind == .Heater {draw_heater(w, &d)}
	}
}
