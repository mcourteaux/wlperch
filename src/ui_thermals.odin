// Thermals module: temperatures, power and fans.
package main

import "core:fmt"
import "core:sync"

import im "third_party:odin-imgui"

@(private = "file")
heat_color :: proc(c: f32) -> u32 {
	switch {
	case c < 50: return C_TEXT
	case c < 70: return C_YELLOW
	case c < 85: return C_ORANGE
	}
	return C_RED
}

// "CPU 38°" style stat; returns its width.
@(private = "file")
stat :: proc(pos: Vec2, name, value: string, col: u32) -> f32 {
	nsz := measure(fonts.ui, SZ_SMALL, name)
	draw_text(fonts.ui, SZ_SMALL, {pos.x, pos.y + 9}, col32(C_MUTED), name)
	draw_text(fonts.bold, 24, {pos.x + nsz.x + 6, pos.y - 2}, col32(col), value)
	return nsz.x + 6 + measure(fonts.bold, 24, value).x
}

draw_thermals :: proc(w: f32) {
	card_begin("thermals", w)
	defer card_end()
	sync.guard(&thermals.mu)
	card_title(ICON_THERMOMETER, "Temperatures & power", C_ORANGE)
	inner := im.GetContentRegionAvail().x

	// ---- Temperatures ---------------------------------------------------
	cpu_t, gpu_t: f32
	for i in 0 ..< thermals.n_temps {
		r := &thermals.temps[i]
		if r.group == .CPU {cpu_t = max(cpu_t, r.value)}
		if r.group == .GPU {gpu_t = max(gpu_t, r.value)}
	}
	p := im.GetCursorScreenPos()
	x := p.x
	if cpu_t > 0 {x += stat({x, p.y}, "CPU", fmt.tprintf("%.0f°", cpu_t), C_ORANGE) + 20}
	if gpu_t > 0 {stat({x, p.y}, "GPU", fmt.tprintf("%.0f°", gpu_t), C_PURPLE)}
	im.Dummy({inner, 30})
	history_graph_multi({{&thermals.cpu_temp_h, C_ORANGE, true}, {&thermals.gpu_temp_h, C_PURPLE, false}}, &perf_view, 100, {inner, 64})
	label(fonts.ui, 10.5, col32(C_FAINT), "0 – 100 °C")

	// ---- Power ------------------------------------------------------------
	im.Dummy({1, 4})
	p = im.GetCursorScreenPos()
	x = p.x
	if thermals.cpu_power_ok {x += stat({x, p.y}, "CPU", fmt.tprintf("%.0f W", thermals.cpu_watts), C_ORANGE) + 20}
	if thermals.gpu_watts > 0 {
		gw := stat({x, p.y}, "GPU", fmt.tprintf("%.0f W", thermals.gpu_watts), C_PURPLE)
		if thermals.gpu_limit > 0 {
			draw_text(fonts.ui, SZ_SMALL, {x + gw + 6, p.y + 9}, col32(C_FAINT), fmt.tprintf("of %.0f W", thermals.gpu_limit))
		}
	}
	im.Dummy({inner, 30})
	// Scale: the GPU power limit or what we've seen, whichever is larger.
	top: f32 = max(thermals.gpu_limit, 50)
	for h in ([]^History{&thermals.gpu_power_h, &thermals.cpu_power_h}) {
		top = max(top, history_view_max(h, &perf_view) * 1.1)
	}
	history_graph_multi({{&thermals.gpu_power_h, C_PURPLE, true}, {&thermals.cpu_power_h, C_ORANGE, false}}, &perf_view, top, {inner, 56})
	label(fonts.ui, 10.5, col32(C_FAINT), fmt.tprintf("0 – %.0f W", top))
	if !thermals.cpu_power_ok {
		label(fonts.ui, SZ_SMALL, col32(C_FAINT), "CPU power: the RAPL counter is root-only (see README)")
	}

	// ---- All sensors --------------------------------------------------------
	sub_heading("Sensors")
	colw := (inner - 16) / 2
	for i in 0 ..< thermals.n_temps {
		r := &thermals.temps[i]
		rp := im.GetCursorScreenPos()
		col := i % 2
		pos := Vec2{rp.x + f32(col) * (colw + 16), rp.y}
		draw_text(fonts.ui, SZ_SMALL + 1, {pos.x, pos.y + 2}, col32(C_TEXT, 0.85), reading_label(r))
		v := fmt.tprintf("%.0f°", r.value)
		vsz := measure(fonts.mono, SZ_SMALL + 1, v)
		draw_text(fonts.mono, SZ_SMALL + 1, {pos.x + colw - vsz.x, pos.y + 2}, col32(heat_color(r.value)), v)
		if col == 1 || i == thermals.n_temps - 1 {
			im.SetCursorScreenPos(rp)
			im.Dummy({inner, 20})
		} else {
			im.SetCursorScreenPos(rp)
		}
	}
	if thermals.n_fans > 0 {
		im.Dummy({1, 2})
		fp := im.GetCursorScreenPos()
		fx := fp.x
		for i in 0 ..< thermals.n_fans {
			f := &thermals.fans[i]
			txt := fmt.tprintf("%s  %d rpm", fan_label(f), f.rpm)
			tw := measure(fonts.ui, SZ_SMALL, txt).x + 26
			if fx + tw > fp.x + inner {
				fp.y += 26
				fx = fp.x
			}
			im.DrawList_AddRectFilled(dl(), {fx, fp.y}, {fx + tw, fp.y + 22}, col32(C_WELL), 7)
			draw_text(fonts.ui, 13, {fx + 7, fp.y + 3}, col32(C_CYAN, 0.8), ICON_FAN)
			draw_text(fonts.ui, SZ_SMALL, {fx + 22, fp.y + 4}, col32(C_MUTED), txt)
			fx += tw + 6
		}
		im.SetCursorScreenPos({fp.x, fp.y})
		im.Dummy({inner, 22})
	}
}
