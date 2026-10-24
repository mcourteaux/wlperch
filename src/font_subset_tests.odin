// The embedded symbol font is a subset (tools/subset_symbols.py): every icon
// the source uses must be in it, or it would render as nothing.
package main

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:testing"
import stbtt "vendor:stb/truetype"

@(private = "file")
is_icon :: proc(r: rune) -> bool {
	return (r >= 0xE000 && r <= 0xF8FF) || (r >= 0xF0000 && r <= 0x10FFFF)
}

@(test)
test_symbol_font_has_icons :: proc(t: ^testing.T) {
	info: stbtt.fontinfo
	if !testing.expect(t, bool(stbtt.InitFont(&info, raw_data(FONT_SYMBOLS), 0)), "symbol font loads") {return}

	files, _ := filepath.glob("src/*.odin", context.temp_allocator)
	if !testing.expect(t, len(files) > 0, "run from the repository root") {return}
	missing := 0
	for f in files {
		data, err := os.read_entire_file(f, context.temp_allocator)
		if err != nil {continue}
		text := string(data)
		check :: proc(t: ^testing.T, info: ^stbtt.fontinfo, f: string, r: rune, missing: ^int) {
			if !is_icon(r) || stbtt.FindGlyphIndex(info, r) != 0 {return}
			missing^ += 1
			testing.expectf(t, false, "%s: icon U+%X is not in the subset; run python3 tools/subset_symbols.py", f, int(r))
		}
		// Literal private-use characters.
		for r in text {check(t, &info, f, r, &missing)}
		// \uXXXX and \UXXXXXXXX escapes.
		for i := 0; i + 1 < len(text); i += 1 {
			if text[i] != '\\' {continue}
			n := 0
			switch text[i + 1] {
			case 'u': n = 4
			case 'U': n = 8
			case: continue
			}
			if i + 2 + n > len(text) {continue}
			v, ok := strconv.parse_uint(text[i + 2:][:n], 16)
			if ok {check(t, &info, f, rune(v), &missing)}
		}
	}
	testing.expect_value(t, missing, 0)
}
