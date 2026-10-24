// Software text rendering into ARGB8888 (premultiplied) pixel buffers, for
// surfaces that don't use the GL renderer (placeholder windows, notification
// popups, the bar). Glyphs missing from Inter come from the symbol font, then
// from a system font fontconfig picks.
package main

import "core:c"
import "core:fmt"
import "core:os"
import stbtt "vendor:stb/truetype"

Soft_Font :: struct {
	info: stbtt.fontinfo,
	ok:   bool,
}

soft_regular, soft_bold, soft_symbols: Soft_Font

soft_fonts_init :: proc() {
	if soft_regular.ok {return}
	soft_regular.ok = bool(stbtt.InitFont(&soft_regular.info, raw_data(FONT_INTER_REGULAR), 0))
	soft_bold.ok = bool(stbtt.InitFont(&soft_bold.info, raw_data(FONT_INTER_SEMIBOLD), 0))
	soft_symbols.ok = bool(stbtt.InitFont(&soft_symbols.info, raw_data(FONT_SYMBOLS), 0))
}

// The font that has a glyph for r: f, else the symbol font (icons), else a
// system font fontconfig finds for it (window titles carry arbitrary
// symbols, e.g. ◑), else f.
@(private = "file")
pick :: proc(f: ^Soft_Font, r: rune) -> ^Soft_Font {
	if stbtt.FindGlyphIndex(&f.info, r) != 0 || r < 0x80 {return f}
	if soft_symbols.ok && stbtt.FindGlyphIndex(&soft_symbols.info, r) != 0 {return &soft_symbols}
	if fb := system_fallback(r); fb != nil {return fb}
	return f
}

// ---- fontconfig fallback ----------------------------------------------------------------------

foreign import fontconfig "system:fontconfig"

@(private = "file") Fc_Pattern :: struct {}
@(private = "file") Fc_Char_Set :: struct {}

@(default_calling_convention = "c", private = "file")
foreign fontconfig {
	FcInit :: proc() -> b32 ---
	FcPatternCreate :: proc() -> ^Fc_Pattern ---
	FcPatternDestroy :: proc(p: ^Fc_Pattern) ---
	FcCharSetCreate :: proc() -> ^Fc_Char_Set ---
	FcCharSetDestroy :: proc(cs: ^Fc_Char_Set) ---
	FcCharSetAddChar :: proc(cs: ^Fc_Char_Set, ucs4: u32) -> b32 ---
	FcCharSetHasChar :: proc(cs: ^Fc_Char_Set, ucs4: u32) -> b32 ---
	FcPatternAddCharSet :: proc(p: ^Fc_Pattern, object: cstring, cs: ^Fc_Char_Set) -> b32 ---
	FcPatternAddBool :: proc(p: ^Fc_Pattern, object: cstring, b: b32) -> b32 ---
	FcConfigSubstitute :: proc(config: rawptr, p: ^Fc_Pattern, kind: c.int) -> b32 ---
	FcDefaultSubstitute :: proc(p: ^Fc_Pattern) ---
	FcFontMatch :: proc(config: rawptr, p: ^Fc_Pattern, result: ^c.int) -> ^Fc_Pattern ---
	FcPatternGetString :: proc(p: ^Fc_Pattern, object: cstring, n: c.int, s: ^cstring) -> c.int ---
	FcPatternGetInteger :: proc(p: ^Fc_Pattern, object: cstring, n: c.int, i: ^c.int) -> c.int ---
	FcPatternGetBool :: proc(p: ^Fc_Pattern, object: cstring, n: c.int, b: ^b32) -> c.int ---
	FcPatternGetCharSet :: proc(p: ^Fc_Pattern, object: cstring, n: c.int, cs: ^^Fc_Char_Set) -> c.int ---
}

@(private = "file") fallback_by_rune: map[rune]^Soft_Font // nil: nothing has it
@(private = "file") fallback_by_file: map[string]^Soft_Font
@(private = "file") fc_ready: bool

// A system font with a real outline for r, looked up once per rune. Colour
// (bitmap emoji) fonts are skipped: stb_truetype can't draw them.
@(private = "file")
system_fallback :: proc(r: rune) -> ^Soft_Font {
	if fb, seen := fallback_by_rune[r]; seen {return fb}
	fallback_by_rune[r] = nil
	if !fc_ready {
		if !FcInit() {return nil}
		fc_ready = true
	}
	pat := FcPatternCreate()
	defer FcPatternDestroy(pat)
	cs := FcCharSetCreate()
	FcCharSetAddChar(cs, u32(r))
	FcPatternAddCharSet(pat, "charset", cs)
	FcCharSetDestroy(cs)
	FcPatternAddBool(pat, "color", false)
	FcConfigSubstitute(nil, pat, 0) // FcMatchPattern
	FcDefaultSubstitute(pat)
	res: c.int
	m := FcFontMatch(nil, pat, &res)
	if m == nil {return nil}
	defer FcPatternDestroy(m)

	have: ^Fc_Char_Set
	color: b32
	file: cstring
	index: c.int
	if FcPatternGetCharSet(m, "charset", 0, &have) != 0 || !FcCharSetHasChar(have, u32(r)) {return nil}
	if FcPatternGetBool(m, "color", 0, &color) == 0 && color {return nil}
	if FcPatternGetString(m, "file", 0, &file) != 0 {return nil}
	FcPatternGetInteger(m, "index", 0, &index)

	key := fmt.aprintf("%s#%d", file, index)
	fb, loaded := fallback_by_file[key]
	if loaded {
		delete(key)
	} else {
		fallback_by_file[key] = nil
		if data, err := os.read_entire_file(string(file), context.allocator); err == nil {
			off := stbtt.GetFontOffsetForIndex(raw_data(data), index)
			font := new(Soft_Font)
			if off >= 0 && stbtt.InitFont(&font.info, raw_data(data), off) {
				font.ok = true
				fallback_by_file[key] = font
				fb = font
			} else {
				free(font)
				delete(data)
			}
		}
	}
	if fb != nil && stbtt.FindGlyphIndex(&fb.info, r) == 0 {fb = nil}
	fallback_by_rune[r] = fb
	return fb
}

soft_text_width :: proc(f: ^Soft_Font, px: f32, s: string) -> f32 {
	if !f.ok {return 0}
	w: f32
	prev: rune = -1
	for r in s {
		g := pick(f, r)
		scale := stbtt.ScaleForPixelHeight(&g.info, px)
		adv, lsb: c.int
		stbtt.GetCodepointHMetrics(&g.info, r, &adv, &lsb)
		if prev >= 0 && g == f {w += f32(stbtt.GetCodepointKernAdvance(&f.info, prev, r)) * scale}
		w += f32(adv) * scale
		prev = g == f ? r : -1
	}
	return w
}

// Ascent in pixels (distance from the top of a line to its baseline).
soft_ascent :: proc(f: ^Soft_Font, px: f32) -> f32 {
	scale := stbtt.ScaleForPixelHeight(&f.info, px)
	asc, desc, gap: c.int
	stbtt.GetFontVMetrics(&f.info, &asc, &desc, &gap)
	return f32(asc) * scale
}

// Draw `s` with its baseline at y, blending `rgb` (0xRRGGBB) over the pixels.
soft_draw_text :: proc(pixels: []u32, stride, height: int, f: ^Soft_Font, px: f32, x, baseline: f32, s: string, rgb: u32, alpha: f32 = 1) {
	if !f.ok {return}
	glyph: [256 * 256]u8
	pen := x
	prev: rune = -1
	for r in s {
		g := pick(f, r)
		scale := stbtt.ScaleForPixelHeight(&g.info, px)
		if prev >= 0 && g == f {pen += f32(stbtt.GetCodepointKernAdvance(&f.info, prev, r)) * scale}
		adv, lsb: c.int
		stbtt.GetCodepointHMetrics(&g.info, r, &adv, &lsb)
		x0, y0, x1, y1: c.int
		stbtt.GetCodepointBitmapBox(&g.info, r, scale, scale, &x0, &y0, &x1, &y1)
		gw, gh := int(x1 - x0), int(y1 - y0)
		if gw > 0 && gh > 0 && gw <= 256 && gh <= 256 {
			stbtt.MakeCodepointBitmap(&g.info, &glyph[0], c.int(gw), c.int(gh), c.int(gw), scale, scale, r)
			ox := int(pen + 0.5) + int(x0)
			oy := int(baseline + 0.5) + int(y0)
			for gy in 0 ..< gh {
				py := oy + gy
				if py < 0 || py >= height {continue}
				for gx in 0 ..< gw {
					cov := f32(glyph[gy * gw + gx]) / 255 * alpha
					if cov <= 0 {continue}
					pxi := ox + gx
					if pxi < 0 || pxi >= stride {continue}
					dst := &pixels[py * stride + pxi]
					// Premultiplied "over".
					inv := 1 - cov
					da := f32((dst^ >> 24) & 0xff)
					dr := f32((dst^ >> 16) & 0xff)
					dg := f32((dst^ >> 8) & 0xff)
					db := f32(dst^ & 0xff)
					sr := f32((rgb >> 16) & 0xff) * cov
					sg := f32((rgb >> 8) & 0xff) * cov
					sb := f32(rgb & 0xff) * cov
					na := u32(255 * cov + da * inv + 0.5)
					nr := u32(sr + dr * inv + 0.5)
					ng := u32(sg + dg * inv + 0.5)
					nb := u32(sb + db * inv + 0.5)
					dst^ = na << 24 | nr << 16 | ng << 8 | nb
				}
			}
		}
		pen += f32(adv) * scale
		prev = g == f ? r : -1
	}
}
