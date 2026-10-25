// Drawing for the bar (bar.odin): its colours in one place, and software
// rendering into premultiplied ARGB8888 shared-memory buffers (rounded
// rectangles, text runs, icons), so the bar never needs the GPU.
package main

import "core:math"
import "core:sys/linux"
import "core:sys/posix"

import stbtt "vendor:stb/truetype"

import "wl"

// Every colour the bar uses. Swapped as a whole for another theme.
Bar_Palette :: struct {
	block:        u32, // the dark blocks behind the modules
	block_alpha:  f32,
	edge:         u32, // their 1px edge
	edge_alpha:   f32,
	text:         u32,
	soft:         u32, // window title, clock
	muted:        u32,
	faint:        u32,
	off:          u32, // a module that's switched off
	on_accent:    u32, // text on a solid coloured pill
	hover:        u32, // hover tint (with hover_alpha)
	hover_alpha:  f32,
	accent:       u32,
	red, orange, yellow, green, teal, cyan, purple: u32,
	popup:        u32, // tooltips and menus
	popup_edge:   u32,
	popup_hi:     u32, // menu row under the pointer
}

// Built from the panels' colours (theme.odin) for the current mode, so the
// bar matches them; bar_set_theme swaps it.
bar_palette :: proc(light: bool) -> Bar_Palette {
	if light {
		return Bar_Palette {
			block = C_CARD, block_alpha = 0.97,
			edge = 0x000000, edge_alpha = 0.10,
			text = C_TEXT, soft = 0x2e3440, muted = C_MUTED, faint = C_FAINT, off = 0xb4bac6,
			on_accent = 0xffffff,
			hover = 0x000000, hover_alpha = 0.06,
			accent = C_BLUE,
			red = C_RED, orange = C_ORANGE, yellow = C_YELLOW, green = C_GREEN, teal = C_TEAL, cyan = C_CYAN, purple = C_PURPLE,
			popup = C_CARD, popup_edge = C_BORDER, popup_hi = C_CARD_HI,
		}
	}
	return Bar_Palette {
		block = C_BG, block_alpha = 0.96,
		edge = 0xffffff, edge_alpha = 0.07,
		text = C_TEXT, soft = 0xc8ccd6, muted = C_MUTED, faint = C_FAINT, off = 0x3a404c,
		on_accent = C_BG,
		hover = 0xffffff, hover_alpha = 0.06,
		accent = C_BLUE,
		red = C_RED, orange = C_ORANGE, yellow = C_YELLOW, green = C_GREEN, teal = C_TEAL, cyan = C_CYAN, purple = C_PURPLE,
		popup = C_CARD, popup_edge = C_BORDER, popup_hi = C_CARD_HI,
	}
}

bar_pal: Bar_Palette

// wlperch's colours and the bar's for a mode.
bar_set_theme :: proc(light: bool) {
	theme_set_palette(light)
	bar_pal = bar_palette(light)
}

@(private = "file")
luma :: proc(c: u32) -> f32 {
	r, g, b := f32((c >> 16) & 0xff), f32((c >> 8) & 0xff), f32(c & 0xff)
	return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
}

// Text on a solid pill of colour c (a project's own colour can be anything).
bar_on :: proc(c: u32) -> u32 {return luma(c) > 0.55 ? 0x16181d : 0xffffff}

// A user colour (a project's) as text on the bar: in light mode, a bright one
// is darkened until it reads on the light block.
bar_ink :: proc(c: u32) -> u32 {
	if !theme_light {return c}
	c := c
	for _ in 0 ..< 6 {
		if luma(c) <= 0.42 {break}
		r, g, b := (c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff
		c = (r * 4 / 5) << 16 | (g * 4 / 5) << 8 | b * 4 / 5
	}
	return c
}

Bar_Rect :: struct {x, y, w, h: f32}

bar_in_rect :: proc(r: Bar_Rect, x, y: f32) -> bool {return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h}

Bar_Font :: enum u8 {Regular, Bold, Mono}

bar_mono: Soft_Font

bar_font :: proc(f: Bar_Font) -> ^Soft_Font {
	soft_fonts_init()
	switch f {
	case .Bold: return &soft_bold
	case .Mono:
		if !bar_mono.ok {soft_font_init(&bar_mono, FONT_MONO)}
		return &bar_mono
	case .Regular:
	}
	return &soft_regular
}

// A buffer being drawn, in buffer pixels; coordinates passed in are logical.
Bar_Canvas :: struct {
	px:   []u32,
	w, h: int,
	s:    f32, // buffer scale
}

@(private = "file")
blend :: proc(dst: ^u32, rgb: u32, a: f32) {
	if a <= 0 {return}
	inv := 1 - a
	d := dst^
	na := u32(255 * a + f32((d >> 24) & 0xff) * inv + 0.5)
	nr := u32(f32((rgb >> 16) & 0xff) * a + f32((d >> 16) & 0xff) * inv + 0.5)
	ng := u32(f32((rgb >> 8) & 0xff) * a + f32((d >> 8) & 0xff) * inv + 0.5)
	nb := u32(f32(rgb & 0xff) * a + f32(d & 0xff) * inv + 0.5)
	dst^ = min(na, 255) << 24 | min(nr, 255) << 16 | min(ng, 255) << 8 | min(nb, 255)
}

// Signed distance to a rounded rectangle with per-corner radii
// (top-left, top-right, bottom-right, bottom-left); negative inside.
@(private = "file")
rr_dist :: proc(x, y: f32, r: Bar_Rect, radii: [4]f32) -> f32 {
	cx0, cy0 := r.x, r.y
	cx1, cy1 := r.x + r.w, r.y + r.h
	left := x < (cx0 + cx1) / 2
	top := y < (cy0 + cy1) / 2
	rad := top ? (left ? radii[0] : radii[1]) : (left ? radii[3] : radii[2])
	cx := clamp(x, cx0 + rad, cx1 - rad)
	cy := clamp(y, cy0 + rad, cy1 - rad)
	dx, dy := x - cx, y - cy
	if rad <= 0 {
		// Plain box distance.
		ox := max(cx0 - x, x - cx1, 0)
		oy := max(cy0 - y, y - cy1, 0)
		if ox > 0 || oy > 0 {return math.sqrt(ox * ox + oy * oy)}
		return -min(x - cx0, cx1 - x, y - cy0, cy1 - y)
	}
	return math.sqrt(dx * dx + dy * dy) - rad
}

bar_fill :: proc(cv: ^Bar_Canvas, r: Bar_Rect, radii: [4]f32, rgb: u32, alpha: f32) {
	if alpha <= 0 {return}
	s := cv.s
	rs := Bar_Rect{r.x * s, r.y * s, r.w * s, r.h * s}
	rad := radii * s
	for y in max(int(rs.y), 0) ..< min(int(math.ceil(rs.y + rs.h)), cv.h) {
		for x in max(int(rs.x), 0) ..< min(int(math.ceil(rs.x + rs.w)), cv.w) {
			cov := clamp(0.5 - rr_dist(f32(x) + 0.5, f32(y) + 0.5, rs, rad), 0, 1)
			if cov > 0 {blend(&cv.px[y * cv.w + x], rgb, cov * alpha)}
		}
	}
}

bar_fill_round :: proc(cv: ^Bar_Canvas, r: Bar_Rect, radius: f32, rgb: u32, alpha: f32) {
	bar_fill(cv, r, {radius, radius, radius, radius}, rgb, alpha)
}

// A 1px (logical) line just inside the rounded rectangle's outline.
bar_stroke :: proc(cv: ^Bar_Canvas, r: Bar_Rect, radii: [4]f32, rgb: u32, alpha: f32) {
	if alpha <= 0 {return}
	s := cv.s
	rs := Bar_Rect{r.x * s, r.y * s, r.w * s, r.h * s}
	rad := radii * s
	for y in max(int(rs.y), 0) ..< min(int(math.ceil(rs.y + rs.h)), cv.h) {
		for x in max(int(rs.x), 0) ..< min(int(math.ceil(rs.x + rs.w)), cv.w) {
			d := rr_dist(f32(x) + 0.5, f32(y) + 0.5, rs, rad)
			cov := clamp(0.5 - d, 0, 1) - clamp(0.5 - (d + s), 0, 1)
			if cov > 0 {blend(&cv.px[y * cv.w + x], rgb, cov * alpha)}
		}
	}
}

// Text with its baseline at `baseline` (logical). tnum: tabular digits, for
// numbers that change (what follows them doesn't jiggle).
bar_text :: proc(cv: ^Bar_Canvas, f: Bar_Font, px, x, baseline: f32, s: string, rgb: u32, alpha: f32 = 1, tnum := false) {
	soft_draw_text(cv.px, cv.w, cv.h, bar_font(f), px * cv.s, x * cv.s, baseline * cv.s, s, rgb, alpha, tnum)
}

bar_text_width :: proc(f: Bar_Font, px: f32, s: string, tnum := false) -> f32 {
	return soft_text_width(bar_font(f), px, s, tnum)
}

// Icon thumbnail (ICON_PX²) scaled into a size×size box, bilinear.
bar_icon :: proc(cv: ^Bar_Canvas, ic: ^Notif_Icon, x, y, size: f32, alpha: f32 = 1) {
	if ic == nil {return}
	s := cv.s
	dx, dy, ds := int(x * s + 0.5), int(y * s + 0.5), int(size * s + 0.5)
	for py in 0 ..< ds {
		for px in 0 ..< ds {
			X, Y := dx + px, dy + py
			if X < 0 || Y < 0 || X >= cv.w || Y >= cv.h {continue}
			tx := clamp((f32(px) + 0.5) / f32(ds) * ICON_PX - 0.5, 0, ICON_PX - 1)
			ty := clamp((f32(py) + 0.5) / f32(ds) * ICON_PX - 0.5, 0, ICON_PX - 1)
			ix, iy := int(tx), int(ty)
			fx, fy := tx - f32(ix), ty - f32(iy)
			ix1, iy1 := min(ix + 1, ICON_PX - 1), min(iy + 1, ICON_PX - 1)
			c: [4]f32
			for ch in 0 ..< 4 {
				sh := u32(ch * 8)
				get :: proc(ic: ^Notif_Icon, x, y: int, sh: u32) -> f32 {return f32((ic.px[y * ICON_PX + x] >> sh) & 0xff)}
				top := get(ic, ix, iy, sh) * (1 - fx) + get(ic, ix1, iy, sh) * fx
				bot := get(ic, ix, iy1, sh) * (1 - fx) + get(ic, ix1, iy1, sh) * fx
				c[ch] = top * (1 - fy) + bot * fy
			}
			a := c[3] / 255 * alpha
			if a <= 0 {continue}
			rgb := u32(c[2] / max(c[3], 1) * 255) << 16 | u32(c[1] / max(c[3], 1) * 255) << 8 | u32(c[0] / max(c[3], 1) * 255)
			blend(&cv.px[Y * cv.w + X], rgb, a)
		}
	}
}

// Rounded rectangle drop shadow below a popup card.
bar_shadow :: proc(cv: ^Bar_Canvas, card: Bar_Rect, radius, spread: f32) {
	sc := Bar_Rect{card.x * cv.s, (card.y + 2) * cv.s, card.w * cv.s, card.h * cv.s}
	sp := spread * cv.s
	rad := radius * cv.s
	for y in 0 ..< cv.h {
		for x in 0 ..< cv.w {
			d := max(rr_dist(f32(x) + 0.5, f32(y) + 0.5, sc, {rad, rad, rad, rad}), 0)
			t := clamp(1 - d / sp, 0, 1)
			if a := t * t * 0.4; a > 0 {cv.px[y * cv.w + x] = u32(a * 255) << 24}
		}
	}
}

// A shared-memory buffer of w×h buffer pixels to draw into; bar_buffer_attach
// hands it to the surface (and frees our mapping).
Bar_Buffer :: struct {
	cv:   Bar_Canvas,
	fd:   linux.Fd,
	mem:  rawptr,
	size: int,
}

bar_buffer_new :: proc(w, h: int, scale: f32) -> (b: Bar_Buffer, ok: bool) {
	b.size = w * h * 4
	if b.size <= 0 {return}
	fd, err := linux.memfd_create("wlperch-bar", {.CLOEXEC})
	if err != .NONE {return}
	if linux.ftruncate(fd, i64(b.size)) != .NONE {
		linux.close(fd)
		return
	}
	mem := posix.mmap(nil, uint(b.size), {.READ, .WRITE}, {.SHARED}, posix.FD(fd), 0)
	if mem == posix.MAP_FAILED {
		linux.close(fd)
		return
	}
	b.fd, b.mem = fd, mem
	b.cv = {px = ([^]u32)(mem)[:w * h], w = w, h = h, s = scale}
	return b, true
}

@(private = "file")
buffer_listener := wl.Buffer_Listener {
	release = proc "c" (data: rawptr, self: ^wl.Buffer) {wl.buffer_destroy(self)},
}

bar_buffer_attach :: proc(b: ^Bar_Buffer, shm: ^wl.Shm, surface: ^wl.Surface, scale: i32) {
	posix.munmap(b.mem, uint(b.size))
	pool := wl.shm_create_pool(shm, i32(b.fd), i32(b.size))
	buf := wl.shm_pool_create_buffer(pool, 0, i32(b.cv.w), i32(b.cv.h), i32(b.cv.w * 4), wl.SHM_FORMAT_ARGB8888)
	wl.shm_pool_destroy(pool)
	linux.close(b.fd)
	wl.buffer_add_listener(buf, &buffer_listener, nil)
	wl.surface_set_buffer_scale(surface, scale)
	wl.surface_attach(surface, buf, 0, 0)
	wl.surface_damage_buffer(surface, 0, 0, i32(b.cv.w), i32(b.cv.h))
}

// A filled area chart of vals (0–100, oldest first) in r, slot cap - 1 at the
// right edge, so a short history fills from the right. Drawn per device pixel
// column: the fill up to the column's mean, a 1 px top line over the column's
// min..max (anti-aliased, steep parts stay joined), a faint 0 % line where
// there is no data yet. The box is snapped to device pixels.
bar_sparkline :: proc(cv: ^Bar_Canvas, r: Bar_Rect, vals: []f32, cap: int, rgb: u32, fill_alpha: f32 = 0.24, line_alpha: f32 = 0.95) {
	s := cv.s
	x0, x1 := int(math.round(r.x * s)), int(math.round((r.x + r.w) * s))
	y0, y1 := int(math.round(r.y * s)), int(math.round((r.y + r.h) * s))
	if x1 - x0 < 2 || y1 - y0 < 2 || cap < 2 {return}
	lw := max(math.round(s), 1) // line width, device px
	top, bot := f32(y0) + lw / 2, f32(y1) - lw / 2 // the line's centre at 100 % / 0 %
	yof :: proc(v, top, bot: f32) -> f32 {return bot - clamp(v, 0, 100) / 100 * (bot - top)}
	n := len(vals)
	first := f32(cap - n) // slot of the oldest sample
	per := f32(cap - 1) / f32(x1 - x0) // slots per device column
	at :: proc(vals: []f32, first, t: f32) -> f32 {
		i := t - first
		k := clamp(int(i), 0, len(vals) - 1)
		if k + 1 >= len(vals) {return vals[len(vals) - 1]}
		f := i - f32(k)
		return vals[k] * (1 - f) + vals[k + 1] * f
	}
	cover :: proc(row: int, a, b: f32) -> f32 {return clamp(min(f32(row + 1), b) - max(f32(row), a), 0, 1)}
	for cx in max(x0, 0) ..< min(x1, cv.w) {
		tl, tr := f32(cx - x0) * per, f32(cx - x0 + 1) * per
		if n == 0 || tr < first {
			// No data yet: the 0 % line, faint.
			for row in max(int(bot - lw / 2), 0) ..< min(y1, cv.h) {
				blend(&cv.px[row * cv.w + cx], rgb, cover(row, bot - lw / 2, bot + lw / 2) * line_alpha * 0.3)
			}
			continue
		}
		tl = max(tl, first)
		// The curve over this column: its ends and the samples inside.
		va, vb := at(vals, first, tl), at(vals, first, tr)
		lo, hi, sum, cnt := min(va, vb), max(va, vb), va + vb, f32(2)
		for k := int(math.ceil(tl)); f32(k) < tr; k += 1 {
			v := vals[clamp(k - (cap - n), 0, n - 1)]
			lo, hi, sum, cnt = min(lo, v), max(hi, v), sum + v, cnt + 1
		}
		fill_top := yof(sum / cnt, top, bot)
		la, lb := yof(hi, top, bot) - lw / 2, yof(lo, top, bot) + lw / 2
		for row in max(y0, 0) ..< min(y1, cv.h) {
			p := &cv.px[row * cv.w + cx]
			if f := clamp(f32(row + 1) - fill_top, 0, 1); f > 0 {blend(p, rgb, f * fill_alpha)}
			if l := cover(row, la, lb); l > 0 {blend(p, rgb, l * line_alpha)}
		}
	}
}
