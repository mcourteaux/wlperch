// Fonts, palette and Dear ImGui style.
package main

import im "third_party:odin-imgui"

FONT_INTER_REGULAR :: #load("../assets/fonts/Inter-Regular.ttf")
FONT_INTER_SEMIBOLD :: #load("../assets/fonts/Inter-SemiBold.ttf")
FONT_MONO :: #load("../assets/fonts/JetBrainsMono-Medium.ttf")
FONT_SYMBOLS :: #load("../assets/fonts/SymbolsNerdFont-Regular.ttf")

Fonts :: struct {
	ui:   ^im.Font,
	bold: ^im.Font,
	mono: ^im.Font,
}
fonts: Fonts

// Font sizes (logical pixels).
SZ_SMALL :: 12.0
SZ_BODY :: 14.0
SZ_TITLE :: 15.5
SZ_BIG :: 26.0
SZ_HUGE :: 36.0

// Palette ------------------------------------------------------------------
rgba :: proc(hex: u32, a: f32 = 1) -> im.Vec4 {
	return {f32((hex >> 16) & 0xff) / 255, f32((hex >> 8) & 0xff) / 255, f32(hex & 0xff) / 255, a}
}

col32 :: proc(hex: u32, a: f32 = 1) -> u32 {
	r := (hex >> 16) & 0xff
	g := (hex >> 8) & 0xff
	b := hex & 0xff
	return r | g << 8 | b << 16 | u32(clamp(a, 0, 1) * 255) << 24
}

// Neutrals follow the theme (theme_set_palette); accents stay.
C_BG: u32 = 0x111318
C_CARD: u32 = 0x1a1d24
C_CARD_HI: u32 = 0x232731
C_BORDER: u32 = 0x2b303b
C_TEXT: u32 = 0xe4e7ee
C_MUTED: u32 = 0x8a92a3
C_FAINT: u32 = 0x5a6172
C_WELL: u32 = 0x12151b     // sunken areas: graphs, bars, segment tracks
C_TRACK: u32 = 0x2a2f3a    // empty part of sliders, switches, meters
C_TRACK_HI: u32 = 0x3d4453
C_OVERLAY: u32 = 0xffffff  // hover tints (with a small alpha)
C_POPUP: u32 = 0x1e222a

Palette :: struct {
	bg, card, card_hi, border, text, muted, faint, well, track, track_hi, overlay, popup: u32,
}

PALETTE_DARK :: Palette{0x111318, 0x1a1d24, 0x232731, 0x2b303b, 0xe4e7ee, 0x8a92a3, 0x5a6172, 0x12151b, 0x2a2f3a, 0x3d4453, 0xffffff, 0x1e222a}
PALETTE_LIGHT :: Palette{0xe8eaf0, 0xffffff, 0xf0f2f6, 0xd6dae2, 0x1b1f28, 0x596173, 0x969cab, 0xf1f3f7, 0xd5d9e1, 0xbfc5d0, 0x000000, 0xffffff}

theme_light: bool

// Switch the neutrals (and the Dear ImGui style when a context exists).
theme_set_palette :: proc(light: bool) {
	theme_light = light
	p := light ? PALETTE_LIGHT : PALETTE_DARK
	C_BG, C_CARD, C_CARD_HI, C_BORDER = p.bg, p.card, p.card_hi, p.border
	C_TEXT, C_MUTED, C_FAINT = p.text, p.muted, p.faint
	C_WELL, C_TRACK, C_TRACK_HI, C_OVERLAY, C_POPUP = p.well, p.track, p.track_hi, p.overlay, p.popup
	if im.GetCurrentContext() != nil {theme_style_colors()}
}

C_BLUE :: 0x7aa2f7
C_CYAN :: 0x7dcfff
C_GREEN :: 0x9ece6a
C_ORANGE :: 0xff9e64
C_YELLOW :: 0xe0af68
C_RED :: 0xf7768e
C_PURPLE :: 0xbb9af7
C_TEAL :: 0x73daca

@(private = "file")
add_font :: proc(atlas: ^im.FontAtlas, data: []u8, size: f32, merge := false, offset_y: f32 = 0) -> ^im.Font {
	cfg: im.FontConfig
	cfg.FontDataOwnedByAtlas = false
	cfg.MergeMode = merge
	cfg.GlyphOffset = {0, offset_y}
	cfg.RasterizerMultiply = 1
	cfg.RasterizerDensity = 1
	cfg.GlyphMaxAdvanceX = max(f32)
	cfg.OversampleH = 0
	cfg.OversampleV = 0
	cfg.ExtraSizeScale = 1
	return im.FontAtlas_AddFontFromMemoryTTF(atlas, raw_data(data), i32(len(data)), size, &cfg)
}

theme_init :: proc() {
	io := im.GetIO()
	atlas := io.Fonts
	fonts.ui = add_font(atlas, FONT_INTER_REGULAR, SZ_BODY)
	add_font(atlas, FONT_SYMBOLS, SZ_BODY, merge = true, offset_y = 1)
	fonts.bold = add_font(atlas, FONT_INTER_SEMIBOLD, SZ_BODY)
	add_font(atlas, FONT_SYMBOLS, SZ_BODY, merge = true, offset_y = 1)
	fonts.mono = add_font(atlas, FONT_MONO, SZ_BODY)
	add_font(atlas, FONT_SYMBOLS, SZ_BODY, merge = true, offset_y = 1)

	s := im.GetStyle()
	s.WindowPadding = {14, 14}
	s.FramePadding = {10, 6}
	s.ItemSpacing = {8, 8}
	s.ItemInnerSpacing = {6, 6}
	s.WindowRounding = 14
	s.ChildRounding = 10
	s.FrameRounding = 8
	s.PopupRounding = 10
	s.GrabRounding = 8
	s.ScrollbarRounding = 8
	s.ScrollbarSize = 8
	s.GrabMinSize = 12
	s.WindowBorderSize = 0
	s.ChildBorderSize = 1
	s.PopupBorderSize = 1
	s.FrameBorderSize = 0
	s.SelectableTextAlign = {0, 0.5}
	s.AntiAliasedLines = true
	s.AntiAliasedFill = true

	theme_style_colors()
}

theme_style_colors :: proc() {
	c := &im.GetStyle().Colors
	c[im.Col.Text] = rgba(C_TEXT)
	c[im.Col.TextDisabled] = rgba(C_MUTED)
	c[im.Col.WindowBg] = rgba(C_BG, 0)
	c[im.Col.ChildBg] = rgba(C_CARD)
	c[im.Col.PopupBg] = rgba(C_POPUP, 0.98)
	c[im.Col.Border] = rgba(C_BORDER)
	c[im.Col.BorderShadow] = rgba(0, 0)
	c[im.Col.FrameBg] = rgba(C_CARD_HI)
	c[im.Col.FrameBgHovered] = rgba(C_TRACK)
	c[im.Col.FrameBgActive] = rgba(C_TRACK_HI)
	c[im.Col.ScrollbarBg] = rgba(0, 0)
	c[im.Col.ScrollbarGrab] = rgba(C_BORDER)
	c[im.Col.ScrollbarGrabHovered] = rgba(C_TRACK_HI)
	c[im.Col.ScrollbarGrabActive] = rgba(C_BLUE)
	c[im.Col.CheckMark] = rgba(C_BLUE)
	c[im.Col.SliderGrab] = rgba(C_BLUE)
	c[im.Col.SliderGrabActive] = rgba(0x9bbcff)
	c[im.Col.Button] = rgba(C_CARD_HI)
	c[im.Col.ButtonHovered] = rgba(C_TRACK)
	c[im.Col.ButtonActive] = rgba(C_TRACK_HI)
	c[im.Col.Header] = rgba(C_BLUE, 0.18)
	c[im.Col.HeaderHovered] = rgba(C_OVERLAY, 0.06)
	c[im.Col.HeaderActive] = rgba(C_BLUE, 0.28)
	c[im.Col.Separator] = rgba(C_BORDER)
	c[im.Col.NavCursor] = rgba(C_BLUE, 0.8)
	c[im.Col.TextSelectedBg] = rgba(C_BLUE, 0.35)
	c[im.Col.ModalWindowDimBg] = rgba(0, 0.3)
}
