// Time tracker module.
package main

import "core:fmt"
import "core:math"
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

	// Gathering banner.
	if tracker_pin_active() {
		pr := tracker.projects[tracker.pinned]
		bp := im.GetCursorScreenPos()
		bh: f32 = 34
		im.DrawList_AddRectFilled(dl(), bp, {bp.x + inner, bp.y + bh}, col32(pr.color, 0.14), 9)
		draw_text(fonts.ui, 15, {bp.x + 10, bp.y + 8}, col32(pr.color), ICON_PIN)
		msg := fmt.tprintf("Gathering into %s: Mod+Shift+P from any workspace", pr.name)
		draw_text(fonts.ui, SZ_SMALL, {bp.x + 32, bp.y + 10}, col32(C_TEXT), msg)
		left := fmt.tprintf("%ds", int(time.duration_seconds(tracker_pin_left()) + 0.5))
		lsz := measure(fonts.mono, SZ_SMALL, left)
		im.SetCursorScreenPos({bp.x + inner - lsz.x - 40, bp.y + 3})
		if icon_button("##unpin", ICON_CLOSE, C_MUTED, 28, tooltip = "Stop gathering") {tracker_unpin()}
		draw_text(fonts.mono, SZ_SMALL, {bp.x + inner - lsz.x - 8, bp.y + 10}, col32(C_MUTED), left)
		im.SetCursorScreenPos(bp)
		im.Dummy({inner, bh})
		request_redraw(1) // countdown
	}

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
	rename_go := false
	for pr, i in tracker.projects {
		rp := im.GetCursorScreenPos()
		h: f32 = 34
		PENCIL_W :: f32(28)
		clicked := im.InvisibleButton(cstr(fmt.tprintf("proj:%s", pr.key)), {inner - PENCIL_W, h})
		hovered := im.IsItemHovered()
		// The pencil at the right end of the row: rename the project.
		editing := ren.key == pr.key
		im.SetCursorScreenPos({rp.x + inner - PENCIL_W + 2, rp.y + 3})
		if im.InvisibleButton(cstr(fmt.tprintf("rename:%s", pr.key)), {PENCIL_W, h - 6}) {
			if editing {rename_close()} else {rename_open(pr)}
			editing = ren.key == pr.key
		}
		pencil_hovered := im.IsItemHovered()
		if pencil_hovered {
			im.SetMouseCursor(.Hand)
			tip(fmt.tprintf("Rename %s: its time log, config.ini section\nand (if you like) its sway workspaces", pr.name))
		}
		row_hovered := im.IsMouseHoveringRect({rp.x - 6, rp.y}, {rp.x + inner + 6, rp.y + h})
		if row_hovered || editing {
			pc := pencil_hovered || editing ? pr.color : C_FAINT
			psz := measure(fonts.ui, 15, ICON_PENCIL)
			draw_text(fonts.ui, 15, {rp.x + inner - PENCIL_W / 2 + 2 - psz.x / 2, rp.y + 8}, col32(pc), ICON_PENCIL)
		}
		im.SetCursorScreenPos({rp.x, rp.y + h})
		d := dl()
		active := i == tracker.running
		if active {
			im.DrawList_AddRectFilled(d, {rp.x - 6, rp.y}, {rp.x + inner + 6, rp.y + h}, col32(pr.color, hovered ? 0.2 : 0.12), 8)
		} else if hovered {
			im.DrawList_AddRectFilled(d, {rp.x - 6, rp.y}, {rp.x + inner + 6, rp.y + h}, col32(C_OVERLAY, 0.05), 8)
		}
		if hovered {
			im.SetMouseCursor(.Hand)
			tip(active ? fmt.tprintf("Bring all monitors back to %s\nRight click: gather windows into it for a minute", pr.name) : fmt.tprintf("Open %s's workspaces on all monitors\nRight click: gather windows into it for a minute", pr.name))
		}
		// Also for the active project: re-syncs every monitor (e.g. one wandered off).
		if clicked {start = i}
		// Right click: gather windows into this project for a minute.
		if hovered && im.IsMouseClicked(.Right) {tracker_pin(i)}
		im.DrawList_AddCircleFilled(d, {rp.x + 6, rp.y + h / 2}, 5, col32(pr.color, active ? 1 : 0.7))
		draw_text(active ? fonts.bold : fonts.ui, SZ_BODY, {rp.x + 20, rp.y + 8}, col32(C_TEXT), pr.name)
		if pr.client != "" {
			nsz := measure(active ? fonts.bold : fonts.ui, SZ_BODY, pr.name)
			draw_text(fonts.ui, SZ_SMALL, {rp.x + 28 + nsz.x, rp.y + 10}, col32(C_FAINT), pr.client)
		}
		tt := fmt_duration(totals_today[pr.name])
		tsz := measure(fonts.mono, SZ_BODY, tt)
		draw_text(fonts.mono, SZ_BODY, {rp.x + inner - tsz.x - 26 - PENCIL_W, rp.y + 8}, col32(totals_today[pr.name] > 0 ? C_TEXT : C_FAINT), tt)
		icon := active ? ICON_MONITORS : ICON_PLAY
		draw_text(fonts.ui, 15, {rp.x + inner - 16 - PENCIL_W, rp.y + 8}, col32(hovered || active ? pr.color : C_FAINT, active && !hovered ? 0.6 : 1), icon)
		if editing && draw_rename_editor(pr, inner) {rename_go = true}
	}
	// Applied after the list: a merge removes a project from it.
	if rename_go {rename_apply()}
	draw_rename_result(inner)
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
			label(fonts.ui, SZ_SMALL, col32(C_FAINT), fmt.tprintf("No breaks yet (a break = no input for %s)", fmt_idle(tracker.idle)))
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
	im.DrawList_AddRectFilled(d, gp, {gp.x + inner, gp.y + gh}, col32(C_WELL), 8)
	for hgrid := i64(2); hgrid < hours; hgrid += 2 {
		y := gp.y + gh - gh * f32(hgrid) / f32(hours)
		im.DrawList_AddLine(d, {gp.x + 4, y}, {gp.x + inner - 4, y}, col32(C_OVERLAY, 0.04))
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

// Visible part of today's timeline, in seconds since midnight.
@(private = "file")
TL_MIN_SPAN :: 15 * 60
@(private = "file")
tl := struct {
	start, span: f64,
}{0, 86400}

@(private = "file")
tl_clamp_view :: proc() {
	tl.span = clamp(tl.span, TL_MIN_SPAN, 86400)
	tl.start = clamp(tl.start, 0, 86400 - tl.span)
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

	// Zoom & pan: scroll zooms around the pointer, drag pans, double-click resets.
	tl_clamp_view()
	im.InvisibleButton("##timeline", {inner, bh + 14})
	tl_hovered := im.IsItemHovered()
	im.SetItemKeyOwner(.MouseWheelY) // the wheel zooms instead of scrolling the panel
	im.SetItemKeyOwner(.MouseWheelX) // the horizontal wheel pans
	if tl_hovered {
		wheel := im.GetIO().MouseWheel
		if wheel != 0 {
			frac := f64(clamp((im.GetMousePos().x - p.x) / inner, 0, 1))
			anchor := tl.start + frac * tl.span
			tl.span = clamp(tl.span * (wheel > 0 ? 0.8 : 1.25), TL_MIN_SPAN, 86400)
			tl.start = anchor - frac * tl.span
			tl_clamp_view()
		} else if wh := im.GetIO().MouseWheelH; wh != 0 {
			// A notch pans a tenth of the view (>0 = left, earlier).
			tl.start -= f64(wh) * 0.1 * tl.span
			tl_clamp_view()
		}
		if im.IsMouseDoubleClicked(.Left) {tl.start, tl.span = 0, 86400}
		if tl.span < 86400 {im.SetMouseCursor(.ResizeEW)}
	}
	if im.IsItemActive() && im.IsMouseDragging(.Left, 1) {
		dx := im.GetIO().MouseDelta.x
		tl.start -= f64(dx / inner) * tl.span
		tl_clamp_view()
	}
	im.SetCursorScreenPos(p)

	view_from := f64(day_start) + tl.start
	view_span := tl.span
	x_of :: proc(t: i64, from, span: f64, x0, w: f32) -> f32 {
		return x0 + w * f32((f64(t) - from) / span)
	}
	im.DrawList_AddRectFilled(d, p, {p.x + inner, p.y + bh}, col32(C_WELL), 6)

	// Ticks: pick a step giving roughly 6-12 labels at this zoom.
	steps := [?]f64{300, 600, 900, 1800, 3600, 7200, 10800, 21600}
	step := steps[len(steps) - 1]
	for st in steps {
		if view_span / st <= 12 {
			step = st
			break
		}
	}
	minor := step / (step >= 3600 ? 3 : 5)
	im.DrawList_PushClipRect(d, p, {p.x + inner, p.y + bh}, true)
	for t := math.floor(tl.start / minor) * minor; t <= tl.start + view_span; t += minor {
		x := x_of(i64(f64(day_start) + t), view_from, view_span, p.x, inner)
		major := math.mod(t, step) < 1
		im.DrawList_AddLine(d, {x, p.y + 3}, {x, p.y + bh - 3}, col32(C_OVERLAY, major ? 0.10 : 0.035))
	}
	hovered_seg := -1
	mouse := im.GetMousePos()
	for sg, i in segs {
		x0 := x_of(sg.s, view_from, view_span, p.x, inner)
		x1 := max(x_of(sg.e, view_from, view_span, p.x, inner), x0 + 1)
		if x1 < p.x || x0 > p.x + inner {continue}
		col, is_project := color_of(sg.project)
		c: u32
		switch {
		case !sg.idle:     c = col32(col)
		case is_project:   c = col32(col, 0.22) // a break during a project session
		case:              c = col32(C_MUTED, 0.45) // a break outside projects
		}
		im.DrawList_AddRectFilled(d, {x0, p.y + 2}, {x1, p.y + bh - 2}, c, 2)
		if mouse.x >= x0 && mouse.x < x1 && mouse.y >= p.y && mouse.y < p.y + bh {hovered_seg = i}
	}
	// "Now" marker.
	nx := x_of(now, view_from, view_span, p.x, inner)
	im.DrawList_AddLine(d, {nx, p.y}, {nx, p.y + bh}, col32(C_TEXT, 0.9), 1.5)
	im.DrawList_PopClipRect(d)
	im.Dummy({inner, bh})

	// Tick labels.
	lp := im.GetCursorScreenPos()
	for t := math.ceil(tl.start / step) * step; t <= tl.start + view_span + 1; t += step {
		secs := int(t)
		lbl := step >= 3600 ? fmt.tprintf("%02d", secs / 3600) : fmt.tprintf("%02d:%02d", secs / 3600, (secs / 60) % 60)
		if secs >= 86400 {lbl = step >= 3600 ? "24" : "24:00"}
		lsz := measure(fonts.ui, 10.5, lbl)
		x := x_of(i64(f64(day_start) + t), view_from, view_span, p.x, inner) - lsz.x / 2
		x = clamp(x, p.x, p.x + inner - lsz.x)
		draw_text(fonts.ui, 10.5, {x, lp.y}, col32(C_FAINT), lbl)
	}
	if tl.span < 86400 {
		hint := "double-click: whole day"
		hsz := measure(fonts.ui, 10, hint)
		draw_text(fonts.ui, 10, {p.x + inner - hsz.x, p.y - 15}, col32(C_FAINT), hint)
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

// ---- Renaming a project -------------------------------------------------------

@(private = "file")
Ren :: struct {
	key:        string, // project being renamed ("" = none)
	old:        string,
	color:      u32,
	buf:        [128]u8,
	focus:      bool,
	workspaces: bool,
	armed:      bool, // a merge: the first click arms, the second applies
	// The preview, for this text and workspace choice.
	plan_text:  string,
	plan_ws:    bool,
	plan_at:    time.Tick,
	err:        string,
	head:       string,
	details:    [dynamic]string,
	merge:      bool,
	new_name:   string, // as it will be (an existing project's spelling when merging)
	ws_n:       int,
	result:     string,
	result_ok:  bool,
}
@(private = "file")
ren: Ren

@(private = "file")
rename_text :: proc() -> string {return strings.trim_space(string(cstring(&ren.buf[0])))}

@(private = "file")
rename_clear_plan :: proc() {
	delete(ren.plan_text)
	delete(ren.err)
	delete(ren.head)
	delete(ren.new_name)
	ren.new_name = ""
	for l in ren.details {delete(l)}
	clear(&ren.details)
	ren.plan_text, ren.err, ren.head = "", "", ""
}

@(private = "file")
rename_open :: proc(pr: Project) {
	rename_close()
	ren.key = strings.clone(pr.key)
	ren.old = strings.clone(pr.name)
	ren.color = pr.color
	ren.buf = {}
	copy(ren.buf[:len(ren.buf) - 1], pr.name)
	ren.focus = true
	ren.armed = false
	// The workspaces still carry the old name: renaming them is what keeps
	// the project counting, so it's on unless you turn it off.
	ren.workspaces = true
	delete(ren.result)
	ren.result = ""
}

@(private = "file")
rename_close :: proc() {
	delete(ren.key)
	delete(ren.old)
	ren.key, ren.old = "", ""
	rename_clear_plan()
}

// Escape while renaming cancels the rename instead of closing the panel.
time_rename_escape :: proc() -> bool {
	if ren.key == "" {return false}
	rename_close()
	request_redraw()
	return true
}

@(private = "file")
rename_refresh_plan :: proc() {
	text := rename_text()
	if ren.plan_text == text && ren.plan_ws == ren.workspaces && (ren.head != "" || ren.err != "") && time.tick_since(ren.plan_at) < 3 * time.Second {return}
	if ren.plan_text != text {ren.armed = false}
	rename_clear_plan()
	ren.plan_text = strings.clone(text)
	ren.plan_ws = ren.workspaces
	ren.plan_at = time.tick_now()
	if text == ren.old {
		ren.err = strings.clone("Type the new name")
		return
	}
	p := rename_plan(ren.old, text)
	ren.merge = p.merge
	ren.new_name = strings.clone(p.new)
	ren.ws_n = len(p.ws_moves)
	if p.err != "" {
		ren.err = strings.clone(p.err)
		return
	}
	ren.head = strings.clone(rename_headline(p))
	for l in rename_details(p, {workspaces = ren.workspaces}) {append(&ren.details, strings.clone(l))}
}

@(private = "file")
rename_apply :: proc() {
	text := strings.clone(rename_text(), context.temp_allocator)
	report, ok := tracker_rename(ren.old, text, {merge = ren.merge, workspaces = ren.workspaces}, true)
	rename_close()
	delete(ren.result)
	r, _ := strings.replace_all(strings.trim_space(report), "\n  ", "\n·  ", context.temp_allocator)
	ren.result = strings.clone(r)
	ren.result_ok = ok
	request_redraw()
}

@(private = "file")
wrapped :: proc(font: ^im.Font, size: f32, col: u32, s: string, width: f32) {
	im.PushFontFloat(font, size)
	im.PushStyleColor(.Text, col)
	im.PushTextWrapPos(im.GetCursorPosX() + width)
	b, e := str_range(s)
	im.TextUnformatted(b, e)
	im.PopTextWrapPos()
	im.PopStyleColor()
	im.PopFont()
}

// Under the project's row: the new name, what will change, confirm. Returns
// true when the rename should be applied.
@(private = "file")
draw_rename_editor :: proc(pr: Project, inner: f32) -> bool {
	PAD :: f32(12)
	top := im.GetCursorScreenPos()
	w := inner - 2 * PAD
	im.SetCursorScreenPos({top.x + PAD, top.y + 10})
	im.BeginGroup()
	label(fonts.bold, SZ_SMALL, col32(C_MUTED), fmt.tprintf("Rename %s to", pr.name))
	im.Dummy({1, 2})

	fp := im.GetCursorScreenPos()
	fe := fp + Vec2{w, SZ_BODY + 16}
	field_fill(fp, fe, 8, col32(C_BG))
	im.PushFontFloat(fonts.ui, SZ_BODY)
	im.PushStyleVarImVec2(.FramePadding, {10, 8})
	im.PushStyleVar(.FrameBorderSize, 0)
	im.PushStyleColorImVec4(.FrameBg, {})
	im.PushStyleColorImVec4(.FrameBgHovered, {})
	im.PushStyleColorImVec4(.FrameBgActive, {})
	if ren.focus {
		im.SetKeyboardFocusHere()
		ren.focus = false
	}
	im.SetNextItemWidth(w)
	entered := im.InputTextWithHint("##rename", "New name", cstring(&ren.buf[0]), uint(len(ren.buf)), {.EnterReturnsTrue, .AutoSelectAll})
	active := im.IsItemActive()
	if active {im.SetNavCursorVisible(false)}
	im.PopStyleVar(2)
	im.PopStyleColor(3)
	im.PopFont()
	field_outline(fp, fe, 8, active ? col32(pr.color, 0.85) : col32(C_BORDER))
	if entered {ren.focus = true} // keep typing after a refused Enter

	rename_refresh_plan()
	im.Dummy({1, 4})
	go := false
	if ren.err != "" {
		wrapped(fonts.ui, SZ_SMALL, col32(ren.err == "Type the new name" ? C_FAINT : C_RED), ren.err, w)
	} else {
		wrapped(fonts.bold, SZ_SMALL + 1, col32(ren.merge ? C_ORANGE : C_TEXT), ren.head, w)
		for l in ren.details {wrapped(fonts.ui, SZ_SMALL, col32(C_MUTED), fmt.tprintf("·  %s", l), w)}
	}
	if ren.ws_n > 0 {
		im.Dummy({1, 4})
		tp := im.GetCursorScreenPos()
		if toggle_switch("##renws", ren.workspaces, pr.color) {ren.workspaces = !ren.workspaces}
		draw_text(fonts.ui, SZ_SMALL, {tp.x + 48, tp.y + 3}, col32(ren.workspaces ? C_TEXT : C_MUTED), "Also rename its sway workspaces")
		if !ren.workspaces {
			wrapped(fonts.ui, SZ_SMALL, col32(C_ORANGE), fmt.tprintf("Off: workspaces named \"%s N\" stop counting as time for the project until you reopen it from this list.", pr.name), w)
		}
	}
	im.Dummy({1, 6})
	if ren.err == "" {
		lbl := ren.merge ? (ren.armed ? "Click again to merge" : fmt.tprintf("Merge into %s", ren.new_name)) : "Rename"
		accent := ren.merge ? C_ORANGE : pr.color
		if pill_button("##rename-go", lbl, accent, true) || (entered && !ren.merge) {
			if ren.merge && !ren.armed {ren.armed = true} else {go = true}
		}
		im.SameLine(0, 8)
	}
	if pill_button("##rename-cancel", "Cancel", C_MUTED) {rename_close()}
	if !go && ren.key != "" {
		im.SameLine(0, 12)
		hp := im.GetCursorScreenPos()
		draw_text(fonts.ui, 11, {hp.x, hp.y + 8}, col32(C_FAINT), "Backups of the log and config are kept")
		im.NewLine()
	}
	im.EndGroup()
	bot := im.GetItemRectMax().y + 10
	field_outline({top.x, top.y + 2}, {top.x + inner, bot}, 10, col32(pr.color, 0.45))
	im.SetCursorScreenPos({top.x, bot + 6})
	im.Dummy({inner, 1})
	return go
}

// The outcome of the last rename, until dismissed.
@(private = "file")
draw_rename_result :: proc(inner: f32) {
	if ren.result == "" {return}
	top := im.GetCursorScreenPos()
	col: u32 = ren.result_ok ? C_GREEN : C_RED
	im.SetCursorScreenPos({top.x + 34, top.y + 8})
	im.BeginGroup()
	wrapped(fonts.ui, SZ_SMALL, col32(C_TEXT), ren.result, inner - 70)
	im.EndGroup()
	bot := im.GetItemRectMax().y + 8
	im.DrawList_AddRectFilled(dl(), top, {top.x + inner, bot}, col32(col, 0.10), 9)
	draw_text(fonts.ui, 16, {top.x + 10, top.y + 8}, col32(col), ren.result_ok ? ICON_CHECK_CIRCLE : ICON_ALERT)
	im.SetCursorScreenPos({top.x + inner - 30, top.y + 2})
	if icon_button("##rename-result-close", ICON_CLOSE, C_MUTED, 28, tooltip = "Dismiss") {
		delete(ren.result)
		ren.result = ""
	}
	im.SetCursorScreenPos({top.x, bot + 6})
	im.Dummy({inner, 1})
}
