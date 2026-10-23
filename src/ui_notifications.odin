// Notification center: history grouped by day, do not disturb, clear.
package main

import "core:fmt"
import "core:strings"
import "core:time"

import im "third_party:odin-imgui"
import gl "vendor:OpenGL"

// Notifications that were unread when the panel opened keep their dot while it's open.
@(private = "file") fresh: map[u32]bool

// GL texture for an icon (straight alpha, as imgui blends), made on first use.
@(private = "file")
icon_texture :: proc(ic: ^Notif_Icon) -> im.TextureID {
	if ic.tex != 0 {return im.TextureID(ic.tex)}
	rgba := make([]u8, ICON_PX * ICON_PX * 4, context.temp_allocator)
	for p, i in ic.px {
		a := p >> 24
		un :: proc(v, a: u32) -> u8 {return a == 0 ? 0 : u8(min(v * 255 / a, 255))}
		rgba[i * 4 + 0] = un((p >> 16) & 0xff, a)
		rgba[i * 4 + 1] = un((p >> 8) & 0xff, a)
		rgba[i * 4 + 2] = un(p & 0xff, a)
		rgba[i * 4 + 3] = u8(a)
	}
	gl.GenTextures(1, &ic.tex)
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
		im.DrawList_AddImageRounded(d, im.TextureRef{_TexID = icon_texture(n.icon)}, p, {p.x + size, p.y + size}, {0, 0}, {1, 1}, 0xffffffff, n.icon.rounded ? 7 : 0)
		return
	}
	col := app_color(n.app)
	im.DrawList_AddCircleFilled(d, {p.x + size / 2, p.y + size / 2}, size / 2, col32(col, 0.2))
	ini := app_initial(n.app)
	isz := measure(fonts.bold, 15, ini)
	draw_text(fonts.bold, 15, {p.x + (size - isz.x) / 2, p.y + (size - isz.y) / 2}, col32(col), ini)
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
		msg := !config.notifications ? "Notifications are off in the config ([notifications] enabled)." : notifs.other != "" ? fmt.tprintf("%s is showing your notifications right now. wlwidgets takes over as soon as it stops.", notifs.other) : "Another program is showing your notifications right now. wlwidgets takes over as soon as it stops."
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

	// Newest first, grouped by day; scrolls past 640 px.
	im.PushStyleColorImVec4(.ChildBg, {0, 0, 0, 0})
	im.SetNextWindowSizeConstraints({inner, 0}, {inner, 640})
	im.BeginChild("##notif-list", {inner, 0}, {.AutoResizeY}, {})
	lw := im.GetContentRegionAvail().x
	act_id: u32
	act_key: string
	remove_id: u32
	day := ""
	for i := len(notifs.list) - 1; i >= 0; i -= 1 {
		n := notifs.list[i]
		if n.transient {continue}
		if dlab := day_label(n.at); dlab != day {
			day = dlab
			im.Dummy({1, 4})
			label(fonts.bold, SZ_SMALL, col32(C_FAINT), strings.to_upper(day, context.temp_allocator))
			im.Dummy({1, 2})
		}
		p := im.GetCursorScreenPos()
		tx := p.x + 46
		tw := lw - 46 - 8
		// Measure the row: summary + (clipped) body + actions.
		body := clip(n.body, 220)
		im.PushFontFloat(fonts.ui, SZ_SMALL + 1)
		body_h := body != "" ? im.CalcTextSize(cstr(body), nil, false, tw).y : 0
		im.PopFont()
		n_act := 0
		if n.open {for a in n.actions {if a.key != "default" {n_act += 1}}}
		row_h := 10 + 16 + 19 + (body != "" ? body_h + 3 : 0) + (n_act > 0 ? 34 : 0) + 10
		im.SetCursorScreenPos(p)
		im.SetNextItemAllowOverlap() // the remove and action buttons sit on top
		clicked := im.InvisibleButton(cstr(fmt.tprintf("##n%d", n.id)), {lw, row_h})
		hovered := im.IsItemHovered()
		d := dl()
		if hovered {
			im.DrawList_AddRectFilled(d, p, {p.x + lw, p.y + row_h}, col32(0xffffff, 0.045), 9)
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
		if fresh[n.id] {im.DrawList_AddCircleFilled(d, {p.x + 4, p.y + 26}, 3, col32(C_PURPLE))}
		draw_badge(n, {p.x + 10, p.y + 10}, 30)
		y := p.y + 9
		app_col := n.urgency == 2 ? col32(C_RED) : col32(C_MUTED)
		draw_text(fonts.ui, SZ_SMALL, {tx, y}, app_col, n.app != "" ? n.app : "Notification")
		when_s := ago(n.at)
		wsz := measure(fonts.ui, SZ_SMALL, when_s)
		if hovered {
			im.SetCursorScreenPos({p.x + lw - 30, p.y + 4})
			if icon_button(fmt.tprintf("##rm%d", n.id), ICON_CLOSE, C_MUTED, 24, tooltip = "Remove") {remove_id = n.id}
		} else {
			draw_text(fonts.ui, SZ_SMALL, {p.x + lw - 8 - wsz.x, y}, col32(C_FAINT), when_s)
		}
		y += 16
		summary := n.summary != "" ? n.summary : n.app
		draw_text(fonts.bold, SZ_BODY, {tx, y}, col32(C_TEXT), clip(summary, 60))
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
		im.Dummy({lw, 2})
	}
	im.EndChild()
	im.PopStyleColor()
	if act_id != 0 {
		notif_invoke(act_id, act_key)
		hide_requested = true
	}
	if remove_id != 0 {notif_remove(remove_id)}
}
