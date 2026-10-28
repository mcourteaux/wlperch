// Notification popups: one small layer surface per notification, stacked in
// the top-right corner (under the bar), software-rendered into shared memory
// so they never need the GPU.
//
//   click        default action (or focus the app), then dismiss
//   action pill  invoke that action
//   ×, right     dismiss
//   middle       dismiss all
package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"

import "wl"

@(private = "file") CARD_W :: 380
@(private = "file") SHADOW_M :: 14 // transparent margin around the card for its shadow
@(private = "file") GAP :: 8
@(private = "file") PAD :: 14
@(private = "file") ICON :: 40
@(private = "file") RADIUS :: 14
@(private = "file") MAX_VISIBLE :: 4
@(private = "file") TOP_MARGIN :: 8
@(private = "file") RIGHT_MARGIN :: 10
@(private = "file") BAR_H :: 3 // timeout line along the bottom edge
@(private = "file") BAR_FRAME :: 66 * time.Millisecond // at most ~15 line redraws a second
@(private = "file") BAR_REFILL :: 2 * time.Second // hovering refills an empty bar in this long
@(private = "file") GLIMPSE :: 10 * time.Second // on screen over a fullscreen game, at most

@(private = "file") PX_APP :: 12.0
@(private = "file") PX_SUMMARY :: 14.5
@(private = "file") PX_BODY :: 13.5
@(private = "file") PX_ACTION :: 12.5

@(private = "file")
Rect :: struct {x, y, w, h: f32}

@(private = "file")
in_rect :: proc(r: Rect, x, y: f32) -> bool {return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h}

@(private = "file")
Popup :: struct {
	id:          u32,
	rev:         int, // notification content this was rendered from
	conn:        string, // output it was put on ("" = the compositor's choice)
	surface:     ^wl.Surface,
	layer:       ^wl.Zwlr_Layer_Surface_V1,
	w, h:        i32, // logical surface size (card + shadow margins)
	top:         i32,
	configured:  bool,
	dirty:       bool,
	hovered:     bool,
	mx, my:      f32,
	part:        int, // under the pointer: -1 card, 0 close, 1.. action
	close_r:     Rect,
	action_r:    [6]Rect,
	n_actions:   int,
	// Laid-out text, kept between renders.
	summary:     []string,
	body:        []string,
	scale:       i32,
	// The card without its timeout line, so the line can be redrawn alone.
	base:        []u32,
	bar_px:      int, // timeout line width last presented, in buffer pixels
	bar_at:      time.Tick,
	refill_at:   time.Tick,
}

@(private = "file") popups: [dynamic]^Popup

notify_owns :: proc(surface: ^wl.Surface) -> bool {return find_popup(surface) != nil}

@(private = "file")
find_popup :: proc(surface: ^wl.Surface) -> ^Popup {
	if surface == nil {return nil}
	for p in popups {if p.surface == surface {return p}}
	return nil
}

// ---- Text layout ----------------------------------------------------------------

// Word-wrap into at most max_lines lines of width w; the last one gets "…".
@(private = "file")
wrap :: proc(f: ^Soft_Font, px, w: f32, text: string, max_lines: int) -> []string {
	lines: [dynamic]string
	for para in strings.split_lines(text, context.temp_allocator) {
		rest := strings.trim_space(para)
		if rest == "" {continue}
		for rest != "" {
			if len(lines) == max_lines {
				last := lines[len(lines) - 1]
				lines[len(lines) - 1] = ellipsize(f, px, w, strings.concatenate({last, " ", rest}, context.temp_allocator))
				return lines[:]
			}
			// Longest prefix that fits, broken at a space when possible.
			fit := len(rest)
			if soft_text_width(f, px, rest) > w {
				fit = 0
				space := -1
				for i := 0; i < len(rest); {
					_, sz := utf8.decode_rune_in_string(rest[i:])
					if soft_text_width(f, px, rest[:i + sz]) > w {break}
					i += sz
					fit = i
					if i < len(rest) && rest[i] == ' ' {space = i}
				}
				if space > 0 && fit < len(rest) {fit = space}
				if fit == 0 {_, fit = utf8.decode_rune_in_string(rest)}
			}
			append(&lines, strings.clone(strings.trim_right_space(rest[:fit])))
			rest = strings.trim_left_space(rest[fit:])
		}
	}
	return lines[:]
}

@(private = "file")
ellipsize :: proc(f: ^Soft_Font, px, w: f32, s: string) -> string {
	if soft_text_width(f, px, s) <= w {return strings.clone(s)}
	ell := "…"
	cut := len(s)
	for cut > 0 && soft_text_width(f, px, s[:cut]) + soft_text_width(f, px, ell) > w {
		_, sz := utf8.decode_last_rune_in_string(s[:cut])
		cut -= sz
	}
	return strings.concatenate({strings.trim_right_space(s[:cut]), ell})
}

@(private = "file")
free_lines :: proc(lines: []string) {
	for l in lines {delete(l)}
	delete(lines)
}

// Card height for a notification (and the laid-out text).
@(private = "file")
layout :: proc(p: ^Popup, n: ^Notification) -> i32 {
	soft_fonts_init()
	free_lines(p.summary)
	free_lines(p.body)
	tw := f32(CARD_W - PAD * 2 - ICON - 12)
	p.summary = wrap(&soft_bold, PX_SUMMARY, tw, n.summary != "" ? n.summary : n.app, 2)
	p.body = wrap(&soft_regular, PX_BODY, tw, n.body, 4)
	h := f32(PAD) + 16 // app line
	h += f32(len(p.summary)) * 19
	if len(p.body) > 0 {h += 2 + f32(len(p.body)) * 18}
	if n.value >= 0 {h += 14}
	p.n_actions = 0
	for a in n.actions {if a.key != "default" && p.n_actions < len(p.action_r) {p.n_actions += 1}}
	if p.n_actions > 0 {h += 12 + 28}
	h = max(h + PAD, f32(PAD * 2 + ICON))
	return i32(math.ceil(h))
}

// ---- Drawing ----------------------------------------------------------------------

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

// Signed distance to a rounded rectangle (negative inside).
@(private = "file")
rr_dist :: proc(x, y: f32, r: Rect, radius: f32) -> f32 {
	cx := clamp(x, r.x + radius, r.x + r.w - radius)
	cy := clamp(y, r.y + radius, r.y + r.h - radius)
	dx, dy := x - cx, y - cy
	return math.sqrt(dx * dx + dy * dy) - radius
}

@(private = "file")
Canvas :: struct {
	px:    []u32,
	w, h:  int,
	s:     f32, // buffer scale
}

@(private = "file")
fill_rr :: proc(cv: ^Canvas, r: Rect, radius: f32, rgb: u32, alpha: f32) {
	s := cv.s
	rs := Rect{r.x * s, r.y * s, r.w * s, r.h * s}
	x0, y0 := max(int(rs.x), 0), max(int(rs.y), 0)
	x1, y1 := min(int(math.ceil(rs.x + rs.w)), cv.w), min(int(math.ceil(rs.y + rs.h)), cv.h)
	for y in y0 ..< y1 {
		for x in x0 ..< x1 {
			d := rr_dist(f32(x) + 0.5, f32(y) + 0.5, rs, radius * s)
			cov := clamp(0.5 - d, 0, 1)
			if cov > 0 {blend(&cv.px[y * cv.w + x], rgb, cov * alpha)}
		}
	}
}

// 1px (logical) outline just inside a rounded rect.
@(private = "file")
stroke_rr :: proc(cv: ^Canvas, r: Rect, radius: f32, rgb: u32, alpha: f32) {
	s := cv.s
	rs := Rect{r.x * s, r.y * s, r.w * s, r.h * s}
	for y in max(int(rs.y), 0) ..< min(int(math.ceil(rs.y + rs.h)), cv.h) {
		for x in max(int(rs.x), 0) ..< min(int(math.ceil(rs.x + rs.w)), cv.w) {
			d := rr_dist(f32(x) + 0.5, f32(y) + 0.5, rs, radius * s)
			cov := clamp(0.5 - d, 0, 1) - clamp(0.5 - (d + s), 0, 1)
			if cov > 0 {blend(&cv.px[y * cv.w + x], rgb, cov * alpha)}
		}
	}
}

@(private = "file")
text :: proc(cv: ^Canvas, f: ^Soft_Font, px: f32, x, top: f32, s: string, rgb: u32, alpha: f32 = 1) {
	baseline := top + soft_ascent(f, px)
	soft_draw_text(cv.px, cv.w, cv.h, f, px * cv.s, x * cv.s, baseline * cv.s, s, rgb, alpha)
}

// Icon thumbnail (ICON_PX²) scaled into a size×size box, bilinear.
@(private = "file")
draw_icon :: proc(cv: ^Canvas, ic: ^Notif_Icon, x, y, size: f32) {
	s := cv.s
	dx, dy, ds := int(x * s), int(y * s), int(size * s)
	box := Rect{f32(dx), f32(dy), f32(ds), f32(ds)}
	for py in 0 ..< ds {
		for px in 0 ..< ds {
			tx := clamp((f32(px) + 0.5) / f32(ds) * ICON_PX - 0.5, 0, ICON_PX - 1)
			ty := clamp((f32(py) + 0.5) / f32(ds) * ICON_PX - 0.5, 0, ICON_PX - 1)
			ix, iy := int(tx), int(ty)
			fx, fy := tx - f32(ix), ty - f32(iy)
			ix1, iy1 := min(ix + 1, ICON_PX - 1), min(iy + 1, ICON_PX - 1)
			c := [4]f32{}
			for ch in 0 ..< 4 {
				sh := u32(ch * 8)
				get :: proc(ic: ^Notif_Icon, x, y: int, sh: u32) -> f32 {return f32((ic.px[y * ICON_PX + x] >> sh) & 0xff)}
				top := get(ic, ix, iy, sh) * (1 - fx) + get(ic, ix1, iy, sh) * fx
				bot := get(ic, ix, iy1, sh) * (1 - fx) + get(ic, ix1, iy1, sh) * fx
				c[ch] = top * (1 - fy) + bot * fy
			}
			m: f32 = 1
			if ic.rounded {m = clamp(0.5 - rr_dist(f32(dx + px) + 0.5, f32(dy + py) + 0.5, box, 9 * s), 0, 1)}
			a := c[3] / 255 * m
			if a <= 0 {continue}
			x, y := dx + px, dy + py
			if x < 0 || y < 0 || x >= cv.w || y >= cv.h {continue}
			// Source is premultiplied: un-premultiply for blend().
			rgb := u32(c[2] / max(c[3], 1) * 255) << 16 | u32(c[1] / max(c[3], 1) * 255) << 8 | u32(c[0] / max(c[3], 1) * 255)
			blend(&cv.px[y * cv.w + x], rgb, a)
		}
	}
}

@(private = "file")
APP_COLORS := [?]u32{C_BLUE, C_PURPLE, C_TEAL, C_ORANGE, C_GREEN, C_CYAN, C_YELLOW}

app_color :: proc(app: string) -> u32 {
	h: u32 = 2166136261
	for b in transmute([]u8)app {h = (h ~ u32(b)) * 16777619}
	return APP_COLORS[h % len(APP_COLORS)]
}

app_initial :: proc(app: string) -> string {
	for r in app {return strings.to_upper(utf8.runes_to_string({r}, context.temp_allocator), context.temp_allocator)}
	return "?"
}

@(private = "file")
render :: proc(p: ^Popup, n: ^Notification) {
	if plat.shm == nil {return}
	s := max(p.scale, 1)
	bw, bh := p.w * s, p.h * s
	if len(p.base) != int(bw * bh) {
		delete(p.base)
		p.base = make([]u32, bw * bh)
	} else {
		slice.zero(p.base)
	}
	cv := Canvas{px = p.base, w = int(bw), h = int(bh), s = f32(s)}

	card := Rect{SHADOW_M, SHADOW_M, CARD_W, f32(p.h - 2 * SHADOW_M)}
	// Shadow: soft falloff around the card, a little heavier below it.
	{
		sc := Rect{card.x * cv.s, (card.y + 3) * cv.s, card.w * cv.s, card.h * cv.s}
		spread := f32(SHADOW_M - 2) * cv.s
		for y in 0 ..< cv.h {
			for x in 0 ..< cv.w {
				d := rr_dist(f32(x) + 0.5, f32(y) + 0.5, sc, RADIUS * cv.s)
				if d <= 0 {d = 0}
				t := clamp(1 - d / spread, 0, 1)
				a := t * t * 0.45
				if a > 0 {cv.px[y * cv.w + x] = u32(a * 255) << 24}
			}
		}
	}
	critical := n.urgency == 2
	fill_rr(&cv, card, RADIUS, p.hovered ? C_CARD_HI : C_CARD, 0.98)
	stroke_rr(&cv, card, RADIUS, critical ? C_RED : C_BORDER, critical ? 0.9 : 1)

	ix, iy := card.x + PAD, card.y + PAD
	if n.icon != nil {
		draw_icon(&cv, n.icon, ix, iy, ICON)
	} else {
		col := app_color(n.app)
		fill_rr(&cv, {ix, iy, ICON, ICON}, ICON / 2, col, 0.22)
		ini := app_initial(n.app)
		w := soft_text_width(&soft_bold, 18, ini)
		text(&cv, &soft_bold, 18, ix + (ICON - w) / 2, iy + 9, ini, col)
	}

	tx := ix + ICON + 12
	tw := card.x + card.w - PAD - tx
	y := card.y + PAD - 1
	// App name · time; the close button takes the corner on hover.
	app := n.app != "" ? n.app : "Notification"
	stamp := ""
	if r, ok := clock_read(local_region, time.unix(n.at, 0)); ok {stamp = fmt.tprintf("%02d:%02d", r.dt.hour, r.dt.minute)}
	head := ellipsize(&soft_regular, PX_APP, tw - 60, app)
	defer delete(head)
	text(&cv, &soft_regular, PX_APP, tx, y, head, critical ? C_RED : C_MUTED)
	cx := tx + soft_text_width(&soft_regular, PX_APP, head) + 7
	// More messages from this app came in before this one: how many are new.
	if run := notif_run_unread(notifs.list[:], n); run > 1 {
		more := fmt.tprintf("· %d new", run)
		text(&cv, &soft_regular, PX_APP, cx - 2, y, more, C_FAINT)
		cx += soft_text_width(&soft_regular, PX_APP, more) + 5
	}
	// The same text again: a counter after the app name.
	if n.count > 1 {
		cnt := fmt.tprintf("×%d", n.count)
		cw := soft_text_width(&soft_bold, PX_APP - 1, cnt)
		fill_rr(&cv, {cx, y - 1, cw + 12, 16}, 8, C_PURPLE, 0.18)
		text(&cv, &soft_bold, PX_APP - 1, cx + 6, y, cnt, C_PURPLE)
	}
	if p.hovered {
		p.close_r = {card.x + card.w - PAD - 20, card.y + PAD - 5, 24, 24}
		hot := p.part == 0
		fill_rr(&cv, p.close_r, 12, hot ? C_RED : C_OVERLAY, hot ? 0.22 : 0.07)
		cw := soft_text_width(&soft_symbols, 14, ICON_CLOSE)
		text(&cv, &soft_symbols, 14, p.close_r.x + (p.close_r.w - cw) / 2, p.close_r.y + 4, ICON_CLOSE, hot ? C_RED : C_MUTED)
	} else if stamp != "" {
		sw := soft_text_width(&soft_regular, PX_APP, stamp)
		text(&cv, &soft_regular, PX_APP, card.x + card.w - PAD - sw, y, stamp, C_FAINT)
	}
	y += 16
	for line in p.summary {
		text(&cv, &soft_bold, PX_SUMMARY, tx, y, line, C_TEXT)
		y += 19
	}
	if len(p.body) > 0 {
		y += 2
		for line in p.body {
			text(&cv, &soft_regular, PX_BODY, tx, y, line, C_TEXT, 0.78)
			y += 18
		}
	}
	if n.value >= 0 {
		y += 5
		fill_rr(&cv, {tx, y, tw, 5}, 2.5, 0xffffff, 0.08)
		v := clamp(f32(n.value), 0, 100) / 100
		if v > 0 {fill_rr(&cv, {tx, y, max(tw * v, 5), 5}, 2.5, C_BLUE, 1)}
		y += 9
	}
	if p.n_actions > 0 {
		y += 12
		ax := tx
		i := 0
		for a in n.actions {
			if a.key == "default" || i >= p.n_actions {continue}
			label := a.label != "" ? a.label : a.key
			w := min(soft_text_width(&soft_bold, PX_ACTION, label) + 24, card.x + card.w - PAD - ax)
			if w < 40 {break}
			r := Rect{ax, y, w, 28}
			p.action_r[i] = r
			hot := p.part == i + 1
			fill_rr(&cv, r, 8, C_BLUE, hot ? 0.3 : 0.14)
			l := ellipsize(&soft_bold, PX_ACTION, w - 24, label)
			text(&cv, &soft_bold, PX_ACTION, ax + 12, y + 7, l, C_BLUE)
			delete(l)
			ax += w + 8
			i += 1
		}
		p.n_actions = i
	}
	p.dirty = false
	p.rev = n.rev
	present(p, n)
}

// Fraction of the timeout left, or -1 for popups that stay until dismissed.
@(private = "file")
bar_frac :: proc(n: ^Notification) -> f32 {
	if n.timeout <= 0 {return -1}
	if n.expires == {} {return 1}
	return clamp(f32(time.tick_diff(time.tick_now(), n.expires)) / f32(n.timeout), 0, 1)
}

@(private = "file")
bar_width :: proc(p: ^Popup, f: f32) -> int {return int(CARD_W * f32(max(p.scale, 1)) * f)}

// Copy the rendered card into a fresh buffer, add the timeout line, show it.
@(private = "file")
present :: proc(p: ^Popup, n: ^Notification) {
	s := max(p.scale, 1)
	bw, bh := p.w * s, p.h * s
	if len(p.base) != int(bw * bh) {return}
	size := int(bw * bh * 4)
	fd, err := linux.memfd_create("wlperch-notification", {.CLOEXEC})
	if err != .NONE {return}
	defer linux.close(fd)
	if linux.ftruncate(fd, i64(size)) != .NONE {return}
	mem := posix.mmap(nil, uint(size), {.READ, .WRITE}, {.SHARED}, posix.FD(fd), 0)
	if mem == posix.MAP_FAILED {return}
	cv := Canvas{px = ([^]u32)(mem)[:bw * bh], w = int(bw), h = int(bh), s = f32(s)}
	copy(cv.px, p.base)

	card := Rect{SHADOW_M, SHADOW_M, CARD_W, f32(p.h - 2 * SHADOW_M)}
	f := bar_frac(n)
	if f > 0 {
		// Clipped to the card's rounded corners; anti-aliased at the moving end.
		rs := Rect{card.x * cv.s, card.y * cv.s, card.w * cv.s, card.h * cv.s}
		end := rs.x + rs.w * f
		for y in max(int(rs.y + rs.h - BAR_H * cv.s), 0) ..< min(int(math.ceil(rs.y + rs.h)), cv.h) {
			for x in max(int(rs.x), 0) ..< min(int(math.ceil(end)), cv.w) {
				d := rr_dist(f32(x) + 0.5, f32(y) + 0.5, rs, RADIUS * cv.s)
				cov := clamp(0.5 - d, 0, 1) * clamp(end - f32(x), 0, 1)
				if cov > 0 {blend(&cv.px[y * cv.w + x], C_BLUE, cov * 0.85)}
			}
		}
	}
	p.bar_px = bar_width(p, max(f, 0))
	p.bar_at = time.tick_now()
	posix.munmap(mem, uint(size))

	pool := wl.shm_create_pool(plat.shm, i32(fd), i32(size))
	buf := wl.shm_pool_create_buffer(pool, 0, bw, bh, bw * 4, wl.SHM_FORMAT_ARGB8888)
	wl.shm_pool_destroy(pool)
	wl.buffer_add_listener(buf, &buffer_listener, nil)
	wl.surface_set_buffer_scale(p.surface, s)
	wl.surface_attach(p.surface, buf, 0, 0)
	wl.surface_damage_buffer(p.surface, 0, 0, bw, bh)
	// Only the card takes clicks; the shadow lets them through.
	region := wl.compositor_create_region(plat.compositor)
	wl.region_add(region, i32(card.x), i32(card.y), i32(card.w), i32(card.h))
	wl.surface_set_input_region(p.surface, region)
	wl.region_destroy(region)
	wl.surface_commit(p.surface)
}

@(private = "file")
buffer_listener := wl.Buffer_Listener {
	release = proc "c" (data: rawptr, self: ^wl.Buffer) {wl.buffer_destroy(self)},
}

// ---- Surfaces ---------------------------------------------------------------------

@(private = "file")
layer_listener := wl.Zwlr_Layer_Surface_V1_Listener {
	configure = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1, serial, width, height: u32) {
		p := cast(^Popup)data
		wl.zwlr_layer_surface_v1_ack_configure(self, serial)
		p.configured = true
		p.dirty = true
	},
	closed = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1) {
		(cast(^Popup)data).configured = false
	},
}

@(private = "file")
output_scale :: proc() -> i32 {
	s: i32 = 1
	for o in plat.outputs {s = max(s, o.scale)}
	return s
}

@(private = "file")
create :: proc(n: ^Notification, place: Popup_Place) -> ^Popup {
	if plat.layer_shell == nil || plat.compositor == nil {return nil}
	p := new(Popup)
	p.id = n.id
	p.conn = place.output != nil ? strings.clone(place.conn) : ""
	p.part = -1
	p.scale = output_scale()
	p.h = layout(p, n) + 2 * SHADOW_M
	p.w = CARD_W + 2 * SHADOW_M
	p.surface = wl.compositor_create_surface(plat.compositor)
	p.layer = wl.zwlr_layer_shell_v1_get_layer_surface(plat.layer_shell, p.surface, place.output, wl.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "wlperch-notification")
	wl.zwlr_layer_surface_v1_add_listener(p.layer, &layer_listener, p)
	wl.zwlr_layer_surface_v1_set_anchor(p.layer, wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT)
	wl.zwlr_layer_surface_v1_set_size(p.layer, u32(p.w), u32(p.h))
	wl.zwlr_layer_surface_v1_set_margin(p.layer, TOP_MARGIN - SHADOW_M, RIGHT_MARGIN - SHADOW_M, 0, 0)
	wl.surface_commit(p.surface)
	return p
}

@(private = "file")
destroy :: proc(p: ^Popup) {
	if plat.pointer_surface == p.surface {plat.pointer_surface = nil}
	wl.zwlr_layer_surface_v1_destroy(p.layer)
	wl.surface_destroy(p.surface)
	free_lines(p.summary)
	free_lines(p.body)
	delete(p.base)
	delete(p.conn)
	free(p)
}

// Show even when a fullscreen game covers every output: critical ones and
// volume / brightness OSDs (what do not disturb lets through too).
@(private = "file")
passes_hold :: proc(n: ^Notification) -> bool {
	return n.urgency == 2 || (n.tag != "" && n.value >= 0)
}

// Over a fullscreen game: a short look (GLIMPSE), then it waits.
@(private = "file")
start_glimpse :: proc(n: ^Notification) {
	if n.glimpse || n.glimpsed {return}
	n.glimpse = true
	n.glimpse_timeout = n.timeout
	if n.timeout == 0 || n.timeout > GLIMPSE {n.timeout = GLIMPSE}
	n.expires = {}
}

@(private = "file")
end_glimpse :: proc(n: ^Notification) {
	if !n.glimpse && !n.glimpsed {return}
	n.timeout = n.glimpse_timeout
	n.glimpse, n.glimpsed = false, false
	n.expires = {} // its full time, once on screen again
}

// Popups waiting for a fullscreen game to go (for the bar and the center).
notif_held_count :: proc() -> int {
	if !notifs.held {return 0}
	c := 0
	for n in notifs.list {if n.popup && (!passes_hold(n) || n.glimpsed) {c += 1}}
	return c
}

// Match the set of popups to the notifications that want one: newest on top,
// on the focused output unless a fullscreen game covers it ([notifications]
// fullscreen): then on another output, or none at all (they wait, timers
// paused, and appear once the game leaves fullscreen).
notify_popups_layout :: proc() {
	place := popup_place()
	held := !place.free
	if notifs.held && !held {
		// Back from the game: the newest few pop up, the rest wait in the center.
		c := 0
		for i := len(notifs.list) - 1; i >= 0; i -= 1 {
			n := notifs.list[i]
			if !n.popup || n.transient || (passes_hold(n) && !n.glimpsed) {continue}
			c += 1
			if c > MAX_VISIBLE {n.popup = false}
		}
	}
	notifs.held = held
	if !held {
		for n in notifs.list {end_glimpse(n)}
	}

	want: [dynamic]^Notification
	want.allocator = context.temp_allocator
	for i := len(notifs.list) - 1; i >= 0 && len(want) < MAX_VISIBLE; i -= 1 {
		n := notifs.list[i]
		if !n.popup {continue}
		if held && (!passes_hold(n) || n.glimpsed) {continue}
		append(&want, n)
	}
	// Drop popups that are no longer wanted, or sit on an output a game now
	// covers while another one is free (they move there).
	for i := len(popups) - 1; i >= 0; i -= 1 {
		p := popups[i]
		keep := false
		for n in want {if n.id == p.id {keep = true}}
		covered := fullscreen_blocks(p.conn)
		if keep && covered && !held {keep = false}
		if !keep {
			if n, _ := notif_find(p.id); n != nil && n.popup {
				// Held or moving: the timer starts afresh where it shows next.
				n.expires = {}
				n.hover = false
			}
			destroy(p)
			ordered_remove(&popups, i)
		} else if covered {
			if n, _ := notif_find(p.id); n != nil {start_glimpse(n)}
		}
	}
	ordered: [dynamic]^Popup
	tops := make(map[string]i32, 4, context.temp_allocator) // stacked per output
	for n in want {
		p: ^Popup
		for q in popups {if q.id == n.id {p = q}}
		if p == nil {
			p = create(n, place)
			if p == nil {continue}
			if held {start_glimpse(n)}
			append(&popups, p)
		} else if p.rev != n.rev {
			// Replaced content: new size, redraw.
			h := layout(p, n) + 2 * SHADOW_M
			if h != p.h {
				p.h = h
				wl.zwlr_layer_surface_v1_set_size(p.layer, u32(p.w), u32(p.h))
			}
			p.dirty = true
		}
		top := tops[p.conn] or_else TOP_MARGIN
		if p.top != top {
			p.top = top
			wl.zwlr_layer_surface_v1_set_margin(p.layer, top - SHADOW_M, RIGHT_MARGIN - SHADOW_M, 0, 0)
			if p.configured && !p.dirty {wl.surface_commit(p.surface)}
		}
		tops[p.conn] = top + p.h - 2 * SHADOW_M + GAP
		append(&ordered, p)
	}
	delete(popups)
	popups = ordered
}

// Render what changed; start expiry timers for popups that just appeared;
// move the timeout lines (hovering refills them instead of pausing).
notify_popups_tick :: proc() {
	now := time.tick_now()
	for p in popups {
		n, _ := notif_find(p.id)
		if n == nil || !p.configured {continue}
		if n.timeout > 0 && n.expires != {} {
			if n.hover && p.refill_at != {} {
				left := time.tick_diff(now, n.expires)
				left += time.Duration(f64(time.tick_diff(p.refill_at, now)) * f64(n.timeout) / f64(BAR_REFILL))
				n.expires = time.tick_add(now, min(left, n.timeout))
			}
		}
		p.refill_at = now
		if p.dirty || p.rev != n.rev {
			render(p, n)
		} else if f := bar_frac(n); f >= 0 && bar_width(p, f) != p.bar_px && time.tick_diff(p.bar_at, now) >= BAR_FRAME {
			present(p, n)
		}
		if n.expires == {} && n.timeout > 0 {n.expires = time.tick_add(now, n.timeout)}
	}
}

// Redraw every popup (the theme changed).
notify_popups_restyle :: proc() {
	for p in popups {p.dirty = true}
}

// How long until a timeout line needs to move (-1: none moving).
notify_popups_next_frame :: proc() -> time.Duration {
	best := time.Duration(-1)
	now := time.tick_now()
	for p in popups {
		n, _ := notif_find(p.id)
		if n == nil || !p.configured || n.timeout <= 0 || n.expires == {} {continue}
		if plat.away && !n.hover {continue} // held while away: the line stands still
		left := time.tick_diff(now, n.expires)
		wait := BAR_FRAME - time.tick_diff(p.bar_at, now)
		if n.hover {
			if left >= n.timeout {continue} // full again
		} else {
			// Until the line loses its next pixel.
			px_dur := n.timeout / time.Duration(bar_width(p, 1))
			next := left - time.Duration(bar_width(p, bar_frac(n))) * px_dur + time.Millisecond
			wait = max(wait, next)
		}
		wait = max(wait, 0)
		if best < 0 || wait < best {best = wait}
	}
	return best
}

// ---- Pointer (called from the platform's pointer listener) ---------------------------

@(private = "file")
hit :: proc(p: ^Popup) -> int {
	if p.hovered && in_rect(p.close_r, p.mx, p.my) {return 0}
	for i in 0 ..< p.n_actions {if in_rect(p.action_r[i], p.mx, p.my) {return i + 1}}
	return -1
}

notify_on_enter :: proc(surface: ^wl.Surface, x, y: f32) -> bool {
	p := find_popup(surface)
	if p == nil {return false}
	p.hovered = true
	p.mx, p.my = x, y
	p.part = hit(p)
	p.dirty = true
	if n, _ := notif_find(p.id); n != nil {n.hover = true}
	if plat.cursor_device != nil {
		wl.wp_cursor_shape_device_v1_set_shape(plat.cursor_device, plat.pointer_serial, wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER)
	}
	return true
}

notify_on_leave :: proc(surface: ^wl.Surface) -> bool {
	p := find_popup(surface)
	if p == nil {return false}
	p.hovered = false
	p.part = -1
	p.dirty = true
	if n, _ := notif_find(p.id); n != nil {
		n.hover = false
		// A moment to move away before it disappears.
		if n.expires != {} {
			if left := time.tick_diff(time.tick_now(), n.expires); left < 2 * time.Second {
				n.expires = time.tick_add(time.tick_now(), 2 * time.Second)
			}
		}
	}
	return true
}

notify_on_motion :: proc(surface: ^wl.Surface, x, y: f32) -> bool {
	p := find_popup(surface)
	if p == nil {return false}
	p.mx, p.my = x, y
	if part := hit(p); part != p.part {
		p.part = part
		p.dirty = true
	}
	return true
}

notify_on_button :: proc(surface: ^wl.Surface, button, state: u32) -> bool {
	p := find_popup(surface)
	if p == nil {return false}
	if state != wl.POINTER_BUTTON_STATE_RELEASED {return true}
	n, _ := notif_find(p.id)
	if n == nil {return true}
	switch button {
	case 0x110: // left
		part := hit(p)
		switch {
		case part == 0:
			dismiss(n)
		case part > 0:
			i := 0
			for a in n.actions {
				if a.key == "default" {continue}
				i += 1
				if i == part {notif_invoke(n.id, a.key); break}
			}
		case:
			has_default := false
			for a in n.actions {if a.key == "default" {has_default = true}}
			if has_default {notif_invoke(n.id, "default")} else {focus_app(n); dismiss(n)}
		}
	case 0x111: // right
		dismiss(n)
	case 0x112: // middle: everything goes
		for x in notifs.list {if x.popup {dismiss(x)}}
	}
	return true
}

// Off the screen (and read); the app hears it was dismissed.
@(private = "file")
dismiss :: proc(n: ^Notification) {
	n.read = true
	n.popup = false
	notif_close(n.id, .Dismissed)
}
