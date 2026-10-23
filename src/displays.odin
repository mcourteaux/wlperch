// Display preset scripts (desk.sh & friends). We parse the sway `output`
// lines they write so the drop-down can show a preview of each layout, and
// run the script to apply it.
package main

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"

Preset_Output :: struct {
	name:      string,
	enabled:   bool,
	x, y:      i32,
	w, h:      i32, // mode size (0 = unknown -> use current mode)
	scale:     f32,
	transform: string,
}

Preset :: struct {
	path:    string,
	name:    string,
	label:   string,
	outputs: [dynamic]Preset_Output,
}

Displays :: struct {
	presets:  [dynamic]Preset,
	selected: int,
	applying: string,
}
displays: Displays

@(private = "file")
prettify :: proc(file: string) -> string {
	base := strings.trim_suffix(file, ".sh")
	words, _ := strings.replace_all(base, "_", " ", context.temp_allocator)
	words, _ = strings.replace_all(words, "-", " ", context.temp_allocator)
	b := strings.builder_make()
	for w, i in strings.fields(words, context.temp_allocator) {
		if i > 0 {strings.write_byte(&b, ' ')}
		lw := strings.to_lower(w, context.temp_allocator)
		switch lw {
		case "tv": strings.write_string(&b, "TV")
		case "4k": strings.write_string(&b, "4K")
		case:
			if i == 0 {
				strings.write_string(&b, strings.to_upper(lw[:1], context.temp_allocator))
				strings.write_string(&b, lw[1:])
			} else {
				strings.write_string(&b, lw)
			}
		}
	}
	return strings.to_string(b)
}

parse_preset :: proc(path: string) -> (p: Preset, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if !strings.has_prefix(l, "output ") {continue}
		f := strings.fields(l, context.temp_allocator)
		if len(f) < 3 {continue}
		o := Preset_Output {
			name    = strings.clone(f[1]),
			enabled = true,
			scale   = 1,
			transform = "normal",
		}
		// Merge with an earlier line for the same output.
		existing := -1
		for eo, i in p.outputs {if eo.name == o.name {existing = i}}
		if existing >= 0 {
			delete(o.name)
			o = p.outputs[existing]
		}
		for i := 2; i < len(f); i += 1 {
			switch f[i] {
			case "disable", "disabled":
				o.enabled = false
			case "enable":
				o.enabled = true
			case "pos", "position":
				if i + 2 < len(f) {
					o.x = i32(strconv.parse_int(f[i + 1]) or_else 0)
					o.y = i32(strconv.parse_int(f[i + 2]) or_else 0)
					i += 2
				}
			case "res", "resolution", "mode":
				if i + 1 < len(f) {
					m := f[i + 1]
					if at := strings.index_byte(m, '@'); at >= 0 {m = m[:at]}
					if xi := strings.index_byte(m, 'x'); xi >= 0 {
						o.w = i32(strconv.parse_int(m[:xi]) or_else 0)
						o.h = i32(strconv.parse_int(m[xi + 1:]) or_else 0)
					}
					i += 1
				}
			case "scale":
				if i + 1 < len(f) {
					o.scale = f32(strconv.parse_f64(f[i + 1]) or_else 1)
					i += 1
				}
			case "transform":
				if i + 1 < len(f) {
					o.transform = strings.clone(f[i + 1])
					i += 1
				}
			}
		}
		if existing >= 0 {p.outputs[existing] = o} else {append(&p.outputs, o)}
	}
	if len(p.outputs) == 0 {return}
	p.path = strings.clone(path)
	file := filepath.base(path)
	p.name = strings.clone(file)
	p.label = prettify(file)
	return p, true
}

displays_scan :: proc() {
	for &p in displays.presets {
		for o in p.outputs {delete(o.name)}
		delete(p.outputs)
		delete(p.path); delete(p.name); delete(p.label)
	}
	clear(&displays.presets)
	seen: map[string]bool
	defer delete(seen)
	for dir in config.preset_dirs {
		pattern := strings.concatenate({dir, "/", config.preset_glob}, context.temp_allocator)
		matches, _ := filepath.glob(pattern, context.temp_allocator)
		for m in matches {
			// Dedupe symlinks (desk.sh in ~/.local/bin links into dotfiles).
			real := m
			if rp := posix.realpath(strings.clone_to_cstring(m, context.temp_allocator), nil); rp != nil {
				real = strings.clone_from_cstring(rp, context.temp_allocator)
				posix.free(rawptr(rp))
			}
			if seen[real] {continue}
			seen[strings.clone(real, context.temp_allocator)] = true
			if p, ok := parse_preset(m); ok {append(&displays.presets, p)}
		}
	}
	// Sort by label for a stable menu.
	for i in 1 ..< len(displays.presets) {
		for j := i; j > 0 && displays.presets[j].label < displays.presets[j - 1].label; j -= 1 {
			displays.presets[j], displays.presets[j - 1] = displays.presets[j - 1], displays.presets[j]
		}
	}
	displays.selected = displays_active_preset()
}

// Logical size of a preset output, using the current mode when the preset
// doesn't specify one.
preset_output_rect :: proc(o: Preset_Output) -> (x, y, w, h: f32) {
	mw, mh := f32(o.w), f32(o.h)
	if mw == 0 || mh == 0 {
		sync.guard(&sway.mu)
		for so in sway.outputs {
			if so.name == o.name && so.mode_w > 0 {
				mw, mh = f32(so.mode_w), f32(so.mode_h)
			}
		}
		if mw == 0 {mw, mh = 1920, 1080}
	}
	if o.transform == "90" || o.transform == "270" || o.transform == "flipped-90" || o.transform == "flipped-270" {
		mw, mh = mh, mw
	}
	s := o.scale > 0 ? o.scale : 1
	return f32(o.x), f32(o.y), mw / s, mh / s
}

// Index of the preset that matches the current layout, or -1.
displays_active_preset :: proc() -> int {
	sync.guard(&sway.mu)
	if !sway.ok {return -1}
	for p, pi in displays.presets {
		match := true
		for o in p.outputs {
			found := false
			for so in sway.outputs {
				if so.name != o.name {continue}
				found = true
				if so.active != o.enabled {match = false}
				if o.enabled && so.active {
					if so.x != o.x || so.y != o.y {match = false}
					if o.w > 0 && (so.mode_w != o.w || so.mode_h != o.h) {match = false}
					if so.transform != o.transform {match = false}
				}
			}
			// An output the preset enables but isn't connected can't match.
			if !found && o.enabled {match = false}
		}
		// Every active output must be described by the preset.
		for so in sway.outputs {
			if !so.active {continue}
			described := false
			for o in p.outputs {if o.name == so.name {described = true}}
			if !described {match = false}
		}
		if match {return pi}
	}
	return -1
}

displays_apply :: proc(index: int) {
	if index < 0 || index >= len(displays.presets) {return}
	p := displays.presets[index]
	delete(displays.applying)
	displays.applying = strings.clone(p.label)
	launch_detached({p.path})
}
