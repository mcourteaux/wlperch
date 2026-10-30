// Unit tests for the wallpaper process's pure parts (wallpaper_proc.odin).
package main

import "core:testing"
import "core:time"

@(test)
test_wallpaper_cover_rect :: proc(t: ^testing.T) {
	// Wider than the output: the sides go.
	x, y, w, h := wallpaper_cover_rect(8751, 4000, 2560, 1440)
	testing.expect_value(t, h, 4000)
	testing.expect_value(t, w, 7111)
	testing.expect_value(t, x, (8751 - 7111) / 2)
	testing.expect_value(t, y, 0)
	// Taller (a portrait photo on a landscape output): top and bottom go.
	x, y, w, h = wallpaper_cover_rect(3000, 4000, 1920, 1080)
	testing.expect_value(t, w, 3000)
	testing.expect_value(t, h, 1688)
	testing.expect_value(t, x, 0)
	testing.expect_value(t, y, (4000 - 1688) / 2)
	// Same aspect: all of it.
	x, y, w, h = wallpaper_cover_rect(3840, 2160, 1920, 1080)
	testing.expect(t, x == 0 && y == 0 && w == 3840 && h == 2160)
	// A rotated (portrait) output.
	_, _, w, h = wallpaper_cover_rect(1920, 1080, 1080, 1920)
	testing.expect_value(t, h, 1080)
	testing.expect_value(t, w, 608)
	// Nothing to cover.
	_, _, w, h = wallpaper_cover_rect(100, 100, 0, 10)
	testing.expect(t, w == 0 && h == 0)
}

@(test)
test_wallpaper_pixel_size :: proc(t: ^testing.T) {
	pw, ph := wallpaper_pixel_size(2560, 1440, 0, 1)
	testing.expect(t, pw == 2560 && ph == 1440)
	pw, ph = wallpaper_pixel_size(1280, 720, 0, 2)
	testing.expect(t, pw == 2560 && ph == 1440)
	// 1.5 (180/120): a 4K panel shown as 2560x1440.
	pw, ph = wallpaper_pixel_size(2560, 1440, 180, 2)
	testing.expect(t, pw == 3840 && ph == 2160)
	// 1.25 rounds to whole pixels.
	pw, ph = wallpaper_pixel_size(1229, 691, 150, 1)
	testing.expect(t, pw == 1536 && ph == 864)

	// Better: the output's own pixels, when the surface covers it.
	ok: bool
	pw, ph, ok = wallpaper_mode_pixels(1600, 900, 0, 1066, 600, 180) // 1.5: 1066 x 1.5 = 1599
	testing.expect(t, ok && pw == 1600 && ph == 900)
	pw, ph, ok = wallpaper_mode_pixels(2560, 1440, 1, 720, 1280, 240) // turned 90 degrees, scale 2
	testing.expect(t, ok && pw == 1440 && ph == 2560)
	pw, ph, ok = wallpaper_mode_pixels(3840, 2160, 0, 2560, 1440, 0) // no fractional scale known
	testing.expect(t, ok && pw == 3840 && ph == 2160)
	_, _, ok = wallpaper_mode_pixels(1920, 1080, 0, 1920, 1050, 120) // not the whole output
	testing.expect(t, !ok)
	_, _, ok = wallpaper_mode_pixels(0, 0, 0, 1920, 1080, 120)
	testing.expect(t, !ok)
}

@(test)
test_wallpaper_prescale :: proc(t: ^testing.T) {
	testing.expect_value(t, wallpaper_prescale_factor(7111, 4000, 2560, 1440), 2)
	testing.expect_value(t, wallpaper_prescale_factor(3840, 2160, 2560, 1440), 1)
	testing.expect_value(t, wallpaper_prescale_factor(1920, 1080, 3840, 2160), 1) // upscale
	testing.expect_value(t, wallpaper_prescale_factor(15360, 8640, 3840, 2160), 4)
	// Never below the output's size afterwards.
	w, h := 7111, 4000
	k := wallpaper_prescale_factor(w, h, 2560, 1440)
	testing.expect(t, w / k >= 2560 && h / k >= 1440)

	// A 4x2 RGBA region averaged 2x2: two pixels.
	src := []u8 {
		10, 20, 30, 255, 30, 40, 50, 255, 0, 0, 0, 255, 100, 100, 100, 255,
		50, 60, 70, 255, 70, 80, 90, 255, 0, 0, 0, 255, 100, 100, 100, 255,
	}
	out, ow, oh := wallpaper_box_down(src, 16, 0, 0, 4, 2, 2, context.temp_allocator)
	testing.expect(t, ow == 2 && oh == 1)
	testing.expect_value(t, out[0], 40)
	testing.expect_value(t, out[1], 50)
	testing.expect_value(t, out[2], 60)
	testing.expect_value(t, out[3], 255)
	testing.expect_value(t, out[4], 50)
	// An offset region: just the right column pair.
	out, ow, oh = wallpaper_box_down(src, 16, 2, 0, 2, 2, 2, context.temp_allocator)
	testing.expect(t, ow == 1 && oh == 1 && out[0] == 50 && out[3] == 255)
}

@(test)
test_wallpaper_pixels :: proc(t: ^testing.T) {
	// stb's RGBA bytes, read as little-endian words.
	px := []u32{0xff_33_22_11, 0x80_ff_ff_ff, 0x00_ff_00_00}
	wallpaper_rgba_to_xrgb(px)
	testing.expect_value(t, px[0], 0xff_11_22_33) // R and B swap places
	testing.expect_value(t, px[1], 0xff_80_80_80) // half transparent white over black
	testing.expect_value(t, px[2], 0xff_00_00_00) // transparent: black

	a := []u32{0xff_00_00_00, 0xff_ff_ff_ff, 0xff_ff_00_00, 0xff_20_40_80}
	b := []u32{0xff_ff_ff_ff, 0xff_00_00_00, 0xff_00_00_ff, 0xff_20_40_80}
	out := make([]u32, 4, context.temp_allocator)
	wallpaper_blend(a, b, out, 0)
	for i in 0 ..< 4 {testing.expect_value(t, out[i] & 0xffffff, a[i] & 0xffffff)}
	wallpaper_blend(a, b, out, 256)
	for i in 0 ..< 4 {testing.expect_value(t, out[i] & 0xffffff, b[i] & 0xffffff)}
	wallpaper_blend(a, b, out, 128)
	testing.expect_value(t, out[0] & 0xffffff, 0x7f7f7f)
	testing.expect_value(t, out[1] & 0xffffff, 0x7f7f7f)
	testing.expect_value(t, out[2] & 0xffffff, 0x7f007f)
	testing.expect_value(t, out[3] & 0xffffff, 0x204080) // the same colour stays put
	// No channel bleeds into its neighbour.
	wallpaper_blend([]u32{0x00ff00ff}, []u32{0x00ff00ff}, out[:1], 200)
	testing.expect_value(t, out[0] & 0xffffff, 0xff00ff)
}

@(test)
test_wallpaper_fade_and_rotation :: proc(t: ^testing.T) {
	testing.expect_value(t, wallpaper_fade_weight(0, WALLPAPER_FADE), 0)
	testing.expect_value(t, wallpaper_fade_weight(WALLPAPER_FADE, WALLPAPER_FADE), 256)
	testing.expect_value(t, wallpaper_fade_weight(WALLPAPER_FADE / 2, WALLPAPER_FADE), 128)
	// Eased: slow at both ends, always moving forward.
	testing.expect(t, wallpaper_fade_weight(WALLPAPER_FADE / 10, WALLPAPER_FADE) < 256 / 10)
	prev := u32(0)
	for i in 0 ..= 20 {
		w := wallpaper_fade_weight(WALLPAPER_FADE * time.Duration(i) / 20, WALLPAPER_FADE)
		testing.expect(t, w >= prev)
		prev = w
	}

	testing.expect_value(t, wallpaper_rotate_in(0, 1000, 99999), -1) // off
	testing.expect_value(t, wallpaper_rotate_in(10, 1000, 1000), 600)
	testing.expect_value(t, wallpaper_rotate_in(10, 1000, 1500), 100)
	testing.expect_value(t, wallpaper_rotate_in(10, 1000, 1600), 0) // due
	testing.expect_value(t, wallpaper_rotate_in(10, 1000, 9000), 0) // overdue: once, not a backlog
}
