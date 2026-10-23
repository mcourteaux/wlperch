// Display presets: [display.<name>] sections in the config, one line per
// output in sway's own words. The drop-down previews and applies them, and
// "wlperch display <name>" switches from the command line.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"

Preset_Output :: struct {
	name:      string,
	enabled:   bool,
	x, y:      i32,
	w, h:      i32, // mode size (0 = unknown -> use current mode)
	refresh:   f32, // Hz, 0 = sway's pick
	scale:     f32, // 0 = leave as is
	transform: string,
}

Preset :: struct {
	key:        string, // section name after "display."
	label:      string,
	outputs:    [dynamic]Preset_Output,
	workspaces: [dynamic]Preset_Workspace,
	run:        string, // shell command run after switching
}

Preset_Workspace :: struct {
	ws, output: string,
}

Displays :: struct {
	presets:  [dynamic]Preset,
	selected: int,
	applying: string,
}
displays: Displays

// Name of the sway file that keeps the applied layout across sway restarts.
DISPLAYS_SWAY_FILE :: "wlperch-displays.conf"

@(private = "file")
prettify :: proc(key: string) -> string {
	words, _ := strings.replace_all(key, "_", " ", context.temp_allocator)
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

// `3440x1440@59.973Hz pos 0 0 scale 1 transform 90`, or `off`.
parse_output_words :: proc(o: ^Preset_Output, words: []string) {
	o.enabled = true
	parse_mode :: proc(o: ^Preset_Output, m: string) -> bool {
		m := m
		if at := strings.index_byte(m, '@'); at >= 0 {
			r := strings.trim_suffix(strings.trim_suffix(m[at + 1:], "Hz"), "hz")
			o.refresh = f32(strconv.parse_f64(r) or_else 0)
			m = m[:at]
		}
		xi := strings.index_byte(m, 'x')
		if xi < 0 {return false}
		w, wok := strconv.parse_int(m[:xi])
		h, hok := strconv.parse_int(m[xi + 1:])
		if !wok || !hok {return false}
		o.w, o.h = i32(w), i32(h)
		return true
	}
	for i := 0; i < len(words); i += 1 {
		switch strings.to_lower(words[i], context.temp_allocator) {
		case "off", "disable", "disabled":
			o.enabled = false
		case "on", "enable", "enabled":
			o.enabled = true
		case "pos", "position":
			if i + 1 < len(words) && strings.contains_rune(words[i + 1], ',') {
				xy := strings.split(words[i + 1], ",", context.temp_allocator)
				o.x = i32(strconv.parse_int(xy[0]) or_else 0)
				o.y = i32(strconv.parse_int(xy[1]) or_else 0)
				i += 1
			} else if i + 2 < len(words) {
				o.x = i32(strconv.parse_int(words[i + 1]) or_else 0)
				o.y = i32(strconv.parse_int(words[i + 2]) or_else 0)
				i += 2
			}
		case "res", "resolution", "mode":
			if i + 1 < len(words) {
				parse_mode(o, words[i + 1])
				i += 1
			}
		case "scale":
			if i + 1 < len(words) {
				o.scale = f32(strconv.parse_f64(words[i + 1]) or_else 1)
				i += 1
			}
		case "transform", "rotate":
			if i + 1 < len(words) {
				o.transform = strings.clone(words[i + 1])
				i += 1
			}
		case:
			parse_mode(o, words[i]) // a bare 2560x1440
		}
	}
}

// All [display.<name>] sections of a config file, in file order. Every key
// except name / workspaces / run is an output.
presets_from_ini_text :: proc(text: string) -> (out: [dynamic]Preset) {
	text := text
	cur: ^Preset
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' || l[0] == ';' {continue}
		if l[0] == '[' {
			cur = nil
			if strings.has_prefix(l, "[display.") && strings.has_suffix(l, "]") {
				key := l[len("[display."):len(l) - 1]
				append(&out, Preset{key = strings.clone(key), label = prettify(key)})
				cur = &out[len(out) - 1]
			}
			continue
		}
		if cur == nil {continue}
		eq := strings.index_byte(l, '=')
		if eq < 0 {continue}
		key := unquote(strings.trim_space(l[:eq]))
		value := strings.trim_space(l[eq + 1:])
		// Inline comments: `DP-1 = off   ; the TV`
		for c in ([]string{" ;", " #", "\t;", "\t#"}) {
			if ci := strings.index(value, c); ci >= 0 {value = strings.trim_space(value[:ci])}
		}
		value = unquote(value)
		switch key {
		case "name":
			delete(cur.label)
			cur.label = strings.clone(value)
		case "run":
			cur.run = strings.clone(value)
		case "workspaces":
			// DP-1: 1 2 3, DP-3: 4 5 6
			for group in strings.split(value, ",", context.temp_allocator) {
				colon := strings.index_byte(group, ':')
				if colon < 0 {continue}
				output := strings.trim_space(group[:colon])
				for ws in strings.fields(group[colon + 1:], context.temp_allocator) {
					append(&cur.workspaces, Preset_Workspace{ws = strings.clone(ws), output = strings.clone(output)})
				}
			}
		case:
			o := Preset_Output{name = strings.clone(key), transform = "normal"}
			parse_output_words(&o, strings.fields(value, context.temp_allocator))
			append(&cur.outputs, o)
		}
	}
	// A section without outputs is a typo, not a preset.
	for i := len(out) - 1; i >= 0; i -= 1 {
		if len(out[i].outputs) == 0 {
			preset_destroy(&out[i])
			ordered_remove(&out, i)
		}
	}
	return
}

preset_destroy :: proc(p: ^Preset) {
	for o in p.outputs {
		delete(o.name)
		if o.transform != "normal" {delete(o.transform)}
	}
	for w in p.workspaces {delete(w.ws); delete(w.output)}
	delete(p.outputs)
	delete(p.workspaces)
	delete(p.key)
	delete(p.label)
	delete(p.run)
}

// Re-read the presets from the config file (cheap; picks up edits without a restart).
displays_scan :: proc() {
	for &p in displays.presets {preset_destroy(&p)}
	delete(displays.presets)
	text, _ := os.read_entire_file(config_path(), context.temp_allocator)
	displays.presets = presets_from_ini_text(string(text))
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
					if o.scale > 0 && abs(so.scale - o.scale) > 0.001 {match = false}
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

// Preset by section name, label (any case) or 1-based number.
displays_find :: proc(name: string) -> int {
	for p, i in displays.presets {
		if strings.equal_fold(p.key, name) || strings.equal_fold(p.label, name) {return i}
	}
	if n, ok := strconv.parse_int(name); ok && n >= 1 && n <= len(displays.presets) {return n - 1}
	return -1
}

// The sway `output` arguments for one preset output.
@(private = "file")
output_args :: proc(o: Preset_Output) -> string {
	if !o.enabled {return "disable"}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "enable")
	if o.w > 0 {
		fmt.sbprintf(&b, " mode %dx%d", o.w, o.h)
		if o.refresh > 0 {fmt.sbprintf(&b, "@%.3fHz", o.refresh)}
	}
	fmt.sbprintf(&b, " pos %d %d", o.x, o.y)
	if o.scale > 0 {fmt.sbprintf(&b, " scale %g", o.scale)}
	fmt.sbprintf(&b, " transform %s", o.transform)
	return strings.to_string(b)
}

@(private = "file")
quote_output :: proc(name: string) -> string {
	return strings.contains_any(name, " \"'") ? fmt.tprintf("%q", name) : name
}

// Switch sway to a preset (synchronously over sway IPC) and remember it in
// sway's config dir so it survives a restart.
displays_apply_now :: proc(p: Preset) -> (ok: bool, msg: string) {
	ok = true
	errors: [dynamic]string
	errors.allocator = context.temp_allocator
	// Enable the new outputs before turning the others off, so there's never
	// a moment without any screen.
	for pass in 0 ..< 2 {
		for o in p.outputs {
			if o.enabled != (pass == 0) {continue}
			cmd := fmt.tprintf("output %s %s", quote_output(o.name), output_args(o))
			if !sway_command(cmd) {
				ok = false
				append(&errors, o.name)
			}
		}
	}
	for w in p.workspaces {
		sway_command(fmt.tprintf("workspace %s output %s", w.ws, quote_output(w.output)))
		// Existing workspaces move over too (an empty one doesn't exist).
		sway_command(fmt.tprintf("[workspace=\"^%s$\"] move workspace to output %s", w.ws, quote_output(w.output)))
	}
	displays_remember(p)
	if p.run != "" {launch_shell(p.run)}
	if !ok {return false, fmt.tprintf("sway refused %s", strings.join(errors[:], ", ", context.temp_allocator))}
	return true, ""
}

@(private = "file")
displays_remember :: proc(p: Preset) {
	dir := sway_dir()
	if !os.is_dir(dir) {return}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "# Written by wlperch: the display preset \"%s\" (switch with `wlperch display <name>`).\n", p.label)
	strings.write_string(&b, "# Overwritten on every switch; edit the presets in ~/.config/wlperch/config.ini instead.\n")
	for o in p.outputs {
		fmt.sbprintf(&b, "output %s %s\n", quote_output(o.name), output_args(o))
	}
	for w in p.workspaces {
		fmt.sbprintf(&b, "workspace %s output %s\n", w.ws, quote_output(w.output))
	}
	path := strings.concatenate({dir, "/", DISPLAYS_SWAY_FILE}, context.temp_allocator)
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, strings.to_string(b)) == nil {os.rename(tmp, path)}
}

// From the popup: run the CLI in the background so a slow modeset doesn't
// freeze the UI.
displays_apply :: proc(index: int) {
	if index < 0 || index >= len(displays.presets) {return}
	p := displays.presets[index]
	delete(displays.applying)
	displays.applying = strings.clone(p.label)
	exe := setup_self_path()
	if exe == "" {exe = "wlperch"}
	launch_detached({exe, "display", p.key})
}

// ---- Presets from the current layout -----------------------------------

// `[display.<key>]` text describing the live layout.
@(private = "file")
preset_section :: proc(b: ^strings.Builder, key, label: string, only: string = "") {
	fmt.sbprintf(b, "\n[display.%s]\nname = %s\n", key, label)
	for so in sway.outputs {
		on := only == "" ? so.active : so.name == only
		if !on {
			fmt.sbprintf(b, "%s = off\n", quote_output(so.name))
			continue
		}
		fmt.sbprintf(b, "%s = ", quote_output(so.name))
		if so.mode_w > 0 {
			fmt.sbprintf(b, "%dx%d", so.mode_w, so.mode_h)
			if so.refresh > 0 {fmt.sbprintf(b, "@%.3fHz", so.refresh)}
			strings.write_byte(b, ' ')
		}
		x, y := so.x, so.y
		if only != "" {x, y = 0, 0}
		fmt.sbprintf(b, "pos %d %d", x, y)
		if so.active && so.scale > 0 && so.scale != 1 {fmt.sbprintf(b, " scale %g", so.scale)}
		if so.active && so.transform != "" && so.transform != "normal" {fmt.sbprintf(b, " transform %s", so.transform)}
		strings.write_byte(b, '\n')
	}
}

@(private = "file")
output_title :: proc(so: Sway_Output) -> string {
	if so.model != "" && so.model != "Unknown" {return so.model}
	return so.name
}

// Presets for a config written from scratch: the layout as it is now and,
// with several monitors, each one on its own. Empty without sway.
displays_default_presets :: proc() -> string {
	sync.guard(&sway.mu)
	if !sway.ok || len(sway.outputs) == 0 {return ""}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\n# Display presets, generated from the layout wlperch found on its first run.\n")
	if len(sway.outputs) == 1 {
		preset_section(&b, "default", "Default")
		return strings.to_string(b)
	}
	preset_section(&b, "all", "All monitors")
	for so in sway.outputs {
		key := strings.to_lower(fmt.tprintf("only-%s", so.name), context.temp_allocator)
		key, _ = strings.replace_all(key, " ", "-", context.temp_allocator)
		preset_section(&b, key, fmt.tprintf("%s only", output_title(so)), only = so.name)
	}
	return strings.to_string(b)
}

// The current layout as a new [display.<key>] section.
displays_section_for_current :: proc(key, label: string) -> string {
	sync.guard(&sway.mu)
	b := strings.builder_make(context.temp_allocator)
	preset_section(&b, key, label)
	return strings.to_string(b)
}

// ---- CLI ----------------------------------------------------------------

DISPLAY_USAGE :: `usage: wlperch display [list]           presets ("*" = the current layout)
       wlperch display <name|number>    switch to a preset
       wlperch display next|prev        cycle through them
       wlperch display save <name> [label]  add the current layout as a preset
`

displays_cli :: proc(args: []string) -> int {
	if !sway_load_outputs() {
		fmt.eprintln("wlperch: can't reach sway (is SWAYSOCK set?)")
		return 1
	}
	displays_scan()
	active := displays_active_preset()
	sub := len(args) > 0 ? args[0] : "list"
	switch sub {
	case "-h", "--help", "help":
		fmt.print(DISPLAY_USAGE)
		return 0
	case "list":
		if len(displays.presets) == 0 {
			fmt.println("No display presets. Add [display.<name>] sections to the config, or run \"wlperch display save <name>\".")
			return 0
		}
		for p, i in displays.presets {
			names: [dynamic]string
			names.allocator = context.temp_allocator
			for o in p.outputs {if o.enabled {append(&names, o.name)}}
			fmt.printfln("%s %d  %-16s %s  (%s)", i == active ? "*" : " ", i + 1, p.key, p.label, strings.join(names[:], " + ", context.temp_allocator))
		}
		return 0
	case "save":
		if len(args) < 2 {
			fmt.eprint(DISPLAY_USAGE)
			return 2
		}
		key := args[1]
		if displays_find(key) >= 0 {
			fmt.eprintfln("wlperch: a preset called \"%s\" already exists", key)
			return 1
		}
		label := len(args) > 2 ? strings.join(args[2:], " ", context.temp_allocator) : prettify(key)
		path := config_path()
		text, _ := os.read_entire_file(path, context.temp_allocator)
		joined := strings.concatenate({string(text), displays_section_for_current(key, label)}, context.temp_allocator)
		if os.write_entire_file(path, joined) != nil {
			fmt.eprintln("wlperch: couldn't write", path)
			return 1
		}
		fmt.printfln("Saved the current layout as \"%s\" (wlperch display %s)", label, key)
		return 0
	}
	if len(displays.presets) == 0 {
		fmt.eprintln("wlperch: no display presets in the config")
		return 1
	}
	index := -1
	switch sub {
	case "next":
		index = (active + 1) % len(displays.presets)
	case "prev", "previous":
		index = active < 0 ? len(displays.presets) - 1 : (active + len(displays.presets) - 1) % len(displays.presets)
	case:
		index = displays_find(strings.join(args, " ", context.temp_allocator))
	}
	if index < 0 {
		fmt.eprintfln("wlperch: no display preset \"%s\" (see \"wlperch display list\")", strings.join(args, " ", context.temp_allocator))
		return 1
	}
	p := displays.presets[index]
	ok, msg := displays_apply_now(p)
	if !ok {
		fmt.eprintfln("wlperch: %s: %s", p.label, msg)
		return 1
	}
	fmt.printfln("Switched to \"%s\"", p.label)
	return 0
}
