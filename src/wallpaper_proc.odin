// `wlperch wallpaper`: the desktop background, in place of swaybg. One
// layer-shell surface per output on the background layer, software-rendered
// into shared memory (no GPU), with a short crossfade whenever the picture
// changes, and rotation through the current mode's set every
// [wallpapers] rotate_minutes.
//
// It is its own process (sway starts it from config.d/wlperch-wallpaper.conf,
// which also sets `swaybg_command -` so sway's swaybg stays off): the
// daemon's GPU-release re-exec and a daemon crash leave the wallpaper alone,
// and the last picture shows at login before the daemon is up.
//
// Control is a file, not a socket: the picture to show is the full path in
// $XDG_DATA_HOME/wlperch/wallpaper (wallpaper_state_save, written by the
// theme switch, the Wallpapers tab and the rotation alike, replaced
// atomically). This process watches it with inotify, so it needs nobody to
// be running, a restart shows the last picture straight away, and its mtime
// is when the picture last changed (the rotation counts from there).
//
// Memory: the decoded source lives only while the outputs' buffers are
// scaled from it (big photos are box-averaged first); after that each output
// keeps one buffer of its own pixel size. A crossfade adds the new picture's
// buffer and two frames to blend into, freed when it ends.
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

import stbi "vendor:stb/image"

import "wl"

WALLPAPER_COMM :: "wlperch-wall" // the process name (ps, setup's checks)
WALLPAPER_FADE :: 800 * time.Millisecond
@(private = "file") FALLBACK_XRGB :: u32(0xff1d1f23) // no picture (or an unreadable one)
@(private = "file") MAX_SRC_PIXELS :: 200_000_000

foreign import libc_wpd "system:c"
@(private = "file")
@(default_calling_convention = "c")
foreign libc_wpd {
	@(link_name = "malloc_trim")
	wpd_malloc_trim :: proc(pad: c.size_t) -> c.int ---
}

// ---- Pure parts (tested) -------------------------------------------------------------

// The centred part of a sw x sh picture with the aspect of tw x th: what
// covers the output ("fill").
wallpaper_cover_rect :: proc(sw, sh, tw, th: int) -> (x, y, w, h: int) {
	if sw <= 0 || sh <= 0 || tw <= 0 || th <= 0 {return}
	if sw * th > sh * tw {
		h = sh
		w = clamp(int(math.round(f64(sh) * f64(tw) / f64(th))), 1, sw)
	} else {
		w = sw
		h = clamp(int(math.round(f64(sw) * f64(th) / f64(tw))), 1, sh)
	}
	return (sw - w) / 2, (sh - h) / 2, w, h
}

// The buffer size for a surface of lw x lh: the fractional scale (in 120ths)
// when the compositor sent one, else the output's integer scale.
wallpaper_pixel_size :: proc(lw, lh: i32, pref120: u32, scale: i32) -> (pw, ph: int) {
	if pref120 > 0 {
		return int((i64(lw) * i64(pref120) + 60) / 120), int((i64(lh) * i64(pref120) + 60) / 120)
	}
	s := max(scale, 1)
	return int(lw * s), int(lh * s)
}

// The surface covers the whole output, so its buffer is best the output's
// own pixels (a fractional scale rounds the logical size: 1600 / 1.5 = 1066,
// and back 1599). The mode, turned like the output; only when it matches
// the surface's shape (else the logical size times the scale).
wallpaper_mode_pixels :: proc(mw, mh, transform, lw, lh: i32, pref120: u32) -> (pw, ph: int, ok: bool) {
	if mw <= 0 || mh <= 0 || lw <= 0 || lh <= 0 {return}
	w, h := mw, mh
	if transform & 1 == 1 {w, h = mh, mw} // 90, 270 (and flipped)
	// Within a pixel or two of what the scale gives, else the layer surface
	// doesn't cover the output (exclusive zones…): not the mode then.
	ew, eh := wallpaper_pixel_size(lw, lh, pref120, 1)
	if pref120 == 0 {ew, eh = int(w), int(h)}
	if abs(ew - int(w)) > 2 || abs(eh - int(h)) > 2 {return}
	return int(w), int(h), true
}

// By how much a w x h region is box-averaged before the filtered scale to
// tw x th: the filter then shrinks it less than 2x (fast on 8K photos).
wallpaper_prescale_factor :: proc(w, h, tw, th: int) -> int {
	if tw <= 0 || th <= 0 {return 1}
	return max(min(w / tw, h / th), 1)
}

// The region (x, y, w, h) of RGBA `src` (row stride in bytes) averaged over
// k x k blocks.
wallpaper_box_down :: proc(src: []u8, stride, x, y, w, h, k: int, allocator := context.allocator) -> (out: []u8, ow, oh: int) {
	ow, oh = w / k, h / k
	out = make([]u8, ow * oh * 4, allocator)
	sums := make([]u32, ow * 4, context.temp_allocator)
	n := u32(k * k)
	for oy in 0 ..< oh {
		slice.zero(sums)
		for dy in 0 ..< k {
			row := src[(y + oy * k + dy) * stride + x * 4:]
			for ox in 0 ..< ow {
				p := row[ox * k * 4:]
				s := sums[ox * 4:]
				for dx in 0 ..< k {
					q := p[dx * 4:]
					s[0] += u32(q[0])
					s[1] += u32(q[1])
					s[2] += u32(q[2])
					s[3] += u32(q[3])
				}
			}
		}
		o := out[oy * ow * 4:]
		for i in 0 ..< ow * 4 {o[i] = u8((sums[i] + n / 2) / n)}
	}
	return
}

// RGBA bytes (as stb gives them) to XRGB8888 words in place; a transparent
// part goes over black.
wallpaper_rgba_to_xrgb :: proc(px: []u32) {
	for &p in px {
		r, g, b, a := p & 0xff, (p >> 8) & 0xff, (p >> 16) & 0xff, p >> 24
		if a != 255 {
			r, g, b = (r * a + 127) / 255, (g * a + 127) / 255, (b * a + 127) / 255
		}
		p = 0xff000000 | r << 16 | g << 8 | b
	}
}

// out = a * (256 - t) / 256 + b * t / 256 per channel; t in 0..256. Two
// channels per multiply (the 0x00ff00ff trick), so it stays cheap at 4K.
wallpaper_blend :: proc(a, b, out: []u32, t: u32) {
	n := min(len(a), len(b), len(out))
	it := 256 - t
	for i in 0 ..< n {
		x, y := a[i], b[i]
		rb := ((x & 0x00ff00ff) * it + (y & 0x00ff00ff) * t) >> 8 & 0x00ff00ff
		g := (((x >> 8) & 0x00ff00ff) * it + ((y >> 8) & 0x00ff00ff) * t) & 0xff00ff00
		out[i] = rb | g
	}
}

// How far a crossfade is (0..256) after `elapsed` of `total`, eased.
wallpaper_fade_weight :: proc(elapsed, total: time.Duration) -> u32 {
	if total <= 0 || elapsed >= total {return 256}
	if elapsed <= 0 {return 0}
	x := f64(elapsed) / f64(total)
	return u32(math.round(x * x * (3 - 2 * x) * 256))
}

// Seconds until the next rotation: -1 when it's off, 0 when it's due.
wallpaper_rotate_in :: proc(minutes: int, changed_unix, now_unix: i64) -> i64 {
	if minutes <= 0 {return -1}
	return max(changed_unix + i64(minutes) * 60 - now_unix, 0)
}

// ---- Who runs ------------------------------------------------------------------------

wallpaper_lock_path :: proc() -> string {
	dir := posix_getenv("XDG_RUNTIME_DIR")
	if dir == "" {dir = "/tmp"}
	return fmt.tprintf("%s/wlperch-wallpaper-%s.lock", dir, posix_getenv("WAYLAND_DISPLAY"))
}

// The running wallpaper process of this Wayland session (0: none).
wallpaper_running :: proc() -> int {
	data, err := os.read_entire_file(wallpaper_lock_path(), context.temp_allocator)
	if err != nil {return 0}
	pid, ok := strconv.parse_int(strings.trim_space(string(data)))
	if !ok || pid <= 1 {return 0}
	comm, cerr := os.read_entire_file(fmt.tprintf("/proc/%d/comm", pid), context.temp_allocator)
	if cerr != nil || strings.trim_space(string(comm)) != WALLPAPER_COMM {return 0}
	return pid
}

// config.d/wlperch-wallpaper.conf: written by setup's Wallpaper card.
wallpaper_conf_path :: proc() -> string {return strings.concatenate({sway_dir(), "/", WALLPAPER_CONF_NAME}, context.temp_allocator)}
wallpaper_conf_installed :: proc() -> bool {return os.exists(wallpaper_conf_path())}

WALLPAPER_CONF_NAME :: "wlperch-wallpaper.conf"
WALLPAPER_CONF :: `# wlperch's wallpaper instead of swaybg (written by wlperch setup; the
# Wallpaper card's "Switch back" removes this file).
# Sway's own background program stays off: an "output * bg" line elsewhere
# then does nothing, and wlperch shows the wallpaper (crossfades, the dark /
# light sets of the Wallpapers tab, [wallpapers] rotate_minutes).
swaybg_command -
# Started on every reload too; a second one exits at once.
exec_always wlperch wallpaper
`

// The binary to start it with: the installed one, else this one.
wallpaper_exe :: proc() -> string {
	exe := fmt.tprintf("%s/.local/bin/wlperch", os.get_env("HOME", context.temp_allocator))
	return os.exists(exe) ? exe : self_exe()
}

// The swaybg processes on this Wayland display (sway's, for `output * bg`):
// ours, with the same runtime dir and display name. (sway forks it off, so
// the parent is no guide: it's often init.)
sway_swaybg_pids :: proc() -> []posix.pid_t {
	out: [dynamic]posix.pid_t
	out.allocator = context.temp_allocator
	rt := strings.concatenate({"XDG_RUNTIME_DIR=", posix_getenv("XDG_RUNTIME_DIR")}, context.temp_allocator)
	for pid in session_pids("swaybg") {
		env, err := os.read_entire_file(fmt.tprintf("/proc/%d/environ", pid), context.temp_allocator)
		if err != nil {continue}
		for kv in strings.split(string(env), "\x00", context.temp_allocator) {
			if kv == rt {
				append(&out, pid)
				break
			}
		}
	}
	return out[:]
}

// ---- The process ----------------------------------------------------------------------

@(private = "file")
Wp_Buf :: struct {
	buf:        ^wl.Buffer,
	mem:        rawptr,
	size:       int,
	px:         []u32,
	w, h:       int,
	busy, dead: bool, // the compositor holds it; destroy once it lets go
}

@(private = "file")
Wp_Out :: struct {
	output:        ^wl.Output,
	name:          u32,
	conn:          string,
	scale:         i32,
	surface:       ^wl.Surface,
	layer:         ^wl.Zwlr_Layer_Surface_V1,
	viewport:      ^wl.Wp_Viewport,
	frac:          ^wl.Wp_Fractional_Scale_V1,
	pref120:       u32,
	mode_w:        i32, // the output's current mode, in its own orientation
	mode_h:        i32,
	transform:     i32,
	lw, lh:        i32,
	configured:    bool,
	frame_pending: bool,
	cur:           ^Wp_Buf, // the picture (during a fade: the one faded to)
	path:          string, // what cur shows
	from:          ^Wp_Buf, // during a fade: the picture faded from
	slots:         [2]^Wp_Buf, // blended frames
	last_slot:     int, // the slot on screen (-1: none yet)
	fading:        bool,
	fade_at:       time.Tick,
}

@(private = "file")
Wpd :: struct {
	display:       ^wl.Display,
	compositor:    ^wl.Compositor,
	shm:           ^wl.Shm,
	layer_shell:   ^wl.Zwlr_Layer_Shell_V1,
	viewporter:    ^wl.Wp_Viewporter,
	frac_mgr:      ^wl.Wp_Fractional_Scale_Manager_V1,
	outputs:       [dynamic]^Wp_Out,
	want:          string, // the picture to show ("" = plain colour)
	changed_unix:  i64, // when it last changed (rotation)
	data_fd:       linux.Fd,
	cfg_fd:        linux.Fd,
	wake_r:        posix.FD,
	wake_w:        posix.FD,
	first_done:    bool,
	replace:       bool,
	lock_fd:       posix.FD,
}
@(private = "file") wpd: Wpd
@(private = "file") wpd_ctx: runtime.Context
@(private = "file") wpd_term: bool

@(private = "file")
buf_listener := wl.Buffer_Listener {
	release = proc "c" (data: rawptr, self: ^wl.Buffer) {
		context = wpd_ctx
		b := (^Wp_Buf)(data)
		b.busy = false
		if b.dead {
			wl.buffer_destroy(b.buf)
			free(b)
		}
	},
}

@(private = "file")
buf_new :: proc(w, h: int) -> ^Wp_Buf {
	size := w * h * 4
	if size <= 0 {return nil}
	fd, err := linux.memfd_create("wlperch-wallpaper", {.CLOEXEC})
	if err != .NONE {return nil}
	defer linux.close(fd)
	if linux.ftruncate(fd, i64(size)) != .NONE {return nil}
	mem := posix.mmap(nil, uint(size), {.READ, .WRITE}, {.SHARED}, posix.FD(fd), 0)
	if mem == posix.MAP_FAILED {return nil}
	b := new(Wp_Buf)
	pool := wl.shm_create_pool(wpd.shm, i32(fd), i32(size))
	b.buf = wl.shm_pool_create_buffer(pool, 0, i32(w), i32(h), i32(w * 4), wl.SHM_FORMAT_XRGB8888)
	wl.shm_pool_destroy(pool)
	wl.buffer_add_listener(b.buf, &buf_listener, b)
	b.mem, b.size, b.w, b.h = mem, size, w, h
	b.px = ([^]u32)(mem)[:w * h]
	return b
}

// Our mapping goes now; the wl_buffer once the compositor is done with it.
@(private = "file")
buf_free :: proc(b: ^Wp_Buf) {
	if b == nil {return}
	if b.mem != nil {posix.munmap(b.mem, uint(b.size))}
	b.mem, b.px = nil, nil
	if b.busy {
		b.dead = true
		return
	}
	wl.buffer_destroy(b.buf)
	free(b)
}

// ---- Pictures ----------------------------------------------------------------------------

@(private = "file")
Src :: struct {
	px:        [^]u8,
	w, h:      int,
	tried, ok: bool,
}

@(private = "file")
src_load :: proc(s: ^Src, path: string) {
	s.tried = true
	if path == "" {return}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	iw, ih, n: c.int
	if stbi.info(cpath, &iw, &ih, &n) == 0 || iw <= 0 || ih <= 0 {
		log.warnf("wallpaper: can't read %s", path)
		return
	}
	if int(iw) * int(ih) > MAX_SRC_PIXELS {
		log.warnf("wallpaper: %s is too big (%dx%d)", path, iw, ih)
		return
	}
	t := time.tick_now()
	data := stbi.load(cpath, &iw, &ih, &n, 4)
	if data == nil {
		log.warnf("wallpaper: can't decode %s", path)
		return
	}
	s.px, s.w, s.h, s.ok = data, int(iw), int(ih), true
	log.debugf("wallpaper: decoded %s (%dx%d) in %v", path, iw, ih, time.tick_since(t))
}

@(private = "file")
src_free :: proc(s: ^Src) {
	if s.px != nil {stbi.image_free(s.px)}
	s^ = {}
	wpd_malloc_trim(0) // a decoded photo is easily 100 MB
}

// The picture scaled to cover b, or the plain colour.
@(private = "file")
paint :: proc(b: ^Wp_Buf, s: ^Src) {
	if !s.ok {
		slice.fill(b.px, FALLBACK_XRGB)
		return
	}
	x, y, w, h := wallpaper_cover_rect(s.w, s.h, b.w, b.h)
	stride := s.w * 4
	all := s.px[:s.w * s.h * 4]
	out := ([^]u8)(b.mem)
	if k := wallpaper_prescale_factor(w, h, b.w, b.h); k >= 2 {
		small, sw, sh := wallpaper_box_down(all, stride, x, y, w, h, k)
		defer delete(small)
		stbi.resize_uint8(raw_data(small), c.int(sw), c.int(sh), 0, out, c.int(b.w), c.int(b.h), 0, 4)
	} else {
		stbi.resize_uint8(&all[y * stride + x * 4], c.int(w), c.int(h), c.int(stride), out, c.int(b.w), c.int(b.h), 0, 4)
	}
	wallpaper_rgba_to_xrgb(b.px)
}

// ---- Outputs -----------------------------------------------------------------------------

@(private = "file")
pixel_size :: proc(o: ^Wp_Out) -> (int, int) {
	if o.viewport != nil {
		if w, h, ok := wallpaper_mode_pixels(o.mode_w, o.mode_h, o.transform, o.lw, o.lh, o.pref120); ok {return w, h}
	}
	return wallpaper_pixel_size(o.lw, o.lh, o.viewport != nil ? o.pref120 : 0, o.scale)
}

@(private = "file")
present :: proc(o: ^Wp_Out, b: ^Wp_Buf) {
	if o.viewport != nil {
		wl.wp_viewport_set_destination(o.viewport, o.lw, o.lh)
	} else {
		wl.surface_set_buffer_scale(o.surface, max(o.scale, 1))
	}
	wl.surface_attach(o.surface, b.buf, 0, 0)
	b.busy = true
	wl.surface_damage_buffer(o.surface, 0, 0, i32(b.w), i32(b.h))
	cb := wl.surface_frame(o.surface)
	wl.callback_add_listener(cb, &frame_listener, o)
	o.frame_pending = true
	wl.surface_commit(o.surface)
}

@(private = "file")
end_fade :: proc(o: ^Wp_Out) {
	buf_free(o.from)
	o.from = nil
	for &sl in o.slots {
		buf_free(sl)
		sl = nil
	}
	o.fading = false
	o.last_slot = -1
}

// The next frame of a crossfade, or its end.
@(private = "file")
fade_step :: proc(o: ^Wp_Out) {
	el := time.tick_since(o.fade_at)
	if el >= WALLPAPER_FADE || o.from == nil || o.from.w != o.cur.w || o.from.h != o.cur.h {
		present(o, o.cur)
		end_fade(o)
		return
	}
	if o.frame_pending {return}
	slot := -1
	for sl, i in o.slots {
		if sl == nil || !sl.busy {
			slot = i
			break
		}
	}
	if slot < 0 {return}
	if o.slots[slot] == nil {o.slots[slot] = buf_new(o.cur.w, o.cur.h)}
	sl := o.slots[slot]
	if sl == nil {
		present(o, o.cur)
		end_fade(o)
		return
	}
	wallpaper_blend(o.from.px, o.cur.px, sl.px, wallpaper_fade_weight(el, WALLPAPER_FADE))
	present(o, sl)
	o.last_slot = slot
}

@(private = "file")
start_fade :: proc(o: ^Wp_Out, b: ^Wp_Buf) {
	if o.fading {
		// Mid-fade: carry on from the frame on screen to the newest picture.
		if o.last_slot >= 0 {
			buf_free(o.from)
			o.from = o.slots[o.last_slot]
			o.slots[o.last_slot] = nil
		}
		buf_free(o.cur)
	} else {
		o.from = o.cur
	}
	o.cur = b
	o.fading = true
	o.fade_at = time.tick_now()
	o.last_slot = -1
}

@(private = "file")
needs_render :: proc(o: ^Wp_Out) -> bool {
	if !o.configured || o.surface == nil || o.lw <= 0 || o.lh <= 0 {return false}
	if o.cur == nil {return true}
	pw, ph := pixel_size(o)
	return o.cur.w != pw || o.cur.h != ph || o.path != wpd.want
}

// Every output that shows something else than wpd.want (or at another size):
// decode once, scale for each, then fade (same size) or swap, all outputs
// together (scaling is the slow part, so it all comes first).
@(private = "file")
render_pending :: proc() {
	Job :: struct {o: ^Wp_Out, b: ^Wp_Buf, fade: bool}
	jobs: [dynamic]Job
	jobs.allocator = context.temp_allocator
	{
		src: Src
		defer if src.tried {src_free(&src)}
		for o in wpd.outputs {
			if !needs_render(o) {continue}
			pw, ph := pixel_size(o)
			same_size := o.cur != nil && o.cur.w == pw && o.cur.h == ph
			if !src.tried {src_load(&src, wpd.want)}
			if !src.ok && wpd.want != "" && same_size {
				// An unreadable picture: keep the one there is.
				delete(o.path)
				o.path = strings.clone(wpd.want)
				continue
			}
			b := buf_new(pw, ph)
			if b == nil {continue}
			t := time.tick_now()
			paint(b, &src)
			log.debugf("wallpaper: %s %dx%d in %v", o.conn, pw, ph, time.tick_since(t))
			delete(o.path)
			o.path = strings.clone(wpd.want)
			append(&jobs, Job{o, b, same_size})
		}
	}
	for j in jobs {
		o := j.o
		if j.fade {
			start_fade(o, j.b)
			fade_step(o)
		} else {
			// The first picture, or the output changed size: no fade.
			if o.fading {end_fade(o)}
			old := o.cur
			o.cur = j.b
			present(o, j.b)
			buf_free(old)
		}
	}
}

@(private = "file")
empty_input :: proc(s: ^wl.Surface) {
	r := wl.compositor_create_region(wpd.compositor)
	wl.surface_set_input_region(s, r)
	wl.region_destroy(r)
}

@(private = "file")
create_surface :: proc(o: ^Wp_Out) {
	o.surface = wl.compositor_create_surface(wpd.compositor)
	o.layer = wl.zwlr_layer_shell_v1_get_layer_surface(wpd.layer_shell, o.surface, o.output, wl.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "wallpaper")
	wl.zwlr_layer_surface_v1_add_listener(o.layer, &layer_listener, o)
	wl.zwlr_layer_surface_v1_set_anchor(o.layer, wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT)
	wl.zwlr_layer_surface_v1_set_exclusive_zone(o.layer, -1)
	wl.zwlr_layer_surface_v1_set_keyboard_interactivity(o.layer, 0)
	wl.zwlr_layer_surface_v1_set_size(o.layer, 0, 0)
	empty_input(o.surface)
	if wpd.viewporter != nil {o.viewport = wl.wp_viewporter_get_viewport(wpd.viewporter, o.surface)}
	if wpd.frac_mgr != nil && o.viewport != nil {
		o.frac = wl.wp_fractional_scale_manager_v1_get_fractional_scale(wpd.frac_mgr, o.surface)
		wl.wp_fractional_scale_v1_add_listener(o.frac, &frac_listener, o)
	}
	wl.surface_commit(o.surface)
}

@(private = "file")
destroy_surface :: proc(o: ^Wp_Out) {
	if o.fading {end_fade(o)}
	buf_free(o.cur)
	o.cur = nil
	delete(o.path)
	o.path = ""
	if o.frac != nil {wl.wp_fractional_scale_v1_destroy(o.frac)}
	if o.viewport != nil {wl.wp_viewport_destroy(o.viewport)}
	if o.layer != nil {wl.zwlr_layer_surface_v1_destroy(o.layer)}
	if o.surface != nil {wl.surface_destroy(o.surface)}
	o.frac, o.viewport, o.layer, o.surface = nil, nil, nil, nil
	o.configured, o.frame_pending = false, false
}

@(private = "file")
frame_listener := wl.Callback_Listener {
	done = proc "c" (data: rawptr, self: ^wl.Callback, t: u32) {
		(^Wp_Out)(data).frame_pending = false
		wl.callback_destroy(self)
	},
}

@(private = "file")
frac_listener := wl.Wp_Fractional_Scale_V1_Listener {
	preferred_scale = proc "c" (data: rawptr, self: ^wl.Wp_Fractional_Scale_V1, scale: u32) {
		(^Wp_Out)(data).pref120 = scale
	},
}

@(private = "file")
layer_listener := wl.Zwlr_Layer_Surface_V1_Listener {
	configure = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1, serial, width, height: u32) {
		o := (^Wp_Out)(data)
		wl.zwlr_layer_surface_v1_ack_configure(self, serial)
		o.lw, o.lh = i32(width), i32(height)
		o.configured = true
	},
	closed = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1) {
		context = wpd_ctx
		destroy_surface((^Wp_Out)(data))
	},
}

@(private = "file")
output_listener := wl.Output_Listener {
	geometry = proc "c" (data: rawptr, self: ^wl.Output, x, y, pw, ph, subpixel: i32, make, model: cstring, transform: i32) {
		(^Wp_Out)(data).transform = transform
	},
	mode = proc "c" (data: rawptr, self: ^wl.Output, flags: u32, width, height, refresh: i32) {
		if flags & 1 != 0 { // current
			o := (^Wp_Out)(data)
			o.mode_w, o.mode_h = width, height
		}
	},
	done = proc "c" (data: rawptr, self: ^wl.Output) {
		context = wpd_ctx
		o := (^Wp_Out)(data)
		if o.surface == nil {create_surface(o)}
	},
	scale = proc "c" (data: rawptr, self: ^wl.Output, factor: i32) {
		(^Wp_Out)(data).scale = max(factor, 1)
	},
	name = proc "c" (data: rawptr, self: ^wl.Output, name: cstring) {
		context = wpd_ctx
		o := (^Wp_Out)(data)
		delete(o.conn)
		o.conn = strings.clone(string(name))
	},
	description = proc "c" (data: rawptr, self: ^wl.Output, description: cstring) {},
}

@(private = "file")
registry_listener := wl.Registry_Listener {
	global = proc "c" (data: rawptr, registry: ^wl.Registry, name: u32, iface: cstring, version: u32) {
		context = wpd_ctx
		switch iface {
		case "wl_compositor":
			wpd.compositor = cast(^wl.Compositor)wl.registry_bind(registry, name, &wl.compositor_interface, min(version, 4))
		case "wl_shm":
			wpd.shm = cast(^wl.Shm)wl.registry_bind(registry, name, &wl.shm_interface, 1)
		case "zwlr_layer_shell_v1":
			wpd.layer_shell = cast(^wl.Zwlr_Layer_Shell_V1)wl.registry_bind(registry, name, &wl.zwlr_layer_shell_v1_interface, min(version, 4))
		case "wp_viewporter":
			wpd.viewporter = cast(^wl.Wp_Viewporter)wl.registry_bind(registry, name, &wl.wp_viewporter_interface, 1)
		case "wp_fractional_scale_manager_v1":
			wpd.frac_mgr = cast(^wl.Wp_Fractional_Scale_Manager_V1)wl.registry_bind(registry, name, &wl.wp_fractional_scale_manager_v1_interface, 1)
		case "wl_output":
			o := new(Wp_Out)
			o.name = name
			o.scale = 1
			o.last_slot = -1
			o.output = cast(^wl.Output)wl.registry_bind(registry, name, &wl.output_interface, min(version, 4))
			wl.output_add_listener(o.output, &output_listener, o)
			append(&wpd.outputs, o)
			// Bound after the first roundtrip (hotplug): its surface waits for done.
		}
	},
	global_remove = proc "c" (data: rawptr, registry: ^wl.Registry, name: u32) {
		context = wpd_ctx
		for o, i in wpd.outputs {
			if o.name != name {continue}
			destroy_surface(o)
			if wl.output_get_version(o.output) >= 3 {wl.output_release(o.output)} else {wl.output_destroy(o.output)}
			delete(o.conn)
			free(o)
			ordered_remove(&wpd.outputs, i)
			return
		}
	},
}

// ---- State ---------------------------------------------------------------------------------

// The picture to show at start (and after a config change, when nothing was
// ever picked): the last one, else the mode's [theme.*] wallpaper.
@(private = "file")
initial_picture :: proc() -> (path: string, changed: i64) {
	cur := wallpaper_current()
	if cur != "" {
		changed = time.to_unix_seconds(time.now())
		if fi, err := os.stat(wallpaper_state_path(), context.temp_allocator); err == nil {changed = time.to_unix_seconds(fi.modification_time)}
		return cur, changed
	}
	return config.theme_targets[theme_mode_load()].wallpaper, time.to_unix_seconds(time.now())
}

@(private = "file")
set_want :: proc(path: string, changed: i64) {
	wpd.changed_unix = changed
	if path == wpd.want {return}
	log.infof("wallpaper: %s", path == "" ? "(plain colour)" : path)
	delete(wpd.want)
	wpd.want = strings.clone(path)
}

@(private = "file")
data_watch_open :: proc() -> linux.Fd {
	dir := data_dir()
	defer delete(dir)
	os.make_directory_all(dir)
	fd, err := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if err != .NONE {return -1}
	if _, werr := linux.inotify_add_watch(fd, strings.clone_to_cstring(dir, context.temp_allocator), {.CLOSE_WRITE, .MOVED_TO}); werr != .NONE {
		linux.close(fd)
		return -1
	}
	return fd
}

// Drains the watch: true when the wallpaper file was written or replaced.
@(private = "file")
data_watch_read :: proc(fd: linux.Fd) -> bool {
	buf: [4096]u8
	hit := false
	for {
		n, err := linux.read(fd, buf[:])
		if err != .NONE || n <= 0 {break}
		for off := 0; off + size_of(linux.Inotify_Event) <= n; {
			ev := (^linux.Inotify_Event)(&buf[off])
			name := string(cstring(&buf[off + size_of(linux.Inotify_Event)])) if ev.len > 0 else ""
			if name == WALLPAPER_STATE_NAME {hit = true}
			off += size_of(linux.Inotify_Event) + int(ev.len)
		}
	}
	return hit
}

// The rotation: the next picture of the current mode's set.
@(private = "file")
rotate :: proc() {
	now := time.to_unix_seconds(time.now())
	wpd.changed_unix = now // an empty set tries again a period later, not in a loop
	pick := wallpaper_for_mode(theme_mode_load())
	if pick == "" || pick == wpd.want {return}
	log.infof("wallpaper: rotating to %s", pick)
	wallpaper_state_save(pick) // our watch then shows it (and the tab sees it)
}

// Once every output shows something: take over from the instance we replace
// and stop sway's swaybg, which would otherwise keep covering us.
@(private = "file")
after_first_frame :: proc() {
	wpd.first_done = true
	wl.display_roundtrip(wpd.display)
	if wpd.replace {
		if old := wallpaper_running(); old > 0 && old != int(posix.getpid()) {
			log.infof("wallpaper: taking over from pid %d", old)
			posix.kill(posix.pid_t(old), .SIGTERM)
		}
		for _ in 0 ..< 30 {
			if take_lock(wpd.lock_fd) {break}
			time.sleep(100 * time.Millisecond)
		}
	}
	if wallpaper_conf_installed() {
		for pid in sway_swaybg_pids() {
			log.infof("wallpaper: stopping sway's swaybg (pid %d)", pid)
			posix.kill(pid, .SIGTERM)
		}
	}
}

@(private = "file")
take_lock :: proc(fd: posix.FD) -> bool {
	if fd < 0 {return true}
	if linux.flock(linux.Fd(fd), {.EX, .NB}) != .NONE {return false}
	posix.ftruncate(fd, 0)
	pid := fmt.tprintf("%d\n", posix.getpid())
	posix.pwrite(fd, raw_data(pid), len(pid), 0)
	return true
}

@(private = "file")
log_to_file :: proc() {
	if posix.isatty(2) {return}
	dir := posix_getenv("XDG_RUNTIME_DIR")
	if dir == "" {dir = "/tmp"}
	path := fmt.ctprintf("%s/wlperch-wallpaper-%s.log", dir, posix_getenv("WAYLAND_DISPLAY"))
	fd := posix.open(path, {.CREAT, .WRONLY, .TRUNC, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd < 0 {return}
	posix.dup2(fd, 2)
	posix.close(fd)
}

@(private = "file")
on_term :: proc "c" (sig: posix.Signal) {
	wpd_term = true
	b := u8(1)
	posix.write(wpd.wake_w, &b, 1)
}

// `wlperch wallpaper [--replace]`. Without --replace a second instance
// leaves the running one alone (sway's exec_always on every reload);
// with it, the new one draws first, then asks the old one to go.
wallpaper_main :: proc(args: []string) -> int {
	wpd_ctx = context
	for a in args {if a == "--replace" {wpd.replace = true}}
	log_to_file()
	name := cstring(WALLPAPER_COMM)
	linux.prctl(15, uint(uintptr(rawptr(name))), 0, 0, 0) // PR_SET_NAME
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

	wpd.lock_fd = posix.open(strings.clone_to_cstring(wallpaper_lock_path(), context.temp_allocator), {.CREAT, .RDWR, .CLOEXEC}, {.IRUSR, .IWUSR})
	if !take_lock(wpd.lock_fd) && !wpd.replace {
		log.infof("wallpaper: already running (pid %d)", wallpaper_running())
		return 0
	}

	fds: [2]posix.FD
	posix.pipe(&fds)
	wpd.wake_r, wpd.wake_w = fds[0], fds[1]
	set_cloexec_nonblock(wpd.wake_r)
	set_cloexec_nonblock(wpd.wake_w)
	wpd.data_fd = data_watch_open()
	wpd.cfg_fd = config_watch_open()
	path, changed := initial_picture()
	set_want(path, changed)

	wpd.display = wl.display_connect(nil)
	if wpd.display == nil {
		log.error("wallpaper: cannot connect to the Wayland display")
		return 1
	}
	registry := wl.display_get_registry(wpd.display)
	wl.registry_add_listener(registry, &registry_listener, nil)
	wl.display_roundtrip(wpd.display)
	if wpd.compositor == nil || wpd.layer_shell == nil || wpd.shm == nil {
		log.error("wallpaper: the compositor lacks wl_shm or zwlr_layer_shell_v1")
		return 1
	}
	wl.display_roundtrip(wpd.display) // output names and scales; done -> surfaces
	wl.display_roundtrip(wpd.display) // configure, preferred scale

	for sig in ([]posix.Signal{.SIGTERM, .SIGINT, .SIGHUP}) {posix.signal(sig, on_term)}
	for iteration() {}
	return 0
}

@(private = "file")
iteration :: proc() -> bool {
	d := wpd.display
	render_pending()
	fading := false
	for o in wpd.outputs {
		if !o.fading {continue}
		fade_step(o)
		if o.fading {fading = true}
	}
	if !wpd.first_done {
		all := len(wpd.outputs) > 0
		for o in wpd.outputs {if o.surface != nil && o.cur == nil {all = false}}
		if all {after_first_frame()}
	}
	now := time.to_unix_seconds(time.now())
	if wallpaper_rotate_in(config.wallpapers_rotate_minutes, wpd.changed_unix, now) == 0 {rotate()}

	for wl.display_prepare_read(d) != 0 {wl.display_dispatch_pending(d)}
	wl.display_flush(d)

	timeout := i64(-1)
	if r := wallpaper_rotate_in(config.wallpapers_rotate_minutes, wpd.changed_unix, now); r >= 0 {timeout = max(r, 1) * 1000}
	if fading {
		// Frame callbacks pace it; the end comes even when none do (output off).
		left := i64(WALLPAPER_FADE / time.Millisecond)
		for o in wpd.outputs {
			if o.fading {left = min(left, i64((WALLPAPER_FADE - time.tick_since(o.fade_at)) / time.Millisecond))}
		}
		left = max(left, 0) + 1
		if timeout < 0 || left < timeout {timeout = left}
	}
	pfds := [4]posix.pollfd {
		{fd = posix.FD(wl.display_get_fd(d)), events = {.IN}},
		{fd = wpd.wake_r, events = {.IN}},
		{fd = posix.FD(wpd.data_fd), events = {.IN}},
		{fd = posix.FD(wpd.cfg_fd), events = {.IN}},
	}
	n := posix.poll(&pfds[0], len(pfds), i32(min(timeout, 1 << 30)))
	if n < 0 {
		wl.display_cancel_read(d)
		return posix.errno() == .EINTR && !wpd_term
	}
	if .IN in pfds[0].revents {wl.display_read_events(d)} else {wl.display_cancel_read(d)}
	if .HUP in pfds[0].revents || .ERR in pfds[0].revents {
		log.error("wallpaper: lost the Wayland connection")
		return false
	}
	if wl.display_dispatch_pending(d) < 0 {return false}
	if wpd_term {return false}
	if .IN in pfds[1].revents {
		buf: [64]u8
		for posix.read(wpd.wake_r, &buf[0], len(buf)) > 0 {}
	}
	if wpd.data_fd >= 0 && .IN in pfds[2].revents && data_watch_read(wpd.data_fd) {
		if cur := wallpaper_current(); cur != "" {set_want(cur, time.to_unix_seconds(time.now()))}
	}
	if wpd.cfg_fd >= 0 && .IN in pfds[3].revents && config_watch_changed(wpd.cfg_fd) {
		config_reload_theme()
		if wallpaper_current() == "" {set_want(config.theme_targets[theme_mode_load()].wallpaper, wpd.changed_unix)}
	}
	free_all(context.temp_allocator)
	return true
}

// `wlperch wallpaper [restart|next|set <file>|--replace]`.
wallpaper_cli :: proc(args: []string) -> int {
	sub := len(args) > 0 ? args[0] : ""
	switch sub {
	case "", "--replace":
		return wallpaper_main(args)
	case "restart":
		if !launch_detached({wallpaper_exe(), "wallpaper", "--replace"}) {
			fmt.eprintln("wlperch wallpaper: couldn't start it")
			return 1
		}
		return 0
	case "next":
		m := theme_mode_load()
		pick := wallpaper_for_mode(m)
		if pick == "" {
			fmt.eprintfln("wlperch wallpaper: no pictures marked for %s (the setup window's Wallpapers tab)", theme_mode_name(m))
			return 1
		}
		fmt.println(pick)
		return wallpaper_apply(pick) ? 0 : 1
	case "set":
		if len(args) < 2 {
			fmt.eprintln("usage: wlperch wallpaper set <file>")
			return 2
		}
		path := args[1]
		if !strings.has_prefix(path, "/") {
			cwd, _ := os.get_working_directory(context.temp_allocator)
			path = fmt.tprintf("%s/%s", cwd, path)
		}
		if !os.exists(path) {
			fmt.eprintfln("wlperch wallpaper: no such file: %s", path)
			return 1
		}
		return wallpaper_apply(path) ? 0 : 1
	}
	fmt.eprintln("usage: wlperch wallpaper [restart|next|set <file>]")
	return 2
}
