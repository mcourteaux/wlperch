// Unit tests for the lock screen's blurred-screenshot background
// (lock_capture.odin): privacy floor, transforms, pixel formats, config.
package main

import "core:testing"

import "wl"

@(private = "file")
spread :: proc(img: Blur_Image) -> (lo, hi: u32) {
	lo = 255
	for p in img.px {
		g := (p >> 8) & 0xff
		lo, hi = min(lo, g), max(hi, g)
	}
	return
}

// Fake glyphs: 1-3 px strokes in 12 px cells, black on white.
@(private = "file")
text_like :: proc(w, h: int) -> []u32 {
	px := make([]u32, w * h)
	for y in 0 ..< h {
		for x in 0 ..< w {
			ink := (x % 12 < 2 || y % 12 == 5 || (x + y) % 9 == 0) && y % 24 < 14
			px[y * w + x] = ink ? 0 : 0xffffff
		}
	}
	return px
}

@(test)
test_lock_blur_hides_text_at_minimum :: proc(t: ^testing.T) {
	W, H := 640, 360
	px := text_like(W, H)
	defer delete(px)
	ct := Capture_Target{w = i32(W), h = i32(H), stride = i32(W * 4), format = wl.SHM_FORMAT_XRGB8888, scale = 1, strength = 0, mem = raw_data(px)}
	img := lock_reduce_and_blur(&ct)
	defer delete(img.px)
	lo, hi := spread(img)
	// Away from the edges every pixel is the same mid grey: no strokes left.
	inner_lo, inner_hi := u32(255), u32(0)
	for y in img.h / 4 ..< img.h * 3 / 4 {
		for x in img.w / 4 ..< img.w * 3 / 4 {
			g := (img.px[y * img.w + x] >> 8) & 0xff
			inner_lo, inner_hi = min(inner_lo, g), max(inner_hi, g)
		}
	}
	testing.expectf(t, inner_hi - inner_lo <= 6, "strokes survive the minimum blur: %d..%d", inner_lo, inner_hi)
	testing.expect(t, hi >= lo)
	testing.expect(t, lock_blur_sigma(0) == LOCK_BLUR_MIN_SIGMA && lock_blur_sigma(-5) == LOCK_BLUR_MIN_SIGMA)
	testing.expect(t, lock_blur_sigma(100) == LOCK_BLUR_MAX_SIGMA && lock_blur_sigma(500) == LOCK_BLUR_MAX_SIGMA)
}

@(test)
test_lock_blur_transform_and_formats :: proc(t: ^testing.T) {
	// Native 800x400: left half red, right half blue. With wl transform 1
	// (sway's "transform 270") the logical picture is portrait, red on top
	// (checked against grim on a rotated headless output).
	W, H := 800, 400
	px := make([]u32, W * H)
	defer delete(px)
	for y in 0 ..< H {for x in 0 ..< W {px[y * W + x] = x < W / 2 ? 0xff0000 : 0x0000ff}}
	ct := Capture_Target{w = i32(W), h = i32(H), stride = i32(W * 4), format = wl.SHM_FORMAT_XRGB8888, scale = 1, strength = 0, transform = 1, mem = raw_data(px)}
	img := lock_reduce_and_blur(&ct)
	defer delete(img.px)
	testing.expect(t, img.h > img.w)
	top, bottom := img.px[img.w / 2], img.px[(img.h - 1) * img.w + img.w / 2]
	testing.expectf(t, top >> 16 > 0xc0 && top & 0xff < 0x40, "top should be red: %x", top)
	testing.expectf(t, bottom & 0xff > 0xc0 && bottom >> 16 < 0x40, "bottom should be blue: %x", bottom)

	// The same red as BGR888 (bytes R, G, B) and XBGR8888 / XRGB2101010.
	b24 := make([]u8, 64 * 64 * 3)
	defer delete(b24)
	for i in 0 ..< 64 * 64 {b24[i * 3] = 0xff}
	c24 := Capture_Target{w = 64, h = 64, stride = 64 * 3, format = wl.SHM_FORMAT_BGR888, scale = 1, mem = raw_data(b24)}
	i24 := lock_reduce_and_blur(&c24)
	defer delete(i24.px)
	testing.expectf(t, i24.px[0] == 0xff0000, "BGR888: %x", i24.px[0])
	x10 := make([]u32, 64 * 64)
	defer delete(x10)
	for &p in x10 {p = 0x3ff << 20}
	c10 := Capture_Target{w = 64, h = 64, stride = 64 * 4, format = wl.SHM_FORMAT_XRGB2101010, scale = 1, mem = raw_data(x10)}
	i10 := lock_reduce_and_blur(&c10)
	defer delete(i10.px)
	testing.expectf(t, i10.px[0] == 0xff0000, "XRGB2101010: %x", i10.px[0])
}

@(test)
test_lock_bg_mode_parse :: proc(t: ^testing.T) {
	testing.expect(t, lock_bg_mode_parse("", "") == .Color)
	testing.expect(t, lock_bg_mode_parse("", "/x.png") == .Image)
	testing.expect(t, lock_bg_mode_parse("blur", "/x.png") == .Blur)
	testing.expect(t, lock_bg_mode_parse(" Blur ", "") == .Blur)
	testing.expect(t, lock_bg_mode_parse("color", "/x.png") == .Color)
	testing.expect(t, lock_bg_mode_parse("image", "") == .Color) // no picture set
	testing.expect(t, lock_bg_mode_parse("nonsense", "") == .Color)
}

// blur_draw's fixed-point upscale: exact at the source pixels, a midpoint
// between them, the tint mixed in, alpha opaque.
@(test)
test_blur_draw_upscale :: proc(t: ^testing.T) {
	src := []u32{0x000000, 0xff8040, 0x204060, 0x204060}
	img := Blur_Image{src, 2, 2}
	dst := make([]u32, 8 * 2)
	defer delete(dst)
	blur_draw(dst, 8, 2, img, 0, 0, grain = false)
	testing.expect_value(t, dst[0], 0xff000000) // left of the first centre: clamped
	testing.expect_value(t, dst[7], 0xffff8040)
	testing.expect_value(t, dst[8], 0xff204060)
	// x = 3 samples 0.375 of the way from black to 0xff8040: 0xff * 96 / 256.
	testing.expect_value(t, (dst[3] >> 16) & 0xff, 0x5f)
	// Half toward white.
	blur_draw(dst, 8, 2, img, 0xffffff, 0.5, grain = false)
	testing.expect_value(t, dst[0], 0xff7f7f7f)
	// Grain stays within ±3 levels.
	flat := Blur_Image{[]u32{0x808080}, 1, 1}
	blur_draw(dst, 8, 2, flat, 0, 0)
	for p in dst {testing.expect(t, abs(i32((p >> 8) & 0xff) - 0x80) <= 3, "grain")}
}

// The animation's fast upscale matches blur_draw (no grain) within two levels.
@(test)
test_blur_draw_fast_matches :: proc(t: ^testing.T) {
	sw, sh := 37, 23
	src := make([]u32, sw * sh)
	defer delete(src)
	for &p, i in src {p = u32(i * 2654435761) & 0xffffff}
	W, H := 301, 157 // not a multiple of 8: the scalar tail too
	a := make([]u32, W * H)
	b := make([]u32, W * H)
	defer {delete(a); delete(b)}
	blur_draw(a, W, H, {src, sw, sh}, 0x14161b, 0.32, grain = false)
	blur_draw_fast(b, W, H, {src, sw, sh}, 0x14161b, 0.32)
	worst: i32
	for i in 0 ..< W * H {
		testing.expect(t, b[i] >> 24 == 0xff)
		for sh in ([]u32{0, 8, 16}) {worst = max(worst, abs(i32((a[i] >> sh) & 0xff) - i32((b[i] >> sh) & 0xff)))}
	}
	testing.expectf(t, worst <= 2, "fast upscale off by %d", worst)
}

// Animated: the incremental blur (many small passes, halvings) ends where
// the static copy is, the brightness doesn't drift, and the start is
// much sharper.
@(test)
test_lock_blur_anim_converges :: proc(t: ^testing.T) {
	W, H := 960, 540
	px := text_like(W, H)
	defer delete(px)
	// Big shapes too, so the blur width matters.
	for y in 0 ..< H {for x in 0 ..< W {if (x / 160 + y / 120) % 2 == 0 && y % 24 >= 14 {px[y * W + x] = 0x3060c0}}}
	for strength in ([]int{0, 60, 100}) {
		ct := Capture_Target{w = i32(W), h = i32(H), stride = i32(W * 4), format = wl.SHM_FORMAT_XRGB8888, scale = 1, strength = strength, mem = raw_data(px), animate = true, anim_from = 0}
		static := lock_reduce_and_blur(&ct)
		defer delete(static.px)
		testing.expect(t, ct.anim.img.px != nil && ct.anim.D >= 2 && ct.anim.D <= max(ct.anim.D_static, 2))
		a := blur_anim_init(ct.anim)
		defer blur_anim_free(&a)

		up_static := make([]u32, W * H)
		up_anim := make([]u32, W * H)
		defer {delete(up_static); delete(up_anim)}
		blur_draw(up_static, W, H, static, 0, 0, grain = false)
		// Sharp at the start: far from the static picture.
		blur_draw(up_anim, W, H, blur_anim_image(&a), 0, 0, grain = false)
		start_diff, _, _ := img_diff(up_static, up_anim)
		// ~1.5 s at 60 fps.
		for f in 1 ..= 90 {blur_anim_step(&a, blur_anim_sigma_at(&a, f64(f) / 90))}
		blur_draw(up_anim, W, H, blur_anim_image(&a), 0, 0, grain = false)
		mean, worst, drift := img_diff(up_static, up_anim)
		testing.expectf(t, mean < 2 && worst <= 16 && abs(drift) < 0.5, "strength %d: mean %.2f, worst %d, drift %.2f", strength, mean, worst, drift)
		testing.expectf(t, start_diff > 4 * mean, "strength %d: the start isn't sharper (%.2f vs %.2f)", strength, start_diff, mean)
	}

	img_diff :: proc(a, b: []u32) -> (mean: f64, worst: i32, drift: f64) {
		sum, sd: i64
		for i in 0 ..< len(a) {
			for sh in ([]u32{0, 8, 16}) {
				d := i32((b[i] >> sh) & 0xff) - i32((a[i] >> sh) & 0xff)
				sum += i64(abs(d)); sd += i64(d)
				worst = max(worst, abs(d))
			}
		}
		n := f64(len(a) * 3)
		return f64(sum) / n, worst, f64(sd) / n
	}
}
