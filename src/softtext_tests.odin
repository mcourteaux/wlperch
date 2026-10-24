// Unit tests for the software text renderer (softtext.odin): kerning,
// tabular digits, glyph positions.
package main

import "core:fmt"
import "core:math"
import "core:testing"

@(private = "file")
kern_px :: proc(f: ^Soft_Font, px: f32, a, b: string) -> f32 {
	return soft_text_width(f, px, fmt.tprintf("%s%s", a, b)) - soft_text_width(f, px, a) - soft_text_width(f, px, b)
}

@(test)
test_softtext_gpos_kerning :: proc(t: ^testing.T) {
	soft_fonts_init()
	// Inter's kerning is GPOS-only, mostly in an Extension lookup (which
	// stb_truetype's reader skips). In font units (2048/em), per fontTools:
	// A V -140, T o -160, 7 . -256, p m 0.
	units :: proc(f: ^Soft_Font, a, b: string) -> int {return int(math.round(kern_px(f, 1 / f.scale1, a, b)))}
	testing.expect_value(t, units(&soft_regular, "A", "V"), -140)
	testing.expect_value(t, units(&soft_regular, "T", "o"), -160)
	testing.expect_value(t, units(&soft_regular, "7", "."), -256)
	testing.expect_value(t, units(&soft_regular, "p", "m"), 0)
	testing.expect(t, units(&soft_bold, "A", "V") < 0)
	// Not in ASCII (the uncached path): Ä V kerns like A V.
	testing.expect_value(t, units(&soft_regular, "Ä", "V"), units(&soft_regular, "A", "V"))
	free_all(context.temp_allocator)
}

@(test)
test_softtext_tabular_digits :: proc(t: ^testing.T) {
	soft_fonts_init()
	for f in ([]^Soft_Font{&soft_regular, &soft_bold}) {
		one := soft_text_width(f, 14, "1", tnum = true)
		for d in ([]string{"0", "4", "7", "8"}) {
			testing.expect(t, abs(soft_text_width(f, 14, d, tnum = true) - one) < 1e-4)
		}
		// Proportional by default.
		testing.expect(t, soft_text_width(f, 14, "1") < soft_text_width(f, 14, "8"))
		// "988 ppm" is "88 ppm" plus one digit, exactly.
		w88 := soft_text_width(f, 14, "88 ppm", tnum = true)
		testing.expect(t, abs(soft_text_width(f, 14, "988 ppm", tnum = true) - w88 - one) < 1e-3)
		testing.expect(t, abs(soft_text_width(f, 14, "1088 ppm", tnum = true) - w88 - 2 * one) < 1e-3)
	}
}

// The glyphs land where the (fractional) pen says, to a quarter pixel: the
// gap between two letters doesn't depend on where the text starts.
@(test)
test_softtext_subpixel_positions :: proc(t: ^testing.T) {
	soft_fonts_init()
	W, H :: 200, 30
	ink_x :: proc(s: string, x: f32) -> f32 {
		buf := make([]u32, W * H, context.temp_allocator)
		soft_draw_text(buf, W, H, &soft_regular, 14, x, 20, s, 0xffffff)
		sum, n: f32
		for p, i in buf {
			a := f32(p >> 24)
			sum += a * f32(i % W)
			n += a
		}
		return sum / n
	}
	base := ink_x("m", 10)
	for k in 0 ..< 8 {
		dx := f32(k) * 0.125
		testing.expectf(t, abs(ink_x("m", 10 + dx) - base - dx) <= 0.13, "m at +%v moved %v", dx, ink_x("m", 10 + dx) - base)
	}
	free_all(context.temp_allocator)
}
