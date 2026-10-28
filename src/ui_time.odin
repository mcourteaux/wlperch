// Time tracker module.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
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
	shown := -1 // the project Claude counts for, when the status shows it
	if tracker.running >= 0 {
		pr := tracker.projects[tracker.running]
		im.DrawList_AddCircleFilled(dl(), {p.x + 7, p.y + 16}, 6, col32(pr.color))
		draw_text(fonts.bold, 22, {p.x + 22, p.y + 2}, col32(C_TEXT), pr.name)
		sub := pr.client != "" ? pr.client : "personal"
		line := fmt.tprintf("%s   ·   today %s", sub, fmt_duration(totals_today[pr.name]))
		if pr.paying && pr.rate > 0 {line = fmt.tprintf("%s   ·   %s", line, fmt_money(f64(totals_today[pr.name]) / 3600 * pr.rate))}
		draw_text(fonts.ui, SZ_SMALL, {p.x + 22, p.y + 30}, col32(C_MUTED), line)
		// Since the stretch began: after a bridged break that includes the gap.
		el := fmt_duration(now - tracker_stretch_start(tracker_view(now)), true)
		esz := measure(fonts.mono, 24, el)
		draw_text(fonts.mono, 24, {p.x + inner - esz.x, p.y + 4}, col32(pr.color), el)
		cap := "counting"
		csz := measure(fonts.ui, SZ_SMALL, cap)
		draw_text(fonts.ui, SZ_SMALL, {p.x + inner - csz.x, p.y + 32}, col32(C_GREEN), cap)
	} else if left, waiting := tracker_waiting(now); waiting {
		// Away from a project that bridges short breaks: not counting (yet).
		// Back on it within the window and the gap is added at once.
		pi := project_find(tracker.away_project)
		col: u32 = pi >= 0 ? tracker.projects[pi].color : C_TEAL
		im.DrawList_AddCircle(dl(), {p.x + 7, p.y + 16}, 6, col32(col, 0.8), 0, 1.5)
		draw_text(fonts.bold, 22, {p.x + 22, p.y + 2}, col32(C_MUTED), tracker.away_project)
		limit := bridge_limit(bridge_rules(), tracker.away_project)
		draw_text(fonts.ui, SZ_SMALL, {p.x + 22, p.y + 30}, col32(C_FAINT), fmt.tprintf("back within %s and the wait counts as work (breaks < %d min)", fmt_duration(left, true), limit / 60))
		el := fmt_duration(now - tracker.away_start, true)
		esz := measure(fonts.mono, 24, el)
		draw_text(fonts.mono, 24, {p.x + inner - esz.x, p.y + 4}, col32(col, 0.45), el)
		cap := "waiting…"
		csz := measure(fonts.ui, SZ_SMALL, cap)
		draw_text(fonts.ui, SZ_SMALL, {p.x + inner - csz.x, p.y + 32}, col32(C_MUTED), cap)
		request_redraw(1) // the countdown
	} else if ci := claude_counting_project(); ci >= 0 {
		// Nothing of yours counts, but Claude's work on a project does.
		pr := tracker.projects[ci]
		shown = ci
		im.DrawList_AddCircleFilled(dl(), {p.x + 7, p.y + 16}, 6, col32(pr.color))
		draw_text(fonts.bold, 22, {p.x + 22, p.y + 2}, col32(C_TEXT), pr.name)
		nsz := measure(fonts.bold, 22, pr.name)
		draw_text(fonts.ui, 15, {p.x + 30 + nsz.x, p.y + 7}, col32(pr.color), ICON_CLAUDE)
		line := fmt.tprintf("Claude is working on it   ·   today %s", fmt_duration(totals_today[pr.name]))
		if pr.paying && pr.rate > 0 {line = fmt.tprintf("%s   ·   %s", line, fmt_money(f64(totals_today[pr.name]) / 3600 * pr.rate))}
		draw_text(fonts.ui, SZ_SMALL, {p.x + 22, p.y + 30}, col32(C_MUTED), line)
		el := fmt_duration(now - claude_since(pr.name), true)
		esz := measure(fonts.mono, 24, el)
		draw_text(fonts.mono, 24, {p.x + inner - esz.x, p.y + 4}, col32(pr.color), el)
		cap := "counting · Claude"
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

	// Claude working on projects that count it (also while you're elsewhere),
	// except the one the status above already shows.
	for c in tracker.claude_segs {
		pi := project_find(c.project)
		if pi < 0 || !tracker.projects[pi].claude || pi == shown {continue}
		pr := tracker.projects[pi]
		cp := im.GetCursorScreenPos()
		draw_text(fonts.ui, 14, {cp.x + 1, cp.y + 3}, col32(pr.color), ICON_CLAUDE)
		draw_text(fonts.ui, SZ_SMALL, {cp.x + 22, cp.y + 3}, col32(C_TEXT), fmt.tprintf("Claude is working on %s", pr.name))
		el := fmt_duration(now - c.start, true)
		esz := measure(fonts.mono, SZ_SMALL + 1, el)
		draw_text(fonts.mono, SZ_SMALL + 1, {cp.x + inner - esz.x, cp.y + 2}, col32(pr.color), el)
		cap := "counts"
		draw_text(fonts.ui, SZ_SMALL, {cp.x + inner - esz.x - measure(fonts.ui, SZ_SMALL, cap).x - 10, cp.y + 3}, col32(C_GREEN), cap)
		im.Dummy({inner, 22})
	}

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
			tip(fmt.tprintf("Edit %s: count its short breaks as work,\npaying and its rate, Claude's background work,\nor rename it (time log, config.ini section\nand, if you like, its sway workspaces)", pr.name))
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
		by_claude := !active && pr.claude && tracker_claude_active(pr.name) // counting, by Claude
		if active {
			im.DrawList_AddRectFilled(d, {rp.x - 6, rp.y}, {rp.x + inner + 6, rp.y + h}, col32(pr.color, hovered ? 0.2 : 0.12), 8)
		} else if by_claude {
			im.DrawList_AddRectFilled(d, {rp.x - 6, rp.y}, {rp.x + inner + 6, rp.y + h}, col32(pr.color, hovered ? 0.12 : 0.06), 8)
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
		{
			nx := rp.x + 28 + measure(active ? fonts.bold : fonts.ui, SZ_BODY, pr.name).x
			if pr.client != "" {
				draw_text(fonts.ui, SZ_SMALL, {nx, rp.y + 10}, col32(C_FAINT), pr.client)
				nx += measure(fonts.ui, SZ_SMALL, pr.client).x + 8
			}
			// A paid job, and Claude's work counting (bright while it works).
			mark :: proc(x, y: f32, icon: string, col: u32, alpha: f32, tooltip: string) -> f32 {
				sz := measure(fonts.ui, 14, icon)
				draw_text(fonts.ui, 14, {x, y}, col32(col, alpha), icon)
				if im.IsMouseHoveringRect({x - 2, y - 2}, {x + sz.x + 2, y + sz.y + 2}) {tip(tooltip)}
				return x + sz.x + 8
			}
			if pr.paying {
				t := pr.rate > 0 ? fmt.tprintf("Paying job: %s/h\n%s today", fmt_money(pr.rate), fmt_money(f64(totals_today[pr.name]) / 3600 * pr.rate)) : "Paying job (no rate set: the pencil sets one)"
				nx = mark(nx, rp.y + 9, ICON_PAYING, C_GREEN, 0.9, t)
			}
			if pr.claude {
				working := tracker_claude_active(pr.name)
				t := working ? fmt.tprintf("Claude is working on %s: it counts", pr.name) : fmt.tprintf("Claude's background work on %s counts as work", pr.name)
				nx = mark(nx, rp.y + 9, ICON_CLAUDE, working ? pr.color : C_FAINT, working ? 1 : 0.8, t)
			}
			// Bridging on: say so on the row, so it isn't a hidden rule.
			if b := project_bridge(pr); b > 0 {
				bt := fmt.tprintf("breaks < %d min count", b)
				draw_text(fonts.ui, SZ_SMALL, {nx, rp.y + 10}, col32(pr.color, 0.75), bt)
				nx += measure(fonts.ui, SZ_SMALL, bt).x + 12
			}
			tt := fmt_duration(totals_today[pr.name])
			tx := rp.x + inner - measure(fonts.mono, SZ_BODY, tt).x - 26 - PENCIL_W
			// Left of today's total, where there's room.
			if by_claude {
				cap := "counting · Claude"
				csz := measure(fonts.ui, SZ_SMALL, cap)
				if nx + csz.x + 12 < tx {draw_text(fonts.ui, SZ_SMALL, {tx - csz.x - 12, rp.y + 10}, col32(C_GREEN), cap)}
			}
		}
		tt := fmt_duration(totals_today[pr.name])
		tsz := measure(fonts.mono, SZ_BODY, tt)
		draw_text(fonts.mono, SZ_BODY, {rp.x + inner - tsz.x - 26 - PENCIL_W, rp.y + 8}, col32(by_claude ? pr.color : totals_today[pr.name] > 0 ? C_TEXT : C_FAINT), tt)
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
		any_bridged := false
		for _, b in breaks_week {any_bridged ||= b.bridged > 0}
		if n_week == 0 && !tracker.away && !any_bridged {
			label(fonts.ui, SZ_SMALL, col32(C_FAINT), fmt.tprintf("No breaks yet (a break = no input for %s)", fmt_idle(tracker.idle)))
		}
		row :: proc(name, client: string, color: u32, bt, bw: Break_Stats, work_week: i64, inner: f32) {
			rp := im.GetCursorScreenPos()
			h: f32 = 30
			im.DrawList_AddCircleFilled(dl(), {rp.x + 6, rp.y + h / 2}, 4, col32(color, 0.8))
			draw_text(fonts.ui, SZ_BODY, {rp.x + 18, rp.y + 6}, col32(C_TEXT), name)
			counts := fmt.tprintf("%d× today  ·  %d× this week", bt.count, bw.count)
			if bw.bridged > 0 {counts = fmt.tprintf("%s  ·  %d short, counted as work", counts, bw.bridged)}
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
			if left, waiting := tracker_waiting(now); waiting {
				label(fonts.ui, SZ_SMALL, col32(C_MUTED), fmt.tprintf("Away right now since %s: counts as work if you're back on %s within %s", fmt_duration(now - tracker.away_start), tracker.away_project, fmt_duration(left, true)))
			} else {
				label(fonts.ui, SZ_SMALL, col32(C_ORANGE), fmt.tprintf("Away right now since %s", fmt_duration(now - tracker.away_start)))
			}
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

	draw_export(now, inner)
}

// ---- Export (CSV of the hours, e.g. for a monthly invoice) ----------------

@(private = "file")
Exp :: struct {
	project: int, // -1 = all projects
	range:   int, // EXPORT_RANGES
	group:   Export_Group,
	breaks:  bool,
	from:    [16]u8, // custom range, YYYY-MM-DD
	to:      [16]u8,
	inited:  bool,
	result:  string,
	path:    string,
	ok:      bool,
	bridge:  int, // minutes for this export; -1 = as configured (bridge_breaks)
	frac:    f32, // its slider
	// The preview (with and without bridging), recomputed when its inputs change.
	pv_key:  Preview_Key,
	pv:      Export_Summary,
}
@(private = "file")
Preview_Key :: struct {
	n, running, project, bridge, gen: int,
	seg_start, away_start, from, to, minute, claude: i64,
	away, valid: bool,
}
@(private = "file")
exp := Exp{project = -1, bridge = -1}

// The rules this export uses: the slider's value for every project, or config.ini's.
@(private = "file")
export_rules :: proc() -> Bridge_Rules {
	return exp.bridge >= 0 ? bridge_rules_override(exp.bridge) : bridge_rules()
}

// Worked time in the export's range with and without bridging, from the log
// in memory. Only recomputed when the range, project, bridge value or log
// changes (and once a minute for the running segment), not every frame.
@(private = "file")
export_preview :: proc(project: string, from, to, now: i64) -> Export_Summary {
	rules := export_rules()
	claude_key := i64(len(tracker.claude_segs))
	for c in tracker.claude_segs {claude_key = claude_key * 31 + c.start}
	key := Preview_Key{len(tracker.entries), tracker.running, exp.project, exp.bridge, rules.gen, tracker.seg_start, tracker.away_start, from, to, now / 60, claude_key, tracker.away, true}
	if key != exp.pv_key {
		entries := make([dynamic]Export_Entry, 0, len(tracker.entries) + 2 + len(tracker.claude_segs), context.temp_allocator)
		for e in tracker.entries {append(&entries, Export_Entry{e.start, e.end, e.project, "", e.idle, false, e.claude})}
		if tracker.running >= 0 {append(&entries, Export_Entry{tracker.seg_start, now, tracker.projects[tracker.running].name, "", false, false, false})}
		if tracker.away {append(&entries, Export_Entry{tracker.away_start, now, tracker.away_project, "", true, false, false})}
		for c in tracker.claude_segs {append(&entries, Export_Entry{c.start, max(now, c.last), c.project, "", false, false, true})}
		exp.pv = export_bridge_summary(entries[:], {project = project, from = from, to = to > 0 ? to : now + 1, bridge = rules})
		exp.pv_key = key
	}
	return exp.pv
}

// The bridge-gap control: a slider (0–120 min) and − / + for this export,
// starting at the configured value; "as configured" goes back to that, and
// with one project picked "Save for <project>" makes it its bridge_breaks.
@(private = "file")
// The first project (in list order) Claude is working on that counts it; -1 if none.
claude_counting_project :: proc() -> int {
	for pr, i in tracker.projects {if pr.claude && tracker_claude_active(pr.name) {return i}}
	return -1
}

// When Claude's current stretch on `name` began (the earliest open one).
claude_since :: proc(name: string) -> i64 {
	since: i64 = max(i64)
	for c in tracker.claude_segs {if c.project == name {since = min(since, c.start)}}
	return since
}

draw_export_bridge :: proc(inner: f32) {
	configured := exp.project >= 0 ? project_bridge(tracker.projects[exp.project]) : tracker.bridge_default
	minutes := exp.bridge >= 0 ? exp.bridge : configured
	MAXM :: f32(LIM_BRIDGE_BREAKS.hi)
	bp := im.GetCursorScreenPos()
	lbl := "Count breaks shorter than"
	draw_text(fonts.ui, SZ_SMALL, {bp.x, bp.y + 6}, col32(C_MUTED), lbl)
	if im.IsMouseHoveringRect(bp, {bp.x + measure(fonts.ui, SZ_SMALL, lbl).x, bp.y + 24}) {
		tip("Breaks shorter than this, between two stretches of work on the same project,\ncount as work (bridge_breaks). Changing it here only affects this export\nand the preview below, until you save it for the project.")
	}
	x := bp.x + measure(fonts.ui, SZ_SMALL, lbl).x + 12
	sw := clamp(inner * 0.3, 110, 200)
	im.SetCursorScreenPos({x, bp.y + 2})
	exp.frac = f32(minutes) / MAXM
	if slider("##exp-bridge", &exp.frac, 1, C_TEAL, sw) {
		exp.bridge = clamp(int(exp.frac * MAXM + 0.5), 0, int(MAXM))
	}
	x += sw + 10
	im.SetCursorScreenPos({x, bp.y})
	if pill_button("##exp-bridge-dec", "−", C_TEAL) {exp.bridge = max(minutes - 1, 0)}
	im.SameLine(0, 4)
	if pill_button("##exp-bridge-inc", "+", C_TEAL) {exp.bridge = min(minutes + 1, int(MAXM))}
	im.SameLine(0, 10)
	minutes = exp.bridge >= 0 ? exp.bridge : configured
	vp := im.GetCursorScreenPos()
	// All projects, nothing changed: each project's own value applies.
	val := exp.project < 0 && exp.bridge < 0 ? "as configured" : minutes == 0 ? "off" : fmt.tprintf("%d min", minutes)
	draw_text(fonts.bold, SZ_SMALL + 1, {vp.x, vp.y + 5}, col32(exp.bridge >= 0 ? C_TEAL : C_TEXT), val)
	im.SetCursorScreenPos(bp)
	im.Dummy({inner, 30})
	if exp.bridge >= 0 && exp.bridge != configured || (exp.project < 0 && exp.bridge >= 0) {
		// Changed for this export: keep it for the project, or go back.
		if exp.project >= 0 {
			pr := tracker.projects[exp.project]
			if pill_button("##exp-bridge-save", fmt.tprintf("Save %d min for %s", minutes, pr.name), C_TEAL) {
				if tracker_set_bridge(exp.project, exp.bridge) {exp.bridge = -1}
			}
			if im.IsItemHovered() {tip(fmt.tprintf("Write bridge_breaks = %d to [project.%s] in config.ini:\nthe panel, the bar and later exports count it too", minutes, pr.key))}
			im.SameLine(0, 10)
		}
		rp := im.GetCursorScreenPos()
		rl := exp.project < 0 ? "↺ as configured per project" : configured == 0 ? "↺ as configured (off)" : fmt.tprintf("↺ as configured (%d min)", configured)
		rsz := measure(fonts.ui, SZ_SMALL, rl)
		if im.InvisibleButton("##exp-bridge-reset", rsz + {0, 28 - rsz.y}) {exp.bridge = -1}
		hov := im.IsItemHovered()
		if hov {im.SetMouseCursor(.Hand)}
		draw_text(fonts.ui, SZ_SMALL, {rp.x, rp.y + 6}, col32(C_TEAL, hov ? 1 : 0.8), rl)
		if exp.project < 0 {
			im.SameLine(0, 10)
			hp := im.GetCursorScreenPos()
			draw_text(fonts.ui, SZ_SMALL, {hp.x, hp.y + 6}, col32(C_FAINT), "this export only, every project")
			im.NewLine()
		}
		im.Dummy({1, 2})
	}
}

@(private = "file")
EXPORT_RANGES := []string{"This month", "Last month", "Custom", "All time"}

@(private = "file")
EXPORT_GROUPS := []string{"Entries", "Per day", "Per project"}

// The chosen range: [from, to) (to 0 = no end), its display name and the
// file name part; ok false for an unfinished custom range.
@(private = "file")
export_range :: proc(now: i64) -> (from, to: i64, title, file_label: string, ok: bool) {
	switch exp.range {
	case 0, 1:
		f, t, lbl, mok := month_range(exp.range == 0 ? "this" : "last", now)
		if !mok {return}
		r, _ := clock_read(local_region, time.unix(f, 0))
		return f, t, fmt.tprintf("%s %d", MONTHS[r.dt.month - 1], r.dt.year), lbl, true
	case 2:
		fs := strings.trim_space(string(cstring(&exp.from[0])))
		ts := strings.trim_space(string(cstring(&exp.to[0])))
		f, fok := parse_local_date(fs)
		t, tok := parse_local_date(ts)
		if !fok || !tok || t < f {return}
		return f, local_day_start(t + 86400 + 7200), fmt.tprintf("%s to %s", fs, ts), fmt.tprintf("%s_%s", fs, ts), true
	}
	return 0, 0, "All time", "all-time", true
}

@(private = "file")
date_field :: proc(id, hint: string, buf: []u8, w: f32, valid: bool) {
	fp := im.GetCursorScreenPos()
	fe := fp + Vec2{w, SZ_BODY + 12}
	field_fill(fp, fe, 7, col32(C_BG))
	im.PushFontFloat(fonts.mono, SZ_BODY)
	im.PushStyleVarImVec2(.FramePadding, {8, 6})
	im.PushStyleVar(.FrameBorderSize, 0)
	im.PushStyleColorImVec4(.FrameBg, {})
	im.PushStyleColorImVec4(.FrameBgHovered, {})
	im.PushStyleColorImVec4(.FrameBgActive, {})
	im.SetNextItemWidth(w)
	im.InputTextWithHint(cstr(id), cstr(hint), cstring(&buf[0]), uint(len(buf)), {.CharsNoBlank})
	active := im.IsItemActive()
	im.PopStyleVar(2)
	im.PopStyleColor(3)
	im.PopFont()
	field_outline(fp, fe, 7, active ? col32(C_TEAL, 0.85) : valid ? col32(C_BORDER) : col32(C_RED, 0.7))
}

@(private = "file")
draw_export :: proc(now: i64, inner: f32) {
	if !exp.inited {
		// Custom range: this month so far.
		f, _, _, _ := month_range("this", now)
		copy(exp.from[:15], fmt.tprintf("%s", export_date(f)))
		copy(exp.to[:15], fmt.tprintf("%s", export_date(now)))
		exp.inited = true
	}
	sub_heading("Export hours")

	// Project and range.
	{
		names := make([]string, len(tracker.projects) + 1, context.temp_allocator)
		names[0] = "All projects"
		for pr, i in tracker.projects {names[i + 1] = pr.name}
		if exp.project >= len(tracker.projects) {exp.project = -1}
		cw := inner * 0.36
		im.SetNextItemWidth(cw)
		im.PushStyleVarImVec2(.FramePadding, {10, 5})
		if im.BeginCombo("##exp-project", cstr(names[exp.project + 1]), {.HeightLarge}) {
			for n, i in names {
				if im.Selectable(cstr(fmt.tprintf("%s##exp%d", n, i)), i - 1 == exp.project) {exp.project = i - 1}
			}
			im.EndCombo()
		}
		im.PopStyleVar()
		im.SameLine(0, 10)
		if k := segmented("##exp-range", EXPORT_RANGES, exp.range, C_TEAL); k >= 0 {exp.range = k}
	}
	from, to, title, file_label, range_ok := export_range(now)
	if exp.range == 2 {
		fw: f32 = 120
		fs := strings.trim_space(string(cstring(&exp.from[0])))
		ts := strings.trim_space(string(cstring(&exp.to[0])))
		_, fok := parse_local_date(fs)
		_, tok := parse_local_date(ts)
		date_field("##exp-from", "YYYY-MM-DD", exp.from[:], fw, fok)
		im.SameLine(0, 8)
		lp := im.GetCursorScreenPos()
		draw_text(fonts.ui, SZ_SMALL, {lp.x, lp.y + 6}, col32(C_MUTED), "to")
		im.Dummy({16, 1})
		im.SameLine(0, 8)
		date_field("##exp-to", "YYYY-MM-DD", exp.to[:], fw, tok)
		im.SameLine(0, 10)
		lp = im.GetCursorScreenPos()
		draw_text(fonts.ui, SZ_SMALL, {lp.x, lp.y + 6}, col32(C_FAINT), "both days included")
		im.Dummy({1, SZ_BODY + 12})
	}

	// Rows and breaks.
	if k := segmented("##exp-group", EXPORT_GROUPS, int(exp.group), C_TEAL); k >= 0 {exp.group = Export_Group(k)}
	im.SameLine(0, 16)
	{
		bp := im.GetCursorScreenPos()
		if toggle_switch("##exp-breaks", exp.breaks, C_TEAL) {exp.breaks = !exp.breaks}
		if im.IsItemHovered() {tip("Also the time away from the keyboard, as rows with type \"break\";\nper entry, short breaks counted as work get type \"bridged\"\n(they're in the worked hours either way)")}
		draw_text(fonts.ui, SZ_SMALL, {bp.x + 48, bp.y + 4}, col32(exp.breaks ? C_TEAL : C_MUTED), "Include breaks")
		im.SetCursorScreenPos(bp)
		im.Dummy({140, 26})
	}

	draw_export_bridge(inner)

	// What it covers, from the log in memory: with and without bridging.
	project := exp.project >= 0 ? tracker.projects[exp.project].name : ""
	if range_ok {
		pv := export_preview(project, from, to, now)
		who := project != "" ? project : "all projects"
		label(fonts.ui, SZ_SMALL + 1, col32(C_TEXT), fmt.tprintf("%s  ·  %s  ·  %s  (%.2f h)", title, who, fmt_bridge_summary(pv.without, pv.with, pv.gaps), f64(pv.with) / 3600))
		if extra := fmt_summary_extra(pv); extra != "" {label(fonts.ui, SZ_SMALL, col32(C_MUTED), extra)}
	} else {
		label(fonts.ui, SZ_SMALL + 1, col32(C_RED), "Enter both days as YYYY-MM-DD (from before to)")
	}

	dir := export_dir()
	name := export_file_name(project, file_label)
	if pill_button("##exp-go", "Export CSV", C_TEAL, true) && range_ok {
		entries: [dynamic]Export_Entry
		entries.allocator = context.temp_allocator
		export_collect(true, &entries)
		csv, work, rows := export_csv(entries[:], {project = project, from = from, to = to, group = exp.group, breaks = exp.breaks, bridge = export_rules()}, context.temp_allocator)
		path := fmt.tprintf("%s/%s", dir, name)
		delete(exp.result)
		delete(exp.path)
		if os.write_entire_file(path, csv) == nil {
			exp.ok = true
			exp.result = fmt.aprintf("Saved %d rows (%s h) to %s", rows, fmt_duration(work), home_short(path))
		} else {
			exp.ok = false
			exp.result = fmt.aprintf("Couldn't write %s", home_short(path))
		}
		exp.path = strings.clone(path)
	}
	im.SameLine(0, 10)
	np := im.GetCursorScreenPos()
	draw_text(fonts.mono, SZ_SMALL, {np.x, np.y + 7}, col32(C_FAINT), fmt.tprintf("%s/%s", home_short(dir), name))
	im.NewLine()
	if exp.result != "" {
		label(fonts.ui, SZ_SMALL, col32(exp.ok ? C_GREEN : C_RED), exp.result)
		if exp.ok {
			if pill_button("##exp-open", "Open folder", C_TEAL) {run_async({"xdg-open", dir})}
			im.SameLine(0, 8)
			if pill_button("##exp-copy", "Copy path", C_TEAL) {copy_to_clipboard(exp.path)}
		}
	}
	im.Dummy({1, 4})
}

@(private = "file")
export_date :: proc(t: i64) -> string {
	r, _ := clock_read(local_region, time.unix(t, 0))
	return fmt.tprintf("%04d-%02d-%02d", r.dt.year, r.dt.month, r.dt.day)
}

// "/home/me/Documents/x" -> "~/Documents/x"
@(private = "file")
home_short :: proc(p: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home != "" && strings.has_prefix(p, home) {return fmt.tprintf("~%s", p[len(home):])}
	return p
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

// Today as a 24 h timeline, one lane per project (Claude can work on one
// while you work on another): work in the project's color, breaks in a dim
// version of it, breaks outside projects in gray on a lane of their own;
// untracked time is the track. Short breaks counted as work (bridged) are
// hatched in the project's color, Claude's counted work is a lighter fill
// with a solid top edge.
@(private = "file")
draw_day_timeline :: proc(day_start, now: i64, inner: f32) {
	Seg :: struct {
		s, e:    i64,
		project: string,
		idle:    bool,
		bridged: bool,
		claude:  bool,
		lane:    int,
	}
	segs: [dynamic]Seg
	segs.allocator = context.temp_allocator
	day_end := day_start + 86400
	any_bridged, any_claude := false, false
	for e in tracker_view(now) {
		if e.end > day_start && e.start < day_end {
			append(&segs, Seg{e.start, e.end, e.project, e.idle, e.bridged, e.claude, 0})
			any_bridged ||= e.bridged
			any_claude ||= e.claude
		}
	}
	// Lanes: projects in config order, then names only the log knows, then
	// breaks outside projects.
	lanes: [dynamic]string
	lanes.allocator = context.temp_allocator
	lane_of :: proc(lanes: []string, name: string) -> int {
		for l, i in lanes {if l == name {return i}}
		return -1
	}
	for pr in tracker.projects {
		for sg in segs {
			if sg.project == pr.name {
				append(&lanes, pr.name)
				break
			}
		}
	}
	for sg in segs {
		if sg.project != NO_PROJECT && lane_of(lanes[:], sg.project) < 0 {append(&lanes, sg.project)}
	}
	for sg in segs {
		if sg.project == NO_PROJECT {
			append(&lanes, NO_PROJECT)
			break
		}
	}
	if len(lanes) == 0 {append(&lanes, "")}
	for &sg in segs {sg.lane = max(lane_of(lanes[:], sg.project), 0)}
	// Merge back-to-back pieces of the same kind (restarts split the log).
	for i in 1 ..< len(segs) {
		for j := i; j > 0 && segs[j].s < segs[j - 1].s; j -= 1 {segs[j], segs[j - 1] = segs[j - 1], segs[j]}
	}
	merged: [dynamic]Seg
	merged.allocator = context.temp_allocator
	for sg in segs {
		if n := len(merged); n > 0 {
			last := &merged[n - 1]
			if last.project == sg.project && last.idle == sg.idle && last.bridged == sg.bridged && last.claude == sg.claude && sg.s - last.e <= 90 {
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
	// One lane: as tall as it always was; more share a little more height.
	n_lanes := len(lanes)
	lane_h: f32 = n_lanes == 1 ? 18 : 13
	LANE_GAP :: f32(3)
	bh := 4 + f32(n_lanes) * lane_h + f32(n_lanes - 1) * LANE_GAP
	lane_y :: proc(top: f32, lane: int, lane_h: f32) -> f32 {return top + 2 + f32(lane) * (lane_h + LANE_GAP)}
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
	// Claude's pieces last: they sit on top of the breaks they overlap.
	for pass in 0 ..< 2 {
		for sg, i in segs {
			if sg.claude != (pass == 1) {continue}
			x0 := x_of(sg.s, view_from, view_span, p.x, inner)
			x1 := max(x_of(sg.e, view_from, view_span, p.x, inner), x0 + 1)
			if x1 < p.x || x0 > p.x + inner {continue}
			col, is_project := color_of(sg.project)
			y0 := lane_y(p.y, sg.lane, lane_h)
			y1 := y0 + lane_h
			if mouse.x >= x0 && mouse.x < x1 && mouse.y >= y0 - 1 && mouse.y < y1 + 1 {hovered_seg = i}
			c: u32
			switch {
			case sg.claude:
				// Counts as work, done by Claude in the background.
				im.DrawList_AddRectFilled(d, {x0, y0}, {x1, y1}, col32(col, 0.45), 2)
				im.DrawList_AddRectFilled(d, {x0, y0}, {x1, y0 + 3}, col32(col), 2)
				continue
			case sg.bridged:
				// Hatched: counts as work, but you weren't at the keyboard.
				im.DrawList_AddRectFilled(d, {x0, y0}, {x1, y1}, col32(col, 0.4), 2)
				im.DrawList_PushClipRect(d, {max(x0, p.x), y0}, {min(x1, p.x + inner), y1}, true)
				for hx := x0 - lane_h; hx < x1; hx += 6 {
					im.DrawList_AddLine(d, {hx, y1}, {hx + lane_h, y0}, col32(col, 0.9), 1.5)
				}
				im.DrawList_PopClipRect(d)
				continue
			case !sg.idle:     c = col32(col)
			case is_project:   c = col32(col, 0.22) // a break during a project session
			case:              c = col32(C_MUTED, 0.45) // a break outside projects
			}
			im.DrawList_AddRectFilled(d, {x0, y0}, {x1, y1}, c, 2)
		}
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
		items := [5]struct {
			col:   u32,
			alpha: f32,
			text:  string,
		}{{accent, 1, "working"}, {accent, 0.22, "break during a project"}, {0x8a92a3, 0.45, "break, no project"}, {accent, -1, "short break, counted as work"}, {accent, -2, "Claude, counted"}}
		for it in items {
			if it.alpha == -2 {
				// Only on days that have some.
				if !any_claude {continue}
				im.DrawList_AddRectFilled(dl(), {x, lg.y + 4}, {x + 10, lg.y + 12}, col32(it.col, 0.45), 2)
				im.DrawList_AddRectFilled(dl(), {x, lg.y + 4}, {x + 10, lg.y + 6}, col32(it.col), 1)
			} else if it.alpha < 0 {
				// Only on days that have one.
				if !any_bridged {continue}
				im.DrawList_AddRectFilled(dl(), {x, lg.y + 4}, {x + 10, lg.y + 12}, col32(it.col, 0.4), 2)
				im.DrawList_PushClipRect(dl(), {x, lg.y + 4}, {x + 10, lg.y + 12}, true)
				for hx := x - 8; hx < x + 10; hx += 4 {im.DrawList_AddLine(dl(), {hx, lg.y + 12}, {hx + 8, lg.y + 4}, col32(it.col, 0.9), 1)}
				im.DrawList_PopClipRect(dl())
			} else {
				im.DrawList_AddRectFilled(dl(), {x, lg.y + 4}, {x + 10, lg.y + 12}, col32(it.col, it.alpha), 2)
			}
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
		if sg.bridged {
			what = fmt.tprintf("%s: short break, counted as work\n(breaks under %d min bridge on %s)", sg.project, bridge_limit(bridge_rules(), sg.project) / 60, sg.project)
		}
		if sg.claude {what = fmt.tprintf("%s: Claude working, counted as work", sg.project)}
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
	rate:       [24]u8, // the hourly rate field
	rate_focus: bool,
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
	ren.rate = {}
	if pr.rate > 0 {copy(ren.rate[:len(ren.rate) - 1], fmt_rate(pr.rate))}
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

@(private = "file")
BRIDGE_PRESETS := [?]int{0, 2, 5, 10, 15, 30}
@(private = "file")
BRIDGE_LABELS := [?]string{"Off", "2 min", "5 min", "10 min", "15 min", "30 min"}

// Under the project's row: short breaks counted as work (applied at once),
// then the new name, what will change, confirm. Returns true when the rename
// should be applied.
@(private = "file")
draw_rename_editor :: proc(pr: Project, inner: f32) -> bool {
	PAD :: f32(12)
	top := im.GetCursorScreenPos()
	w := inner - 2 * PAD
	im.SetCursorScreenPos({top.x + PAD, top.y + 10})
	im.BeginGroup()

	// ---- Bridging short breaks ([project.KEY] bridge_breaks) ----
	label(fonts.bold, SZ_SMALL, col32(C_MUTED), "Count breaks shorter than this as work")
	im.Dummy({1, 2})
	cur := project_bridge(pr)
	preset := -1
	for v, k in BRIDGE_PRESETS {if v == cur {preset = k}}
	if k := segmented(fmt.tprintf("##bridge:%s", pr.key), BRIDGE_LABELS[:], preset, pr.color); k >= 0 && BRIDGE_PRESETS[k] != cur {
		if i := project_find(pr.name); i >= 0 {tracker_set_bridge(i, BRIDGE_PRESETS[k])}
		cur = BRIDGE_PRESETS[k]
	}
	{
		why: string
		switch {
		case cur > 0:
			why = fmt.tprintf("A break under %d min between two stretches of %s counts as work for it (between projects, or with no %s after it, it stays a break). The log keeps every break, so this applies to past days too.", cur, pr.name, pr.name)
		case:
			why = fmt.tprintf("Off: every break (no input for %s) pauses %s.", fmt_idle(tracker.idle), pr.name)
		}
		if preset < 0 {why = fmt.tprintf("%d min (config.ini). %s", cur, why)}
		if pr.bridge < 0 && tracker.bridge_default > 0 {why = fmt.tprintf("%s From the [timetracker] default.", why)}
		wrapped(fonts.ui, SZ_SMALL, col32(C_FAINT), why, w)
	}
	im.Dummy({1, 8})
	draw_project_billing(pr, w)
	im.Dummy({1, 8})

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

// Paying job and hourly rate, and whether Claude's background work counts
// ([project.KEY] paying, rate, claude_counts; applied at once).
@(private = "file")
draw_project_billing :: proc(pr: Project, w: f32) {
	idx := project_find(pr.name)
	row :: proc(id: string, on: bool, accent: u32, icon, text: string) -> bool {
		tp := im.GetCursorScreenPos()
		clicked := toggle_switch(id, on, accent)
		draw_text(fonts.ui, 14, {tp.x + 48, tp.y + 3}, col32(on ? accent : C_FAINT), icon)
		draw_text(fonts.ui, SZ_SMALL + 1, {tp.x + 70, tp.y + 2}, col32(on ? C_TEXT : C_MUTED), text)
		return clicked
	}
	if row(fmt.tprintf("##paying:%s", pr.key), pr.paying, pr.color, ICON_PAYING, "Paying job") {tracker_set_paying(idx, !pr.paying)}
	if pr.paying {
		// The rate, saved on Enter or when the field loses focus.
		rp := im.GetCursorScreenPos()
		im.Dummy({1, 2})
		lbl := "Hourly rate"
		draw_text(fonts.ui, SZ_SMALL, {rp.x + 48, rp.y + 8}, col32(C_MUTED), lbl)
		fx := rp.x + 48 + measure(fonts.ui, SZ_SMALL, lbl).x + 10
		cur_w := measure(fonts.ui, SZ_SMALL + 1, tracker.currency).x
		draw_text(fonts.ui, SZ_SMALL + 1, {fx, rp.y + 7}, col32(C_MUTED), tracker.currency)
		fp := Vec2{fx + cur_w + 6, rp.y + 2}
		fw: f32 = 100
		fe := fp + Vec2{fw, SZ_BODY + 10}
		im.SetCursorScreenPos(fp)
		field_fill(fp, fe, 7, col32(C_BG))
		im.PushFontFloat(fonts.mono, SZ_BODY)
		im.PushStyleVarImVec2(.FramePadding, {8, 5})
		im.PushStyleVar(.FrameBorderSize, 0)
		im.PushStyleColorImVec4(.FrameBg, {})
		im.PushStyleColorImVec4(.FrameBgHovered, {})
		im.PushStyleColorImVec4(.FrameBgActive, {})
		im.SetNextItemWidth(fw)
		entered := im.InputTextWithHint(cstr(fmt.tprintf("##rate:%s", pr.key)), "none", cstring(&ren.rate[0]), uint(len(ren.rate)), {.CharsDecimal, .EnterReturnsTrue})
		active := im.IsItemActive()
		done := entered || im.IsItemDeactivatedAfterEdit()
		im.PopStyleVar(2)
		im.PopStyleColor(3)
		im.PopFont()
		text := strings.trim_space(string(cstring(&ren.rate[0])))
		text, _ = strings.replace_all(text, ",", ".", context.temp_allocator)
		r, ok := strconv.parse_f64(text)
		valid := text == "" || (ok && r >= 0)
		field_outline(fp, fe, 7, active ? col32(pr.color, 0.85) : valid ? col32(C_BORDER) : col32(C_RED, 0.7))
		if done && valid {
			if text == "" {r = 0}
			if r != pr.rate {tracker_set_rate(idx, r)}
		}
		hint := "per hour; the export adds rate and amount"
		if pr.rate > 0 {
			today := tracker_totals(local_day_start(time.to_unix_seconds(time.now())), time.to_unix_seconds(time.now()) + 1)[pr.name]
			hint = fmt.tprintf("per hour  ·  today %s", fmt_money(f64(today) / 3600 * pr.rate))
		}
		draw_text(fonts.ui, SZ_SMALL, {fe.x + 10, rp.y + 8}, col32(C_FAINT), hint)
		im.SetCursorScreenPos(rp)
		im.Dummy({w, SZ_BODY + 16})
	}
	im.Dummy({1, 6})
	if row(fmt.tprintf("##claude:%s", pr.key), pr.claude, pr.color, ICON_CLAUDE, "Count Claude's background work") {tracker_set_claude(idx, !pr.claude)}
	im.Dummy({1, 2})
	why := pr.claude ? fmt.tprintf("While Claude Code works in a terminal on one of %s's workspaces (its spinner in the window title), the time counts for %s, also when you're on another project or away. Time you work on it yourself counts once.", pr.name, pr.name) : fmt.tprintf("Off: Claude working on %s's workspaces is logged but doesn't count. Turning it on counts past days too.", pr.name)
	wrapped(fonts.ui, SZ_SMALL, col32(C_FAINT), why, w)
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
