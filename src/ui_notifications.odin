// Notification center: history grouped by day, do not disturb, clear.
package main

import "core:fmt"
import "core:strings"
import "core:time"

import im "third_party:odin-imgui"
import gl "vendor:OpenGL"

// Notifications that were unread when the panel opened keep their dot while it's open.
@(private = "file") fresh: map[u32]bool
// Groups opened past their first few messages, by their newest entry's id.
@(private = "file") expanded: map[u32]bool

// GL texture for an icon (straight alpha, as imgui blends), made on first use.
// Also used by the media card.
icon_texture :: proc(ic: ^Notif_Icon) -> im.TextureID {
	if ic.tex != 0 && !ic.stale {return im.TextureID(ic.tex)}
	rgba := make([]u8, ICON_PX * ICON_PX * 4, context.temp_allocator)
	for p, i in ic.px {
		a := p >> 24
		un :: proc(v, a: u32) -> u8 {return a == 0 ? 0 : u8(min(v * 255 / a, 255))}
		rgba[i * 4 + 0] = un((p >> 16) & 0xff, a)
		rgba[i * 4 + 1] = un((p >> 8) & 0xff, a)
		rgba[i * 4 + 2] = un(p & 0xff, a)
		rgba[i * 4 + 3] = u8(a)
	}
	if ic.tex == 0 {gl.GenTextures(1, &ic.tex)}
	ic.stale = false
	gl.BindTexture(gl.TEXTURE_2D, ic.tex)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA, ICON_PX, ICON_PX, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(rgba))
	return im.TextureID(ic.tex)
}

// The GL context went away: textures are gone with it.
notif_textures_reset :: proc() {
	for _, ic in icon_cache {ic.tex = 0}
}

@(private = "file")
draw_badge :: proc(n: ^Notification, p: Vec2, size: f32) {
	d := dl()
	if n.icon != nil {
		im.DrawList_AddImageRounded(d, im.TextureRef{_TexID = icon_texture(n.icon)}, p, {p.x + size, p.y + size}, {0, 0}, {1, 1}, 0xffffffff, n.icon.rounded ? size * 8 / 35 : 0)
		return
	}
	col := app_color(n.app)
	im.DrawList_AddCircleFilled(d, {p.x + size / 2, p.y + size / 2}, size / 2, col32(col, 0.2))
	ini := app_initial(n.app)
	px := size * 0.48
	isz := measure(fonts.bold, px, ini)
	draw_text(fonts.bold, px, {p.x + (size - isz.x) / 2, p.y + (size - isz.y) / 2}, col32(col), ini)
}

@(private = "file")
ago :: proc(t: i64) -> string {
	d := time.to_unix_seconds(time.now()) - t
	switch {
	case d < 60:   return "now"
	case d < 3600: return fmt.tprintf("%d min", d / 60)
	case d < 6 * 3600: return fmt.tprintf("%d h", d / 3600)
	}
	if r, ok := clock_read(local_region, time.unix(t, 0)); ok {return fmt.tprintf("%02d:%02d", r.dt.hour, r.dt.minute)}
	return ""
}

@(private = "file")
day_label :: proc(t: i64) -> string {
	now := time.to_unix_seconds(time.now())
	today := local_day_start(now)
	switch {
	case t >= today:         return "Today"
	case t >= today - 86400: return "Yesterday"
	}
	if r, ok := clock_read(local_region, time.unix(t, 0)); ok {
		return fmt.tprintf("%s %d %s", WEEKDAYS[weekday_of(r.dt)], r.dt.day, MONTHS[r.dt.month - 1])
	}
	return ""
}

// Text clipped to `max` runes with an ellipsis.
@(private = "file")
clip :: proc(s: string, max: int) -> string {
	n := 0
	for _, i in s {
		if n == max {return strings.concatenate({strings.trim_right_space(s[:i]), "…"}, context.temp_allocator)}
		n += 1
	}
	return s
}

draw_notifications :: proc(w: f32) {
	card_begin("notifications", w)
	defer card_end()
	inner := im.GetContentRegionAvail().x

	// Snapshot what's new, then it counts as read.
	if ui.shown_frames == 1 {
		clear(&fresh)
		for n in notifs.list {if !n.read && !n.transient {fresh[n.id] = true}}
		notif_mark_all_read()
	}

	if !config.notifications || !notifs.owner {
		p := im.GetCursorScreenPos()
		msg := !config.notifications ? "Notifications are off in the config ([notifications] enabled)." : notifs.other != "" ? fmt.tprintf("%s is showing your notifications right now. wlperch takes over as soon as it stops.", notifs.other) : "Another program is showing your notifications right now. wlperch takes over as soon as it stops."
		im.DrawList_AddRectFilled(dl(), p, {p.x + inner, p.y + 78}, col32(C_ORANGE, 0.1), 9)
		draw_text(fonts.ui, 16, {p.x + 12, p.y + 11}, col32(C_ORANGE), ICON_INFO)
		im.SetCursorScreenPos({p.x + 38, p.y + 10})
		im.PushFontFloat(fonts.ui, SZ_SMALL + 0.5)
		im.PushTextWrapPos(im.GetCursorPosX() + inner - 50)
		b, e := str_range(msg)
		im.TextUnformatted(b, e)
		im.PopTextWrapPos()
		im.PopFont()
		if config.notifications {
			im.SetCursorScreenPos({p.x + 38, p.y + 44})
			if pill_button("##notif-setup", "Switch in setup", C_ORANGE) {
				setup_launch()
				hide_requested = true
			}
		}
		im.SetCursorScreenPos(p)
		im.Dummy({inner, 84})
	}

	// Do not disturb + clear.
	{
		p := im.GetCursorScreenPos()
		im.SetCursorScreenPos({p.x, p.y + 1})
		if toggle_switch("##dnd", notifs.dnd, C_PURPLE) {notif_set_dnd(!notifs.dnd)}
		if im.IsItemHovered() {tip("Hold popups (critical ones still show); everything lands here")}
		draw_text(fonts.ui, SZ_BODY, {p.x + 48, p.y + 3}, col32(notifs.dnd ? C_PURPLE : C_TEXT, 0.9), "Do not disturb")
		has := false
		for n in notifs.list {if !n.transient {has = true; break}}
		if has {
			lbl := "Clear all"
			im.SetCursorScreenPos({p.x + inner - measure(fonts.bold, SZ_SMALL + 1, lbl).x - 24, p.y - 2})
			if pill_button("##clear", lbl, C_MUTED) {notif_clear_all()}
		}
		im.SetCursorScreenPos(p)
		im.Dummy({inner, 28})
	}

	// A fullscreen game keeps popups off its monitor.
	if outs, game := fullscreen_blocked(); len(outs) > 0 {
		p := im.GetCursorScreenPos()
		at := strings.join(outs, ", ", context.temp_allocator)
		what := game ? "a game is" : "an app is"
		held := notif_held_count()
		msg := notifs.held ? fmt.tprintf("Popups held while %s fullscreen on %s%s", what, at, held > 0 ? fmt.tprintf(" · %d waiting", held) : "") : fmt.tprintf("Popups keep off %s while %s fullscreen there", at, what)
		draw_text(fonts.ui, SZ_SMALL + 2, {p.x + 2, p.y}, col32(C_FAINT), game ? ICON_GAMEPAD : ICON_FULLSCREEN)
		draw_text(fonts.ui, SZ_SMALL, {p.x + 24, p.y + 1}, col32(C_MUTED), msg)
		im.Dummy({inner, 22})
	}

	shown := 0
	for n in notifs.list {if !n.transient {shown += 1}}
	if shown == 0 {
		im.Dummy({1, 18})
		msg := "No notifications"
		sz := measure(fonts.ui, SZ_BODY, msg)
		p := im.GetCursorScreenPos()
		draw_text(fonts.ui, 28, {p.x + (inner - 26) / 2, p.y}, col32(C_FAINT), ICON_BELL)
		draw_text(fonts.ui, SZ_BODY, {p.x + (inner - sz.x) / 2, p.y + 40}, col32(C_FAINT), msg)
		im.Dummy({inner, 70})
		return
	}

	// Newest first, grouped by day; scrolls past 640 px. A run from the same
	// app with nothing in between is one group: its icon and name once, the
	// newest GROUP_SHOWN messages, and the rest behind "N more".
	GROUP_SHOWN :: 3
	rows := make([dynamic]^Notification, context.temp_allocator)
	for i := len(notifs.list) - 1; i >= 0; i -= 1 {if !notifs.list[i].transient {append(&rows, notifs.list[i])}}
	cont := make([]bool, len(rows), context.temp_allocator) // continues the group above it
	for k in 1 ..< len(rows) {
		a, b := rows[k - 1], rows[k]
		cont[k] = notif_same_origin(a, b.app, b.desktop) && day_label(a.at) == day_label(b.at)
	}
	im.PushStyleColorImVec4(.ChildBg, {0, 0, 0, 0})
	im.SetNextWindowSizeConstraints({inner, 0}, {inner, 640})
	im.BeginChild("##notif-list", {inner, 0}, {.AutoResizeY}, {})
	lw := im.GetContentRegionAvail().x
	act_id: u32
	act_key: string
	remove_id: u32
	clear_day := ""
	day := ""
	group_id: u32 // the group's newest entry
	group_size, group_at := 0, 0
	prev_bottom: f32 // the row above's bottom edge, where a group's thread comes from
	prev_icon: ^Notif_Icon // the row above's (icons are shared by content)
	for n, k in rows {
		if !cont[k] {
			group_id, group_at, group_size = n.id, 0, 1
			for j := k + 1; j < len(rows) && cont[j]; j += 1 {group_size += 1}
		} else {
			group_at += 1
		}
		open_group := expanded[group_id]
		if group_at >= GROUP_SHOWN && !open_group {continue}
		if dlab := day_label(n.at); dlab != day {
			day = dlab
			im.Dummy({1, 4})
			hp := im.GetCursorScreenPos()
			title := strings.to_upper(day, context.temp_allocator)
			label(fonts.bold, SZ_SMALL, col32(C_FAINT), title)
			im.Dummy({1, 2})
			// "Clear" right after the day's title: removes that day's entries.
			cl := "Clear"
			cx := hp.x + measure(fonts.bold, SZ_SMALL, title).x + 10
			csz := measure(fonts.ui, SZ_SMALL, cl)
			back := im.GetCursorScreenPos()
			im.SetCursorScreenPos({cx - 4, hp.y - 2})
			if im.InvisibleButton(cstr(fmt.tprintf("##clr-%s", day)), {csz.x + 8, csz.y + 4}) {clear_day = day}
			ch := im.IsItemHovered()
			if ch {
				im.SetMouseCursor(.Hand)
				tip(fmt.tprintf("Remove the notifications of %s", strings.to_lower(day, context.temp_allocator)))
			}
			draw_text(fonts.ui, SZ_SMALL, {cx, hp.y}, col32(ch ? C_TEXT : C_FAINT, ch ? 0.9 : 0.7), cl)
			im.SetCursorScreenPos(back)
		}
		head := group_at == 0 // icon and app line; the rest of the group sits under it
		last := group_at == group_size - 1 || (group_at == GROUP_SHOWN - 1 && !open_group)
		p := im.GetCursorScreenPos()
		// The icon fills the smallest row (app line + summary) between its paddings.
		ICON_SZ :: 35
		tx := p.x + 10 + ICON_SZ + 12
		tw := lw - (10 + ICON_SZ + 12) - 8
		// Measure the row: summary + (clipped) body + actions.
		body := clip(n.body, 220)
		im.PushFontFloat(fonts.ui, SZ_SMALL + 1)
		body_h := body != "" ? im.CalcTextSize(cstr(body), nil, false, tw).y : 0
		im.PopFont()
		n_act := 0
		if n.open {for a in n.actions {if a.key != "default" {n_act += 1}}}
		top: f32 = head ? 10 + 16 : 4
		row_h := top + 19 + (body != "" ? body_h + 3 : 0) + (n_act > 0 ? 34 : 0) + (last ? 10 : 4)
		if head {row_h = max(row_h, 10 + ICON_SZ + 10)}
		im.SetCursorScreenPos(p)
		im.SetNextItemAllowOverlap() // the remove and action buttons sit on top
		clicked := im.InvisibleButton(cstr(fmt.tprintf("##n%d", n.id)), {lw, row_h})
		// Hover by rect: the remove button on top would otherwise un-hover the
		// row, swapping the button back for the time under the pointer; and while
		// it is held the window must still count as hovered so it can be released.
		hovered := im.IsWindowHovered(im.HoveredFlags_AllowWhenBlockedByActiveItem) && im.IsMouseHoveringRect(p, {p.x + lw, p.y + row_h})
		d := dl()
		if hovered {
			im.DrawList_AddRectFilled(d, p, {p.x + lw, p.y + row_h}, col32(C_OVERLAY, 0.045), 9)
			im.SetMouseCursor(.Hand)
		}
		if clicked {
			has_default := false
			for a in n.actions {if a.key == "default" {has_default = true}}
			if n.open && has_default {
				act_id, act_key = n.id, "default"
			} else {
				focus_app(n)
				hide_requested = true
			}
		}
		// The group's thread: from under the icon past each of its messages.
		lx := p.x + 10 + ICON_SZ / 2
		if !last {
			from := head ? p.y + 10 + ICON_SZ + 4 : p.y + top + 9
			if !head && n.icon != nil && n.icon != prev_icon {from = p.y + top + 9 + 11 + 3} // under its avatar
			im.DrawList_AddRectFilled(d, {lx - 1, from}, {lx + 1, p.y + row_h}, col32(C_OVERLAY, 0.12), 1)
		}
		// Someone else in a chat (another avatar than the row above): their
		// picture, small, on the thread; otherwise a dot.
		AV :: 22
		new_face := !head && n.icon != nil && n.icon != prev_icon
		if !head {
			ap := Vec2{lx - AV / 2, p.y + top + 9 - AV / 2}
			im.DrawList_AddRectFilled(d, {lx - 1, prev_bottom}, {lx + 1, new_face ? ap.y - 3 : p.y + top + 9}, col32(C_OVERLAY, 0.12), 1)
			if new_face {
				draw_badge(n, ap, AV)
			} else {
				im.DrawList_AddCircleFilled(d, {lx, p.y + top + 9}, 3, col32(C_OVERLAY, 0.22))
			}
		}
		prev_bottom = p.y + row_h
		prev_icon = n.icon
		if fresh[n.id] {im.DrawList_AddCircleFilled(d, {p.x + 4, head ? p.y + 10 + ICON_SZ / 2 : p.y + top + 9}, 3, col32(C_PURPLE))}
		when_s := ago(n.at)
		wsz := measure(fonts.ui, SZ_SMALL, when_s)
		// Time (or remove) on the first line of the row.
		ty := head ? p.y + 9 : p.y + top + 2
		if hovered {
			im.SetCursorScreenPos({p.x + lw - 30, ty - 5})
			if icon_button(fmt.tprintf("##rm%d", n.id), ICON_CLOSE, C_MUTED, 24, tooltip = "Remove") {remove_id = n.id}
		} else {
			draw_text(fonts.ui, SZ_SMALL, {p.x + lw - 8 - wsz.x, ty}, col32(C_FAINT), when_s)
		}
		y := p.y + 9
		if head {
			draw_badge(n, {p.x + 10, p.y + 10}, ICON_SZ)
			app_col := n.urgency == 2 ? col32(C_RED) : col32(C_MUTED)
			app := n.app != "" ? n.app : "Notification"
			draw_text(fonts.ui, SZ_SMALL, {tx, y}, app_col, app)
			if group_size > 1 {
				gx := tx + measure(fonts.ui, SZ_SMALL, app).x + 6
				draw_text(fonts.ui, SZ_SMALL, {gx, y}, col32(C_FAINT), fmt.tprintf("· %d", group_size))
			}
			y += 16
		} else {
			y = p.y + top
		}
		summary := n.summary != "" ? n.summary : n.app
		sum_s := clip(summary, n.count > 1 ? 48 : 60)
		draw_text(fonts.bold, SZ_BODY, {tx, y}, col32(n.urgency == 2 && !head ? C_RED : C_TEXT), sum_s)
		// The same text again and again: once, with how many times.
		if n.count > 1 {
			cnt := fmt.tprintf("×%d", n.count)
			cx := tx + measure(fonts.bold, SZ_BODY, sum_s).x + 7
			csz := measure(fonts.bold, SZ_SMALL, cnt)
			im.DrawList_AddRectFilled(d, {cx, y}, {cx + csz.x + 12, y + 17}, col32(C_PURPLE, 0.18), 8.5)
			draw_text(fonts.bold, SZ_SMALL, {cx + 6, y + 1}, col32(C_PURPLE), cnt)
			if im.IsMouseHoveringRect({cx, y}, {cx + csz.x + 12, y + 17}) {tip(fmt.tprintf("%d times in a row", n.count))}
		}
		y += 19
		if body != "" {
			im.SetCursorScreenPos({tx, y + 1})
			im.PushFontFloat(fonts.ui, SZ_SMALL + 1)
			im.PushStyleColorImVec4(.Text, rgba(C_TEXT, 0.72))
			im.PushTextWrapPos(im.GetCursorPosX() + tw)
			b, e := str_range(body)
			im.TextUnformatted(b, e)
			im.PopTextWrapPos()
			im.PopStyleColor()
			im.PopFont()
			y += body_h + 3
		}
		if n_act > 0 {
			ax := tx
			for a in n.actions {
				if a.key == "default" {continue}
				lbl := a.label != "" ? a.label : a.key
				im.SetCursorScreenPos({ax, y + 6})
				if pill_button(fmt.tprintf("##a%d:%s", n.id, a.key), lbl, C_BLUE) {act_id, act_key = n.id, a.key}
				ax += measure(fonts.bold, SZ_SMALL + 1, lbl).x + 24 + 6
			}
		}
		im.SetCursorScreenPos({p.x, p.y + row_h})
		// After the group's last shown message: the rest of it, or fold it back.
		if group_size > GROUP_SHOWN && (last && group_at == group_size - 1 && open_group || group_at == GROUP_SHOWN - 1 && !open_group) {
			more := open_group ? "Show fewer" : fmt.tprintf("%d more from %s", group_size - GROUP_SHOWN, n.app != "" ? n.app : "this app")
			mp := im.GetCursorScreenPos()
			msz := measure(fonts.ui, SZ_SMALL, more)
			im.SetCursorScreenPos({tx - 4, mp.y})
			if im.InvisibleButton(cstr(fmt.tprintf("##more%d", group_id)), {msz.x + 8, msz.y + 6}) {
				if open_group {delete_key(&expanded, group_id)} else {expanded[group_id] = true}
			}
			mh := im.IsItemHovered()
			if mh {im.SetMouseCursor(.Hand)}
			draw_text(fonts.ui, SZ_SMALL, {tx, mp.y + 2}, col32(mh ? C_TEXT : C_BLUE, mh ? 0.9 : 0.85), more)
			im.SetCursorScreenPos({p.x, mp.y + msz.y + 8})
		}
		im.Dummy({lw, 2})
	}
	im.EndChild()
	im.PopStyleColor()
	if act_id != 0 {
		notif_invoke(act_id, act_key)
		hide_requested = true
	}
	if remove_id != 0 {notif_remove(remove_id)}
	if clear_day != "" {
		ids: [dynamic]u32
		ids.allocator = context.temp_allocator
		for n in notifs.list {if !n.transient && day_label(n.at) == clear_day {append(&ids, n.id)}}
		for id in ids {notif_remove(id)}
	}
}
