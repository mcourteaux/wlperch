// Time tracker module.
package main

import "core:fmt"
import "core:strings"
import "core:time"

import im "third_party:odin-imgui"

@(private = "file")
DAY_LETTERS := [7]string{"Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"}

draw_time :: proc(w: f32) {
	now := time.to_unix_seconds(time.now())
	today := local_day_start(now)
	week_from := today - 6 * 86400
	week := tracker_totals(week_from, now + 1)
	week_total: i64
	for _, s in week {week_total += s}

	card_begin("time", w)
	defer card_end()
	card_title(ICON_CLOCK, "Time tracking", C_TEAL, fmt.tprintf("7 days %s", fmt_duration(week_total)))
	inner := im.GetContentRegionAvail().x

	if len(tracker.projects) == 0 {
		label(fonts.ui, SZ_BODY, col32(C_MUTED), "No projects yet: add [project.NAME] sections to")
		label(fonts.mono, SZ_SMALL, col32(C_TEXT), config_path())
		return
	}
	totals_today := tracker_totals(today, now + 1)

	// ---- Status -----------------------------------------------------------
	p := im.GetCursorScreenPos()
	if tracker.running >= 0 {
		pr := tracker.projects[tracker.running]
		im.DrawList_AddCircleFilled(dl(), {p.x + 7, p.y + 16}, 6, col32(pr.color))
		draw_text(fonts.bold, 22, {p.x + 22, p.y + 2}, col32(C_TEXT), pr.name)
		sub := pr.client != "" ? pr.client : "personal"
		draw_text(fonts.ui, SZ_SMALL, {p.x + 22, p.y + 30}, col32(C_MUTED), fmt.tprintf("%s   ·   today %s", sub, fmt_duration(totals_today[pr.name])))
		el := fmt_duration(now - tracker.seg_start, true)
		esz := measure(fonts.mono, 24, el)
		draw_text(fonts.mono, 24, {p.x + inner - esz.x, p.y + 4}, col32(pr.color), el)
		cap := "counting"
		csz := measure(fonts.ui, SZ_SMALL, cap)
		draw_text(fonts.ui, SZ_SMALL, {p.x + inner - csz.x, p.y + 32}, col32(C_GREEN), cap)
	} else {
		msg := tracker.paused_idle ? "Paused — you were away" : "Not on a project workspace"
		col: u32 = tracker.paused_idle ? C_ORANGE : C_MUTED
		draw_text(fonts.bold, 18, {p.x, p.y + 4}, col32(col), msg)
		hint := tracker.paused_idle ? "counting resumes with your next input" : "pick a project below to open its workspaces"
		draw_text(fonts.ui, SZ_SMALL, {p.x, p.y + 30}, col32(C_FAINT), hint)
	}
	im.Dummy({inner, 50})

	// ---- Projects (quick switch) ----------------------------------------
	sub_heading("Projects")
	{
		// Group lock toggle, right-aligned on the "Projects" heading line.
		hp := im.GetCursorScreenPos()
		lbl := "Group-lock monitors"
		lsz := measure(fonts.ui, SZ_SMALL, lbl)
		im.SetCursorScreenPos({hp.x + inner - 38, hp.y - 24})
		if toggle_switch("##grouplock", tracker.lock, C_TEAL) {tracker_set_lock(!tracker.lock)}
		if im.IsItemHovered() {tip("When on, all monitors enter and leave a project's workspaces together")}
		draw_text(fonts.ui, SZ_SMALL, {hp.x + inner - 46 - lsz.x, hp.y - 21}, col32(tracker.lock ? C_TEAL : C_MUTED), lbl)
		draw_text(fonts.ui, 14, {hp.x + inner - 66 - lsz.x, hp.y - 22}, col32(tracker.lock ? C_TEAL : C_FAINT), ICON_LINK)
		im.SetCursorScreenPos(hp)
	}
	start := -1
	for pr, i in tracker.projects {
		rp := im.GetCursorScreenPos()
		h: f32 = 34
		clicked := im.InvisibleButton(cstr(fmt.tprintf("proj:%s", pr.key)), {inner, h})
		hovered := im.IsItemHovered()
		d := dl()
		active := i == tracker.running
		if active {
			im.DrawList_AddRectFilled(d, {rp.x - 6, rp.y}, {rp.x + inner + 6, rp.y + h}, col32(pr.color, hovered ? 0.2 : 0.12), 8)
		} else if hovered {
			im.DrawList_AddRectFilled(d, {rp.x - 6, rp.y}, {rp.x + inner + 6, rp.y + h}, col32(0xffffff, 0.05), 8)
		}
		if hovered {
			im.SetMouseCursor(.Hand)
			tip(active ? fmt.tprintf("Bring all monitors back to %s", pr.name) : fmt.tprintf("Open %s's workspaces on all monitors", pr.name))
		}
		// Also for the active project: re-syncs every monitor (e.g. one wandered off).
		if clicked {start = i}
		im.DrawList_AddCircleFilled(d, {rp.x + 6, rp.y + h / 2}, 5, col32(pr.color, active ? 1 : 0.7))
		draw_text(active ? fonts.bold : fonts.ui, SZ_BODY, {rp.x + 20, rp.y + 8}, col32(C_TEXT), pr.name)
		if pr.client != "" {
			nsz := measure(active ? fonts.bold : fonts.ui, SZ_BODY, pr.name)
			draw_text(fonts.ui, SZ_SMALL, {rp.x + 28 + nsz.x, rp.y + 10}, col32(C_FAINT), pr.client)
		}
		tt := fmt_duration(totals_today[pr.name])
		tsz := measure(fonts.mono, SZ_BODY, tt)
		draw_text(fonts.mono, SZ_BODY, {rp.x + inner - tsz.x - 26, rp.y + 8}, col32(totals_today[pr.name] > 0 ? C_TEXT : C_FAINT), tt)
		icon := active ? ICON_MONITORS : ICON_PLAY
		draw_text(fonts.ui, 15, {rp.x + inner - 16, rp.y + 8}, col32(hovered || active ? pr.color : C_FAINT, active && !hovered ? 0.6 : 1), icon)
	}
	// Keep-alive toggle: placeholder windows hold empty project workspaces open.
	{
		kp := im.GetCursorScreenPos()
		im.Dummy({1, 2})
		lbl := "Keep empty workspaces (placeholder windows)"
		im.SetCursorScreenPos({kp.x, kp.y + 4})
		if toggle_switch("##keepws", placeholders.keep, C_TEAL) {placeholders_set_keep(!placeholders.keep)}
		if im.IsItemHovered() {tip("Empty project workspaces get a placeholder window so sway doesn't remove them;\nit closes as soon as you put a real window there")}
		draw_text(fonts.ui, SZ_SMALL, {kp.x + 48, kp.y + 7}, col32(placeholders.keep ? C_TEAL : C_MUTED), lbl)
		im.SetCursorScreenPos(kp)
		im.Dummy({inner, 30})
	}
	if start >= 0 {
		tracker_start(start)
		hide_requested = true // get out of the way of the new workspaces
	}

	// ---- Today ----------------------------------------------------------
	day_total: i64
	for _, s in totals_today {day_total += s}
	sub_heading(fmt.tprintf("Today   ·   %s", fmt_duration(day_total)))
	draw_day_timeline(today, now, inner)
	im.Dummy({1, 4})

	// ---- Breaks (away from keyboard) ------------------------------------
	{
		breaks_today := tracker_breaks(today, now + 1)
		breaks_week := tracker_breaks(week_from, now + 1)
		n_today, n_week: int
		for _, b in breaks_today {n_today += b.count}
		for _, b in breaks_week {n_week += b.count}
		sub_heading(fmt.tprintf("Away from keyboard   ·   today %d×   ·   7 days %d×", n_today, n_week))
		if n_week == 0 && !tracker.away {
			label(fonts.ui, SZ_SMALL, col32(C_FAINT), fmt.tprintf("No breaks yet (a break = no input for %d min)", int(time.duration_minutes(tracker.idle))))
		}
		row :: proc(name, client: string, color: u32, bt, bw: Break_Stats, work_week: i64, inner: f32) {
			rp := im.GetCursorScreenPos()
			h: f32 = 30
			im.DrawList_AddCircleFilled(dl(), {rp.x + 6, rp.y + h / 2}, 4, col32(color, 0.8))
			draw_text(fonts.ui, SZ_BODY, {rp.x + 18, rp.y + 6}, col32(C_TEXT), name)
			counts := fmt.tprintf("%d× today  ·  %d× this week", bt.count, bw.count)
			nsz := measure(fonts.ui, SZ_BODY, name)
			draw_text(fonts.ui, SZ_SMALL, {rp.x + 26 + nsz.x, rp.y + 8}, col32(C_FAINT), counts)
			right := fmt.tprintf("away %s", fmt_duration(bw.secs))
			// How long you work, on average, before walking away.
			if work_week > 0 && bw.count > 0 {
				right = fmt.tprintf("every %dm  ·  %s", int(work_week / i64(bw.count) / 60), right)
			}
			rsz := measure(fonts.mono, SZ_SMALL + 1, right)
			draw_text(fonts.mono, SZ_SMALL + 1, {rp.x + inner - rsz.x, rp.y + 7}, col32(C_MUTED), right)
			im.Dummy({inner, h})
		}
		for pr in tracker.projects {
			bw, has := breaks_week[pr.name]
			if !has {continue}
			row(pr.name, pr.client, pr.color, breaks_today[pr.name], bw, week[pr.name], inner)
		}
		if bw, has := breaks_week[NO_PROJECT]; has {
			row("No project", "", C_FAINT, breaks_today[NO_PROJECT], bw, 0, inner)
		}
		if tracker.away {
			label(fonts.ui, SZ_SMALL, col32(C_ORANGE), fmt.tprintf("Away right now since %s", fmt_duration(now - tracker.away_start)))
		}
	}

	// ---- Week -----------------------------------------------------------
	sub_heading("Last 7 days")
	gp := im.GetCursorScreenPos()
	d := dl()
	gh: f32 = 110
	label_h: f32 = 18
	days: [7]map[string]i64
	most: i64 = 4 * 3600
	for i in 0 ..< 7 {
		from := week_from + i64(i) * 86400
		days[i] = tracker_totals(from, from + 86400)
		tot: i64
		for _, s in days[i] {tot += s}
		most = max(most, tot)
	}
	hours := (most + 3599) / 3600
	im.DrawList_AddRectFilled(d, gp, {gp.x + inner, gp.y + gh}, col32(0x12151b), 8)
	for hgrid := i64(2); hgrid < hours; hgrid += 2 {
		y := gp.y + gh - gh * f32(hgrid) / f32(hours)
		im.DrawList_AddLine(d, {gp.x + 4, y}, {gp.x + inner - 4, y}, col32(0xffffff, 0.04))
		draw_text(fonts.ui, 10, {gp.x + 6, y - 12}, col32(C_FAINT), fmt.tprintf("%dh", hgrid))
	}
	colw := (inner - 40) / 7
	for i in 0 ..< 7 {
		x0 := gp.x + 32 + f32(i) * colw + colw * 0.2
		x1 := x0 + colw * 0.6
		y := gp.y + gh - 4
		tot: i64
		for pr in tracker.projects {
			s := days[i][pr.name]
			if s <= 0 {continue}
			tot += s
			hseg := (gh - 8) * f32(f64(s) / f64(hours * 3600))
			im.DrawList_AddRectFilled(d, {x0, y - hseg}, {x1, y}, col32(pr.color), 3)
			y -= hseg
		}
		day := week_from + i64(i) * 86400
		wd := 0
		if r, ok := clock_read(local_region, time.unix(day + 43200, 0)); ok {wd = weekday_of(r.dt)}
		lbl := DAY_LETTERS[wd]
		is_today := i == 6
		lsz := measure(is_today ? fonts.bold : fonts.ui, SZ_SMALL, lbl)
		draw_text(is_today ? fonts.bold : fonts.ui, SZ_SMALL, {(x0 + x1) / 2 - lsz.x / 2, gp.y + gh + 3}, col32(is_today ? C_TEXT : C_MUTED), lbl)
		if tot > 0 && im.IsMouseHoveringRect({x0 - 4, gp.y}, {x1 + 4, gp.y + gh}) {
			lines: [dynamic]string
			lines.allocator = context.temp_allocator
			for pr in tracker.projects {
				if s := days[i][pr.name]; s > 0 {append(&lines, fmt.tprintf("%s  %s", pr.name, fmt_duration(s)))}
			}
			tip(strings.join(lines[:], "\n", context.temp_allocator))
		}
	}
	im.Dummy({inner, gh + label_h})
}

// Today as a 24 h timeline: work in the project's color, breaks in a dim
// version of it, breaks outside projects in gray; untracked time is the track.
@(private = "file")
draw_day_timeline :: proc(day_start, now: i64, inner: f32) {
	Seg :: struct {
		s, e:    i64,
		project: string,
		idle:    bool,
	}
	segs: [dynamic]Seg
	segs.allocator = context.temp_allocator
	day_end := day_start + 86400
	for e in tracker.entries {
		if e.end > day_start && e.start < day_end {append(&segs, Seg{e.start, e.end, e.project, e.idle})}
	}
	if tracker.running >= 0 {append(&segs, Seg{tracker.seg_start, now, tracker.projects[tracker.running].name, false})}
	if tracker.away {append(&segs, Seg{tracker.away_start, now, tracker.away_project, true})}
	// Merge back-to-back pieces of the same kind (restarts split the log).
	for i in 1 ..< len(segs) {
		for j := i; j > 0 && segs[j].s < segs[j - 1].s; j -= 1 {segs[j], segs[j - 1] = segs[j - 1], segs[j]}
	}
	merged: [dynamic]Seg
	merged.allocator = context.temp_allocator
	for sg in segs {
		if n := len(merged); n > 0 {
			last := &merged[n - 1]
			if last.project == sg.project && last.idle == sg.idle && sg.s - last.e <= 90 {
				last.e = max(last.e, sg.e)
				continue
			}
		}
		append(&merged, sg)
	}
	segs = merged

	color_of :: proc(project: string) -> (u32, bool) {
		for pr in tracker.projects {if pr.name == project {return pr.color, true}}
		return C_FAINT, false
	}

	p := im.GetCursorScreenPos()
	bh: f32 = 22
	d := dl()
	x_of :: proc(t, day_start: i64, x0, w: f32) -> f32 {
		return x0 + w * f32(f64(clamp(t, day_start, day_start + 86400) - day_start) / 86400)
	}
	im.DrawList_AddRectFilled(d, p, {p.x + inner, p.y + bh}, col32(0x12151b), 6)
	// Hour grid.
	for h in 1 ..< 24 {
		x := p.x + inner * f32(h) / 24
		a: f32 = h % 6 == 0 ? 0.10 : 0.04
		im.DrawList_AddLine(d, {x, p.y + 3}, {x, p.y + bh - 3}, col32(0xffffff, a))
	}
	hovered_seg := -1
	mouse := im.GetMousePos()
	im.DrawList_PushClipRect(d, p, {p.x + inner, p.y + bh}, true)
	for sg, i in segs {
		x0 := x_of(sg.s, day_start, p.x, inner)
		x1 := max(x_of(sg.e, day_start, p.x, inner), x0 + 1)
		col, is_project := color_of(sg.project)
		c: u32
		switch {
		case !sg.idle:     c = col32(col)
		case is_project:   c = col32(col, 0.22) // a break during a project session
		case:              c = col32(0x8a92a3, 0.45) // a break outside projects
		}
		im.DrawList_AddRectFilled(d, {x0, p.y + 2}, {x1, p.y + bh - 2}, c, 2)
		if mouse.x >= x0 && mouse.x < x1 && mouse.y >= p.y && mouse.y < p.y + bh {hovered_seg = i}
	}
	// "Now" marker.
	nx := x_of(now, day_start, p.x, inner)
	im.DrawList_AddLine(d, {nx, p.y}, {nx, p.y + bh}, col32(C_TEXT, 0.9), 1.5)
	im.DrawList_PopClipRect(d)
	im.Dummy({inner, bh})

	// Hour labels.
	lp := im.GetCursorScreenPos()
	for h := 0; h <= 24; h += 3 {
		lbl := fmt.tprintf("%02d", h % 24)
		if h == 24 {lbl = "24"}
		lsz := measure(fonts.ui, 10.5, lbl)
		x := p.x + inner * f32(h) / 24 - lsz.x / 2
		x = clamp(x, p.x, p.x + inner - lsz.x)
		draw_text(fonts.ui, 10.5, {x, lp.y}, col32(C_FAINT), lbl)
	}
	im.Dummy({inner, 14})

	// Legend.
	{
		lg := im.GetCursorScreenPos()
		x := lg.x
		accent: u32 = tracker.running >= 0 ? tracker.projects[tracker.running].color : C_TEAL
		items := [3]struct {
			col:   u32,
			alpha: f32,
			text:  string,
		}{{accent, 1, "working"}, {accent, 0.22, "break during a project"}, {0x8a92a3, 0.45, "break, no project"}}
		for it in items {
			im.DrawList_AddRectFilled(dl(), {x, lg.y + 4}, {x + 10, lg.y + 12}, col32(it.col, it.alpha), 2)
			draw_text(fonts.ui, 11, {x + 14, lg.y + 1}, col32(C_FAINT), it.text)
			x += 14 + measure(fonts.ui, 11, it.text).x + 16
		}
		im.Dummy({inner, 16})
	}

	if hovered_seg >= 0 {
		sg := segs[hovered_seg]
		hm :: proc(t: i64) -> string {
			if r, ok := clock_read(local_region, time.unix(t, 0)); ok {return fmt.tprintf("%02d:%02d", r.dt.hour, r.dt.minute)}
			return "?"
		}
		what := sg.idle ? (sg.project == NO_PROJECT ? "Break (no project)" : fmt.tprintf("Break during %s", sg.project)) : sg.project
		tip(fmt.tprintf("%s\n%s – %s  (%s)", what, hm(sg.s), hm(sg.e), fmt_duration(sg.e - sg.s)))
	}
}
