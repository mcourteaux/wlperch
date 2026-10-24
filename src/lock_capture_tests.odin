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
