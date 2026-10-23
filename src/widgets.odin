// Custom-drawn widgets on top of Dear ImGui's draw lists.
package main

import "core:fmt"
import "core:math"
import "core:strings"

import im "third_party:odin-imgui"

Vec2 :: im.Vec2

dl :: proc() -> ^im.DrawList {return im.GetWindowDrawList()}

cstr :: proc(s: string) -> cstring {return strings.clone_to_cstring(s, context.temp_allocator)}

// Begin/end pointers of a string for ImGui's (text_begin, text_end) APIs.
str_range :: proc(s: string) -> (begin, end: cstring) {
	b := raw_data(s)
	return cstring(b), cstring(rawptr(uintptr(rawptr(b)) + uintptr(len(s))))
}

measure :: proc(font: ^im.Font, size: f32, s: string) -> Vec2 {
	if len(s) == 0 {return {0, size}}
	im.PushFontFloat(font, size)
	defer im.PopFont()
	b, e := str_range(s)
	return im.CalcTextSize(b, e)
}

draw_text :: proc(font: ^im.Font, size: f32, pos: Vec2, col: u32, s: string) {
	if len(s) == 0 {return}
	b, e := str_range(s)
	im.DrawList_AddTextImFontPtr(dl(), font, size, {math.round(pos.x), math.round(pos.y)}, col, b, e)
}

// Text placed with the cursor (participates in layout).
label :: proc(font: ^im.Font, size: f32, col: u32, s: string) {
	sz := measure(font, size, s)
	p := im.GetCursorScreenPos()
	draw_text(font, size, p, col, s)
	im.Dummy(sz)
}

lerp_col :: proc(a, b: u32, t: f32) -> u32 {
	t := clamp(t, 0, 1)
	res: u32
	for i in u32(0) ..< 4 {
		ca := f32((a >> (i * 8)) & 0xff)
		cb := f32((b >> (i * 8)) & 0xff)
		res |= u32(ca + (cb - ca) * t + 0.5) << (i * 8)
	}
	return res
}

// Color for a 0..100 load value: green -> yellow -> red.
load_color :: proc(pct: f32) -> u32 {
	if pct < 50 {return lerp_col(col32(C_GREEN), col32(C_YELLOW), pct / 50)}
	return lerp_col(col32(C_YELLOW), col32(C_RED), (pct - 50) / 50)
}

// ---- Cards ------------------------------------------------------------------

CARD_PAD :: 14

card_begin :: proc(id: string, width: f32) {
	im.PushStyleVarImVec2(.WindowPadding, {CARD_PAD, CARD_PAD - 2})
	im.PushStyleVarImVec2(.ItemSpacing, {8, 6})
	im.BeginChild(cstr(id), {width, 0}, {.Borders, .AutoResizeY, .AlwaysUseWindowPadding}, {.NoScrollbar, .NoScrollWithMouse})
}

card_end :: proc() {
	im.EndChild()
	im.PopStyleVar(2)
}

// Section title with a colored icon; returns the right edge x for extras.
card_title :: proc(icon: string, title: string, accent: u32, right_text := "") {
	p := im.GetCursorScreenPos()
	w := im.GetContentRegionAvail().x
	draw_text(fonts.ui, 16, {p.x, p.y - 1}, col32(accent), icon)
	draw_text(fonts.bold, SZ_TITLE, {p.x + 22, p.y + 1}, col32(C_TEXT, 0.92), title)
	if right_text != "" {
		sz := measure(fonts.ui, SZ_SMALL, right_text)
		draw_text(fonts.ui, SZ_SMALL, {p.x + w - sz.x, p.y + 2}, col32(C_MUTED), right_text)
	}
	im.Dummy({w, 18})
	im.Dummy({w, 2})
}

sub_heading :: proc(s: string) {
	im.Dummy({1, 2})
	label(fonts.bold, SZ_SMALL, col32(C_FAINT), strings.to_upper(s, context.temp_allocator))
}

// ---- Rows -------------------------------------------------------------------

// A clickable list row with icon, label, sublabel and a selected state.
// Returns true when clicked.
device_row :: proc(id: string, icon, title, sub: string, selected: bool, accent: u32, dim := false, right := "") -> bool {
	w := im.GetContentRegionAvail().x
	h: f32 = sub != "" ? 40 : 32
	p := im.GetCursorScreenPos()
	clicked := im.InvisibleButton(cstr(id), {w, h})
	hovered := im.IsItemHovered()
	if hovered {im.SetMouseCursor(.Hand)}
	d := dl()
	if selected {
		im.DrawList_AddRectFilled(d, p, {p.x + w, p.y + h}, col32(accent, 0.13), 8)
		im.DrawList_AddRectFilled(d, {p.x, p.y + 8}, {p.x + 3, p.y + h - 8}, col32(accent), 2)
	} else if hovered {
		im.DrawList_AddRectFilled(d, p, {p.x + w, p.y + h}, col32(0xffffff, 0.05), 8)
	}
	alpha: f32 = dim ? 0.45 : 1
	icon_col := selected ? col32(accent) : col32(C_MUTED, alpha)
	draw_text(fonts.ui, 18, {p.x + 12, p.y + h / 2 - 10}, icon_col, icon)
	tx := p.x + 40
	title_col := col32(C_TEXT, alpha)
	right_w: f32 = 0
	if right != "" {
		right_w = measure(fonts.ui, SZ_SMALL, right).x + 12
	}
	if selected {right_w = max(right_w, 28)}
	im.DrawList_PushClipRect(d, p, {p.x + w - right_w, p.y + h}, true)
	if sub != "" {
		draw_text(selected ? fonts.bold : fonts.ui, SZ_BODY, {tx, p.y + 4}, title_col, title)
		draw_text(fonts.ui, SZ_SMALL, {tx, p.y + 22}, col32(C_MUTED, alpha), sub)
	} else {
		draw_text(selected ? fonts.bold : fonts.ui, SZ_BODY, {tx, p.y + h / 2 - 9}, title_col, title)
	}
	im.DrawList_PopClipRect(d)
	if right != "" {
		sz := measure(fonts.ui, SZ_SMALL, right)
		off: f32 = selected ? 30 : 10
		draw_text(fonts.ui, SZ_SMALL, {p.x + w - sz.x - off, p.y + h / 2 - 8}, col32(C_MUTED, alpha), right)
	}
	if selected {
		draw_text(fonts.ui, 16, {p.x + w - 24, p.y + h / 2 - 9}, col32(accent), ICON_CHECK)
	}
	return clicked
}

// ---- Slider -----------------------------------------------------------------

// Slim slider with a filled track. `v` in [0, max_v]. Returns true while changing.
slider :: proc(id: string, v: ^f32, max_v: f32, accent: u32, width: f32) -> bool {
	h: f32 = 22
	p := im.GetCursorScreenPos()
	im.InvisibleButton(cstr(id), {width, h})
	hovered := im.IsItemHovered()
	active := im.IsItemActive()
	changed := false
	if active {
		t := clamp((im.GetMousePos().x - p.x) / width, 0, 1)
		nv := t * max_v
		if math.abs(nv - v^) > 0.004 {
			v^ = nv
			changed = true
		}
	} else if hovered {
		wheel := im.GetIO().MouseWheel
		if wheel != 0 {
			v^ = clamp(v^ + wheel * 0.05, 0, max_v)
			changed = true
		}
	}
	if hovered || active {im.SetMouseCursor(.Hand)}
	d := dl()
	cy := p.y + h / 2
	t := clamp(v^ / max_v, 0, 1)
	im.DrawList_AddRectFilled(d, {p.x, cy - 3}, {p.x + width, cy + 3}, col32(0x2e3440), 3)
	// Over-amplification region (>100%) tinted.
	if max_v > 1 {
		x100 := p.x + width / max_v
		im.DrawList_AddRectFilled(d, {x100, cy - 3}, {p.x + width, cy + 3}, col32(C_ORANGE, 0.12), 3)
	}
	fill := accent
	if v^ > 1 {fill = C_ORANGE}
	im.DrawList_AddRectFilled(d, {p.x, cy - 3}, {p.x + width * t, cy + 3}, col32(fill), 3)
	r: f32 = (hovered || active) ? 8 : 7
	im.DrawList_AddCircleFilled(d, {p.x + width * t, cy}, r + 1.5, col32(0x000000, 0.35))
	im.DrawList_AddCircleFilled(d, {p.x + width * t, cy}, r, col32(0xf2f4f8))
	return changed
}

// Small round icon button. Returns true when clicked.
icon_button :: proc(id: string, icon: string, col: u32, size: f32 = 28, active := false, tooltip := "") -> bool {
	p := im.GetCursorScreenPos()
	clicked := im.InvisibleButton(cstr(id), {size, size})
	hovered := im.IsItemHovered()
	d := dl()
	if active {
		im.DrawList_AddRectFilled(d, p, {p.x + size, p.y + size}, col32(col, 0.16), 8)
	} else if hovered {
		im.DrawList_AddRectFilled(d, p, {p.x + size, p.y + size}, col32(0xffffff, 0.07), 8)
	}
	if hovered {
		im.SetMouseCursor(.Hand)
		if tooltip != "" {tip(tooltip)}
	}
	sz := measure(fonts.ui, 17, icon)
	draw_text(fonts.ui, 17, {p.x + (size - sz.x) / 2, p.y + (size - 18) / 2}, col32(col), icon)
	return clicked
}

tip :: proc(s: string) {
	im.PushStyleVarImVec2(.WindowPadding, {10, 6})
	if im.BeginTooltip() {
		label(fonts.ui, SZ_SMALL, col32(C_TEXT), s)
		im.EndTooltip()
	}
	im.PopStyleVar()
}

// ---- Toggle switch ----------------------------------------------------------

toggle_switch :: proc(id: string, on: bool, accent: u32, pending := false) -> bool {
	w, h: f32 = 38, 22
	p := im.GetCursorScreenPos()
	clicked := im.InvisibleButton(cstr(id), {w, h})
	hovered := im.IsItemHovered()
	if hovered {im.SetMouseCursor(.Hand)}
	d := dl()
	bg := on ? col32(accent) : col32(0x353b48)
	if hovered && !on {bg = col32(0x3d4453)}
	im.DrawList_AddRectFilled(d, p, {p.x + w, p.y + h}, bg, h / 2)
	r := h / 2 - 3
	cx := on ? p.x + w - h / 2 : p.x + h / 2
	knob := col32(0xf5f6fa, pending ? 0.6 : 1)
	im.DrawList_AddCircleFilled(d, {cx, p.y + h / 2}, r, knob)
	return clicked
}

// ---- Segmented control ------------------------------------------------------

// Returns the clicked index or -1.
segmented :: proc(id: string, items: []string, active: int, accent: u32) -> int {
	pad: f32 = 12
	h: f32 = 26
	total: f32 = 0
	widths := make([]f32, len(items), context.temp_allocator)
	for it, i in items {
		widths[i] = measure(fonts.ui, SZ_SMALL + 1, it).x + pad * 2
		total += widths[i]
	}
	p := im.GetCursorScreenPos()
	d := dl()
	im.DrawList_AddRectFilled(d, p, {p.x + total + 4, p.y + h + 4}, col32(C_CARD_HI), 9)
	clicked := -1
	x := p.x + 2
	for it, i in items {
		im.SetCursorScreenPos({x, p.y + 2})
		if im.InvisibleButton(cstr(fmt.tprintf("%s#%d", id, i)), {widths[i], h}) {clicked = i}
		hovered := im.IsItemHovered()
		if hovered {im.SetMouseCursor(.Hand)}
		if i == active {
			im.DrawList_AddRectFilled(d, {x, p.y + 2}, {x + widths[i], p.y + 2 + h}, col32(accent, 0.9), 7)
		} else if hovered {
			im.DrawList_AddRectFilled(d, {x, p.y + 2}, {x + widths[i], p.y + 2 + h}, col32(0xffffff, 0.06), 7)
		}
		tc := i == active ? col32(0x11131a) : col32(C_TEXT, 0.85)
		draw_text(i == active ? fonts.bold : fonts.ui, SZ_SMALL + 1, {x + pad, p.y + 2 + (h - 15) / 2}, tc, it)
		x += widths[i]
	}
	im.SetCursorScreenPos(p)
	im.Dummy({total + 4, h + 4})
	return clicked
}

// ---- History graph ----------------------------------------------------------

// Area graph of the last `n` samples (0..100) with gradient fill.
history_graph :: proc(h: ^History, n: int, accent: u32, size: Vec2) {
	p := im.GetCursorScreenPos()
	im.Dummy(size)
	d := dl()
	x0, y0, x1, y1 := p.x, p.y, p.x + size.x, p.y + size.y
	im.DrawList_AddRectFilled(d, {x0, y0}, {x1, y1}, col32(0x12151b), 8)
	for i in 1 ..< 4 {
		gy := y0 + size.y * f32(i) / 4
		im.DrawList_AddLine(d, {x0 + 1, gy}, {x1 - 1, gy}, col32(0xffffff, 0.035), 1)
	}
	count := min(n, h.count)
	if count < 2 {return}
	im.DrawList_PushClipRect(d, {x0, y0}, {x1, y1}, true)
	defer im.DrawList_PopClipRect(d)

	pad: f32 = 2
	pts := make([]Vec2, count, context.temp_allocator)
	step := size.x / f32(n - 1)
	for i in 0 ..< count {
		v := clamp(history_get(h, count, i), 0, 100)
		x := x1 - f32(count - 1 - i) * step
		y := y1 - pad - (size.y - pad * 2) * v / 100
		pts[i] = {x, y}
	}
	uv := im.GetFontTexUvWhitePixel()
	top := col32(accent, 0.38)
	bot := col32(accent, 0.02)
	for i in 0 ..< count - 1 {
		a, b := pts[i], pts[i + 1]
		im.DrawList_PrimReserve(d, 6, 6)
		im.DrawList_PrimVtx(d, a, uv, top)
		im.DrawList_PrimVtx(d, b, uv, top)
		im.DrawList_PrimVtx(d, {b.x, y1}, uv, bot)
		im.DrawList_PrimVtx(d, a, uv, top)
		im.DrawList_PrimVtx(d, {b.x, y1}, uv, bot)
		im.DrawList_PrimVtx(d, {a.x, y1}, uv, bot)
	}
	im.DrawList_AddPolyline(d, &pts[0], i32(count), col32(accent), 1.6)
	last := pts[count - 1]
	im.DrawList_AddCircleFilled(d, last, 3.5, col32(accent))
	im.DrawList_AddCircle(d, last, 6, col32(accent, 0.35), 0, 1.5)
}

// Thin horizontal usage bar.
usage_bar :: proc(frac: f32, col: u32, size: Vec2) {
	p := im.GetCursorScreenPos()
	im.Dummy(size)
	d := dl()
	r := size.y / 2
	im.DrawList_AddRectFilled(d, p, {p.x + size.x, p.y + size.y}, col32(0x2a2f3a), r)
	f := clamp(frac, 0, 1)
	if f > 0 {
		im.DrawList_AddRectFilled(d, p, {p.x + max(size.x * f, size.y), p.y + size.y}, col, r)
	}
}

// ---- Battery ----------------------------------------------------------------

battery_glyph :: proc(pct: int, charging: bool) -> (icon: string, col: u32) {
	switch {
	case charging:  return ICON_BATTERY_CHARGING, C_GREEN
	case pct < 0:   return ICON_BATTERY_UNKNOWN, C_MUTED
	case pct <= 15: return ICON_BATTERY_20, C_RED
	case pct <= 35: return ICON_BATTERY_20, C_ORANGE
	case pct <= 65: return ICON_BATTERY_50, C_YELLOW
	case pct <= 90: return ICON_BATTERY_80, C_GREEN
	}
	return ICON_BATTERY, C_GREEN
}

// ---- Screen layout ----------------------------------------------------------

Layout_Rect :: struct {
	name:      string,
	x, y, w, h: f32,
	focused:   bool,
	detail:    string,
}

// Draws output rectangles scaled to fit `size`, centered.
draw_layout :: proc(rects: []Layout_Rect, p: Vec2, size: Vec2, compact := false, accent: u32 = C_BLUE) {
	if len(rects) == 0 {return}
	d := dl()
	minx, miny := max(f32), max(f32)
	maxx, maxy := -max(f32), -max(f32)
	for r in rects {
		minx = min(minx, r.x); miny = min(miny, r.y)
		maxx = max(maxx, r.x + r.w); maxy = max(maxy, r.y + r.h)
	}
	bw, bh := maxx - minx, maxy - miny
	if bw <= 0 || bh <= 0 {return}
	s := min(size.x / bw, size.y / bh)
	ox := p.x + (size.x - bw * s) / 2
	oy := p.y + (size.y - bh * s) / 2
	gap: f32 = compact ? 1.5 : 3
	for r in rects {
		a := Vec2{ox + (r.x - minx) * s + gap, oy + (r.y - miny) * s + gap}
		b := Vec2{ox + (r.x - minx + r.w) * s - gap, oy + (r.y - miny + r.h) * s - gap}
		rounding: f32 = compact ? 2.5 : 6
		fill := r.focused ? col32(accent, 0.22) : col32(0x2a303c)
		border := r.focused ? col32(accent, 0.9) : col32(0x454d5e)
		im.DrawList_AddRectFilled(d, a, b, fill, rounding)
		im.DrawList_AddRect(d, a, b, border, rounding, compact ? 1 : 1.5)
		if !compact {
			// Stand on the bottom edge, like a monitor.
			nsz := measure(fonts.bold, SZ_BODY, r.name)
			dsz := measure(fonts.ui, SZ_SMALL, r.detail)
			cx := (a.x + b.x) / 2
			cy := (a.y + b.y) / 2
			bh2 := b.y - a.y
			if bh2 > 38 && b.x - a.x > max(nsz.x, dsz.x) + 8 {
				draw_text(fonts.bold, SZ_BODY, {cx - nsz.x / 2, cy - 17}, col32(C_TEXT), r.name)
				draw_text(fonts.ui, SZ_SMALL, {cx - dsz.x / 2, cy + 2}, col32(C_MUTED), r.detail)
			} else if b.x - a.x > nsz.x + 4 {
				draw_text(fonts.bold, SZ_BODY, {cx - nsz.x / 2, cy - 9}, col32(C_TEXT), r.name)
			}
		}
	}
}
