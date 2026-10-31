// The setup window.
package main

import "core:fmt"
import "core:math"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
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
	case .Service:  return {ICON_POWER, "Background service", "The daemon samples CPU/GPU history, tracks time, serves the panels and locks on idle. Sway starts it at login (see Sway integration); optionally systemd does, and restarts it if it crashes.", C_GREEN, DAEMON_UNIT}
	case .Config:   return {ICON_TUNE, "Settings file", "Panels, weather location, clocks, projects, sensors… Created with defaults. The common settings are on this window's pages; the rest you edit in the file, then use the restart button in a panel.", C_TEAL, ""}
	case .Sway:     return {ICON_KEYBOARD, "Sway integration", "One file in sway/config.d: starts the daemon, binds Mod+O (panel), Mod+P / Mod+Shift+P / Mod+Ctrl+P (project workspaces) and styles placeholder windows.", C_PURPLE, SWAY_FILE}
	case .Waybar:   return {ICON_MONITOR, "Waybar buttons", "Panel button, timer, sensors, media and notification pills. Adds them to your bar (with backups), or replaces the whole bar with wlperch's own; Restore puts yours back.", C_CYAN, WAYBAR_JSONC}
	case .Rapl:     return {ICON_LIGHTNING, "CPU power reading", "A udev rule that makes the CPU energy counter readable, so the Temperatures & power module can show CPU watts. Needs your password (root).", C_ORANGE, RAPL_RULE}
	case .Notifications: return {ICON_BELL, "Notifications", "Shows app notifications as popups in the corner, with a history in the Notifications panel and do not disturb. Switches off dunst/mako (masks their service) so they don't take over again.", C_PURPLE, ""}
	case .Lock:     return {ICON_LOCK, "Lock screen", "wlperch lock instead of swaylock: clock, notification count, media and battery. Switches swayidle and your lock key over (with backups).", C_BLUE, LOCK_CONF}
	case .Menu:     return {ICON_APPS, "Launcher", "wlperch's app launcher instead of rofi/wofi/fuzzel: apps, a calculator and the panels as you type, \"> command\" runs one. Switches your launcher keys over (with backups).", C_GREEN, MENU_CONF}
	case .Theme:    return {ICON_THEME, "Dark / light", "wlperch theme switches wlperch (and its bar), GTK apps, waybar, kitty, nvim and the wallpaper between dark and light (see [theme] in the settings). Switches your theme keys over (with backups), copying your theme script's settings.", C_YELLOW, THEME_CONF}
	case .Nvim:     return {ICON_PENCIL, "Neovim theme", "Makes Neovim follow wlperch theme: a small plugin file that reads wlperch's current mode and its [theme] nvim settings, and applies them when you switch. Doesn't edit your init.lua.", C_GREEN, nvim_plugin_preview}
	case .Portal:   return {ICON_THEME, "Desktop portal", "GTK4 apps and Flatpaks read the system dark / light setting from xdg-desktop-portal, which needs systemd's graphical session (screen sharing and file pickers use it too). Starts it from sway (with sway-systemd when installed). Discord and Chrome follow the GTK theme without it.", C_ORANGE, ""}
	case .Bar:      return {ICON_MONITORS, "Bar", "wlperch's own bar instead of waybar: workspaces (project workspaces in their colour), tray, media, timer, sensors, notifications, clock. Switches sway's bar over (with backups).", C_TEAL, BAR_CONF}
	case .Ssh:      return {ICON_KEY, "SSH agent", "OpenSSH's own ssh-agent (not GNOME Keyring's), started by systemd on first use, for the SSH keys panel and the bar's key icon: unlock keys for a while ([ssh] lifetime), forget them when the screen locks. Sets SSH_AUTH_SOCK for your next login (with backups).", C_YELLOW, SSH_PROFILE_BLOCK}
	case .Wallpaper: return {ICON_IMAGE, "Wallpaper", "wlperch draws the wallpaper instead of swaybg: a soft crossfade on every change, the dark / light sets below, and a new picture every few minutes if you like ([wallpapers] rotate_minutes). Turns sway's swaybg off.", C_BLUE, WALLPAPER_CONF}
	case .Idle:     return {ICON_POWER, "Idle", "wlperch locks on idle instead of swayidle: the lock with its countdown, monitors off (sooner once locked), locking before sleep and on loginctl lock-session (with logind). Fullscreen games, idle inhibitors and `wlperch idle hold` keep the session awake. Comments out swayidle's exec lines (with backups).", C_PURPLE, ""}
	case .Launcher: return {ICON_HOME, "App launcher entry", "Adds \"wlperch setup\" to your application launcher (rofi, wofi, fuzzel…).", C_YELLOW, ""}
	}
	return {}
}

@(private = "file")
state_pill :: proc(s: Comp_State, id := Comp_Id.Program) -> (text: string, col: u32) {
	if id == .Ssh && s == .Partial {return "log in again", C_ORANGE}
	if id == .Ssh && s == .Outdated {return "partly set up", C_ORANGE}
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
		unit := daemon_unit_enabled()
		if s == .Running {
			append(&out, Action{"Restart", false, proc() {setup_start_service(true)}, false})
			append(&out, Action{"Stop", false, unit ? setup_service_stop_systemd : setup_stop_service, false})
		} else {append(&out, Action{"Start", true, unit ? setup_service_start_systemd : proc() {setup_start_service(false)}, false})}
		// Optional: systemd keeps it running (needs its graphical session).
		if unit {
			append(&out, Action{"Back to sway", false, setup_service_sway, true})
		} else if setup_systemd_session {
			append(&out, Action{"Run under systemd", false, setup_service_systemd, false})
		}
	case .Config:
		append(&out, Action{s == .Missing ? "Create" : "Open", s == .Missing, setup_create_config, false})
		if s != .Missing {append(&out, Action{"Remove", false, setup_remove_config, true})}
	case .Sway:
		switch s {
		case .Missing:
			append(&out, Action{"Install", true, setup_install_sway, false})
			if sway_keys_clash_count() > 0 {append(&out, Action{"Install without those keys", false, setup_install_sway_skipping, false})}
		case .Outdated:
			append(&out, Action{"Update", true, setup_install_sway, false})
			if sway_keys_clash_count() > 0 {append(&out, Action{"Update without those keys", false, setup_install_sway_skipping, false})}
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
	case .Menu:
		switch s {
		case .Missing:   append(&out, Action{"Use wlperch's launcher", true, setup_install_menu, false})
		case .Outdated:  append(&out, Action{"Switch the rest", true, setup_install_menu, false})
		case .Installed, .Custom, .Running, .Stopped, .Unavailable, .Partial:
		}
		append(&out, Action{"Try it", false, setup_open_menu, false})
		if s == .Installed || s == .Outdated {append(&out, Action{"Switch back", false, setup_remove_menu, true})}
	case .Theme:
		switch s {
		case .Missing:   append(&out, Action{"Use wlperch theme", true, setup_install_theme, false})
		case .Outdated:  append(&out, Action{"Switch the rest", true, setup_install_theme, false})
		case .Installed, .Custom, .Running, .Stopped, .Unavailable, .Partial:
		}
		append(&out, Action{"Toggle now", false, setup_toggle_theme, false})
		if s == .Installed || s == .Outdated {append(&out, Action{"Switch back", false, setup_remove_theme, true})}
	case .Nvim:
		switch s {
		case .Missing:   append(&out, Action{"Install", true, setup_install_nvim, false})
		case .Custom:    if !os.exists(nvim_plugin_path()) {append(&out, Action{"Install", false, setup_install_nvim, false})}
		case .Outdated:  append(&out, Action{"Update", true, setup_install_nvim, false})
		case .Installed, .Running, .Stopped, .Unavailable, .Partial:
		}
		if s == .Installed || s == .Outdated {append(&out, Action{"Remove", false, setup_remove_nvim, true})}
	case .Portal:
		st := portal_status
		if !st.session && !st.elsewhere && !st.installed {append(&out, Action{"Start session", true, setup_install_portal, false})}
		if !st.session && (st.installed || st.elsewhere) {append(&out, Action{"Start now", true, setup_start_portal_session, false})}
		if !st.backend && portal_can_install_backend() {append(&out, Action{"Install " + PORTAL_BACKEND_PKG + " (root)", st.session, setup_install_portal_backend, false})}
		if st.installed {append(&out, Action{"Switch back", false, setup_remove_portal, true})}
	case .Bar:
		switch s {
		case .Missing:   append(&out, Action{"Use wlperch bar", true, setup_install_bar, false})
		case .Outdated:  append(&out, Action{"Switch the rest", true, setup_install_bar, false})
		case .Installed, .Custom, .Running, .Stopped, .Unavailable, .Partial:
		}
		if s == .Installed || s == .Outdated || s == .Custom {append(&out, Action{"Restart bar", false, setup_restart_bar, false})}
		if s == .Installed || s == .Outdated {append(&out, Action{"Switch back", false, setup_remove_bar, true})}
	case .Ssh:
		switch s {
		case .Missing:   append(&out, Action{"Install", true, setup_install_ssh, false})
		case .Outdated:  append(&out, Action{"Finish setup", true, setup_install_ssh, false})
		case .Custom:    append(&out, Action{"Use OpenSSH's agent", false, setup_install_ssh, false})
		case .Installed, .Partial, .Running, .Stopped, .Unavailable:
		}
		if s != .Unavailable {
			ours, theirs := ssh_config_state()
			if ours {
				append(&out, Action{"Stop adding keys on use", false, setup_ssh_stop_add_keys, true})
			} else if !theirs && (s == .Installed || s == .Partial) {
				append(&out, Action{"Add keys on first use", false, setup_ssh_add_keys, false})
			}
		}
		if s == .Installed || s == .Partial || s == .Custom {append(&out, Action{"Show keys", false, setup_ssh_show_keys, false})}
		if s == .Installed || s == .Partial || s == .Outdated {append(&out, Action{"Remove", false, setup_remove_ssh, true})}
	case .Wallpaper:
		switch s {
		case .Missing:  append(&out, Action{"Use wlperch wallpaper", true, setup_install_wallpaper, false})
		case .Stopped:  append(&out, Action{"Start", true, setup_start_wallpaper, false})
		case .Running:  append(&out, Action{"Restart", false, setup_restart_wallpaper, false})
		case .Installed, .Outdated, .Custom, .Unavailable, .Partial:
		}
		if s == .Running || s == .Stopped {append(&out, Action{"Switch back", false, setup_remove_wallpaper, true})}
	case .Idle:
		switch s {
		case .Missing:   append(&out, Action{"Use wlperch idle", true, setup_install_idle, false})
		case .Outdated:  append(&out, Action{"Switch the rest", true, setup_install_idle, false})
		case .Installed, .Custom, .Running, .Stopped, .Unavailable, .Partial:
		}
		if s == .Running || s == .Outdated {append(&out, Action{"Switch back", false, setup_remove_idle, true})}
	case .Lock:
		switch s {
		case .Missing:   append(&out, Action{"Use wlperch lock", true, setup_install_lock, false})
		case .Outdated:  append(&out, Action{"Switch the rest", true, setup_install_lock, false})
		case .Installed, .Custom, .Running, .Stopped, .Unavailable, .Partial:
		}
		if s == .Installed || s == .Outdated || s == .Custom {append(&out, Action{"Lock now", false, setup_lock_now, false})}
		if s == .Installed || s == .Outdated {append(&out, Action{"Switch back", false, setup_remove_lock, true})}
	}
	return out[:]
}

@(private = "file")
is_done :: proc(s: Comp_State) -> bool {return s == .Installed || s == .Running || s == .Custom}

// Applies here, and isn't set up yet: counted on the sidebar and the overview.
@(private = "file")
is_todo :: proc(s: Comp_State) -> bool {return s != .Unavailable && !is_done(s)}

// Every component that applies here is set up.
setup_all_done :: proc() -> bool {
	sync.guard(&setup.mu)
	n := 0
	for id in Comp_Id {
		s := setup.comps[id].state
		if s == .Unavailable {continue}
		if !is_done(s) {return false}
		n += 1
	}
	return n > 0
}

@(private = "file")
needs_attention :: proc(s: Comp_State) -> bool {return s == .Outdated || s == .Partial || s == .Stopped}

// One summary tile: caption, big value, optional sub line and progress bar.
@(private = "file")
stat_tile :: proc(id: string, w: f32, icon, caption, value, sub: string, accent: u32, progress: f32 = -1, clickable := false) -> (clicked: bool) {
	card_begin(id, w)
	p := im.GetCursorScreenPos()
	iw := im.GetContentRegionAvail().x
	// All tiles share one height; without a bar the content sits centered.
	TILE_H :: 51
	if progress < 0 {p.y += 5}
	im.DrawList_AddCircleFilled(dl(), {p.x + 17, p.y + 19}, 17, col32(accent, 0.16))
	draw_icon_centered(fonts.ui, 18, {p.x + 17, p.y + 19}, col32(accent), icon)
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
	if clickable {
		clicked = im.InvisibleButton("##click", {iw, TILE_H})
		if im.IsItemHovered() {im.SetMouseCursor(.Hand)}
	} else {
		im.Dummy({iw, TILE_H})
	}
	card_end()
	return
}

// The overview's count tiles and its to-do rows open the page of a component
// that isn't set up, whose card then pulses for a few seconds (scrolled into
// view first).
@(private = "file")
pulse: struct {
	at:     time.Tick,
	scroll: bool,
}
@(private = "file") PULSE_FOR :: 3 * time.Second

// How bright the pulse ring is now, and whether a pulse runs at all.
@(private = "file")
pulse_alpha :: proc() -> (a: f32, on: bool) {
	if pulse.at == {} {return}
	t := time.tick_since(pulse.at)
	if t >= PULSE_FOR {return}
	request_redraw(2)
	// Three beats, fading out over the last one.
	ph := f32(time.duration_seconds(t))
	beat := 0.5 - 0.5 * math.cos(ph * 2 * math.PI)
	fade := clamp(f32(time.duration_seconds(PULSE_FOR)) - ph, 0, 1)
	return beat * fade, true
}

// Open a page (search cleared), optionally pulsing its cards that aren't set up.
@(private = "file")
go_page :: proc(p: Setup_Page, pulse_todo := false) {
	setup_page = p
	setup_search[0] = 0
	if pulse_todo {pulse = {time.tick_now(), true}}
}

// The cards whose details are shown (description, files, key editor).
@(private = "file")
expanded: [Comp_Id]bool

@(private = "file")
comp_matches :: proc(id: Comp_Id, filter: string) -> bool {
	if filter == "" {return true}
	inf := info(id)
	for f in ([]string{inf.title, inf.desc}) {
		if strings.contains(strings.to_lower(f, context.temp_allocator), filter) {return true}
	}
	return false
}

// A tooltip wrapped to `width`.
@(private = "file")
tip_wrapped :: proc(s: string, width: f32) {
	im.PushStyleVarImVec2(.WindowPadding, {10, 6})
	if im.BeginTooltip() {
		im.PushTextWrapPos(width)
		label(fonts.ui, SZ_SMALL, col32(C_TEXT), s)
		im.PopTextWrapPos()
		im.EndTooltip()
	}
	im.PopStyleVar()
}

// One component card: a line with its icon, name, state and actions; the
// chevron (or a click on the name) shows what it does, its files and, for
// sway, the key editor. Returns the action to run if one was clicked.
@(private = "file")
comp_card :: proc(id: Comp_Id, c: ^Component, width: f32) -> (run: proc()) {
	inf := info(id)
	card_begin(fmt.tprintf("comp:%v", id), width)
	inner := im.GetContentRegionAvail().x
	cp := im.GetCursorScreenPos()

	// Accent strip along the left edge of the card.
	wp := im.GetWindowPos()
	ws := im.GetWindowSize()
	im.DrawList_PushClipRect(dl(), wp, wp + ws, false)
	im.DrawList_AddRectFilled(dl(), {wp.x + 1, wp.y + 1}, {wp.x + 4, wp.y + ws.y - 1}, col32(inf.accent, 0.6), 6, im.DrawFlags_RoundCornersLeft)
	im.DrawList_PopClipRect(dl())

	ROW :: 30
	CHEV :: 26
	// Sway's keys clash: the key editor (in the details) is how to fix that.
	keys := id == .Sway && c.state != .Custom && c.state != .Unavailable
	open := expanded[id] || keys && sway_keys_clash_count() > 0

	// The line: badge, name, state.
	im.DrawList_AddCircleFilled(dl(), {cp.x + 15, cp.y + ROW / 2}, 15, col32(inf.accent, 0.16))
	draw_icon_centered(fonts.ui, 16, {cp.x + 15, cp.y + ROW / 2}, col32(inf.accent), inf.icon)
	tx := cp.x + 40
	tsz := measure(fonts.bold, 15, inf.title)
	draw_text(fonts.bold, 15, {tx, cp.y + (ROW - tsz.y) / 2}, col32(C_TEXT), inf.title)
	stext, scol := state_pill(c.state, id)
	ssz := measure(fonts.bold, 11, stext)
	sx, sy := tx + tsz.x + 10, cp.y + (ROW - 18) / 2
	im.DrawList_AddCircleFilled(dl(), {sx + 9, sy + 9}, 3, col32(scol))
	im.DrawList_AddRectFilled(dl(), {sx, sy}, {sx + ssz.x + 24, sy + 18}, col32(scol, 0.14), 9)
	draw_text(fonts.bold, 11, {sx + 17, sy + 2}, col32(scol), stext)
	head_end := sx + ssz.x + 24
	im.SetCursorScreenPos(cp)
	if im.InvisibleButton(cstr(fmt.tprintf("##head:%v", id)), {head_end - cp.x, ROW}) {expanded[id] = !expanded[id]}
	if im.IsItemHovered() {
		im.SetMouseCursor(.Hand)
		if !open {tip_wrapped(inf.desc, 440)}
	}

	// The chevron, at the right end.
	chx := cp.x + inner - CHEV
	im.SetCursorScreenPos({chx, cp.y + (ROW - CHEV) / 2})
	if im.InvisibleButton(cstr(fmt.tprintf("##more:%v", id)), {CHEV, CHEV}) {expanded[id] = !expanded[id]}
	chov := im.IsItemHovered()
	if chov {
		im.SetMouseCursor(.Hand)
		tip(open ? "Hide the details" : "Details: what it does, its files")
		im.DrawList_AddRectFilled(dl(), {chx, cp.y + (ROW - CHEV) / 2}, {chx + CHEV, cp.y + (ROW + CHEV) / 2}, col32(C_OVERLAY, 0.07), 7)
	}
	draw_icon_centered(fonts.ui, 18, {chx + CHEV / 2, cp.y + ROW / 2}, col32(chov ? C_TEXT : C_MUTED), open ? ICON_CHEVRON_DOWN : ICON_CHEVRON_RIGHT)

	// Actions: right-aligned on the line when they fit, else under it (wrapping).
	acts := actions_for(id, c.state)
	if armed.index >= 0 && time.tick_since(armed.at) > 4 * time.Second {armed.index = -1}
	labels := make([]string, len(acts), context.temp_allocator)
	total: f32
	for a, i in acts {
		is_armed := armed.index == i && armed.id == id
		labels[i] = is_armed ? fmt.tprintf("Really %s?", strings.to_lower(a.label, context.temp_allocator)) : a.label
		total += pill_width(labels[i]) + (i > 0 ? 8 : 0)
	}
	right := chx - 8
	bottom := cp.y + ROW
	if c.busy {
		w := measure(fonts.ui, SZ_SMALL, "working…").x
		draw_text(fonts.ui, SZ_SMALL, {right - w, cp.y + 8}, col32(C_ORANGE), "working…")
	} else if len(acts) > 0 {
		ax, row_y := right - total, cp.y + 1
		start := ax
		if ax < head_end + 16 {
			ax, row_y = tx, cp.y + ROW + 6
			start = tx
		}
		for a, i in acts {
			lw := pill_width(labels[i])
			if ax > start && ax + lw > cp.x + inner {
				ax = tx
				row_y += 34
			}
			im.SetCursorScreenPos({ax, row_y})
			is_armed := armed.index == i && armed.id == id
			if pill_button(fmt.tprintf("##%v:%d", id, i), labels[i], is_armed ? C_RED : inf.accent, a.primary || is_armed) {
				if !a.confirm || is_armed {
					run = a.run
					armed.index = -1
				} else {
					armed = {id, i, time.tick_now()}
				}
			}
			ax += lw + 8
		}
		bottom = max(bottom, row_y + 28)
	}
	im.SetCursorScreenPos({cp.x, bottom})
	im.Dummy({inner, 0})

	// The last action's result stays in view.
	if c.message != "" {
		im.SetCursorScreenPos({tx, im.GetCursorScreenPos().y})
		wrapped(fonts.ui, SZ_SMALL, c.msg_ok ? C_GREEN : C_RED, fmt.tprintf("%s %s", c.msg_ok ? ICON_CHECK : ICON_ALERT, c.message), inner - 40)
	}
	if open {
		im.Dummy({1, 2})
		wrapped(fonts.ui, SZ_BODY, C_MUTED, inf.desc, inner)
		for line in c.detail {wrapped(fonts.mono, SZ_SMALL, C_FAINT, line, inner)}
		if keys {sway_keys_ui(inner, inf.accent)}
		if inf.preview != "" {
			lbl := show_preview[id] ? "Hide file" : "Show file"
			lsz := measure(fonts.ui, SZ_SMALL, lbl)
			lp := im.GetCursorScreenPos()
			if im.InvisibleButton(cstr(fmt.tprintf("##prev:%v", id)), lsz + {0, 4}) {show_preview[id] = !show_preview[id]}
			if im.IsItemHovered() {im.SetMouseCursor(.Hand)}
			draw_text(fonts.ui, SZ_SMALL, {lp.x, lp.y + 1}, col32(inf.accent, 0.9), lbl)
			if show_preview[id] {
				text := strings.trim_space(inf.preview)
				im.PushStyleColorImVec4(.ChildBg, rgba(C_WELL))
				im.PushStyleVarImVec2(.WindowPadding, {12, 10})
				im.BeginChild(cstr(fmt.tprintf("##code:%v", id)), {inner, 0}, {.AutoResizeY, .AlwaysUseWindowPadding}, {})
				wrapped(fonts.mono, SZ_SMALL, C_TEXT, text, inner - 24)
				im.EndChild()
				im.PopStyleVar()
				im.PopStyleColor()
			}
		}
	}
	card_end()
	return
}

// A pulsing ring around the card just drawn, while a pulse runs; the first
// one scrolls the page so the card is in view.
@(private = "file")
pulse_ring :: proc(col: u32) {
	a, on := pulse_alpha()
	if !on {return}
	r0, r1 := im.GetItemRectMin(), im.GetItemRectMax()
	if pulse.scroll {
		pulse.scroll = false
		wy, wh := im.GetWindowPos().y, im.GetWindowSize().y
		if r0.y < wy || r1.y > wy + wh {im.SetScrollFromPosY(r0.y - wy, 0.25)}
	}
	rad := im.GetStyle().ChildRounding
	grow := 1 + 3 * a
	im.DrawList_AddRect(dl(), r0 - grow, r1 + grow, col32(col, 0.25 + 0.65 * a), rad + grow, 1.5 + 1.5 * a)
}

// Narrowest column of component cards; as many as fit, up to MAX_COLS.
@(private = "file") COMP_MIN_COL :: 520
// Gap between the visible window edge and the imgui window: the inner resize strip.
@(private = "file") FRAME_INSET :: 6
MAX_COLS :: 6
@(private = "file") GAP :: 14

// Columns of at least `min_col` that fit `width` (1..MAX_COLS).
fit_columns :: proc(width, min_col, gap: f32) -> int {
	return clamp(int((width + gap) / (min_col + gap)), 1, MAX_COLS)
}

// Cards of the components `ids` that match `filter`, from (x, y), in
// columns; card i always goes into column i % columns, so opening one never
// moves the others. Returns the clicked action and the bottom edge.
@(private = "file")
draw_comp_cards :: proc(x, y, width: f32, ids: []Comp_Id, filter: string) -> (run: proc(), bottom: f32) {
	bottom = y
	shown := make([dynamic]Comp_Id, context.temp_allocator)
	for id in ids {if comp_matches(id, filter) {append(&shown, id)}}
	if len(shown) == 0 {return}
	ncols := min(fit_columns(width, COMP_MIN_COL, GAP), len(shown))
	cw := (width - GAP * f32(ncols - 1)) / f32(ncols)
	cols := make([]f32, ncols, context.temp_allocator)
	for &b in cols {b = y}
	sync.guard(&setup.mu)
	for id, i in shown {
		k := i % ncols
		im.SetCursorScreenPos({x + f32(k) * (cw + GAP), cols[k]})
		if r := comp_card(id, &setup.comps[id], cw); r != nil {run = r}
		if s := setup.comps[id].state; is_todo(s) {pulse_ring(needs_attention(s) ? C_ORANGE : C_BLUE)}
		cols[k] = im.GetItemRectMax().y + GAP
	}
	for b in cols {bottom = max(bottom, b)}
	bottom -= GAP
	im.SetCursorScreenPos({x, bottom})
	im.Dummy({width, 0})
	return
}

// A small caps label over a section, with an optional note after it.
@(private = "file")
section_label :: proc(x, y, width: f32, text: string, note := "") -> f32 {
	caps := strings.to_upper(text, context.temp_allocator)
	draw_text(fonts.bold, SZ_SMALL, {x + 2, y}, col32(C_FAINT), caps)
	if note != "" {
		nx := x + 2 + measure(fonts.bold, SZ_SMALL, caps).x + 14
		if nx + measure(fonts.ui, SZ_SMALL, note).x <= x + width {draw_text(fonts.ui, SZ_SMALL, {nx, y}, col32(C_FAINT), note)}
	}
	return y + 24
}

// Components not set up yet, the ones needing attention first.
@(private = "file")
todo_list :: proc() -> []Comp_Id {
	out := make([dynamic]Comp_Id, context.temp_allocator)
	sync.guard(&setup.mu)
	for id in Comp_Id {if needs_attention(setup.comps[id].state) {append(&out, id)}}
	for id in Comp_Id {if s := setup.comps[id].state; is_todo(s) && !needs_attention(s) {append(&out, id)}}
	return out[:]
}

// For the sidebar: how many of a page's components aren't set up, and
// whether one of them needs attention.
@(private = "file")
page_todo :: proc(p: Setup_Page) -> (n: int, attention: bool) {
	sync.guard(&setup.mu)
	ids := SETUP_PAGES[p].comps
	if p == .Overview {
		for id in Comp_Id {if is_todo(setup.comps[id].state) {n += 1}; attention ||= needs_attention(setup.comps[id].state)}
		return
	}
	for id in ids {
		s := setup.comps[id].state
		if is_todo(s) {n += 1}
		attention ||= needs_attention(s)
	}
	return
}

// For the sidebar while searching: matching cards and settings on a page.
@(private = "file")
page_matches :: proc(p: Setup_Page, filter: string) -> int {
	n := settings_match_count(p, filter)
	for id in SETUP_PAGES[p].comps {if comp_matches(id, filter) {n += 1}}
	return n
}

// ---- Overview ----------------------------------------------------------------------

@(private = "file")
update_checking: bool

@(private = "file")
draw_overview :: proc(x, y, width: f32) -> (run: proc()) {
	// ---- Summary tiles: one row of four, or two rows of two ----------------
	done, applicable, attention, missing := 0, 0, 0, 0
	svc_text, ntf_text: string
	svc_col, ntf_col: u32
	{
		sync.guard(&setup.mu)
		for id in Comp_Id {
			s := setup.comps[id].state
			if s == .Unavailable {continue}
			applicable += 1
			if is_done(s) {done += 1}
			if needs_attention(s) {attention += 1}
			if s == .Missing {missing += 1}
		}
		svc_text, svc_col = state_pill(setup.comps[.Service].state)
		ntf_text, ntf_col = state_pill(setup.comps[.Notifications].state)
	}
	per_row := width >= 4 * 210 + 3 * GAP ? 4 : 2
	tw := (width - GAP * f32(per_row - 1)) / f32(per_row)
	ty := y
	tiles := [4]struct {
		icon, caption, value, sub: string,
		accent:                    u32,
		progress:                  f32,
	} {
		// Green like the installed components once everything is set up.
		{ICON_CHECK, "Set up", fmt.tprintf("%d / %d", done, applicable), "components", applicable > 0 && done == applicable ? C_GREEN : C_BLUE, applicable > 0 ? f32(done) / f32(applicable) : 0},
		{ICON_POWER, "Daemon", svc_text, "", svc_col, -1},
		{ICON_BELL, "Notifications", ntf_text, "", ntf_col, -1},
		attention > 0 ? {ICON_ALERT, "Needs attention", fmt.tprintf("%d", attention), attention == 1 ? "component" : "components", C_ORANGE, -1} : missing > 0 ? {ICON_HOME, "Not installed", fmt.tprintf("%d", missing), "optional", C_MUTED, -1} : {ICON_CHECK, "Nothing left", "all set", "", C_GREEN, -1},
	}
	todo := todo_list()
	tile_h: f32 = 0
	for t, i in tiles {
		if i > 0 && i % per_row == 0 {ty += tile_h + GAP}
		im.SetCursorScreenPos({x + f32(i % per_row) * (tw + GAP), ty})
		// The count tiles open the first page with something to set up.
		clickable := len(todo) > 0 && (i == 0 || i == 3)
		if stat_tile(fmt.tprintf("tile:%d", i), tw, t.icon, t.caption, t.value, t.sub, t.accent, t.progress, clickable) {
			go_page(comp_page(todo[0]), true)
		}
		if clickable && im.IsItemHovered() {tip(fmt.tprintf("Open %s, where %s is", SETUP_PAGES[comp_page(todo[0])].title, info(todo[0]).title))}
		tile_h = max(tile_h, im.GetItemRectSize().y)
	}
	top := ty + tile_h + 18

	// ---- To do, and updates --------------------------------------------------------
	two := width >= 2 * SETTINGS_MIN_COL + GAP
	uw: f32 = two ? clamp(width * 0.36, SETTINGS_MIN_COL, 520) : width
	lw := two ? width - uw - GAP : width
	im.SetCursorScreenPos({x, top})
	card_begin("##todo", lw)
	inner := im.GetContentRegionAvail().x
	card_title(len(todo) > 0 ? ICON_ALERT : ICON_CHECK, "To do", len(todo) > 0 ? (attention > 0 ? C_ORANGE : C_BLUE) : C_GREEN, fmt.tprintf("%d of %d set up", done, applicable))
	if len(todo) == 0 {
		wrapped(fonts.ui, SZ_BODY, C_MUTED, "Everything that applies here is set up. The pages on the left hold each part's settings.", inner)
	}
	for id, k in todo {
		if k > 0 {
			lp := im.GetCursorScreenPos()
			im.DrawList_AddLine(dl(), {lp.x, lp.y + 1}, {lp.x + inner, lp.y + 1}, col32(C_BORDER), 1)
			im.Dummy({inner, 4})
		}
		inf := info(id)
		state: Comp_State
		{
			sync.guard(&setup.mu)
			state = setup.comps[id].state
		}
		rp := im.GetCursorScreenPos()
		RH :: 30
		im.DrawList_AddCircleFilled(dl(), {rp.x + 13, rp.y + RH / 2}, 13, col32(inf.accent, 0.16))
		draw_icon_centered(fonts.ui, 15, {rp.x + 13, rp.y + RH / 2}, col32(inf.accent), inf.icon)
		draw_text(fonts.bold, SZ_BODY, {rp.x + 36, rp.y + 6}, col32(C_TEXT), inf.title)
		stext, scol := state_pill(state, id)
		sx := rp.x + 36 + measure(fonts.bold, SZ_BODY, inf.title).x + 10
		ssz := measure(fonts.bold, 11, stext)
		im.DrawList_AddRectFilled(dl(), {sx, rp.y + 6}, {sx + ssz.x + 16, rp.y + 24}, col32(scol, 0.14), 9)
		draw_text(fonts.bold, 11, {sx + 8, rp.y + 8}, col32(scol), stext)
		pg := comp_page(id)
		open := fmt.tprintf("%s  %s", SETUP_PAGES[pg].title, ICON_CHEVRON_RIGHT)
		ow := pill_width(open)
		where_x := sx + ssz.x + 26
		im.SetCursorScreenPos({rp.x + inner - ow, rp.y + 1})
		if pill_button(fmt.tprintf("##todo:%v", id), open, page_accent(pg)) {go_page(pg, true)}
		if im.IsItemHovered() {tip(fmt.tprintf("Open %s: %s", SETUP_PAGES[pg].title, SETUP_PAGES[pg].sub))}
		_ = where_x
		im.SetCursorScreenPos({rp.x, rp.y + RH})
		im.Dummy({inner, 2})
	}
	card_end()
	left_bottom := im.GetItemRectMax().y

	ux := two ? x + lw + GAP : x
	uy := two ? top : left_bottom + GAP
	im.SetCursorScreenPos({ux, uy})
	card_begin("##updates", uw)
	inner = im.GetContentRegionAvail().x
	when RELEASE_BUILD {build := "release build"} else {build := "dev build"}
	ucol, utip, uhi := update_button_info()
	card_title(ICON_UPDATE, "Updates", uhi ? ucol : C_GREEN, fmt.tprintf("wlperch %s · %s", VERSION, build))
	wrapped(fonts.ui, SZ_BODY, uhi ? ucol : C_MUTED, strings.trim_suffix(strings.trim_suffix(utip, "\nclick to check again"), "\nclick to try again"), inner)
	im.Dummy({1, 2})
	if pill_button("##upd-check", update_checking ? "Checking…" : "Check now", C_GREEN) && !update_checking {
		update_checking = true
		thread.create_and_start(proc() {
			update_check_now()
			update_checking = false
			free_all(context.temp_allocator)
			wake_main()
		}, self_cleanup = true)
	}
	if update_available() {
		im.SameLine(0, 8)
		if pill_button("##upd-install", "Install", C_GREEN, true) {launch_detached({setup.self_path, "update"})}
		if im.IsItemHovered() {tip("Downloads the release, checks it against SHA256SUMS, replaces ~/.local/bin/wlperch and restarts the daemon")}
	}
	im.SameLine(0, 8)
	if pill_button("##upd-settings", "Settings", C_GREEN) {go_page(.Basics)}
	if im.IsItemHovered() {tip("The daily check: Basics, Updates")}
	card_end()
	bottom := max(left_bottom, im.GetItemRectMax().y)
	im.SetCursorScreenPos({x, bottom})
	im.Dummy({width, 0})
	return
}

// ---- Pages -------------------------------------------------------------------------

// A page under its header: its cards, its settings and, on Look, the wallpapers.
@(private = "file")
draw_page :: proc(page: Setup_Page, x, y, width: f32) -> (run: proc()) {
	if page == .Overview {return draw_overview(x, y, width)}
	pi := SETUP_PAGES[page]
	y := y
	if len(pi.comps) > 0 {
		y = section_label(x, y, width, "Set up")
		r, b := draw_comp_cards(x, y, width, pi.comps, "")
		if r != nil {run = r}
		y = b + 26
	}
	if len(pi.groups) > 0 {
		y = section_label(x, y, width, "Settings", SETTINGS_NOTE)
		draw_settings(x, y, width, page, "")
		y = im.GetCursorScreenPos().y + 26
	}
	switch page {
	case .Time:
		im.SetCursorScreenPos({x + 2, y - 12})
		wrapped(fonts.ui, SZ_SMALL, C_FAINT, "Projects (names, colours, rates, Claude's work), the timeline and the export are in the Time panel. More keys ([project.NAME] sections) are in config.ini: Basics, Settings file, Open.", width)
	case .Look:
		y = section_label(x, y, width, "Wallpapers")
		if setup_scroll_wallpapers {
			im.SetCursorScreenPos({x, y - 24})
			im.SetScrollHereY(0)
			// Again until the settings above have their final height.
			@(static) frames := 0
			frames += 1
			if frames > 4 {setup_scroll_wallpapers = false}
			request_redraw(1)
		}
		draw_wallpapers(x, y, width)
	case .Overview, .Basics, .Bar, .Lock, .Notifications, .Launcher, .Ssh:
	}
	return
}

// Searching: the matching cards and settings of every page, under the page's name.
@(private = "file")
draw_results :: proc(x, y, width: f32, filter: string) -> (run: proc()) {
	y := y
	any := false
	for page in Setup_Page {
		if page == .Overview || page_matches(page, filter) == 0 {continue}
		any = true
		pi := SETUP_PAGES[page]
		acc := page_accent(page)
		// The page's name: a click opens it.
		tsz := measure(fonts.bold, 17, pi.title)
		im.SetCursorScreenPos({x, y})
		if im.InvisibleButton(cstr(fmt.tprintf("##res:%v", page)), {tsz.x + 60, 26}) {go_page(page)}
		hov := im.IsItemHovered()
		if hov {
			im.SetMouseCursor(.Hand)
			tip(fmt.tprintf("Open %s", pi.title))
		}
		draw_icon_centered(fonts.ui, 17, {x + 10, y + 12}, col32(acc), pi.icon)
		draw_text(fonts.bold, 17, {x + 28, y + 2}, col32(hov ? acc : C_TEXT), pi.title)
		draw_text(fonts.ui, 15, {x + 36 + tsz.x, y + 4}, col32(C_FAINT), ICON_CHEVRON_RIGHT)
		y += 34
		if r, b := draw_comp_cards(x, y, width, pi.comps, filter); b > y {
			if r != nil {run = r}
			y = b + GAP
		}
		if settings_match_count(page, filter) > 0 {
			draw_settings(x, y, width, page, filter)
			y = im.GetCursorScreenPos().y + GAP
		}
		y += 14
	}
	if !any {
		im.SetCursorScreenPos({x + 2, y})
		wrapped(fonts.ui, SZ_BODY, C_MUTED, "Nothing matches. The rest of config.ini (panels, sensors, display presets, projects) is edited by hand: Basics, Settings file, Open.", width)
	}
	return
}

// ---- Sidebar -----------------------------------------------------------------------

@(private = "file")
focus_search: bool

@(private = "file")
search_box :: proc(width: f32) {
	p := im.GetCursorScreenPos()
	im.PushFontFloat(fonts.ui, SZ_BODY)
	im.PushStyleVarImVec2(.FramePadding, {32, 7})
	im.PushStyleVar(.FrameRounding, 9)
	im.PushStyleVar(.FrameBorderSize, 1)
	im.PushStyleColorImVec4(.FrameBg, rgba(C_WELL))
	im.PushStyleColorImVec4(.FrameBgHovered, rgba(C_WELL))
	im.PushStyleColorImVec4(.FrameBgActive, rgba(C_WELL))
	im.PushStyleColorImVec4(.Border, rgba(C_BORDER))
	im.PushStyleColorImVec4(.TextDisabled, rgba(C_FAINT))
	im.SetNextItemWidth(width)
	if focus_search {
		im.SetKeyboardFocusHere()
		focus_search = false
	}
	im.InputTextWithHint("##setup-search", "Search…", cstring(&setup_search[0]), len(setup_search), {.EscapeClearsAll})
	if im.IsItemHovered() && !im.IsItemActive() {tip("Search every page's settings and parts (Ctrl+F)")}
	im.PopStyleColor(5)
	im.PopStyleVar(3)
	im.PopFont()
	draw_text(fonts.ui, 16, {p.x + 10, p.y + 7}, col32(C_MUTED), ICON_MAGNIFY)
}

// The sidebar: the logo, the search box and a row per page, with a badge
// counting what's left to set up (orange: something needs attention), or the
// matches while searching. Narrow windows get icons only.
@(private = "file")
draw_sidebar :: proc(p: Vec2, w, h: f32, compact: bool, filter: string) {
	d := dl()
	im.DrawList_AddRectFilled(d, p, {p.x + w, p.y + h}, col32(C_CARD), 14)
	im.DrawList_AddRect(d, p, {p.x + w, p.y + h}, col32(C_BORDER), 14)
	pad: f32 = compact ? 8 : 12
	x, y := p.x + pad, p.y + 14
	iw := w - 2 * pad

	// Logo.
	lx := compact ? p.x + w / 2 : x + 18
	im.DrawList_AddCircleFilled(d, {lx, y + 18}, 18, col32(C_BLUE, 0.16))
	draw_icon_centered(fonts.ui, 20, {lx, y + 18}, col32(C_BLUE), ICON_TUNE_BAR)
	if !compact {
		draw_text(fonts.bold, 20, {x + 46, y + 1}, col32(C_TEXT), "wlperch")
		draw_text(fonts.ui, SZ_SMALL, {x + 46, y + 23}, col32(C_FAINT), fmt.tprintf("setup · %s", VERSION))
	}
	y += 52
	if !compact {
		im.SetCursorScreenPos({x, y})
		search_box(iw)
		y += 46
	} else {
		y += 4
	}

	ITEM_H :: 36
	for page in Setup_Page {
		pi := SETUP_PAGES[page]
		acc := page_accent(page)
		active := filter == "" && page == setup_page
		count, attention := 0, false
		dim := false
		if filter != "" {
			if page == .Overview {dim = true} else {
				count = page_matches(page, filter)
				dim = count == 0
			}
		} else {
			count, attention = page_todo(page)
		}
		im.SetCursorScreenPos({x, y})
		if im.InvisibleButton(cstr(fmt.tprintf("##page:%v", page)), {iw, ITEM_H - 2}) {go_page(page)}
		hov := im.IsItemHovered()
		if hov {
			im.SetMouseCursor(.Hand)
			if compact {tip(pi.title)}
		}
		switch {
		case active: im.DrawList_AddRectFilled(d, {x, y}, {x + iw, y + ITEM_H - 2}, col32(acc, 0.16), 9)
		case hov:    im.DrawList_AddRectFilled(d, {x, y}, {x + iw, y + ITEM_H - 2}, col32(C_OVERLAY, 0.06), 9)
		}
		alpha: f32 = dim ? 0.4 : 1
		ix := compact ? x + iw / 2 : x + 16
		draw_icon_centered(fonts.ui, 17, {ix, y + (ITEM_H - 2) / 2}, col32(active ? acc : C_MUTED, alpha), pi.icon)
		if !compact {
			draw_text(active ? fonts.bold : fonts.ui, SZ_BODY + 1, {x + 36, y + 8}, col32(active ? C_TEXT : C_TEXT, alpha * (active ? 1 : 0.85)), pi.title)
		}
		if count > 0 {
			bc: u32 = filter != "" ? C_MUTED : (attention ? C_ORANGE : C_BLUE)
			txt := fmt.tprintf("%d", count)
			tsz := measure(fonts.bold, 11, txt)
			bw := max(tsz.x + 10, 18)
			bx := compact ? x + iw - bw + 6 : x + iw - bw - 8
			by := compact ? y - 3 : y + (ITEM_H - 2 - 18) / 2
			im.DrawList_AddRectFilled(d, {bx, by}, {bx + bw, by + 18}, col32(bc, filter != "" ? 0.18 : 0.9), 9)
			draw_text(fonts.bold, 11, {bx + (bw - tsz.x) / 2, by + 2}, filter != "" ? col32(C_TEXT) : col32(0x111318), txt)
			if hov && !compact && filter == "" {
				tip(page == .Overview ? fmt.tprintf("%d part%s not set up yet", count, count == 1 ? "" : "s") : fmt.tprintf("%d part%s here not set up yet%s", count, count == 1 ? "" : "s", attention ? ", one needs attention" : ""))
			}
		}
		y += ITEM_H
	}
}

// ---- The window --------------------------------------------------------------------

draw_setup :: proc() {
	filter := setup_search_filter()
	// Ctrl+F searches; Escape leaves a text field first, then clears the
	// search, and only then closes the window.
	if im.GetIO().KeyCtrl && im.IsKeyPressed(.F, false) {focus_search = true}
	if im.IsKeyPressed(.Escape, false) && !im.IsAnyItemActive() {
		if filter != "" {setup_search[0] = 0} else {plat.closed = true}
	}

	// The window's own frame: a rounded card with a shadow while floating,
	// a plain rectangle filling its tile otherwise.
	fpos, fsize, rounded := platform_window_frame()
	bg := im.GetBackgroundDrawList()
	if rounded {
		draw_shadow(fpos, fsize, WIN_SHADOW - 3, 3, WIN_RADIUS)
		im.DrawList_AddRectFilled(bg, fpos, fpos + fsize, col32(C_BG), WIN_RADIUS)
		im.DrawList_AddRect(bg, fpos, fpos + fsize, window_border_color(0.07), WIN_RADIUS)
	} else {
		im.DrawList_AddRectFilled(bg, fpos, fpos + fsize, col32(C_BG))
	}
	im.SetNextWindowPos(fpos + FRAME_INSET)
	im.SetNextWindowSize(fsize - 2 * FRAME_INSET)
	im.PushStyleColorImVec4(.WindowBg, rgba(C_BG, 0))
	im.PushStyleVar(.WindowRounding, rounded ? WIN_RADIUS - FRAME_INSET : 0)
	im.PushStyleVar(.WindowBorderSize, 0)
	im.PushStyleVarImVec2(.WindowPadding, {20 - FRAME_INSET, 20 - FRAME_INSET})
	im.Begin("setup", nil, {.NoTitleBar, .NoResize, .NoMove, .NoCollapse, .NoSavedSettings, .NoScrollbar, .NoScrollWithMouse})
	im.PopStyleVar(3)
	im.PopStyleColor()

	origin := im.GetCursorScreenPos()
	full := im.GetContentRegionAvail()
	// Narrow windows: icons only, the search box above the page.
	compact := full.x < 1000
	side_w: f32 = compact ? 56 : 224
	draw_sidebar(origin, side_w, full.y, compact, filter)

	// Thumbnail textures only while the wallpapers show.
	if !(setup_page == .Look && filter == "") {wallpapers_release()}

	// ---- The page: scrolls on its own, the sidebar stays -------------------------
	cx := origin.x + side_w + 20
	im.SetCursorScreenPos({cx, origin.y})
	im.PushStyleColorImVec4(.ChildBg, rgba(C_BG, 0))
	im.PushStyleVarImVec2(.WindowPadding, {0, 0})
	im.BeginChild("##page", {origin.x + full.x - cx, full.y}, {}, {})
	im.PopStyleVar()
	im.PopStyleColor()
	@(static) shown_page := Setup_Page.Overview
	@(static) was_searching := false
	if shown_page != setup_page || was_searching != (filter != "") {
		im.SetScrollY(0)
		shown_page, was_searching = setup_page, filter != ""
	}
	// Room for the scrollbar on the right.
	width := im.GetContentRegionAvail().x - 14
	p := im.GetCursorScreenPos()

	// ---- Header -----------------------------------------------------------------
	right := p.x + width
	icon, title, sub: string
	acc := page_accent(setup_page)
	if filter != "" {
		n := 0
		for page in Setup_Page {if page != .Overview {n += page_matches(page, filter)}}
		icon, title, acc = ICON_MAGNIFY, "Search", C_BLUE
		sub = fmt.tprintf("%d match%s for “%s” · Escape clears", n, n == 1 ? "" : "es", strings.trim_space(string(cstring(raw_data(setup_search[:])))))
	} else {
		pi := SETUP_PAGES[setup_page]
		icon, title, sub = pi.icon, pi.title, pi.sub
	}
	if compact {
		sw := min(f32(280), width * 0.45)
		right -= sw
		im.SetCursorScreenPos({right, p.y + 7})
		search_box(sw)
		right -= 14
	}
	if setup_page == .Overview && filter == "" && len(todo_list()) > 0 {
		rec := "Install recommended"
		right -= pill_width(rec)
		im.SetCursorScreenPos({right, p.y + 8})
		if pill_button("##recommended", rec, C_BLUE, true) {
			setup_install_recommended()
			setup_check()
		}
		if im.IsItemHovered() {tip("Installs the parts most setups want, with backups of what they change")}
		right -= 14
	}
	im.DrawList_AddCircleFilled(dl(), {p.x + 22, p.y + 22}, 22, col32(acc, 0.16))
	draw_icon_centered(fonts.ui, 22, {p.x + 22, p.y + 22}, col32(acc), icon)
	draw_text(fonts.bold, 24, {p.x + 56, p.y - 1}, col32(C_TEXT), title)
	if p.x + 56 + measure(fonts.ui, SZ_BODY, sub).x + 16 <= right {
		draw_text(fonts.ui, SZ_BODY, {p.x + 56, p.y + 27}, col32(C_MUTED), sub)
	}
	top := p.y + 66

	run: proc()
	if filter != "" {
		run = draw_results(p.x, top, width, filter)
	} else {
		run = draw_page(setup_page, p.x, top, width)
	}
	if run != nil {
		run()
		setup_check()
	}
	im.Dummy({1, 12})
	log_content_height()
	im.EndChild()
	im.End()
}

// Debug: how tall the content is against the window (does it scroll?).
@(private = "file")
log_content_height :: proc() {
	@(static) last: [4]f32
	cur := [4]f32{im.GetCursorPosY(), im.GetWindowSize().y, im.GetScrollMaxY(), f32(plat.win.w)}
	if cur != last {
		last = cur
		log.debugf("setup %v: content %.0f, scrolls %.0f (window %dx%d)", setup_page, cur.x, cur.z, plat.win.w, plat.win.h)
	}
}
