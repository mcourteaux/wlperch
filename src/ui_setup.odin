// The setup window.
package main

import "core:fmt"
import "core:strings"
import "core:sync"

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
	case .Waybar:   return {ICON_MONITOR, "Waybar buttons", "Panel button (turns red when memory runs low), project timer and sensors pills, and memory → system panel. Adds them to your bar with backups of your files.", C_CYAN, WAYBAR_JSONC}
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
}

@(private = "file")
show_preview: [Comp_Id]bool

@(private = "file")
actions_for :: proc(id: Comp_Id, s: Comp_State) -> []Action {
	out: [dynamic]Action
	out.allocator = context.temp_allocator
	switch id {
	case .Program:
		if s == .Missing {append(&out, Action{"Install", true, setup_install_program})}
		if s == .Outdated {append(&out, Action{"Update", true, setup_install_program})}
	case .Service:
		if s == .Running {append(&out, Action{"Restart", false, proc() {setup_start_service(true)}})}
		else {append(&out, Action{"Start", true, proc() {setup_start_service(false)}})}
	case .Config:
		append(&out, Action{s == .Missing ? "Create" : "Open", s == .Missing, setup_create_config})
	case .Sway:
		switch s {
		case .Missing:  append(&out, Action{"Install", true, setup_install_sway})
		case .Outdated: append(&out, Action{"Update", true, setup_install_sway})
		case .Installed:
			append(&out, Action{"Reload sway", false, setup_reload_sway})
			append(&out, Action{"Remove", false, setup_remove_sway})
		case .Custom:   append(&out, Action{"Reload sway", false, setup_reload_sway})
		case .Running, .Stopped, .Unavailable, .Partial:
		}
	case .Waybar:
		switch s {
		case .Missing, .Outdated, .Partial: append(&out, Action{"Add to my bar", true, setup_hook_waybar})
		case .Installed:                   append(&out, Action{"Reload waybar", false, setup_reload_waybar})
		case .Running, .Stopped, .Unavailable, .Custom:
		}
		if s == .Missing || s == .Outdated {append(&out, Action{"Files only", false, proc() {setup_install_waybar_files()}})}
	case .Rapl:
		if s == .Missing {append(&out, Action{"Install (root)", true, proc() {setup_install_rapl(true)}})}
		if s == .Installed {append(&out, Action{"Remove (root)", false, proc() {setup_install_rapl(false)}})}
	case .Notifications:
		switch s {
		case .Missing:   append(&out, Action{"Take over", true, proc() {setup_take_notifications(true)}})
		case .Running:
			if len(other_notification_units()) > 0 {append(&out, Action{"Allow dunst again", false, proc() {setup_take_notifications(false)}})}
		case .Installed, .Outdated, .Custom, .Unavailable, .Stopped, .Partial:
		}
	case .Launcher:
		if s == .Missing {append(&out, Action{"Add", true, proc() {setup_install_launcher(true)}})}
		else {append(&out, Action{"Remove", false, proc() {setup_install_launcher(false)}})}
	}
	return out[:]
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

	// ---- Components ---------------------------------------------------------
	run: proc() = nil
	{
		sync.guard(&setup.mu)
		im.PushStyleVarImVec2(.ItemSpacing, {10, 12})
		for id in Comp_Id {
			c := &setup.comps[id]
			inf := info(id)
			card_begin(fmt.tprintf("comp:%v", id), width)
			inner := im.GetContentRegionAvail().x
			cp := im.GetCursorScreenPos()

			// Title row: icon, title, state pill; actions on the right.
			draw_text(fonts.ui, 19, {cp.x - 1, cp.y - 1}, col32(inf.accent), inf.icon)
			draw_text(fonts.bold, 16, {cp.x + 26, cp.y}, col32(C_TEXT), inf.title)
			tw := measure(fonts.bold, 16, inf.title).x
			stext, scol := state_pill(c.state)
			ssz := measure(fonts.bold, 11, stext)
			sx := cp.x + 36 + tw
			im.DrawList_AddRectFilled(dl(), {sx, cp.y + 1}, {sx + ssz.x + 14, cp.y + 19}, col32(scol, 0.16), 9)
			draw_text(fonts.bold, 11, {sx + 7, cp.y + 3}, col32(scol), stext)

			acts := actions_for(id, c.state)
			ax := cp.x + inner
			if c.busy {
				w := measure(fonts.ui, SZ_SMALL, "working…").x
				draw_text(fonts.ui, SZ_SMALL, {ax - w, cp.y + 3}, col32(C_ORANGE), "working…")
			} else {
				for i := len(acts) - 1; i >= 0; i -= 1 {
					a := acts[i]
					ax -= pill_width(a.label)
					im.SetCursorScreenPos({ax, cp.y - 4})
					if pill_button(fmt.tprintf("##%v:%d", id, i), a.label, inf.accent, a.primary) {run = a.run}
					ax -= 8
				}
			}
			im.SetCursorScreenPos(cp)
			im.Dummy({inner, 24})

			wrapped(fonts.ui, SZ_BODY, C_MUTED, inf.desc, inner)
			for line in c.detail {label(fonts.mono, SZ_SMALL, col32(C_FAINT), line)}
			if c.message != "" {
				label(fonts.ui, SZ_SMALL, col32(c.msg_ok ? C_GREEN : C_RED), fmt.tprintf("%s %s", c.msg_ok ? ICON_CHECK : ICON_ALERT, c.message))
			}
			if inf.preview != "" {
				lbl := show_preview[id] ? "Hide file" : "Show file"
				lp := im.GetCursorScreenPos()
				if im.InvisibleButton(cstr(fmt.tprintf("##prev:%v", id)), measure(fonts.ui, SZ_SMALL, lbl) + {0, 2}) {show_preview[id] = !show_preview[id]}
				if im.IsItemHovered() {im.SetMouseCursor(.Hand)}
				draw_text(fonts.ui, SZ_SMALL, lp, col32(inf.accent, 0.9), lbl)
				if show_preview[id] {
					text := strings.trim_space(inf.preview)
					im.PushStyleColorImVec4(.ChildBg, rgba(0x12151b))
					im.PushStyleVarImVec2(.WindowPadding, {12, 10})
					im.BeginChild(cstr(fmt.tprintf("##code:%v", id)), {inner, 0}, {.AutoResizeY, .AlwaysUseWindowPadding}, {})
					wrapped(fonts.mono, SZ_SMALL, C_TEXT, text, inner - 24)
					im.EndChild()
					im.PopStyleVar()
					im.PopStyleColor()
				}
			}
			card_end()
		}
		im.PopStyleVar()
	}
	if run != nil {
		run()
		setup_check()
	}
	im.Dummy({1, 8})
	im.End()
}
