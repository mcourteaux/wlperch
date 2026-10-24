// Lock screen "blur" background: a copy of each output taken just before the
// lock, shrunk and blurred in memory (never written anywhere), drawn
// bilinearly upscaled behind the clock.
//
// Capture prefers ext-image-copy-capture-v1 (+ ext-image-capture-source-v1)
// and falls back to wlr-screencopy-unstable-v1. Every output is captured at
// once into shm; each frame is reduced the moment it arrives: a box-average
// downscale (D x D native pixels -> 1), the output transform applied on that
// small copy, then three box-blur passes per axis (≈ Gaussian). The capture
// buffers are unmapped right after, so only the small blurred copies stay.
//
// Privacy: blur strength 0..100 maps to a Gaussian sigma of
// LOCK_BLUR_MIN_SIGMA..LOCK_BLUR_MAX_SIGMA logical pixels. The floor (20 px)
// is well above any text's stroke width and size, so even the lowest setting
// leaves no readable text.
//
// The lock never waits on this for long: capture_and_blur gives up after its
// timeout and outputs without a copy get the solid colour.
package main

import "base:runtime"
import "core:log"
import "core:math"
import "core:os"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

import "wl"

LOCK_BLUR_MIN_SIGMA :: 20 // logical px, at strength 0
LOCK_BLUR_MAX_SIGMA :: 100 // at strength 100
LOCK_CAPTURE_TIMEOUT :: 300 * time.Millisecond

// Sigma (logical px) for a [lock] screenshot_blur strength.
lock_blur_sigma :: proc(strength: int) -> f32 {
	t := f32(clamp(strength, 0, 100)) / 100
	return LOCK_BLUR_MIN_SIGMA + t * (LOCK_BLUR_MAX_SIGMA - LOCK_BLUR_MIN_SIGMA)
}

// Small blurred copy of an output in its logical orientation (0x00RRGGBB).
Blur_Image :: struct {
	px:   []u32,
	w, h: int,
}

Capture_Target :: struct {
	output:    ^wl.Output,
	transform: i32, // wl_output transform (geometry event; ext's frame event overrides it)
	scale:     i32,
	result:    Blur_Image,

	// in flight
	state:     enum {Idle, Waiting, Copying, Done, Failed},
	format:    u32,
	fmt_rank:  int, // lower is better, max = none yet
	w, h:      i32,
	stride:    i32,
	y_invert:  bool,
	fd:        linux.Fd,
	mem:       rawptr,
	size:      int,
	buffer:    ^wl.Buffer,
	source:    ^wl.Ext_Image_Capture_Source_V1,
	session:   ^wl.Ext_Image_Copy_Capture_Session_V1,
	frame:     ^wl.Ext_Image_Copy_Capture_Frame_V1,
	wframe:    ^wl.Zwlr_Screencopy_Frame_V1,
	strength:  int,
}

Capture_Globals :: struct {
	ext_copy:   ^wl.Ext_Image_Copy_Capture_Manager_V1,
	ext_source: ^wl.Ext_Output_Image_Capture_Source_Manager_V1,
	wlr:        ^wl.Zwlr_Screencopy_Manager_V1,
	shm:        ^wl.Shm,
}

@(private = "file") cg: Capture_Globals
@(private = "file") cap_ctx: runtime.Context

// From the registry listener (only when the blur background is on).
capture_bind :: proc(registry: ^wl.Registry, name: u32, iface: cstring, version: u32) {
	switch iface {
	case "ext_image_copy_capture_manager_v1":
		cg.ext_copy = cast(^wl.Ext_Image_Copy_Capture_Manager_V1)wl.registry_bind(registry, name, &wl.ext_image_copy_capture_manager_v1_interface, 1)
	case "ext_output_image_capture_source_manager_v1":
		cg.ext_source = cast(^wl.Ext_Output_Image_Capture_Source_Manager_V1)wl.registry_bind(registry, name, &wl.ext_output_image_capture_source_manager_v1_interface, 1)
	case "zwlr_screencopy_manager_v1":
		cg.wlr = cast(^wl.Zwlr_Screencopy_Manager_V1)wl.registry_bind(registry, name, &wl.zwlr_screencopy_manager_v1_interface, min(version, 3))
	}
}

@(private = "file")
format_rank :: proc "contextless" (f: u32) -> int {
	switch f {
	case wl.SHM_FORMAT_XRGB8888:    return 0
	case wl.SHM_FORMAT_ARGB8888:    return 1
	case wl.SHM_FORMAT_XBGR8888:    return 2
	case wl.SHM_FORMAT_ABGR8888:    return 3
	case wl.SHM_FORMAT_XRGB2101010: return 4
	case wl.SHM_FORMAT_ARGB2101010: return 5
	case wl.SHM_FORMAT_XBGR2101010: return 6
	case wl.SHM_FORMAT_ABGR2101010: return 7
	case wl.SHM_FORMAT_BGR888:      return 8 // what wlroots' screencopy offers for headless outputs
	case wl.SHM_FORMAT_RGB888:      return 9
	}
	return max(int)
}

@(private = "file")
bytes_per_pixel :: proc "contextless" (f: u32) -> i32 {
	return f == wl.SHM_FORMAT_BGR888 || f == wl.SHM_FORMAT_RGB888 ? 3 : 4
}

@(private = "file")
offer_format :: proc "contextless" (t: ^Capture_Target, f: u32) {
	if r := format_rank(f); r < t.fmt_rank {
		t.fmt_rank = r
		t.format = f
	}
}

@(private = "file")
alloc_buffer :: proc(t: ^Capture_Target) -> bool {
	if t.fmt_rank == max(int) || t.w <= 0 || t.h <= 0 {return false}
	if t.stride < t.w * bytes_per_pixel(t.format) {t.stride = t.w * bytes_per_pixel(t.format)}
	t.size = int(t.stride) * int(t.h)
	fd, err := linux.memfd_create("wlperch-lock-capture", {.CLOEXEC})
	if err != .NONE {return false}
	t.fd = fd
	if linux.ftruncate(fd, i64(t.size)) != .NONE {return false}
	m := posix.mmap(nil, uint(t.size), {.READ, .WRITE}, {.SHARED}, posix.FD(fd), 0)
	if m == posix.MAP_FAILED {return false}
	t.mem = m
	pool := wl.shm_create_pool(cg.shm, i32(fd), i32(t.size))
	t.buffer = wl.shm_pool_create_buffer(pool, 0, t.w, t.h, t.stride, t.format)
	wl.shm_pool_destroy(pool)
	return true
}

@(private = "file")
release :: proc(t: ^Capture_Target) {
	if t.frame != nil {wl.ext_image_copy_capture_frame_v1_destroy(t.frame); t.frame = nil}
	if t.session != nil {wl.ext_image_copy_capture_session_v1_destroy(t.session); t.session = nil}
	if t.source != nil {wl.ext_image_capture_source_v1_destroy(t.source); t.source = nil}
	if t.wframe != nil {wl.zwlr_screencopy_frame_v1_destroy(t.wframe); t.wframe = nil}
	if t.buffer != nil {wl.buffer_destroy(t.buffer); t.buffer = nil}
	if t.mem != nil {posix.munmap(t.mem, uint(t.size)); t.mem = nil}
	if t.fd > 0 {linux.close(t.fd); t.fd = 0}
}

@(private = "file")
fail :: proc(t: ^Capture_Target, why: string) {
	log.warnf("lock: screen capture failed (%s)", why)
	t.state = .Failed
	release(t)
}

@(private = "file")
ready :: proc(t: ^Capture_Target) {
	t0 := time.tick_now()
	t.result = lock_reduce_and_blur(t)
	release(t)
	t.state = t.result.px != nil ? .Done : .Failed
	log.debugf("lock: blurred %dx%d -> %dx%d in %.1f ms", t.w, t.h, t.result.w, t.result.h, time.duration_milliseconds(time.tick_since(t0)))
}

// ---- ext-image-copy-capture-v1 ----------------------------------------------------

@(private = "file")
session_listener := wl.Ext_Image_Copy_Capture_Session_V1_Listener {
	buffer_size = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Session_V1, width, height: u32) {
		t := (^Capture_Target)(data)
		t.w, t.h = i32(width), i32(height)
	},
	shm_format = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Session_V1, format: u32) {
		offer_format((^Capture_Target)(data), format)
	},
	dmabuf_device = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Session_V1, device: ^wl.Array) {},
	dmabuf_format = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Session_V1, format: u32, modifiers: ^wl.Array) {},
	done = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Session_V1) {
		context = cap_ctx
		t := (^Capture_Target)(data)
		if t.state != .Waiting {return}
		t.stride = 0 // alloc_buffer: tightly packed
		if !alloc_buffer(t) {fail(t, "no usable shm format"); return}
		t.frame = wl.ext_image_copy_capture_session_v1_create_frame(self)
		wl.ext_image_copy_capture_frame_v1_add_listener(t.frame, &frame_listener, t)
		wl.ext_image_copy_capture_frame_v1_attach_buffer(t.frame, t.buffer)
		wl.ext_image_copy_capture_frame_v1_damage_buffer(t.frame, 0, 0, t.w, t.h)
		wl.ext_image_copy_capture_frame_v1_capture(t.frame)
		t.state = .Copying
	},
	stopped = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Session_V1) {
		context = cap_ctx
		t := (^Capture_Target)(data)
		if t.state == .Waiting || t.state == .Copying {fail(t, "session stopped")}
	},
}

@(private = "file")
frame_listener := wl.Ext_Image_Copy_Capture_Frame_V1_Listener {
	transform = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Frame_V1, transform: u32) {
		(^Capture_Target)(data).transform = i32(transform)
	},
	damage = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Frame_V1, x, y, width, height: i32) {},
	presentation_time = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Frame_V1, hi, lo, ns: u32) {},
	ready = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Frame_V1) {
		context = cap_ctx
		ready((^Capture_Target)(data))
	},
	failed = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Frame_V1, reason: u32) {
		context = cap_ctx
		fail((^Capture_Target)(data), "frame failed")
	},
}

// ---- wlr-screencopy-unstable-v1 -----------------------------------------------------

@(private = "file")
wlr_copy :: proc(t: ^Capture_Target) {
	if t.state != .Waiting {return}
	if !alloc_buffer(t) {fail(t, "no usable shm format"); return}
	wl.zwlr_screencopy_frame_v1_copy(t.wframe, t.buffer)
	t.state = .Copying
}

@(private = "file")
wlr_listener := wl.Zwlr_Screencopy_Frame_V1_Listener {
	buffer = proc "c" (data: rawptr, self: ^wl.Zwlr_Screencopy_Frame_V1, format, width, height, stride: u32) {
		context = cap_ctx
		t := (^Capture_Target)(data)
		prev := t.fmt_rank
		offer_format(t, format)
		if t.fmt_rank < prev {t.w, t.h, t.stride = i32(width), i32(height), i32(stride)}
		// Before v3 there is exactly one buffer event and no buffer_done.
		if wl.zwlr_screencopy_frame_v1_get_version(self) < 3 {wlr_copy(t)}
	},
	flags = proc "c" (data: rawptr, self: ^wl.Zwlr_Screencopy_Frame_V1, flags: u32) {
		(^Capture_Target)(data).y_invert = flags & wl.ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT != 0
	},
	ready = proc "c" (data: rawptr, self: ^wl.Zwlr_Screencopy_Frame_V1, hi, lo, ns: u32) {
		context = cap_ctx
		ready((^Capture_Target)(data))
	},
	failed = proc "c" (data: rawptr, self: ^wl.Zwlr_Screencopy_Frame_V1) {
		context = cap_ctx
		fail((^Capture_Target)(data), "copy failed")
	},
	damage = proc "c" (data: rawptr, self: ^wl.Zwlr_Screencopy_Frame_V1, x, y, width, height: u32) {},
	linux_dmabuf = proc "c" (data: rawptr, self: ^wl.Zwlr_Screencopy_Frame_V1, format, width, height: u32) {},
	buffer_done = proc "c" (data: rawptr, self: ^wl.Zwlr_Screencopy_Frame_V1) {
		context = cap_ctx
		wlr_copy((^Capture_Target)(data))
	},
}

// ---- Driver ---------------------------------------------------------------------------

capture_available :: proc() -> bool {
	return cg.shm != nil && ((cg.ext_copy != nil && cg.ext_source != nil) || cg.wlr != nil)
}

// Capture every target and blur it at `strength`. Returns how many succeeded;
// the others keep a nil result. Never takes (much) longer than `timeout`.
capture_and_blur :: proc(display: ^wl.Display, shm: ^wl.Shm, targets: []^Capture_Target, strength: int, timeout := LOCK_CAPTURE_TIMEOUT) -> int {
	cap_ctx = context
	cg.shm = shm
	if !capture_available() {
		log.warn("lock: the compositor offers no screen capture; using the solid background")
		return 0
	}
	use_ext := cg.ext_copy != nil && cg.ext_source != nil
	when LOCK_TEST_AUTH {
		// Test builds: WLPERCH_LOCK_TEST_CAPTURE=fail | hang | wlr
		switch os.get_env("WLPERCH_LOCK_TEST_CAPTURE", context.temp_allocator) {
		case "fail":
			log.warn("lock: test: simulated capture failure")
			return 0
		case "wlr":
			if cg.wlr != nil {use_ext = false}
		case "hang":
			for t in targets {t.state = .Waiting}
			return wait_targets(display, targets, timeout)
		}
	}
	log.infof("lock: capturing %d output(s) with %s", len(targets), use_ext ? "ext-image-copy-capture" : "wlr-screencopy")
	for t in targets {
		t.state = .Waiting
		t.fmt_rank = max(int)
		t.strength = strength
		if use_ext {
			t.source = wl.ext_output_image_capture_source_manager_v1_create_source(cg.ext_source, t.output)
			t.session = wl.ext_image_copy_capture_manager_v1_create_session(cg.ext_copy, t.source, 0)
			wl.ext_image_copy_capture_session_v1_add_listener(t.session, &session_listener, t)
		} else {
			t.wframe = wl.zwlr_screencopy_manager_v1_capture_output(cg.wlr, 0, t.output)
			wl.zwlr_screencopy_frame_v1_add_listener(t.wframe, &wlr_listener, t)
		}
	}
	return wait_targets(display, targets, timeout)
}

@(private = "file")
wait_targets :: proc(display: ^wl.Display, targets: []^Capture_Target, timeout: time.Duration) -> int {
	deadline := time.tick_add(time.tick_now(), timeout)
	for {
		pending := 0
		for t in targets {if t.state == .Waiting || t.state == .Copying {pending += 1}}
		if pending == 0 {break}
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 {
			log.warnf("lock: screen capture timed out after %v", timeout)
			break
		}
		for wl.display_prepare_read(display) != 0 {wl.display_dispatch_pending(display)}
		wl.display_flush(display)
		pfd := posix.pollfd{fd = posix.FD(wl.display_get_fd(display)), events = {.IN}}
		ms := max(i32(time.duration_milliseconds(left)), 1)
		if posix.poll(&pfd, 1, ms) > 0 && .IN in pfd.revents {
			wl.display_read_events(display)
		} else {
			wl.display_cancel_read(display)
		}
		if wl.display_dispatch_pending(display) < 0 {break}
	}
	ok := 0
	for t in targets {
		if t.state == .Done {ok += 1} else {
			t.state = .Failed
			release(t)
		}
	}
	// Late events for the destroyed objects are dropped by libwayland.
	return ok
}

// ---- Reduce + blur ----------------------------------------------------------------------

// 8- or 10-bit pixel -> 0x00RRGGBB.
@(private = "file")
to_rgb :: #force_inline proc "contextless" (p: u32, format: u32) -> u32 {
	switch format {
	case wl.SHM_FORMAT_XBGR8888, wl.SHM_FORMAT_ABGR8888:
		return (p & 0xff) << 16 | (p & 0xff00) | (p >> 16) & 0xff
	case wl.SHM_FORMAT_XRGB2101010, wl.SHM_FORMAT_ARGB2101010:
		return ((p >> 22) & 0xff) << 16 | ((p >> 12) & 0xff) << 8 | (p >> 2) & 0xff
	case wl.SHM_FORMAT_XBGR2101010, wl.SHM_FORMAT_ABGR2101010:
		return ((p >> 2) & 0xff) << 16 | ((p >> 12) & 0xff) << 8 | (p >> 22) & 0xff
	}
	return p & 0xffffff
}

// Shrink, orient and blur one captured frame (its shm mapping).
lock_reduce_and_blur :: proc(t: ^Capture_Target) -> Blur_Image {
	W, H := int(t.w), int(t.h)
	if t.mem == nil || W <= 0 || H <= 0 {return {}}
	sigma := lock_blur_sigma(t.strength) * f32(max(t.scale, 1)) // native px
	// Shrink so the remaining blur is ~4 small pixels: cheap passes, and the
	// box downscale already averages away every detail below D px.
	D := clamp(int(sigma / 4), 1, min(W, H))
	nw, nh := W / D, H / D

	// 1. D x D box average, straight from shm (one sequential read).
	acc := make([]u32, nw * 3, context.temp_allocator)
	small := make([]u32, nw * nh, context.temp_allocator)
	src := ([^]u8)(t.mem)
	for by in 0 ..< nh {
		for &a in acc {a = 0}
		for k in 0 ..< D {
			y := by * D + k
			if t.y_invert {y = H - 1 - y}
			row8 := src[y * int(t.stride):]
			row := ([^]u32)(row8) // 32-bit formats: stride is a multiple of 4
			for bx in 0 ..< nw {
				r, g, b: u32
				base := bx * D
				switch t.format {
				case wl.SHM_FORMAT_BGR888: // bytes R, G, B
					for i in 0 ..< D {
						q := row8[(base + i) * 3:]
						r += u32(q[0]); g += u32(q[1]); b += u32(q[2])
					}
				case wl.SHM_FORMAT_RGB888: // bytes B, G, R
					for i in 0 ..< D {
						q := row8[(base + i) * 3:]
						r += u32(q[2]); g += u32(q[1]); b += u32(q[0])
					}
				case wl.SHM_FORMAT_XRGB8888, wl.SHM_FORMAT_ARGB8888:
					for i in 0 ..< D {
						p := row[base + i]
						r += (p >> 16) & 0xff; g += (p >> 8) & 0xff; b += p & 0xff
					}
				case:
					for i in 0 ..< D {
						p := to_rgb(row[base + i], t.format)
						r += (p >> 16) & 0xff; g += (p >> 8) & 0xff; b += p & 0xff
					}
				}
				acc[bx * 3] += r; acc[bx * 3 + 1] += g; acc[bx * 3 + 2] += b
			}
		}
		n := u32(D * D)
		for bx in 0 ..< nw {
			small[by * nw + bx] = (acc[bx * 3] / n) << 16 | (acc[bx * 3 + 1] / n) << 8 | (acc[bx * 3 + 2] / n)
		}
	}

	// 2. Into the logical orientation (buffer -> output, as wlr_box_transform).
	lw, lh := nw, nh
	if t.transform & 1 != 0 {lw, lh = nh, nw}
	out := make([]u32, lw * lh) // the result: kept until the lock exits
	for ny in 0 ..< nh {
		for nx in 0 ..< nw {
			lx, ly: int
			switch t.transform {
			case 1:  lx, ly = nh - 1 - ny, nx
			case 2:  lx, ly = nw - 1 - nx, nh - 1 - ny
			case 3:  lx, ly = ny, nw - 1 - nx
			case 4:  lx, ly = nw - 1 - nx, ny
			case 5:  lx, ly = ny, nx
			case 6:  lx, ly = nx, nh - 1 - ny
			case 7:  lx, ly = nh - 1 - ny, nw - 1 - nx
			case:    lx, ly = nx, ny
			}
			out[ly * lw + lx] = small[ny * nw + nx]
		}
	}

	// 3. Three box passes per axis ≈ Gaussian of the remaining sigma.
	ss := sigma / f32(D)
	r := max(1, int(math.round((math.sqrt(4 * ss * ss + 1) - 1) / 2)))
	tmp := make([]u32, max(lw, lh), context.temp_allocator)
	for _ in 0 ..< 3 {
		for y in 0 ..< lh {box_line(out[y * lw:], 1, lw, r, tmp)}
		for x in 0 ..< lw {box_line(out[x:], lw, lh, r, tmp)}
	}
	return {out, lw, lh}
}

// One box-blur pass over n pixels `step` apart, edges clamped.
@(private = "file")
box_line :: proc(line: []u32, step, n, r: int, tmp: []u32) {
	for i in 0 ..< n {tmp[i] = line[i * step]}
	at :: #force_inline proc "contextless" (tmp: []u32, i, n: int) -> u32 {return tmp[clamp(i, 0, n - 1)]}
	sr, sg, sb: u32
	for i in -r ..= r {
		p := at(tmp, i, n)
		sr += (p >> 16) & 0xff; sg += (p >> 8) & 0xff; sb += p & 0xff
	}
	w := u32(2 * r + 1)
	for i in 0 ..< n {
		line[i * step] = (sr / w) << 16 | (sg / w) << 8 | (sb / w)
		a, b := at(tmp, i + r + 1, n), at(tmp, i - r, n)
		sr += (a >> 16) & 0xff; sg += (a >> 8) & 0xff; sb += a & 0xff
		sr -= (b >> 16) & 0xff; sg -= (b >> 8) & 0xff; sb -= b & 0xff
	}
}

// Fill dst (W x H) with the blurred copy bilinearly upscaled, mixed toward
// `tint` by `mix` (0..1), plus a faint grain against banding: frosted glass.
// (Also the [lock] image's upscale: tint black, no grain.)
// Fixed point throughout: each source row pair is blended vertically once per
// output row, then every output pixel is one horizontal lerp and the tint.
blur_draw :: proc(dst: []u32, W, H: int, img: Blur_Image, tint: u32, mix: f32, grain := true) {
	sw, sh := img.w, img.h
	if sw <= 0 || sh <= 0 || W <= 0 || H <= 0 || len(img.px) < sw * sh || len(dst) < W * H {return}
	k := u32(clamp(mix, 0, 1) * 256)
	ik := 256 - k
	// The tint's share, per 8-bit lane (R|B together, G alone).
	trb, tg := (tint & 0xff00ff) * k, (tint & 0xff00) * k
	// Per-column source indices and weight (8-bit, pixel centres).
	xs0 := make([]i32, W, context.temp_allocator)
	xs1 := make([]i32, W, context.temp_allocator)
	xw := make([]u32, W, context.temp_allocator)
	for x in 0 ..< W {
		f := clamp((f32(x) + 0.5) * f32(sw) / f32(W) - 0.5, 0, f32(sw - 1))
		xs0[x] = i32(f)
		xs1[x] = min(i32(f) + 1, i32(sw - 1))
		xw[x] = u32((f - f32(i32(f))) * 256)
	}
	vrow := make([]u32, sw, context.temp_allocator)
	last_y0, last_wy := -1, u32(0)
	for y in 0 ..< H {
		fy := clamp((f32(y) + 0.5) * f32(sh) / f32(H) - 0.5, 0, f32(sh - 1))
		y0 := int(fy)
		y1 := min(y0 + 1, sh - 1)
		wy := u32((fy - f32(y0)) * 256)
		if y0 != last_y0 || wy != last_wy {
			last_y0, last_wy = y0, wy
			r0, r1 := img.px[y0 * sw:][:sw], img.px[y1 * sw:][:sw]
			for i in 0 ..< sw {vrow[i] = lerp_px(r0[i], r1[i], wy)}
		}
		blur_row(dst[y * W:][:W], vrow, xs0, xs1, xw, y, ik, trb, tg, grain)
	}
}

// Interpolates R|B and G together (8-bit lanes, 8-bit weight).
@(private = "file")
lerp_px :: #force_inline proc "contextless" (p, q, w: u32) -> u32 {
	rb := ((p & 0xff00ff) * (256 - w) + (q & 0xff00ff) * w) >> 8 & 0xff00ff
	g := ((p & 0xff00) * (256 - w) + (q & 0xff00) * w) >> 8 & 0xff00
	return rb | g
}

@(private = "file")
blur_row :: proc(row, vrow: []u32, xs0, xs1: []i32, xw: []u32, y: int, ik, trb, tg: u32, grain: bool) #no_bounds_check {
	// Callers keep xs0/xs1 < len(vrow) and len(row) == len(xs0).
	for x in 0 ..< len(row) {
		v := lerp_px(vrow[xs0[x]], vrow[xs1[x]], xw[x])
		v = ((v & 0xff00ff) * ik + trb) >> 8 & 0xff00ff | ((v & 0xff00) * ik + tg) >> 8 & 0xff00
		if grain {
			// A cheap hash, triangular ±3 levels.
			h := u32(x) * 0x9E3779B1 ~ u32(y) * 0x85EBCA77
			h ~= h >> 16
			h *= 0x7feb352d
			h ~= h >> 15
			n := i32(h >> 30) + i32((h >> 28) & 3) - 3
			rr := clamp(i32((v >> 16) & 0xff) + n, 0, 255)
			gg := clamp(i32((v >> 8) & 0xff) + n, 0, 255)
			bb := clamp(i32(v & 0xff) + n, 0, 255)
			v = u32(rr) << 16 | u32(gg) << 8 | u32(bb)
		}
		row[x] = 0xff000000 | v
	}
}
