// Media card: what's playing, with previous / play-pause / next.
// Hidden while no player is running.
package main

import "core:fmt"
import "core:strings"
import "core:sync"

import im "third_party:odin-imgui"

// Album art and app icons, by file path / icon name (nil = none found).
@(private = "file") art_cache: map[string]^Notif_Icon

@(private = "file")
cached_icon :: proc(key: string, load: proc(s: string) -> ^Notif_Icon) -> ^Notif_Icon {
	if key == "" {return nil}
	if ic, ok := art_cache[key]; ok {return ic}
	ic := load(key)
	art_cache[strings.clone(key)] = ic
	return ic
}

@(private = "file")
load_art :: proc(path: string) -> ^Notif_Icon {return icon_resolve(path)}

@(private = "file")
load_app :: proc(desktop: string) -> ^Notif_Icon {
	if ic := icon_resolve_desktop(desktop); ic != nil {return ic}
	return icon_resolve(desktop)
}

// Round button; `big` is the filled play/pause one.
@(private = "file")
media_button :: proc(id, icon: string, enabled, big: bool) -> bool {
	size: f32 = big ? 40 : 32
	p := im.GetCursorScreenPos()
	if !enabled {im.BeginDisabled()}
	clicked := im.InvisibleButton(cstr(id), {size, size})
	hovered := im.IsItemHovered()
	if !enabled {im.EndDisabled()}
	d := dl()
	c := Vec2{p.x + size / 2, p.y + size / 2}
	if big {
		im.DrawList_AddCircleFilled(d, c, size / 2, col32(C_GREEN, hovered ? 1 : 0.88))
	} else if hovered && enabled {
		im.DrawList_AddCircleFilled(d, c, size / 2, col32(0xffffff, 0.08))
	}
	if hovered && enabled {im.SetMouseCursor(.Hand)}
	px: f32 = big ? 22 : 19
	isz := measure(fonts.ui, px, icon)
	col := big ? col32(0x111318) : col32(C_TEXT, enabled ? 0.9 : 0.3)
	draw_text(fonts.ui, px, {c.x - isz.x / 2, c.y - px / 2 - 1}, col, icon)
	return clicked && enabled
}

draw_media :: proc(w: f32) {
	target, member := draw_media_locked(w)
	if member != "" {media_command_async(target, member)}
}

// Returns a player command to send once the lock is released.
@(private = "file")
draw_media_locked :: proc(w: f32) -> (target, member: string) {
	sync.guard(&media.mu)
	i := media_pick(media.players[:], media.pinned, media.last_playing)
	if i < 0 {return "", ""}
	p := media.players[i]

	card_begin("media", w)
	defer card_end()
	card_title(ICON_MUSIC, "Media", C_GREEN, len(media.players) > 1 ? "" : p.identity)
	inner := im.GetContentRegionAvail().x

	// Several players: pick one (the pick sticks until the popup reopens).
	if len(media.players) > 1 {
		names := make([]string, len(media.players), context.temp_allocator)
		for q, j in media.players {names[j] = q.identity}
		if j := segmented("##players", names, i, C_GREEN); j >= 0 && j != i {
			delete(media.pinned)
			media.pinned = strings.clone(media.players[j].bus_name)
			i = j
			p = media.players[j]
		}
		im.Dummy({1, 2})
	}

	ART :: 64
	top := im.GetCursorScreenPos()
	d := dl()
	art := cached_icon(p.art, load_art)
	if art == nil {art = cached_icon(p.desktop, load_app)}
	if art != nil {
		im.DrawList_AddImageRounded(d, im.TextureRef{_TexID = icon_texture(art)}, top, {top.x + ART, top.y + ART}, {0, 0}, {1, 1}, 0xffffffff, art.rounded || p.art != "" ? 8 : 0)
	} else {
		im.DrawList_AddRectFilled(d, top, {top.x + ART, top.y + ART}, col32(C_GREEN, 0.14), 8)
		isz := measure(fonts.ui, 28, ICON_MUSIC)
		draw_text(fonts.ui, 28, {top.x + (ART - isz.x) / 2, top.y + (ART - 28) / 2 - 1}, col32(C_GREEN), ICON_MUSIC)
	}

	// Controls on the right, centered on the art.
	ctrl_w: f32 = 32 + 6 + 40 + 6 + 32
	cx := top.x + inner - ctrl_w
	cy := top.y + (ART - 40) / 2
	im.SetCursorScreenPos({cx, cy + 4})
	if media_button("##prev", ICON_SKIP_PREV, p.can_prev, false) {member = "Previous"}
	im.SetCursorScreenPos({cx + 38, cy})
	playing := p.status == .Playing
	if media_button("##playpause", playing ? ICON_PAUSE : ICON_PLAY, playing ? p.can_pause : p.can_play, true) {member = "PlayPause"}
	im.SetCursorScreenPos({cx + 84, cy + 4})
	if media_button("##next", ICON_SKIP_NEXT, p.can_next, false) {member = "Next"}

	// Title, artist, album between the art and the controls.
	tx := top.x + ART + 12
	tw := cx - 10 - tx
	title := p.title != "" ? p.title : p.identity
	fit :: proc(font: ^im.Font, size: f32, s: string, w: f32) -> string {
		if measure(font, size, s).x <= w {return s}
		cut := len(s)
		for cut > 0 && measure(font, size, s[:cut]).x + measure(font, size, "…").x > w {
			cut -= 1
			for cut > 0 && (s[cut] & 0xc0) == 0x80 {cut -= 1} // stay on a rune boundary
		}
		return strings.concatenate({s[:cut], "…"}, context.temp_allocator)
	}
	y := top.y + (p.album != "" ? 4 : 11)
	draw_text(fonts.bold, SZ_BODY + 1, {tx, y}, col32(C_TEXT), fit(fonts.bold, SZ_BODY + 1, title, tw))
	y += 21
	if p.artist != "" {
		draw_text(fonts.ui, SZ_BODY, {tx, y}, col32(C_TEXT, 0.75), fit(fonts.ui, SZ_BODY, p.artist, tw))
		y += 19
	}
	if p.album != "" {
		draw_text(fonts.ui, SZ_SMALL, {tx, y}, col32(C_MUTED), fit(fonts.ui, SZ_SMALL, p.album, tw))
	}
	im.SetCursorScreenPos(top)
	im.Dummy({inner, ART})

	// Progress (when the player reports a length).
	if p.length_us > 0 {
		im.Dummy({1, 2})
		pos := media_position(p)
		bp := im.GetCursorScreenPos()
		el := media_fmt_time(pos)
		total := media_fmt_time(p.length_us)
		esz := measure(fonts.mono, SZ_SMALL, el)
		tsz := measure(fonts.mono, SZ_SMALL, total)
		draw_text(fonts.mono, SZ_SMALL, {bp.x, bp.y}, col32(C_MUTED), el)
		draw_text(fonts.mono, SZ_SMALL, {bp.x + inner - tsz.x, bp.y}, col32(C_MUTED), total)
		bx0 := bp.x + esz.x + 10
		bx1 := bp.x + inner - tsz.x - 10
		by := bp.y + 7
		im.DrawList_AddRectFilled(d, {bx0, by}, {bx1, by + 4}, col32(0xffffff, 0.08), 2)
		frac := f32(f64(pos) / f64(p.length_us))
		if frac > 0 {im.DrawList_AddRectFilled(d, {bx0, by}, {bx0 + (bx1 - bx0) * clamp(frac, 0, 1), by + 4}, col32(C_GREEN), 2)}
		im.Dummy({inner, 16})
	}
	if p.status == .Stopped {label(fonts.ui, SZ_SMALL, col32(C_FAINT), fmt.tprintf("%s · stopped", p.identity))}

	return strings.clone(p.bus_name, context.temp_allocator), member
}
