// Performance modules: cpu, memory, gpu, processes.
package main

import "core:fmt"
import "core:strings"
import "core:sync"

import im "third_party:odin-imgui"

@(private = "file")
GiB :: f64(1 << 30)

fmt_bytes :: proc(b: u64) -> string {
	switch {
	case b >= 1 << 30: return fmt.tprintf("%.1f GiB", f64(b) / GiB)
	case b >= 1 << 20: return fmt.tprintf("%.0f MiB", f64(b) / (1 << 20))
	}
	return fmt.tprintf("%.0f KiB", f64(b) / 1024)
}

fmt_uptime :: proc(s: f64) -> string {
	m := int(s) / 60
	h := m / 60
	d := h / 24
	if d > 0 {return fmt.tprintf("%dd %dh", d, h % 24)}
	if h > 0 {return fmt.tprintf("%dh %dm", h, m % 60)}
	return fmt.tprintf("%dm", m)
}

// Big number + unit line used at the top of the perf cards.
@(private = "file")
big_stat :: proc(value: string, value_col: u32, detail: string, inner: f32) {
	p := im.GetCursorScreenPos()
	draw_text(fonts.bold, 30, {p.x, p.y - 4}, col32(value_col), value)
	vsz := measure(fonts.bold, 30, value)
	draw_text(fonts.ui, SZ_SMALL, {p.x + vsz.x + 10, p.y + 12}, col32(C_MUTED), detail)
	im.Dummy({inner, 32})
}

draw_cpu_card :: proc(w: f32) {
	card_begin("cpu", w)
	defer card_end()
	sync.guard(&sysmon.mu)
	card_title(ICON_CPU, "CPU", C_GREEN, sysmon.cpu_name)
	inner := im.GetContentRegionAvail().x

	detail := fmt.tprintf("load %.2f  %.2f  %.2f", sysmon.load[0], sysmon.load[1], sysmon.load[2])
	if sysmon.cpu_temp > 0 {detail = fmt.tprintf("%s   ·   %.0f°C", detail, sysmon.cpu_temp)}
	big_stat(fmt.tprintf("%d%%", int(sysmon.cpu_now + 0.5)), load_color(sysmon.cpu_now), detail, inner)
	history_graph(&sysmon.cpu, &perf_view, C_GREEN, {inner, 96})

	// Per-core bars with a small label underneath every 4th core.
	if sysmon.core_count > 0 {
		im.Dummy({1, 2})
		p := im.GetCursorScreenPos()
		gap: f32 = 3
		n := sysmon.core_count
		cw := (inner - gap * f32(n - 1)) / f32(n)
		ch: f32 = 34
		d := dl()
		for i in 0 ..< n {
			x := p.x + f32(i) * (cw + gap)
			v := clamp(sysmon.cores[i], 0, 100) / 100
			im.DrawList_AddRectFilled(d, {x, p.y}, {x + cw, p.y + ch}, col32(0x12151b), 3)
			if v > 0.01 {
				im.DrawList_AddRectFilled(d, {x, p.y + ch * (1 - v)}, {x + cw, p.y + ch}, load_color(sysmon.cores[i]), 3)
			}
		}
		im.Dummy({inner, ch})
		label(fonts.ui, SZ_SMALL, col32(C_MUTED), fmt.tprintf("%d threads   ·   up %s", n, fmt_uptime(sysmon.uptime)))
	}
}

draw_memory_card :: proc(w: f32) {
	card_begin("memory", w)
	defer card_end()
	sync.guard(&sysmon.mu)
	card_title(ICON_MEMORY, "Memory", C_CYAN, fmt_bytes(sysmon.mem_total))
	inner := im.GetContentRegionAvail().x
	if sysmon.mem_total == 0 {return}

	used, total := sysmon.mem_used, sysmon.mem_total
	pct := f64(used) / f64(total) * 100
	warn := memory_warning(used, total)
	accent: u32 = warn ? C_RED : C_CYAN

	p := im.GetCursorScreenPos()
	big_stat(fmt.tprintf("%d%%", int(pct + 0.5)), accent, fmt.tprintf("%s of %s in use", fmt_bytes(used), fmt_bytes(total)), inner)
	if warn {
		tag := "running low"
		tw := measure(fonts.bold, 11, tag).x
		im.DrawList_AddRectFilled(dl(), {p.x + inner - tw - 12, p.y + 6}, {p.x + inner, p.y + 23}, col32(C_RED, 0.18), 8)
		draw_text(fonts.bold, 11, {p.x + inner - tw - 6, p.y + 7}, col32(C_RED), tag)
	}
	history_graph(&sysmon.mem, &perf_view, accent, {inner, 80})

	// Used | cache | free, as one stacked bar.
	im.Dummy({1, 2})
	bp := im.GetCursorScreenPos()
	bh: f32 = 8
	d := dl()
	cached := min(sysmon.mem_cached, total - used)
	fu := f32(f64(used) / f64(total))
	fc := f32(f64(cached) / f64(total))
	im.DrawList_AddRectFilled(d, bp, {bp.x + inner, bp.y + bh}, col32(0x2a2f3a), bh / 2)
	im.DrawList_AddRectFilled(d, {bp.x + inner * fu, bp.y}, {bp.x + inner * (fu + fc), bp.y + bh}, col32(accent, 0.35), 0)
	im.DrawList_AddRectFilled(d, bp, {bp.x + max(inner * fu, bh), bp.y + bh}, col32(accent), bh / 2)
	im.Dummy({inner, bh})
	legend := fmt.tprintf("used %s    cache %s    free %s", fmt_bytes(used), fmt_bytes(cached), fmt_bytes(total - used - cached))
	label(fonts.ui, SZ_SMALL, col32(C_MUTED), legend)

	if sysmon.swap_total > 0 {
		im.Dummy({1, 2})
		sp := im.GetCursorScreenPos()
		sf := f32(f64(sysmon.swap_used) / f64(sysmon.swap_total))
		draw_text(fonts.bold, SZ_BODY, sp, col32(C_TEXT), "Swap")
		txt := fmt.tprintf("%s / %s", fmt_bytes(sysmon.swap_used), fmt_bytes(sysmon.swap_total))
		tsz := measure(fonts.ui, SZ_SMALL, txt)
		draw_text(fonts.ui, SZ_SMALL, {sp.x + inner - tsz.x, sp.y + 2}, col32(C_MUTED), txt)
		im.Dummy({inner, 18})
		usage_bar(sf, col32(C_PURPLE), {inner, 6})
	}
}

draw_gpu_card :: proc(w: f32) {
	if !sysmon.gpu_ok {return}
	card_begin("gpu", w)
	defer card_end()
	sync.guard(&sysmon.mu)
	name := strings.trim_prefix(sysmon.gpu_name, "NVIDIA ")
	card_title(ICON_GPU, "GPU", C_PURPLE, strings.trim_prefix(name, "GeForce "))
	inner := im.GetContentRegionAvail().x

	detail := ""
	if sysmon.gpu_temp > 0 {detail = fmt.tprintf("%.0f°C", sysmon.gpu_temp)}
	if sysmon.gpu_power > 0 {detail = fmt.tprintf("%s   ·   %.0f W", detail, sysmon.gpu_power)}
	big_stat(fmt.tprintf("%d%%", int(sysmon.gpu_now + 0.5)), C_PURPLE, detail, inner)
	history_graph(&sysmon.gpu, &perf_view, C_PURPLE, {inner, 80})
	if sysmon.vram_total > 0 {
		im.Dummy({1, 2})
		vp := im.GetCursorScreenPos()
		draw_text(fonts.bold, SZ_BODY, vp, col32(C_TEXT), "VRAM")
		txt := fmt.tprintf("%s / %s", fmt_bytes(sysmon.vram_used), fmt_bytes(sysmon.vram_total))
		tsz := measure(fonts.ui, SZ_SMALL, txt)
		draw_text(fonts.ui, SZ_SMALL, {vp.x + inner - tsz.x, vp.y + 2}, col32(C_MUTED), txt)
		im.Dummy({inner, 18})
		usage_bar(f32(f64(sysmon.vram_used) / f64(sysmon.vram_total)), col32(C_PURPLE, 0.8), {inner, 6})
	}
}

@(private = "file")
proc_rows :: proc(groups: []Proc_Group, by_cpu: bool, accent: u32, inner: f32, mem_total: u64) {
	top: f32 = 1
	for g in groups {top = max(top, by_cpu ? g.cpu : f32(g.rss))}
	for &g in groups {
		p := im.GetCursorScreenPos()
		h: f32 = 26
		d := dl()
		frac := by_cpu ? g.cpu / max(top, 100) : f32(f64(g.rss) / f64(max(mem_total, 1)))
		// Bar behind the row, proportional to the value.
		im.DrawList_AddRectFilled(d, {p.x - 4, p.y + 2}, {p.x - 4 + (inner + 8) * clamp(frac, 0, 1), p.y + h - 2}, col32(accent, 0.12), 6)
		name := proc_group_name(&g)
		draw_text(fonts.ui, SZ_BODY, {p.x + 4, p.y + 4}, col32(C_TEXT), name)
		if g.count > 1 {
			nsz := measure(fonts.ui, SZ_BODY, name)
			draw_text(fonts.ui, SZ_SMALL, {p.x + 10 + nsz.x, p.y + 6}, col32(C_FAINT), fmt.tprintf("×%d", g.count))
		}
		val := by_cpu ? fmt.tprintf("%.1f%%", g.cpu) : fmt_bytes(g.rss)
		vsz := measure(fonts.mono, SZ_BODY, val)
		draw_text(fonts.mono, SZ_BODY, {p.x + inner - vsz.x - 4, p.y + 4}, col32(by_cpu && g.cpu >= 50 ? C_ORANGE : C_TEXT), val)
		im.Dummy({inner, h})
	}
}

draw_processes :: proc(w: f32) {
	procs_mark_active()
	card_begin("processes", w)
	defer card_end()
	sync.guard(&procs.mu)
	card_title(ICON_TUNE, "Processes", C_ORANGE, procs.ok ? fmt.tprintf("%d running", procs.total) : "")
	inner := im.GetContentRegionAvail().x
	if !procs.ok {
		label(fonts.ui, SZ_BODY, col32(C_MUTED), "Sampling…")
		im.Dummy({inner, 2 * PROC_TOP * 26})
		return
	}
	sub_heading("Top CPU (% of one core)")
	proc_rows(procs.by_cpu[:procs.n_cpu], true, C_GREEN, inner, 0)
	im.Dummy({1, 6})
	sub_heading("Top memory (resident)")
	total: u64
	{
		sync.guard(&sysmon.mu)
		total = sysmon.mem_total
	}
	proc_rows(procs.by_mem[:procs.n_mem], false, C_CYAN, inner, total)
}
