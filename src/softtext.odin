// Software text rendering into ARGB8888 (premultiplied) pixel buffers, for
// surfaces that don't use the GL renderer (placeholder windows, notification
// popups, the bar). Glyphs missing from Inter come from the symbol font, then
// from a system font fontconfig picks.
package main

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:sync"
import stbtt "vendor:stb/truetype"

Soft_Font :: struct {
	info:        stbtt.fontinfo,
	ok:          bool,
	data:        []u8,
	scale1:      f32, // font units -> pixels at 1px
	kern:        [][]int, // GPOS 'kern' PairPos subtables, per lookup
	kern_legacy: bool, // no GPOS kerning: stb reads the 'kern' table
	digit:       [10]c.int, // tabular ('tnum') glyphs for 0-9
	digit_cell:  c.int, // no tnum glyphs: digits centred in cells this wide
	// ' '..'~', then the tabular digits: glyph, advance, kerning between them.
	slot_glyph:  [ASCII_SLOTS]c.int,
	slot_adv:    [ASCII_SLOTS]c.int,
	kern_cache:  []i16,
}

@(private = "file") ASCII_SLOTS :: 95 + 10
@(private = "file") KERN_UNKNOWN :: max(i16)

soft_regular, soft_bold, soft_symbols: Soft_Font

soft_fonts_init :: proc() {
	if soft_regular.ok {return}
	soft_font_init(&soft_regular, FONT_INTER_REGULAR)
	soft_font_init(&soft_bold, FONT_INTER_SEMIBOLD)
	soft_font_init(&soft_symbols, FONT_SYMBOLS)
}

// The font that has a glyph for r: f, else the symbol font (icons), else a
// system font fontconfig finds for it (window titles carry arbitrary
// symbols, e.g. ◑), else f.
@(private = "file")
pick :: proc(f: ^Soft_Font, r: rune) -> ^Soft_Font {
	if r < 0x80 || stbtt.FindGlyphIndex(&f.info, r) != 0 {return f}
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
@(private = "file") fallback_mu: sync.Mutex // the lock screen draws its outputs in parallel

// A system font with a real outline for r, looked up once per rune. Colour
// (bitmap emoji) fonts are skipped: stb_truetype can't draw them.
@(private = "file")
system_fallback :: proc(r: rune) -> ^Soft_Font {
	sync.guard(&fallback_mu)
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
			if off >= 0 && soft_font_init(font, data, off) {
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


// ---- OpenType: GPOS pair kerning, GSUB tabular figures -----------------------------------------
//
// stb_truetype's own GPOS reader skips Extension lookups (type 9) and stops
// at the first lookup that covers a glyph; Inter keeps most of its kerning in
// an Extension lookup, so stb found 142 of Inter's 1048 kerned ASCII pairs
// (no "AV", "To", "Ty"...). This reads the 'kern' feature's PairPos lookups
// (format 1 and 2, any value format) itself, the way a shaper applies them:
// every lookup in order, the first subtable that matches each, values summed.

@(private = "file")
be16 :: #force_inline proc(d: []u8, o: int) -> int {
	if o < 0 || o + 2 > len(d) {return 0}
	return int(d[o]) << 8 | int(d[o + 1])
}

@(private = "file")
bes16 :: #force_inline proc(d: []u8, o: int) -> int {return int(i16(u16(be16(d, o))))}

@(private = "file")
be32 :: proc(d: []u8, o: int) -> int {return be16(d, o) << 16 | be16(d, o + 2)}

// Offset of table `tag` in the font starting at `start`, or 0.
@(private = "file")
find_table :: proc(d: []u8, start: int, tag: string) -> int {
	n := be16(d, start + 4)
	for i in 0 ..< n {
		rec := start + 12 + 16 * i
		if rec + 16 > len(d) {break}
		if string(d[rec:rec + 4]) == tag {return be32(d, rec + 8)}
	}
	return 0
}

// Coverage index of glyph g, or -1.
@(private = "file")
coverage :: proc(d: []u8, cov: int, g: int) -> int {
	switch be16(d, cov) {
	case 1:
		lo, hi := 0, be16(d, cov + 2) - 1
		for lo <= hi {
			m := (lo + hi) / 2
			v := be16(d, cov + 4 + 2 * m)
			if g < v {hi = m - 1} else if g > v {lo = m + 1} else {return m}
		}
	case 2:
		lo, hi := 0, be16(d, cov + 2) - 1
		for lo <= hi {
			m := (lo + hi) / 2
			r := cov + 4 + 6 * m
			if g < be16(d, r) {hi = m - 1} else if g > be16(d, r + 2) {lo = m + 1} else {return be16(d, r + 4) + g - be16(d, r)}
		}
	}
	return -1
}

@(private = "file")
class_of :: proc(d: []u8, cd: int, g: int) -> int {
	switch be16(d, cd) {
	case 1:
		first := be16(d, cd + 2)
		if g >= first && g < first + be16(d, cd + 4) {return be16(d, cd + 6 + 2 * (g - first))}
	case 2:
		lo, hi := 0, be16(d, cd + 2) - 1
		for lo <= hi {
			m := (lo + hi) / 2
			r := cd + 4 + 6 * m
			if g < be16(d, r) {hi = m - 1} else if g > be16(d, r + 2) {lo = m + 1} else {return be16(d, r + 4)}
		}
	}
	return 0
}

// The subtables (absolute offsets) of the lookups behind feature `tag` in a
// GPOS/GSUB table at `base`, per lookup in lookup order, keeping those of
// type `want` (looking through Extension lookups, type `ext`).
@(private = "file")
feature_subtables :: proc(d: []u8, base: int, tag: string, want, ext: int) -> [][]int {
	if base == 0 || be16(d, base) != 1 {return nil}
	features, lookups := base + be16(d, base + 6), base + be16(d, base + 8)
	used := make([]bool, be16(d, lookups), context.temp_allocator)
	for i in 0 ..< be16(d, features) {
		rec := features + 2 + 6 * i
		if rec + 6 > len(d) || string(d[rec:rec + 4]) != tag {continue}
		ft := features + be16(d, rec + 4)
		for k in 0 ..< be16(d, ft + 2) {
			li := be16(d, ft + 4 + 2 * k)
			if li < len(used) {used[li] = true}
		}
	}
	out := make([dynamic][]int, runtime.heap_allocator())
	for li in 0 ..< len(used) {
		if !used[li] {continue}
		lt := lookups + be16(d, lookups + 2 + 2 * li)
		kind := be16(d, lt)
		subs := make([dynamic]int, runtime.heap_allocator())
		for k in 0 ..< be16(d, lt + 4) {
			st := lt + be16(d, lt + 6 + 2 * k)
			if kind == ext && be16(d, st) == 1 && be16(d, st + 2) == want {
				append(&subs, st + be32(d, st + 4))
			} else if kind == want {
				append(&subs, st)
			}
		}
		if len(subs) > 0 {append(&out, subs[:])} else {delete(subs)}
	}
	return out[:]
}

// Bytes of a ValueRecord, and where XAdvance sits in it (-1: absent).
@(private = "file")
value_layout :: proc(vf: int) -> (size, x_adv: int) {
	for b in 0 ..< 8 {if vf & (1 << uint(b)) != 0 {size += 2}}
	x_adv = -1
	if vf & 4 != 0 {x_adv = (vf & 1 != 0 ? 2 : 0) + (vf & 2 != 0 ? 2 : 0)}
	return
}

// The pair's XAdvance in this subtable; ok = the subtable applies to it.
@(private = "file")
pair_pos :: proc(d: []u8, st: int, g1, g2: int) -> (adv: int, ok: bool) {
	ci := coverage(d, st + be16(d, st + 2), g1)
	if ci < 0 {return}
	size1, x1 := value_layout(be16(d, st + 4))
	size2, _ := value_layout(be16(d, st + 6))
	switch be16(d, st) {
	case 1:
		if ci >= be16(d, st + 8) {return}
		set := st + be16(d, st + 10 + 2 * ci)
		rec := 2 + size1 + size2
		lo, hi := 0, be16(d, set) - 1
		for lo <= hi {
			m := (lo + hi) / 2
			r := set + 2 + rec * m
			v := be16(d, r)
			if g2 < v {hi = m - 1} else if g2 > v {lo = m + 1} else {
				return x1 >= 0 ? bes16(d, r + 2 + x1) : 0, true
			}
		}
	case 2:
		c1 := class_of(d, st + be16(d, st + 8), g1)
		c2 := class_of(d, st + be16(d, st + 10), g2)
		n1, n2 := be16(d, st + 12), be16(d, st + 14)
		if c1 >= n1 || c2 >= n2 {return}
		if x1 < 0 {return 0, true}
		return bes16(d, st + 16 + (c1 * n2 + c2) * (size1 + size2) + x1), true
	}
	return
}

// Kerning between two glyphs of f, in font units.
@(private = "file")
kern :: proc(f: ^Soft_Font, g1, g2: c.int) -> int {
	adv := 0
	for subs in f.kern {
		for st in subs {
			if a, ok := pair_pos(f.data, st, int(g1), int(g2)); ok {adv += a; break}
		}
	}
	return adv
}

// The 'tnum' (tabular figures) substitute of glyph g, or g.
@(private = "file")
single_subst :: proc(d: []u8, lookups: [][]int, g: int) -> int {
	for subs in lookups {
		for st in subs {
			ci := coverage(d, st + be16(d, st + 2), g)
			if ci < 0 {continue}
			switch be16(d, st) {
			case 1: return (g + bes16(d, st + 4)) & 0xffff
			case 2: if ci < be16(d, st + 4) {return be16(d, st + 6 + 2 * ci)}
			}
		}
	}
	return g
}

// ---- Fonts -------------------------------------------------------------------------------------

// Set up f for the font at `start` in data (which must outlive it).
soft_font_init :: proc(f: ^Soft_Font, data: []u8, start: c.int = 0) -> bool {
	f.ok = bool(stbtt.InitFont(&f.info, raw_data(data), start))
	if !f.ok {return false}
	f.data = data
	f.scale1 = stbtt.ScaleForPixelHeight(&f.info, 1)
	f.kern = feature_subtables(data, find_table(data, int(start), "GPOS"), "kern", 2, 9)
	if len(f.kern) == 0 && f.info.kern != 0 {f.kern_legacy = true}
	tnum := feature_subtables(data, find_table(data, int(start), "GSUB"), "tnum", 1, 7)
	defer {for s in tnum {delete(s, runtime.heap_allocator())}; delete(tnum, runtime.heap_allocator())}
	widest: c.int
	for d in 0 ..< 10 {
		g := stbtt.FindGlyphIndex(&f.info, rune('0' + d))
		f.digit[d] = c.int(single_subst(data, tnum, int(g)))
		adv, lsb: c.int
		stbtt.GetGlyphHMetrics(&f.info, g, &adv, &lsb)
		widest = max(widest, adv)
	}
	// No tabular glyphs: centre the digits in cells as wide as the widest.
	all_tabular := true
	for d in 0 ..< 10 {if f.digit[d] == stbtt.FindGlyphIndex(&f.info, rune('0' + d)) {all_tabular = false}}
	f.digit_cell = all_tabular ? 0 : widest
	for i in 0 ..< ASCII_SLOTS {
		f.slot_glyph[i] = i < 95 ? stbtt.FindGlyphIndex(&f.info, rune(' ' + i)) : f.digit[i - 95]
		lsb: c.int
		stbtt.GetGlyphHMetrics(&f.info, f.slot_glyph[i], &f.slot_adv[i], &lsb)
	}
	if len(f.kern) > 0 {
		f.kern_cache = make([]i16, ASCII_SLOTS * ASCII_SLOTS, runtime.heap_allocator())
		for &k in f.kern_cache {k = KERN_UNKNOWN}
	}
	return true
}

// One positioned glyph of a line of text.
@(private = "file")
Placed :: struct {
	font:  ^Soft_Font,
	glyph: c.int,
	x:     f32, // where the glyph's origin goes, in pixels
}

// Walks s glyph by glyph: fonts picked, kerned, digits tabular when asked.
@(private = "file")
Layout :: struct {
	f:         ^Soft_Font,
	px:        f32,
	tnum:      bool,
	pen:       f32,
	prev:      c.int, // previous glyph (-1: none, or it doesn't kern)
	prev_slot: int,
	prev_f:    ^Soft_Font,
}

// Kerning between glyphs a and b of f (sa, sb: their ASCII slots, or -1).
@(private = "file")
pair_kern :: proc(f: ^Soft_Font, a, b: c.int, sa, sb: int) -> int {
	if f.kern_legacy {return int(stbtt.GetGlyphKernAdvance(&f.info, a, b))}
	if len(f.kern) == 0 {return 0}
	if sa < 0 || sb < 0 {return kern(f, a, b)}
	// Text is mostly ASCII: those pairs are looked up once. (The lock
	// screen's threads may race on a slot; they all store the same value.)
	slot := &f.kern_cache[sa * ASCII_SLOTS + sb]
	k := intrinsics.atomic_load_explicit(slot, .Relaxed)
	if k == KERN_UNKNOWN {
		k = i16(kern(f, a, b))
		intrinsics.atomic_store_explicit(slot, k, .Relaxed)
	}
	return int(k)
}

@(private = "file")
next_glyph :: proc(l: ^Layout, r: rune) -> Placed {
	g := pick(l.f, r)
	scale := l.px * g.scale1
	digit := l.tnum && g == l.f && r >= '0' && r <= '9'
	gi, adv: c.int
	slot := -1
	offset: f32
	if digit && g.digit_cell > 0 {
		// No tabular glyphs: centred in a cell, not kerned.
		slot = int(r - ' ')
		gi, adv = g.slot_glyph[slot], g.slot_adv[slot]
		offset = f32(g.digit_cell - adv) / 2 * scale
		adv = g.digit_cell
	} else {
		if digit {
			slot = 95 + int(r - '0')
		} else if r >= ' ' && r <= '~' {
			slot = int(r - ' ')
		}
		if slot >= 0 {
			gi, adv = g.slot_glyph[slot], g.slot_adv[slot]
		} else {
			gi = stbtt.FindGlyphIndex(&g.info, r)
			lsb: c.int
			stbtt.GetGlyphHMetrics(&g.info, gi, &adv, &lsb)
		}
		if g == l.prev_f && l.prev >= 0 {l.pen += f32(pair_kern(g, l.prev, gi, l.prev_slot, slot)) * scale}
	}
	p := Placed{g, gi, l.pen + offset}
	l.pen += f32(adv) * scale
	l.prev, l.prev_slot, l.prev_f = (digit && g.digit_cell > 0) ? -1 : gi, slot, g
	return p
}

// Width of s in pixels. tnum: digits get equal (tabular) advances, so a
// changing number doesn't shift what follows it.
soft_text_width :: proc(f: ^Soft_Font, px: f32, s: string, tnum := false) -> f32 {
	if !f.ok {return 0}
	l := Layout{f = f, px = px, tnum = tnum, prev = -1}
	for r in s {next_glyph(&l, r)}
	return l.pen
}

// Ascent in pixels (distance from the top of a line to its baseline).
soft_ascent :: proc(f: ^Soft_Font, px: f32) -> f32 {
	asc, desc, gap: c.int
	stbtt.GetFontVMetrics(&f.info, &asc, &desc, &gap)
	return f32(asc) * px * f.scale1
}

// ---- Glyph cache -------------------------------------------------------------------------------
//
// Glyphs are drawn at their exact horizontal position, in quarter pixels (the
// baseline stays on whole pixels). Each (font, size, glyph, quarter) is
// rasterised once and kept here; the whole cache is dropped past a few MB.

@(private = "file") SUBPIXELS :: 4
@(private = "file") CACHE_BYTES :: 4 << 20

@(private = "file")
Glyph_Key :: struct {
	font:  ^Soft_Font,
	px:    f32,
	glyph: c.int,
	sub:   u8,
}

@(private = "file")
Glyph_Bitmap :: struct {
	x0, y0, w, h: int,
	cov:          []u8,
}

@(private = "file") glyph_cache: map[Glyph_Key]Glyph_Bitmap
@(private = "file") glyph_cache_bytes: int
@(private = "file") glyph_mu: sync.Mutex // the lock screen draws on several threads

// The bitmap for a key; call with glyph_mu held.
@(private = "file")
cached_glyph :: proc(key: Glyph_Key) -> Glyph_Bitmap {
	if bm, ok := glyph_cache[key]; ok {return bm}
	heap := runtime.heap_allocator()
	if glyph_cache == nil {glyph_cache = make(map[Glyph_Key]Glyph_Bitmap, 256, heap)}
	if glyph_cache_bytes > CACHE_BYTES {
		for _, bm in glyph_cache {delete(bm.cov, heap)}
		clear(&glyph_cache)
		glyph_cache_bytes = 0
	}
	f := key.font
	scale := key.px * f.scale1
	shift := f32(key.sub) / SUBPIXELS
	x0, y0, x1, y1: c.int
	stbtt.GetGlyphBitmapBoxSubpixel(&f.info, key.glyph, scale, scale, shift, 0, &x0, &y0, &x1, &y1)
	bm := Glyph_Bitmap{x0 = int(x0), y0 = int(y0), w = int(x1 - x0), h = int(y1 - y0)}
	if bm.w > 0 && bm.h > 0 && bm.w <= 2048 && bm.h <= 2048 {
		bm.cov = make([]u8, bm.w * bm.h, heap)
		stbtt.MakeGlyphBitmapSubpixel(&f.info, raw_data(bm.cov), c.int(bm.w), c.int(bm.h), c.int(bm.w), scale, scale, shift, 0, key.glyph)
	} else {
		bm.w, bm.h = 0, 0
	}
	glyph_cache[key] = bm
	glyph_cache_bytes += len(bm.cov) + size_of(Glyph_Key) + size_of(Glyph_Bitmap)
	return bm
}

// Draw `s` with its baseline at y, blending `rgb` (0xRRGGBB) over the pixels.
// tnum: tabular digits (see soft_text_width).
soft_draw_text :: proc(pixels: []u32, stride, height: int, f: ^Soft_Font, px, x, baseline: f32, s: string, rgb: u32, alpha: f32 = 1, tnum := false) {
	if !f.ok || alpha <= 0 {return}
	l := Layout{f = f, px = px, tnum = tnum, pen = x, prev = -1}
	oy0 := int(math.floor(baseline + 0.5))
	sr, sg, sb := f32((rgb >> 16) & 0xff), f32((rgb >> 8) & 0xff), f32(rgb & 0xff)
	for r in s {
		p := next_glyph(&l, r)
		// Quarter-pixel position: whole pixels + a subpixel shift.
		q := int(math.floor(p.x * SUBPIXELS + 0.5))
		ix, sub := q >> 2, u8(q & (SUBPIXELS - 1))
		sync.guard(&glyph_mu)
		bm := cached_glyph({p.font, px, p.glyph, sub})
		if bm.w == 0 {continue}
		ox, oy := ix + bm.x0, oy0 + bm.y0
		gx0, gx1 := max(0, -ox), min(bm.w, stride - ox)
		for gy in max(0, -oy) ..< min(bm.h, height - oy) {
			row := (oy + gy) * stride + ox
			src := gy * bm.w
			for gx in gx0 ..< gx1 {
				if bm.cov[src + gx] == 0 {continue}
				cov := f32(bm.cov[src + gx]) / 255 * alpha
				dst := &pixels[row + gx]
				// Premultiplied "over".
				inv := 1 - cov
				da := f32((dst^ >> 24) & 0xff)
				dr := f32((dst^ >> 16) & 0xff)
				dg := f32((dst^ >> 8) & 0xff)
				db := f32(dst^ & 0xff)
				na := u32(255 * cov + da * inv + 0.5)
				nr := u32(sr * cov + dr * inv + 0.5)
				ng := u32(sg * cov + dg * inv + 0.5)
				nb := u32(sb * cov + db * inv + 0.5)
				dst^ = na << 24 | nr << 16 | ng << 8 | nb
			}
		}
	}
}
