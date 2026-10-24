// Notification icons: resolved once when a notification arrives, from raw
// image-data, a file (PNG/JPEG via stb_image, SVG via librsvg when present)
// or an icon-theme name, then scaled to a small premultiplied ARGB thumbnail
// shared by the popups (software) and the notification center (GL texture).
package main

import "core:c"
import "core:dynlib"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import stbi "vendor:stb/image"

ICON_PX :: 64

Notif_Icon :: struct {
	key:     u64,   // content hash; identical icons are shared
	size:    i32,   // square, ICON_PX
	px:      []u32, // premultiplied ARGB8888
	rounded: bool,  // a picture (avatar, photo): drawn with rounded corners
	tex:     u32,   // GL texture in the popup (0 = not uploaded)
	symbolic: bool, // a theme glyph tinted with the text colour (retinted per theme)
	stale:   bool,  // pixels changed since tex was uploaded
}

icon_cache: map[u64]^Notif_Icon

// Intern pixels: returns the shared icon with the same content.
@(private = "file")
icon_intern :: proc(px: []u32, rounded: bool, symbolic := false) -> ^Notif_Icon {
	key := hash.fnv64a(([^]u8)(raw_data(px))[:len(px) * 4])
	if rounded {key ~= 0x9e3779b97f4a7c15}
	if ic, ok := icon_cache[key]; ok {
		delete(px)
		return ic
	}
	ic := new(Notif_Icon)
	ic^ = {key = key, size = ICON_PX, px = px, rounded = rounded, symbolic = symbolic}
	icon_cache[key] = ic
	return ic
}

// The theme changed: symbolic glyphs take the new text colour.
icons_retint :: proc() {
	for _, ic in icon_cache {
		if !ic.symbolic {continue}
		tint(ic.px, C_TEXT)
		ic.stale = true
	}
}

icon_from_pixels :: proc(key: u64, px: []u32, rounded: bool) -> ^Notif_Icon {
	if ic, ok := icon_cache[key]; ok {
		delete(px)
		return ic
	}
	ic := new(Notif_Icon)
	ic^ = {key = key, size = ICON_PX, px = px, rounded = rounded}
	icon_cache[key] = ic
	return ic
}

// Scale straight-alpha RGBA (any size) to a premultiplied ICON_PX square,
// fitting and centering it.
@(private = "file")
thumbnail :: proc(rgba: []u8, w, h, stride, channels: int) -> []u32 {
	out := make([]u32, ICON_PX * ICON_PX)
	if w <= 0 || h <= 0 {return out}
	scale := f32(ICON_PX) / f32(max(w, h))
	tw, th := max(int(f32(w) * scale + 0.5), 1), max(int(f32(h) * scale + 0.5), 1)
	ox, oy := (ICON_PX - tw) / 2, (ICON_PX - th) / 2
	for y in 0 ..< th {
		for x in 0 ..< tw {
			// Area average over the source footprint (box filter; also fine upscaling).
			sx0 := f32(x) / scale
			sy0 := f32(y) / scale
			sx1 := max(f32(x + 1) / scale, sx0 + 1)
			sy1 := max(f32(y + 1) / scale, sy0 + 1)
			r, g, b, a, n: f32
			for sy := int(sy0); sy < int(sy1) && sy < h; sy += 1 {
				for sx := int(sx0); sx < int(sx1) && sx < w; sx += 1 {
					p := rgba[sy * stride + sx * channels:]
					pa := channels == 4 ? f32(p[3]) / 255 : 1
					r += f32(p[0]) * pa
					g += f32(p[1]) * pa
					b += f32(p[2]) * pa
					a += pa
					n += 1
				}
			}
			if n == 0 {continue}
			out[(oy + y) * ICON_PX + ox + x] = u32(a / n * 255 + 0.5) << 24 | u32(r / n + 0.5) << 16 | u32(g / n + 0.5) << 8 | u32(b / n + 0.5)
		}
	}
	return out
}

// The image-data hint: (iiibiiay) width, height, rowstride, has_alpha, bits, channels, data.
icon_from_image_data :: proc(w, h, stride: i32, has_alpha: bool, channels: i32, data: []u8) -> ^Notif_Icon {
	if w <= 0 || h <= 0 || (channels != 3 && channels != 4) || int(stride) * int(h - 1) + int(w * channels) > len(data) {return nil}
	return icon_intern(thumbnail(data, int(w), int(h), int(stride), int(channels)), true)
}

// An encoded image (PNG/JPEG bytes), e.g. a dbusmenu icon-data.
icon_from_encoded :: proc(data: []u8) -> ^Notif_Icon {
	px := decode_raster(data)
	return px == nil ? nil : icon_intern(px, false)
}

// ---- Files --------------------------------------------------------------------

@(private = "file")
load_raster :: proc(path: string) -> []u32 {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return nil}
	return decode_raster(data)
}

@(private = "file")
decode_raster :: proc(data: []u8) -> []u32 {
	if len(data) == 0 {return nil}
	w, h, n: c.int
	px := stbi.load_from_memory(raw_data(data), c.int(len(data)), &w, &h, &n, 4)
	if px == nil {return nil}
	defer stbi.image_free(px)
	return thumbnail(px[:w * h * 4], int(w), int(h), int(w) * 4, 4)
}

// librsvg + cairo, loaded on first use (optional).
@(private = "file")
Rsvg :: struct {
	tried, ok:       bool,
	new_from_file:   proc "c" (path: cstring, err: ^rawptr) -> rawptr,
	render_document: proc "c" (h: rawptr, cr: rawptr, viewport: ^[4]f64, err: ^rawptr) -> b32,
	surface_create:  proc "c" (format: c.int, w, h: c.int) -> rawptr,
	cairo_create:    proc "c" (surface: rawptr) -> rawptr,
	cairo_destroy:   proc "c" (cr: rawptr),
	surface_flush:   proc "c" (surface: rawptr),
	surface_data:    proc "c" (surface: rawptr) -> [^]u8,
	surface_stride:  proc "c" (surface: rawptr) -> c.int,
	surface_destroy: proc "c" (surface: rawptr),
	object_unref:    proc "c" (obj: rawptr),
}
@(private = "file") rsvg: Rsvg

@(private = "file")
rsvg_load :: proc() -> bool {
	if rsvg.tried {return rsvg.ok}
	rsvg.tried = true
	lib, ok := dynlib.load_library("librsvg-2.so.2")
	if !ok {return false}
	cairo, cok := dynlib.load_library("libcairo.so.2")
	gobj, gok := dynlib.load_library("libgobject-2.0.so.0")
	if !cok || !gok {return false}
	sym :: proc(l: dynlib.Library, name: string) -> rawptr {p, _ := dynlib.symbol_address(l, name); return p}
	rsvg.new_from_file = auto_cast sym(lib, "rsvg_handle_new_from_file")
	rsvg.render_document = auto_cast sym(lib, "rsvg_handle_render_document")
	rsvg.surface_create = auto_cast sym(cairo, "cairo_image_surface_create")
	rsvg.cairo_create = auto_cast sym(cairo, "cairo_create")
	rsvg.cairo_destroy = auto_cast sym(cairo, "cairo_destroy")
	rsvg.surface_flush = auto_cast sym(cairo, "cairo_surface_flush")
	rsvg.surface_data = auto_cast sym(cairo, "cairo_image_surface_get_data")
	rsvg.surface_stride = auto_cast sym(cairo, "cairo_image_surface_get_stride")
	rsvg.surface_destroy = auto_cast sym(cairo, "cairo_surface_destroy")
	rsvg.object_unref = auto_cast sym(gobj, "g_object_unref")
	rsvg.ok = rsvg.new_from_file != nil && rsvg.render_document != nil && rsvg.surface_create != nil && rsvg.cairo_create != nil &&
		rsvg.surface_data != nil && rsvg.surface_stride != nil && rsvg.surface_destroy != nil && rsvg.object_unref != nil
	return rsvg.ok
}

@(private = "file")
load_svg :: proc(path: string) -> []u32 {
	if !rsvg_load() {return nil}
	err: rawptr
	h := rsvg.new_from_file(strings.clone_to_cstring(path, context.temp_allocator), &err)
	if h == nil {return nil}
	defer rsvg.object_unref(h)
	surf := rsvg.surface_create(0, ICON_PX, ICON_PX) // CAIRO_FORMAT_ARGB32: premultiplied, like wl ARGB8888
	defer rsvg.surface_destroy(surf)
	cr := rsvg.cairo_create(surf)
	vp := [4]f64{0, 0, ICON_PX, ICON_PX}
	ok := rsvg.render_document(h, cr, &vp, &err)
	rsvg.cairo_destroy(cr)
	if !ok {return nil}
	rsvg.surface_flush(surf)
	data := rsvg.surface_data(surf)
	stride := int(rsvg.surface_stride(surf))
	out := make([]u32, ICON_PX * ICON_PX)
	for y in 0 ..< ICON_PX {
		row := ([^]u32)(&data[y * stride])
		for x in 0 ..< ICON_PX {out[y * ICON_PX + x] = row[x]}
	}
	return out
}

@(private = "file")
load_file :: proc(path: string) -> []u32 {
	if strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".svg") {return load_svg(path)}
	return load_raster(path)
}

// ---- Icon themes ----------------------------------------------------------------
// One scan of the theme directories builds name -> best file. Preference: SVG,
// then the PNG closest to ICON_PX (larger first).

@(private = "file") theme_index: map[string]string
@(private = "file") theme_indexed: bool

@(private = "file")
size_score :: proc(path: string) -> int {
	if strings.has_suffix(path, ".svg") {return strings.contains(path, "symbolic") ? 500 : 1000}
	// Directory names like 48x48, 64x64@2, apps/48.
	best := 0
	for part in strings.split(path, "/", context.temp_allocator) {
		n := 0
		for ch in part {
			if ch < '0' || ch > '9' {break}
			n = n * 10 + int(ch - '0')
		}
		if n > 0 {best = n}
	}
	if best == 0 {return 100}
	if best >= ICON_PX {return 900 - (best - ICON_PX)}
	return 400 + best
}

@(private = "file")
index_dir :: proc(dir: string, depth: int) {
	f, err := os.open(dir)
	if err != nil {return}
	entries, _ := os.read_all_directory(f, context.temp_allocator)
	os.close(f)
	for e in entries {
		full := strings.concatenate({dir, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			if depth > 0 {index_dir(full, depth - 1)}
			continue
		}
		ext := filepath.ext(e.name)
		if ext != ".png" && ext != ".svg" {continue}
		name := e.name[:len(e.name) - len(ext)]
		if old, ok := theme_index[name]; ok {
			if size_score(old) >= size_score(full) {continue}
			delete(old)
			theme_index[name] = strings.clone(full)
		} else {
			theme_index[strings.clone(name)] = strings.clone(full)
		}
	}
}

@(private = "file")
icon_theme_name :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	for p in ([]string{"/.config/gtk-3.0/settings.ini", "/.config/gtk-4.0/settings.ini"}) {
		data, err := os.read_entire_file(strings.concatenate({home, p}, context.temp_allocator), context.temp_allocator)
		if err != nil {continue}
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			kv := strings.split_n(line, "=", 2, context.temp_allocator)
			if len(kv) == 2 && strings.trim_space(kv[0]) == "gtk-icon-theme-name" {return strings.trim_space(kv[1])}
		}
	}
	return "Adwaita"
}

@(private = "file")
build_theme_index :: proc() {
	theme_indexed = true
	dirs: [dynamic]string
	dirs.allocator = context.temp_allocator
	home := os.get_env("HOME", context.temp_allocator)
	append(&dirs, strings.concatenate({home, "/.local/share"}, context.temp_allocator))
	xdg := os.get_env("XDG_DATA_DIRS", context.temp_allocator)
	if xdg == "" {xdg = "/usr/local/share:/usr/share"}
	for d in strings.split(xdg, ":", context.temp_allocator) {if d != "" {append(&dirs, d)}}
	// Lowest priority first: later themes overwrite only with a better size,
	// so index the preferred theme last with a clean slate per name.
	themes := []string{"hicolor", "Adwaita", icon_theme_name()}
	for d in dirs {index_dir(strings.concatenate({d, "/pixmaps"}, context.temp_allocator), 0)}
	for theme in themes {
		for d in dirs {index_dir(strings.concatenate({d, "/icons/", theme}, context.temp_allocator), 3)}
	}
}

@(private = "file")
desktop_icon :: proc(entry: string) -> string {
	if entry == "" {return ""}
	xdg := os.get_env("XDG_DATA_DIRS", context.temp_allocator)
	if xdg == "" {xdg = "/usr/local/share:/usr/share"}
	dirs := strings.split(strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.local/share:", xdg}, context.temp_allocator), ":", context.temp_allocator)
	for d in dirs {
		data, err := os.read_entire_file(strings.concatenate({d, "/applications/", entry, ".desktop"}, context.temp_allocator), context.temp_allocator)
		if err != nil {continue}
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			if strings.has_prefix(line, "Icon=") {return strings.trim_space(line[5:])}
		}
	}
	return ""
}

// Resolve an icon from what the app sent: a path, file:// URI or theme name,
// falling back to the desktop entry's icon and the app name.
icon_resolve :: proc(candidates: ..string) -> ^Notif_Icon {
	try_one :: proc(s: string) -> (px: []u32, symbolic: bool) {
		s := strings.trim_prefix(s, "file://")
		if s == "" {return}
		if strings.has_prefix(s, "/") {return load_file(s), false}
		if !theme_indexed {build_theme_index()}
		for name in ([]string{s, strings.to_lower(s, context.temp_allocator), strings.concatenate({s, "-symbolic"}, context.temp_allocator)}) {
			path, ok := theme_index[name]
			if !ok {continue}
			px = load_file(path)
			// Symbolic icons are dark glyphs meant to be recolored: in the text colour.
			if px != nil && strings.contains(path, "symbolic") {
				tint(px, C_TEXT)
				symbolic = true
			}
			return
		}
		return
	}
	for cand in candidates {
		if px, sym := try_one(cand); px != nil {return icon_intern(px, strings.has_prefix(cand, "/") || strings.has_prefix(cand, "file://"), sym)}
	}
	return nil
}

icon_resolve_desktop :: proc(entry: string) -> ^Notif_Icon {
	if name := desktop_icon(entry); name != "" {return icon_resolve(name)}
	return nil
}

// Recolor to rgb, keeping the alpha (premultiplied).
@(private = "file")
tint :: proc(px: []u32, rgb: u32) {
	for &p in px {
		a := f32(p >> 24) / 255
		p = (p & 0xff000000) | u32(f32((rgb >> 16) & 0xff) * a) << 16 | u32(f32((rgb >> 8) & 0xff) * a) << 8 | u32(f32(rgb & 0xff) * a)
	}
}
