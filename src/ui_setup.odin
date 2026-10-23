// The setup window.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

import im "third_party:odin-imgui"

@(private = "file")
Comp_Info :: struct {
	icon, title, desc: string,
	accent:            u32,
	preview:           string, // file content shown on demand ("" = none)
}

@(private = "file")
info :: proc(id: Comp_Id) -> Comp_Info {
	switch id {
	case .Program:  return {ICON_DESKTOP, "Program", "Copies this binary to ~/.local/bin so `wlperch` works from anywhere. Run setup again from a newer download to update.", C_BLUE, ""}
	case .Service:  return {ICON_POWER, "Background service", "The daemon samples CPU/GPU history, tracks time and serves the panels. Sway starts it at login (see Sway integration).", C_GREEN, ""}
	case .Config:   return {ICON_TUNE, "Settings file", "Panels, weather location, clocks, projects, sensors… Created with defaults; edit it, then use the restart button in a panel.", C_TEAL, ""}
	case .Sway:     return {ICON_KEYBOARD, "Sway integration", "One file in sway/config.d: starts the daemon, binds Mod+O (panel), Mod+P / Mod+Shift+P / Mod+Ctrl+P (project workspaces) and styles placeholder windows.", C_PURPLE, SWAY_FILE}
	case .Waybar:   return {ICON_MONITOR, "Waybar buttons", "Panel button, timer, sensors, media and notification pills. Adds them to your bar (with backups), or replaces the whole bar with wlperch's own; Restore puts yours back.", C_CYAN, WAYBAR_JSONC}
	case .Rapl:     return {ICON_LIGHTNING, "CPU power reading", "A udev rule that makes the CPU energy counter readable, so the Temperatures & power module can show CPU watts. Needs your password (root).", C_ORANGE, RAPL_RULE}
	case .Notifications: return {ICON_BELL, "Notifications", "Shows app notifications as popups in the corner, with a history in the Notifications panel and do not disturb. Switches off dunst/mako (masks their service) so they don't take over again.", C_PURPLE, ""}
	case .Launcher: return {ICON_HOME, "App launcher entry", "Adds \"wlperch setup\" to your application launcher (rofi, wofi, fuzzel…).", C_YELLOW, ""}
	}
	return {}
}

@(private = "file")
state_pill :: proc(s: Comp_State) -> (text: string, col: u32) {
	switch s {
	case .Installed:   return "installed", C_GREEN
	case .Running:     return "running", C_GREEN
	case .Outdated:    return "update available", C_ORANGE
	case .Partial:     return "not in your bar yet", C_ORANGE
	case .Missing:     return "not installed", C_MUTED
	case .Stopped:     return "stopped", C_MUTED
	case .Custom:      return "set up elsewhere", C_BLUE
	case .Unavailable: return "not applicable", C_FAINT
	}
	return "", C_MUTED
}

// Rounded text button. Returns true when clicked.
pill_button :: proc(id, text: string, accent: u32, primary := false) -> bool {
	tsz := measure(fonts.bold, SZ_SMALL + 1, text)
	w := tsz.x + 24
	h: f32 = 28
	p := im.GetCursorScreenPos()
	clicked := im.InvisibleButton(cstr(id), {w, h})
	hovered := im.IsItemHovered()
	if hovered {im.SetMouseCursor(.Hand)}
	d := dl()
	if primary {
		im.DrawList_AddRectFilled(d, p, {p.x + w, p.y + h}, col32(accent, hovered ? 1 : 0.88), 8)
		draw_text(fonts.bold, SZ_SMALL + 1, {p.x + 12, p.y + 6}, col32(0x111318), text)
	} else {
		im.DrawList_AddRectFilled(d, p, {p.x + w, p.y + h}, col32(accent, hovered ? 0.24 : 0.13), 8)
		draw_text(fonts.bold, SZ_SMALL + 1, {p.x + 12, p.y + 6}, col32(accent), text)
	}
	return clicked
}

@(private = "file")
pill_width :: proc(text: string) -> f32 {return measure(fonts.bold, SZ_SMALL + 1, text).x + 24}

@(private = "file")
wrapped :: proc(font: ^im.Font, size: f32, col: u32, text: string, width: f32) {
	im.PushFontFloat(font, size)
	im.PushStyleColorImVec4(.Text, rgba(col & 0xffffff))
	im.PushTextWrapPos(im.GetCursorPosX() + width)
	b, e := str_range(text)
	im.TextUnformatted(b, e)
	im.PopTextWrapPos()
	im.PopStyleColor()
	im.PopFont()
}

@(private = "file")
Action :: struct {
	label:   string,
	primary: bool,
	run:     proc(),
	confirm: bool, // destructive: a second click within a few seconds runs it
}

// The destructive action waiting for its confirming click.
@(private = "file")
armed: struct {
	id:    Comp_Id,
	index: int, // -1: none
	at:    time.Tick,
} = {index = -1}

@(private = "file")
show_preview: [Comp_Id]bool

@(private = "file")
actions_for :: proc(id: Comp_Id, s: Comp_State) -> []Action {
	out: [dynamic]Action
	out.allocator = context.temp_allocator
	switch id {
	case .Program:
		if s == .Missing {append(&out, Action{"Install", true, setup_install_program, false})}
		if s == .Outdated {append(&out, Action{"Update", true, setup_install_program, false})}
		if s != .Missing {append(&out, Action{"Remove", false, setup_remove_program, true})}
	case .Service:
		if s == .Running {
			append(&out, Action{"Restart", false, proc() {setup_start_service(true)}, false})
			append(&out, Action{"Stop", false, setup_stop_service, false})
		} else {append(&out, Action{"Start", true, proc() {setup_start_service(false)}, false})}
	case .Config:
		append(&out, Action{s == .Missing ? "Create" : "Open", s == .Missing, setup_create_config, false})
		if s != .Missing {append(&out, Action{"Remove", false, setup_remove_config, true})}
	case .Sway:
		switch s {
		case .Missing:  append(&out, Action{"Install", true, setup_install_sway, false})
		case .Outdated:
			append(&out, Action{"Update", true, setup_install_sway, false})
			if os.exists(sway_file()) {append(&out, Action{"Remove", false, setup_remove_sway, true})}
		case .Installed:
			append(&out, Action{"Reload sway", false, setup_reload_sway, false})
			append(&out, Action{"Remove", false, setup_remove_sway, true})
		case .Custom:   append(&out, Action{"Reload sway", false, setup_reload_sway, false})
		case .Running, .Stopped, .Unavailable, .Partial:
		}
	case .Waybar:
		if setup.waybar_full {
			if s == .Installed {append(&out, Action{"Reload waybar", false, setup_reload_waybar, false})}
			else {append(&out, Action{"Update", true, setup_install_waybar_full, false})}
			append(&out, Action{"Restore my bar", false, setup_restore_waybar, true})
			break
		}
		switch s {
		case .Missing, .Outdated, .Partial: append(&out, Action{"Add to my bar", true, setup_hook_waybar, false})
		case .Installed:                   append(&out, Action{"Reload waybar", false, setup_reload_waybar, false})
		case .Running, .Stopped, .Unavailable, .Custom:
		}
		if s == .Missing || s == .Outdated {append(&out, Action{"Files only", false, proc() {setup_install_waybar_files()}, false})}
		if s != .Missing && s != .Unavailable {append(&out, Action{"Remove", false, setup_remove_waybar, true})}
		// Aggressive: moves the user's config and style.css aside.
		if s != .Unavailable {append(&out, Action{"Replace whole bar", false, setup_install_waybar_full, true})}
	case .Rapl:
		if s == .Missing {append(&out, Action{"Install (root)", true, proc() {setup_install_rapl(true)}, false})}
		if s == .Installed {append(&out, Action{"Remove (root)", false, proc() {setup_install_rapl(false)}, false})}
	case .Notifications:
		switch s {
		case .Missing:   append(&out, Action{"Take over", true, proc() {setup_take_notifications(true)}, false})
		case .Running, .Stopped: append(&out, Action{"Hand back", false, setup_release_notifications, true})
		case .Unavailable:       append(&out, Action{"Turn on", true, setup_enable_notifications, false})
		case .Installed, .Outdated, .Custom, .Partial:
		}
	case .Launcher:
		if s == .Missing {append(&out, Action{"Add", true, proc() {setup_install_launcher(true)}, false})}
		else {append(&out, Action{"Remove", false, proc() {setup_install_launcher(false)}, false})}
	}
	return out[:]
}

// Components grouped into the dashboard's columns.
@(private = "file")
COLUMNS := [3]struct {
	title: string,
	ids:   []Comp_Id,
} {
	{"Basics", {.Program, .Service, .Config}},
	{"Desktop", {.Sway, .Waybar, .Launcher}},
	{"Extras", {.Notifications, .Rapl}},
}

@(private = "file")
is_done :: proc(s: Comp_State) -> bool {return s == .Installed || s == .Running || s == .Custom}

@(private = "file")
needs_attention :: proc(s: Comp_State) -> bool {return s == .Outdated || s == .Partial || s == .Stopped}

// One summary tile: caption, big value, optional sub line and progress bar.
@(private = "file")
stat_tile :: proc(id: string, w: f32, icon, caption, value, sub: string, accent: u32, progress: f32 = -1) {
	card_begin(id, w)
	p := im.GetCursorScreenPos()
	iw := im.GetContentRegionAvail().x
	// All tiles share one height; without a bar the content sits centered.
	TILE_H :: 51
	if progress < 0 {p.y += 5}
	im.DrawList_AddCircleFilled(dl(), {p.x + 17, p.y + 19}, 17, col32(accent, 0.16))
	isz := measure(fonts.ui, 18, icon)
	draw_text(fonts.ui, 18, {p.x + 17 - isz.x / 2, p.y + 19 - isz.y / 2}, col32(accent), icon)
	draw_text(fonts.ui, SZ_SMALL, {p.x + 46, p.y}, col32(C_MUTED), caption)
	draw_text(fonts.bold, 20, {p.x + 46, p.y + 14}, col32(C_TEXT), value)
	if sub != "" {
		vw := measure(fonts.bold, 20, value).x
		draw_text(fonts.ui, SZ_SMALL, {p.x + 54 + vw, p.y + 21}, col32(C_MUTED), sub)
	}
	if progress >= 0 {
		y := p.y + 46
		im.DrawList_AddRectFilled(dl(), {p.x, y}, {p.x + iw, y + 5}, col32(C_BORDER), 3)
		im.DrawList_AddRectFilled(dl(), {p.x, y}, {p.x + iw * clamp(progress, 0, 1), y + 5}, col32(accent), 3)
	}
	im.Dummy({iw, TILE_H})
	card_end()
}

// One component card; returns the action to run if one was clicked.
@(private = "file")
comp_card :: proc(id: Comp_Id, c: ^Component, width: f32) -> (run: proc()) {
	inf := info(id)
	card_begin(fmt.tprintf("comp:%v", id), width)
	inner := im.GetContentRegionAvail().x
	cp := im.GetCursorScreenPos()

	// Accent strip along the top edge of the card.
	wp := im.GetWindowPos()
	ws := im.GetWindowSize()
	im.DrawList_PushClipRect(dl(), wp, wp + ws, false)
	im.DrawList_AddRectFilled(dl(), {wp.x + 1, wp.y + 1}, {wp.x + ws.x - 1, wp.y + 4}, col32(inf.accent, 0.55), 6, im.DrawFlags_RoundCornersTop)
	im.DrawList_PopClipRect(dl())

	// Header: icon badge, title, state pill underneath.
	im.DrawList_AddCircleFilled(dl(), {cp.x + 18, cp.y + 20}, 18, col32(inf.accent, 0.16))
	isz := measure(fonts.ui, 19, inf.icon)
	draw_text(fonts.ui, 19, {cp.x + 18 - isz.x / 2, cp.y + 20 - isz.y / 2}, col32(inf.accent), inf.icon)
	draw_text(fonts.bold, 16, {cp.x + 48, cp.y + 1}, col32(C_TEXT), inf.title)
	stext, scol := state_pill(c.state)
	ssz := measure(fonts.bold, 11, stext)
	sx, sy := cp.x + 48, cp.y + 22
	im.DrawList_AddCircleFilled(dl(), {sx + 9, sy + 9}, 3, col32(scol))
	im.DrawList_AddRectFilled(dl(), {sx, sy}, {sx + ssz.x + 24, sy + 18}, col32(scol, 0.14), 9)
	draw_text(fonts.bold, 11, {sx + 17, sy + 2}, col32(scol), stext)
	im.Dummy({inner, 44})

	wrapped(fonts.ui, SZ_BODY, C_MUTED, inf.desc, inner)
	for line in c.detail {wrapped(fonts.mono, SZ_SMALL, C_FAINT, line, inner)}
	if c.message != "" {
		wrapped(fonts.ui, SZ_SMALL, c.msg_ok ? C_GREEN : C_RED, fmt.tprintf("%s %s", c.msg_ok ? ICON_CHECK : ICON_ALERT, c.message), inner)
	}
	if inf.preview != "" && show_preview[id] {
		text := strings.trim_space(inf.preview)
		im.PushStyleColorImVec4(.ChildBg, rgba(0x12151b))
		im.PushStyleVarImVec2(.WindowPadding, {12, 10})
		im.BeginChild(cstr(fmt.tprintf("##code:%v", id)), {inner, 0}, {.AutoResizeY, .AlwaysUseWindowPadding}, {})
		wrapped(fonts.mono, SZ_SMALL, C_TEXT, text, inner - 24)
		im.EndChild()
		im.PopStyleVar()
		im.PopStyleColor()
	}

	// Footer: actions on the left, file toggle on the right.
	im.Dummy({1, 2})
	fp := im.GetCursorScreenPos()
	im.DrawList_AddLine(dl(), {fp.x, fp.y - 4}, {fp.x + inner, fp.y - 4}, col32(C_BORDER), 1)
	ax := fp.x
	row_y := fp.y
	acts := actions_for(id, c.state)
	if c.busy {
		draw_text(fonts.ui, SZ_SMALL, {ax, fp.y + 6}, col32(C_ORANGE), "working…")
	} else if len(acts) == 0 {
		draw_text(fonts.ui, SZ_SMALL, {ax, fp.y + 6}, col32(C_FAINT), is_done(c.state) ? "nothing to do" : "—")
	} else {
		if armed.index >= 0 && time.tick_since(armed.at) > 4 * time.Second {armed.index = -1}
		// Pills wrap onto another row; the file toggle keeps the first row's end.
		right := fp.x + inner - (inf.preview != "" ? measure(fonts.ui, SZ_SMALL, "Show file").x + 12 : 0)
		for a, i in acts {
			is_armed := armed.index == i && armed.id == id
			label := is_armed ? fmt.tprintf("Really %s?", strings.to_lower(a.label, context.temp_allocator)) : a.label
			if ax > fp.x && ax + pill_width(label) > right {
				ax = fp.x
				row_y += 34
				right = fp.x + inner
			}
			im.SetCursorScreenPos({ax, row_y})
			if pill_button(fmt.tprintf("##%v:%d", id, i), label, is_armed ? C_RED : inf.accent, a.primary || is_armed) {
				if !a.confirm || is_armed {
					run = a.run
					armed.index = -1
				} else {
					armed = {id, i, time.tick_now()}
				}
			}
			ax += pill_width(label) + 8
		}
	}
	if inf.preview != "" {
		lbl := show_preview[id] ? "Hide file" : "Show file"
		lsz := measure(fonts.ui, SZ_SMALL, lbl)
		lp := Vec2{fp.x + inner - lsz.x, fp.y + 6}
		im.SetCursorScreenPos(lp)
		if im.InvisibleButton(cstr(fmt.tprintf("##prev:%v", id)), lsz + {0, 2}) {show_preview[id] = !show_preview[id]}
		if im.IsItemHovered() {im.SetMouseCursor(.Hand)}
		draw_text(fonts.ui, SZ_SMALL, lp, col32(inf.accent, 0.9), lbl)
	}
	im.SetCursorScreenPos(fp)
	im.Dummy({inner, row_y - fp.y + 28})
	card_end()
	return
}

draw_setup :: proc() {
	io := im.GetIO()
	if im.IsKeyPressed(.Escape, false) {plat.closed = true}
	im.SetNextWindowPos({0, 0})
	im.SetNextWindowSize(io.DisplaySize)
	im.PushStyleColorImVec4(.WindowBg, rgba(C_BG))
	im.PushStyleVar(.WindowRounding, 0)
	im.PushStyleVarImVec2(.WindowPadding, {26, 22})
	im.Begin("setup", nil, {.NoTitleBar, .NoResize, .NoMove, .NoCollapse, .NoSavedSettings})
	im.PopStyleVar(2)
	im.PopStyleColor()

	width := im.GetContentRegionAvail().x
	// ---- Header -------------------------------------------------------------
	p := im.GetCursorScreenPos()
	im.DrawList_AddCircleFilled(dl(), {p.x + 22, p.y + 22}, 22, col32(C_BLUE, 0.16))
	draw_text(fonts.ui, 24, {p.x + 10, p.y + 9}, col32(C_BLUE), ICON_TUNE_BAR)
	draw_text(fonts.bold, 26, {p.x + 58, p.y - 2}, col32(C_TEXT), "wlperch")
	draw_text(fonts.ui, SZ_BODY, {p.x + 58, p.y + 28}, col32(C_MUTED), "Pick the parts you want. Run `wlperch setup` any time to change them.")
	rec := "Install recommended"
	im.SetCursorScreenPos({p.x + width - pill_width(rec), p.y + 8})
	if pill_button("##recommended", rec, C_BLUE, true) {setup_install_recommended(); setup_check()}
	im.SetCursorScreenPos(p)
	im.Dummy({width, 56})
	im.Dummy({1, 6})

	GAP :: 14
	run: proc() = nil
	{
		sync.guard(&setup.mu)

		// ---- Summary tiles ----------------------------------------------------
		done, applicable, attention, missing := 0, 0, 0, 0
		for id in Comp_Id {
			s := setup.comps[id].state
			if s == .Unavailable {continue}
			applicable += 1
			if is_done(s) {done += 1}
			if needs_attention(s) {attention += 1}
			if s == .Missing {missing += 1}
		}
		tw := (width - GAP * 3) / 4
		ty := im.GetCursorScreenPos().y
		svc_text, svc_col := state_pill(setup.comps[.Service].state)
		ntf_text, ntf_col := state_pill(setup.comps[.Notifications].state)
		tiles := [4]struct {
			icon, caption, value, sub: string,
			accent:                    u32,
			progress:                  f32,
		} {
			{ICON_CHECK, "Set up", fmt.tprintf("%d / %d", done, applicable), "components", C_BLUE, applicable > 0 ? f32(done) / f32(applicable) : 0},
			{ICON_POWER, "Daemon", svc_text, "", svc_col, -1},
			{ICON_BELL, "Notifications", ntf_text, "", ntf_col, -1},
			attention > 0 ? {ICON_ALERT, "Needs attention", fmt.tprintf("%d", attention), attention == 1 ? "component" : "components", C_ORANGE, -1} : {ICON_HOME, "Not installed", fmt.tprintf("%d", missing), "optional", C_MUTED, -1},
		}
		tile_h: f32 = 0
		for t, i in tiles {
			im.SetCursorScreenPos({p.x + f32(i) * (tw + GAP), ty})
			stat_tile(fmt.tprintf("tile:%d", i), tw, t.icon, t.caption, t.value, t.sub, t.accent, t.progress)
			tile_h = max(tile_h, im.GetItemRectSize().y)
		}
		im.SetCursorScreenPos({p.x, ty + tile_h + 18})

		// ---- Component columns ------------------------------------------------
		// A card ends with its own 6px spacing; the empty Dummy after each adds the rest.
		im.PushStyleVarImVec2(.ItemSpacing, {10, GAP - 6})
		cw := (width - GAP * 2) / 3
		cy := im.GetCursorScreenPos().y
		bottom := cy
		for col, ci in COLUMNS {
			x := p.x + f32(ci) * (cw + GAP)
			im.SetCursorScreenPos({x, cy})
			im.BeginGroup()
			draw_text(fonts.bold, SZ_SMALL, {x + 2, cy}, col32(C_FAINT), strings.to_upper(col.title, context.temp_allocator))
			im.Dummy({cw, 14})
			for id in col.ids {
				if r := comp_card(id, &setup.comps[id], cw); r != nil {run = r}
				im.Dummy({cw, 0})
			}
			im.EndGroup()
			bottom = max(bottom, im.GetItemRectMax().y)
		}
		im.PopStyleVar()
		im.SetCursorScreenPos({p.x, bottom})
	}
	if run != nil {
		run()
		setup_check()
	}
	im.Dummy({1, 8})
	im.End()
}
