// The setup window's Wallpapers tab: the images in [wallpapers] directory as
// a grid of thumbnails, each with a Dark and a Light switch (the sets in
// wallpapers.odin, used by theme switches) and a click to show it now.
//
// Thumbnails are made on a worker thread: decoded (stb_image), cropped to
// 16:9, scaled down and cached in ~/.cache/wlperch/wallpaper-thumbs (by path,
// mtime and size), so they load at once the next time. Only cards on screen
// get a GL texture, at most MAX_TEXTURES; all are freed when the tab is left.
package main

import "core:c"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import im "third_party:odin-imgui"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

THUMB_W :: 320
THUMB_H :: 180
@(private = "file") THUMB_MAGIC :: "WLT1"
@(private = "file") THUMB_HEADER :: 12 // magic, source width, source height (u32 LE)
@(private = "file") MAX_PIXELS :: 200_000_000 // bigger images aren't decoded (memory)
@(private = "file") MAX_TEXTURES :: 120
@(private = "file") UPLOADS_PER_FRAME :: 6
@(private = "file") CARD_MIN_W :: 250
@(private = "file") GAP :: 14

foreign import libc_wp "system:c"
@(private = "file", default_calling_convention = "c")
foreign libc_wp {
	malloc_trim :: proc(pad: c.size_t) -> c.int ---
}

@(private = "file")
Thumb :: struct {
	name:         string, // heap
	state:        enum {None, Queued, Ready, Failed},
	px:           []u8, // RGBA THUMB_W x THUMB_H while Ready, until uploaded
	tex:          u32,
	src_w, src_h: i32,
	seen:         int, // frame it was last on screen
}

@(private = "file")
Job :: struct {
	gen:        int,
	path, name: string, // heap
	show:       bool, // wanted on screen; else only the cache file is made
}

@(private = "file")
Result :: struct {
	gen:      int,
	name:     string, // heap
	px:       []u8,   // heap; nil for a cache-only job or a failure
	w, h:     i32,
	show, ok: bool,
}

@(private = "file")
wp: struct {
	// Main thread.
	loaded:    bool,
	dir:       string, // heap; the folder shown ("" = none)
	dir_buf:   [512]u8,
	dir_ok:    bool,
	thumbs:    [dynamic]Thumb,
	index:     map[string]int,
	entries:   [dynamic]Wallpaper_Entry, // heap strings
	dir_mtime: i64,
	checked:   time.Tick,
	frame:     int,
	textures:  int,
	drawn:     bool, // since the tab was last left
	current:   string, // heap; full path of the wallpaper showing
	// Shared with the worker.
	mu:        sync.Mutex,
	cond:      sync.Cond,
	gen:       int,
	show_q:    [dynamic]Job,
	cache_q:   [dynamic]Job,
	results:   [dynamic]Result,
	worker:    ^thread.Thread,
}

// ---- Thumbnails (worker) -------------------------------------------------------

// Cover-crop straight RGBA `src` (w x h) to 16:9 and box-filter it into `out`
// (THUMB_W x THUMB_H RGBA). Big sources are sampled sparsely.
wallpaper_thumb_cover :: proc(src: []u8, w, h: int, out: []u8) {
	cw, ch := f32(w), f32(h)
	if cw * THUMB_H > ch * THUMB_W {cw = ch * THUMB_W / THUMB_H} else {ch = cw * THUMB_H / THUMB_W}
	x0, y0 := (f32(w) - cw) / 2, (f32(h) - ch) / 2
	sx, sy := cw / THUMB_W, ch / THUMB_H
	for ty in 0 ..< THUMB_H {
		ya := clamp(int(y0 + f32(ty) * sy), 0, h - 1)
		yb := clamp(int(y0 + f32(ty + 1) * sy), ya + 1, h)
		ystep := max(1, (yb - ya) / 12)
		for tx in 0 ..< THUMB_W {
			xa := clamp(int(x0 + f32(tx) * sx), 0, w - 1)
			xb := clamp(int(x0 + f32(tx + 1) * sx), xa + 1, w)
			xstep := max(1, (xb - xa) / 12)
			sum: [4]u32
			n: u32
			for yy := ya; yy < yb; yy += ystep {
				row := src[yy * w * 4:]
				for xx := xa; xx < xb; xx += xstep {
					for k in 0 ..< 4 {sum[k] += u32(row[xx * 4 + k])}
					n += 1
				}
			}
			o := out[(ty * THUMB_W + tx) * 4:]
			for k in 0 ..< 4 {o[k] = u8((sum[k] + n / 2) / n)}
		}
	}
}

@(private = "file")
thumb_cache_dir :: proc() -> string {
	base := os.get_env("XDG_CACHE_HOME", context.temp_allocator)
	if base == "" {base = strings.concatenate({home_dir(), "/.cache"}, context.temp_allocator)}
	return strings.concatenate({base, "/wlperch/wallpaper-thumbs"}, context.temp_allocator)
}

@(private = "file")
u32_le :: proc(b: []u8) -> u32 {return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24}

// The thumbnail of `path`: from the cache, else decoded (and cached). With
// `want` false only the cache file is made, and px is nil.
@(private = "file")
thumb_make :: proc(path: string, want: bool) -> (px: []u8, w, h: i32, ok: bool) {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {return}
	key := fmt.tprintf("%s\x00%d\x00%d", path, time.to_unix_nanoseconds(fi.modification_time), fi.size)
	dir := thumb_cache_dir()
	cache := fmt.tprintf("%s/%016x.rgba", dir, hash.fnv64a(transmute([]u8)key))
	SIZE :: THUMB_HEADER + THUMB_W * THUMB_H * 4
	if data, rerr := os.read_entire_file(cache, context.temp_allocator); rerr == nil && len(data) == SIZE && string(data[:4]) == THUMB_MAGIC {
		w, h = i32(u32_le(data[4:])), i32(u32_le(data[8:]))
		if want {px = make([]u8, THUMB_W * THUMB_H * 4); copy(px, data[THUMB_HEADER:])}
		return px, w, h, true
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	iw, ih, n: c.int
	if stbi.info(cpath, &iw, &ih, &n) == 0 || iw <= 0 || ih <= 0 || int(iw) * int(ih) > MAX_PIXELS {return}
	src := stbi.load(cpath, &iw, &ih, &n, 4)
	if src == nil {return}
	defer stbi.image_free(src)
	file := make([]u8, SIZE, context.temp_allocator)
	copy(file, THUMB_MAGIC)
	for i in 0 ..< 4 {
		file[4 + i] = u8(u32(iw) >> uint(8 * i))
		file[8 + i] = u8(u32(ih) >> uint(8 * i))
	}
	wallpaper_thumb_cover(src[:int(iw) * int(ih) * 4], int(iw), int(ih), file[THUMB_HEADER:])
	os.make_directory_all(dir)
	tmp := fmt.tprintf("%s.tmp%d", cache, os.get_pid())
	if os.write_entire_file(tmp, file) == nil {os.rename(tmp, cache)}
	if want {px = make([]u8, THUMB_W * THUMB_H * 4); copy(px, file[THUMB_HEADER:])}
	return px, i32(iw), i32(ih), true
}

@(private = "file")
worker_main :: proc() {
	for {
		job: Job
		sync.mutex_lock(&wp.mu)
		for len(wp.show_q) == 0 && len(wp.cache_q) == 0 {sync.cond_wait(&wp.cond, &wp.mu)}
		// The latest card scrolled to first; the cache for the rest after.
		if len(wp.show_q) > 0 {job = pop(&wp.show_q)} else {job = pop_front(&wp.cache_q)}
		sync.mutex_unlock(&wp.mu)

		px, w, h, ok := thumb_make(job.path, job.show)
		delete(job.path)
		sync.mutex_lock(&wp.mu)
		if job.gen == wp.gen {
			append(&wp.results, Result{job.gen, job.name, px, w, h, job.show, ok})
		} else {
			delete(job.name)
			delete(px)
		}
		sync.mutex_unlock(&wp.mu)
		if job.show {wake_main()}
		free_all(context.temp_allocator)
		// A decode takes up to a few hundred MB (a 5K PNG: 59 MB of pixels
		// plus the decoder's buffers); give it back once the queue is done.
		sync.mutex_lock(&wp.mu)
		idle := len(wp.show_q) == 0 && len(wp.cache_q) == 0
		sync.mutex_unlock(&wp.mu)
		if idle {malloc_trim(0)}
	}
}

// ---- State (main thread) -----------------------------------------------------------

@(private = "file")
free_texture :: proc(t: ^Thumb) {
	if t.tex != 0 {
		gl.DeleteTextures(1, &t.tex)
		t.tex = 0
		wp.textures -= 1
	}
	delete(t.px)
	t.px = nil
	if t.state != .Failed {t.state = .None}
}

// From the setup loop's periodic check: the shown folder changed on disk
// (a redraw rescans it).
wallpapers_poll :: proc() -> bool {
	return setup_page == .Look && wp.loaded && dir_stamp(wp.dir) != wp.dir_mtime
}

// Leaving the tab: no textures or pixels stay behind.
wallpapers_release :: proc() {
	if !wp.drawn {return}
	wp.drawn = false
	for &t in wp.thumbs {free_texture(&t)}
	sync.guard(&wp.mu)
	wp.gen += 1 // results on their way are for nothing now
	drop_queues()
}

@(private = "file")
drop_queues :: proc() {
	for j in wp.show_q {delete(j.path); delete(j.name)}
	for j in wp.cache_q {delete(j.path); delete(j.name)}
	for r in wp.results {delete(r.name); delete(r.px)}
	clear(&wp.show_q)
	clear(&wp.cache_q)
	clear(&wp.results)
}

@(private = "file")
dir_stamp :: proc(dir: string) -> i64 {
	fi, err := os.stat(dir, context.temp_allocator)
	if err != nil {return -1}
	return time.to_unix_nanoseconds(fi.modification_time)
}

// (Re)read the folder, the sets and the wallpaper showing.
@(private = "file")
scan :: proc() {
	for &t in wp.thumbs {
		free_texture(&t)
		delete(t.name)
	}
	clear(&wp.thumbs)
	clear(&wp.index)
	files := wallpaper_files(wp.dir)
	wp.dir_ok = wp.dir != "" && os.is_dir(wp.dir)
	wp.dir_mtime = dir_stamp(wp.dir)
	wp.checked = time.tick_now()
	{
		sync.guard(&wp.mu)
		wp.gen += 1
		drop_queues()
		for f, i in files {
			append(&wp.thumbs, Thumb{name = strings.clone(f)})
			wp.index[wp.thumbs[i].name] = i
			// Thumbnails for the whole folder, cached in the background.
			append(&wp.cache_q, Job{wp.gen, fmt.aprintf("%s/%s", wp.dir, f), strings.clone(f), false})
		}
		if wp.worker == nil && len(files) > 0 {
			wp.worker = thread.create_and_start(worker_main, init_context = context)
		}
		sync.cond_signal(&wp.cond)
	}
	for e in wp.entries {delete(e.dir); delete(e.name); delete(e.print)}
	delete(wp.entries)
	wp.entries = wallpaper_sets_load(context.allocator)
	// A renamed file keeps its marks.
	if wallpaper_follow_renames(wp.entries[:], wp.dir, files, context.allocator) {wallpaper_sets_save(wp.entries[:])}
	delete(wp.current)
	cur := wallpaper_current()
	if cur == "" {cur = config.theme_targets[theme_light ? .Light : .Dark].wallpaper}
	wp.current = strings.clone(cur)
}

@(private = "file")
load :: proc() {
	wp.loaded = true
	config_reload_theme()
	delete(wp.dir)
	wp.dir = strings.clone(config.wallpapers_dir)
	wbuf_set(wp.dir_buf[:], tilde(wp.dir))
	scan()
}

// "/home/me/x" -> "~/x"
@(private = "file")
tilde :: proc(path: string) -> string {
	h := home_dir()
	if path != "" && strings.has_prefix(path, h) && (len(path) == len(h) || path[len(h)] == '/') {
		return strings.concatenate({"~", path[len(h):]}, context.temp_allocator)
	}
	return path
}

@(private = "file")
set_dir :: proc(text: string) {
	v := strings.trim_right(strings.trim_space(text), "/")
	if v == "" && strings.trim_space(text) != "" {v = "/"}
	full := strings.has_prefix(v, "~/") ? strings.concatenate({home_dir(), v[1:]}, context.temp_allocator) : v == "~" ? home_dir() : v
	if full == wp.dir {return}
	config_set_value("wallpapers", "directory", tilde(full))
	delete(wp.dir)
	wp.dir = strings.clone(full)
	config.wallpapers_dir = strings.clone(full)
	scan()
}

@(private = "file")
entry_of :: proc(name: string) -> int {
	for e, i in wp.entries {if e.dir == wp.dir && e.name == name {return i}}
	return -1
}

@(private = "file")
set_mark :: proc(name: string, m: Theme_Mode, on: bool) {
	i := entry_of(name)
	if i < 0 {
		if !on {return}
		append(&wp.entries, Wallpaper_Entry{dir = strings.clone(wp.dir), name = strings.clone(name), print = strings.clone(wallpaper_fingerprint(fmt.tprintf("%s/%s", wp.dir, name)))})
		i = len(wp.entries) - 1
	}
	e := &wp.entries[i]
	if m == .Dark {e.dark = on} else {e.light = on}
	if !e.dark && !e.light {
		delete(e.dir)
		delete(e.name)
		delete(e.print)
		ordered_remove(&wp.entries, i)
	}
	wallpaper_sets_save(wp.entries[:])
}

// Show `path` now (swaymsg off the UI thread).
@(private = "file")
apply_async :: proc(path: string) {
	delete(wp.current)
	wp.current = strings.clone(path)
	thread.create_and_start_with_data(rawptr(strings.clone_to_cstring(path)), proc(data: rawptr) {
		p := cstring(data)
		wallpaper_apply(string(p))
		delete(p)
		free_all(context.temp_allocator)
	}, init_context = context, self_cleanup = true)
}

@(private = "file")
upload :: proc(t: ^Thumb) {
	gl.GenTextures(1, &t.tex)
	wp.textures += 1
	gl.BindTexture(gl.TEXTURE_2D, t.tex)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA, THUMB_W, THUMB_H, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(t.px))
	delete(t.px)
	t.px = nil
}

// ---- Drawing --------------------------------------------------------------------------

@(private = "file")
fit :: proc(font: ^im.Font, size: f32, s: string, w: f32) -> string {
	if measure(font, size, s).x <= w {return s}
	for n := len(s) - 1; n > 0; n -= 1 {
		if s[n] & 0xC0 == 0x80 {continue}
		t := fmt.tprintf("%s…", s[:n])
		if measure(font, size, t).x <= w {return t}
	}
	return ""
}

// A Dark / Light switch as a chip: filled in its colour while on.
@(private = "file")
mode_chip :: proc(id, icon, text: string, on: bool, accent: u32) -> bool {
	w := measure(fonts.ui, SZ_SMALL + 1, text).x + 40
	h: f32 = 26
	p := im.GetCursorScreenPos()
	clicked := im.InvisibleButton(cstr(id), {w, h})
	hovered := im.IsItemHovered()
	if hovered {im.SetMouseCursor(.Hand)}
	d := dl()
	if on {
		im.DrawList_AddRectFilled(d, p, {p.x + w, p.y + h}, col32(accent, hovered ? 1 : 0.88), 13)
	} else {
		im.DrawList_AddRectFilled(d, p, {p.x + w, p.y + h}, hovered ? col32(accent, 0.18) : col32(C_CARD_HI), 13)
	}
	fg := on ? col32(0x111318) : col32(C_MUTED)
	draw_icon_centered(fonts.ui, 15, {p.x + 17, p.y + h / 2}, on ? fg : col32(accent, 0.9), icon)
	draw_text(on ? fonts.bold : fonts.ui, SZ_SMALL + 1, {p.x + 30, p.y + (h - 15) / 2}, fg, text)
	return clicked
}

// The Look page's wallpapers, from (x, y) over `width`.
draw_wallpapers :: proc(x, y, width: f32) {
	wp.frame += 1
	wp.drawn = true
	if !wp.loaded {load()}
	// The folder changed on disk (files added, removed, renamed).
	if time.tick_since(wp.checked) > time.Second {
		wp.checked = time.tick_now()
		if dir_stamp(wp.dir) != wp.dir_mtime {scan()}
	}
	// Thumbnails the worker finished.
	{
		sync.guard(&wp.mu)
		for r in wp.results {
			i, ok := wp.index[r.name]
			delete(r.name)
			if !ok || !r.show {
				delete(r.px)
				continue
			}
			t := &wp.thumbs[i]
			t.src_w, t.src_h = r.w, r.h
			if r.ok && r.px != nil {
				delete(t.px)
				t.px = r.px
				t.state = .Ready
			} else {
				t.state = .Failed
			}
		}
		clear(&wp.results)
	}

	n_dark, n_light := 0, 0
	for e in wp.entries {
		if _, ok := wp.index[e.name]; !ok || e.dir != wp.dir {continue}
		if e.dark {n_dark += 1}
		if e.light {n_light += 1}
	}
	mode: Theme_Mode = theme_light ? .Light : .Dark

	// ---- The folder ------------------------------------------------------------------
	im.SetCursorScreenPos({x, y})
	card_begin("##wp-folder", width)
	summary := wp.dir_ok ? fmt.tprintf("%d images · %d for dark · %d for light", len(wp.thumbs), n_dark, n_light) : ""
	card_title(ICON_FOLDER_IMAGE, "Wallpaper folder", C_BLUE, summary)
	inner := im.GetContentRegionAvail().x
	shuffle := fmt.tprintf("%s  Shuffle", ICON_SHUFFLE)
	sw := measure(fonts.bold, SZ_SMALL + 1, shuffle).x + 24
	rescan := fmt.tprintf("%s  Rescan", ICON_REFRESH)
	rw := measure(fonts.bold, SZ_SMALL + 1, rescan).x + 24
	fp := im.GetCursorScreenPos()
	im.PushFontFloat(fonts.ui, SZ_BODY)
	im.PushStyleVarImVec2(.FramePadding, {9, 5})
	im.PushStyleVar(.FrameRounding, 7)
	im.PushStyleVar(.FrameBorderSize, 1)
	im.PushStyleColorImVec4(.FrameBg, rgba(C_WELL))
	im.PushStyleColorImVec4(.FrameBgHovered, rgba(C_WELL))
	im.PushStyleColorImVec4(.FrameBgActive, rgba(C_WELL))
	im.PushStyleColorImVec4(.Border, rgba(C_BORDER))
	im.PushStyleColorImVec4(.TextDisabled, rgba(C_FAINT))
	im.SetNextItemWidth(inner - sw - rw - 20)
	entered := im.InputTextWithHint("##wp-dir", "~/Pictures/wallpapers", cstring(&wp.dir_buf[0]), len(wp.dir_buf), {.EnterReturnsTrue})
	if entered || im.IsItemDeactivatedAfterEdit() {set_dir(wbuf_str(wp.dir_buf[:]))}
	im.PopStyleColor(5)
	im.PopStyleVar(3)
	im.PopFont()
	// Rescan: new or changed files the automatic check missed.
	im.SetCursorScreenPos({fp.x + inner - sw - rw - 8, fp.y})
	if pill_button("##wp-rescan", rescan, wp.dir_ok ? C_BLUE : C_FAINT) && wp.dir_ok {scan()}
	if im.IsItemHovered() {tip("Read the folder again: new, changed and removed images")}
	im.SetCursorScreenPos({fp.x + inner - sw, fp.y})
	can_shuffle := mode == .Dark ? n_dark > 0 : n_light > 0
	if pill_button("##wp-shuffle", shuffle, can_shuffle ? C_BLUE : C_FAINT) && can_shuffle {
		if pick := wallpaper_for_mode(mode); pick != "" {apply_async(pick)}
	}
	if im.IsItemHovered() {
		tip(can_shuffle ? fmt.tprintf("Show a random %s wallpaper now", theme_mode_name(mode)) : fmt.tprintf("Mark wallpapers for %s first", theme_mode_name(mode)))
	}
	im.SetCursorScreenPos({fp.x, fp.y + 34})
	switch {
	case wp.dir == "":
		hint(fmt.tprintf("%s Type the folder that holds your wallpapers (jpg, png) and press Enter.", ICON_INFO), inner, C_MUTED)
	case !wp.dir_ok:
		hint(fmt.tprintf("%s No such folder", ICON_ALERT), inner, C_ORANGE)
	case len(wp.thumbs) == 0:
		hint(fmt.tprintf("%s No jpg or png files in this folder", ICON_ALERT), inner, C_ORANGE)
	}
	// Rotation (the wallpaper process does it; only with wlperch's wallpaper).
	im.Dummy({1, 4})
	if config.wallpapers_rotate_minutes > 0 && !wallpaper_conf_installed() && wallpaper_running() == 0 {
		hint(fmt.tprintf("%s Rotating (Next wallpaper every, above) needs wlperch's wallpaper instead of swaybg: the Wallpaper card at the top of this page.", ICON_INFO), inner, C_ORANGE)
	}
	hint("Switching to dark or light shows a random wallpaper of that set, never the one already showing. With an empty set, the theme's own Wallpaper setting (the Dark / Light theme cards above) is used. Click a picture to show it now.", inner, C_FAINT)
	card_end()

	// ---- The grid ----------------------------------------------------------------------
	top := im.GetItemRectMax().y + 16
	cols := fit_columns(width, CARD_MIN_W, GAP)
	cw := (width - GAP * f32(cols - 1)) / f32(cols)
	th := cw * THUMB_H / THUMB_W
	ch := th + 76
	d := dl()
	uploads := 0
	for &t, i in wp.thumbs {
		p := Vec2{x + f32(i % cols) * (cw + GAP), top + f32(i / cols) * (ch + GAP)}
		if !im.IsRectVisible(p, {p.x + cw, p.y + ch}) {continue}
		t.seen = wp.frame
		path := fmt.tprintf("%s/%s", wp.dir, t.name)
		showing := path == wp.current
		im.DrawList_AddRectFilled(d, p, {p.x + cw, p.y + ch}, col32(C_CARD), 12)

		// The picture: click to show it now.
		switch t.state {
		case .None:
			sync.guard(&wp.mu)
			append(&wp.show_q, Job{wp.gen, strings.clone(path), strings.clone(t.name), true})
			sync.cond_signal(&wp.cond)
			t.state = .Queued
		case .Ready:
			if t.tex == 0 && t.px != nil && uploads < UPLOADS_PER_FRAME {
				upload(&t)
				uploads += 1
			} else if t.tex == 0 {
				request_redraw(1)
			}
		case .Queued, .Failed:
		}
		if t.tex != 0 {
			im.DrawList_AddImageRounded(d, im.TextureRef{_TexID = im.TextureID(t.tex)}, p, {p.x + cw, p.y + th}, {0, 0}, {1, 1}, 0xffffffff, 12, im.DrawFlags_RoundCornersTop)
		} else {
			im.DrawList_AddRectFilled(d, p, {p.x + cw, p.y + th}, col32(C_WELL), 12, im.DrawFlags_RoundCornersTop)
			failed := t.state == .Failed
			draw_icon_centered(fonts.ui, 28, {p.x + cw / 2, p.y + th / 2 - (failed ? 8 : 0)}, col32(failed ? C_ORANGE : C_FAINT, 0.8), failed ? ICON_ALERT : ICON_IMAGE)
			if failed {
				msg := "can't read this image"
				draw_text(fonts.ui, SZ_SMALL, {p.x + (cw - measure(fonts.ui, SZ_SMALL, msg).x) / 2, p.y + th / 2 + 14}, col32(C_MUTED), msg)
			}
		}
		im.SetCursorScreenPos(p)
		if im.InvisibleButton(cstr(fmt.tprintf("##wp-show:%d", i)), {cw, th}) && t.state != .Failed {apply_async(path)}
		if im.IsItemHovered() {
			im.SetMouseCursor(.Hand)
			im.DrawList_AddRectFilled(d, p, {p.x + cw, p.y + th}, col32(0x000000, 0.25), 12, im.DrawFlags_RoundCornersTop)
			label := fmt.tprintf("%s  Show now", ICON_MONITOR)
			lsz := measure(fonts.bold, SZ_BODY, label)
			draw_text(fonts.bold, SZ_BODY, {p.x + (cw - lsz.x) / 2, p.y + (th - lsz.y) / 2}, col32(0xffffff), label)
			if t.src_w > 0 {tip(fmt.tprintf("%s\n%d × %d", t.name, t.src_w, t.src_h))}
		}
		if showing {
			badge := fmt.tprintf("%s showing", ICON_CHECK)
			bw := measure(fonts.bold, SZ_SMALL, badge).x + 16
			im.DrawList_AddRectFilled(d, {p.x + 8, p.y + 8}, {p.x + 8 + bw, p.y + 30}, col32(C_GREEN, 0.92), 11)
			draw_text(fonts.bold, SZ_SMALL, {p.x + 16, p.y + 11}, col32(0x111318), badge)
		}

		// Name, and the Dark / Light switches (not for an image that can't be read).
		draw_text(fonts.ui, SZ_BODY, {p.x + 12, p.y + th + 9}, col32(C_TEXT), fit(fonts.ui, SZ_BODY, t.name, cw - 24))
		e := entry_of(t.name)
		if t.state == .Failed && e < 0 {
			im.DrawList_AddRect(d, p, {p.x + cw, p.y + ch}, col32(C_BORDER), 12)
			continue
		}
		dark := e >= 0 && wp.entries[e].dark
		light := e >= 0 && wp.entries[e].light
		im.SetCursorScreenPos({p.x + 12, p.y + th + 38})
		if mode_chip(fmt.tprintf("##wp-dark:%d", i), ICON_MOON, "Dark", dark, C_PURPLE) {set_mark(t.name, .Dark, !dark)}
		if im.IsItemHovered() {tip(dark ? "In the dark set: click to take it out" : "Use with the dark theme")}
		im.SameLine(0, 8)
		if mode_chip(fmt.tprintf("##wp-light:%d", i), ICON_SUNNY, "Light", light, C_YELLOW) {set_mark(t.name, .Light, !light)}
		if im.IsItemHovered() {tip(light ? "In the light set: click to take it out" : "Use with the light theme")}
		if showing {im.DrawList_AddRect(d, p, {p.x + cw, p.y + ch}, col32(C_GREEN, 0.9), 12, 2)} else {im.DrawList_AddRect(d, p, {p.x + cw, p.y + ch}, col32(C_BORDER), 12)}
	}
	rows := (len(wp.thumbs) + cols - 1) / cols
	im.SetCursorScreenPos({x, top})
	im.Dummy({width, rows > 0 ? f32(rows) * (ch + GAP) - GAP : 0})

	// Too many textures: drop the ones scrolled away.
	if wp.textures > MAX_TEXTURES {
		for &t in wp.thumbs {if t.tex != 0 && t.seen < wp.frame {free_texture(&t)}}
	}
}

@(private = "file")
home_dir :: proc() -> string {return os.get_env("HOME", context.temp_allocator)}

@(private = "file")
wbuf_set :: proc(buf: []u8, s: string) {
	n := min(len(s), len(buf) - 1)
	copy(buf, s[:n])
	buf[n] = 0
}

@(private = "file")
wbuf_str :: proc(buf: []u8) -> string {return string(cstring(raw_data(buf)))}

@(private = "file")
hint :: proc(text: string, width: f32, col: u32) {
	im.PushFontFloat(fonts.ui, SZ_SMALL)
	im.PushStyleColorImVec4(.Text, rgba(col & 0xffffff))
	im.PushTextWrapPos(im.GetCursorPosX() + width)
	b, e := str_range(text)
	im.TextUnformatted(b, e)
	im.PopTextWrapPos()
	im.PopStyleColor()
	im.PopFont()
}
