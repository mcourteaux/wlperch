// Panels: named popups composed of modules laid out in columns.
//
//   [panel.system]
//   width   = 780
//   title   = System                 ; compact title row (when there's no header)
//   header  = false                  ; big clock, date, setup + restart
//   columns = cpu gpu memory | processes
//   tab     = false                  ; no tab in the tab strip (open it with a key binding)
//
// `wlperch toggle system` opens it; the first panel in the file is the default.
package main

import "core:encoding/ini"
import "core:log"
import "core:strconv"
import "core:strings"

Module_Proc :: #type proc(width: f32)

Module :: struct {
	name: string,
	draw: Module_Proc,
}

MODULES := [?]Module {
	{"quick", draw_quick},
	{"audio", draw_audio},
	{"network", draw_network},
	{"weather", draw_weather},
	{"clocks", draw_clocks},
	{"displays", draw_displays},
	{"bluetooth", draw_bluetooth},
	{"storage", draw_storage},
	{"notifications", draw_notifications},
	{"media", draw_media},
	{"calculator", draw_calculator},
	{"launcher", draw_launcher},
	{"cpu", draw_cpu_card},
	{"gpu", draw_gpu_card},
	{"memory", draw_memory_card},
	{"processes", draw_processes},
	{"sensors", draw_sensors},
	{"time", draw_time},
	{"thermals", draw_thermals},
	{"github", draw_github},
	{"github-inbox", draw_github_inbox},
	{"github-repo", draw_github_repo},
}

module_find :: proc(name: string) -> Module_Proc {
	for m in MODULES {
		if m.name == name {return m.draw}
	}
	return nil
}

Panel :: struct {
	name:        string,
	title:       string,
	width:       i32,
	header:      bool,
	tab:         bool, // listed in the tab strip
	columns:     [dynamic][dynamic]string,
	last_height: i32,
	last_panel_h: f32, // panel height (without shadow / tooltip room)
}

panels: [dynamic]Panel
current_panel: int

panel_find :: proc(name: string) -> int {
	for p, i in panels {
		if p.name == name {return i}
	}
	if name == "perf" {return panel_find("system")} // its name before 2026-10
	return -1
}

// Icon for a panel tab, from its first module.
panel_icon :: proc(p: Panel) -> string {
	if len(p.columns) == 0 || len(p.columns[0]) == 0 {return ICON_TUNE}
	switch p.columns[0][0] {
	case "cpu", "gpu", "memory", "processes", "thermals", "storage": return ICON_CHIP
	case "sensors":                                                  return ICON_THERMOMETER
	case "time":                                                     return ICON_CLOCK
	case "weather":                                                  return ICON_W_PARTLY
	case "audio":                                                    return ICON_SPEAKER
	case "notifications":                                            return ICON_BELL
	case "calculator":                                               return ICON_CALC
	case "launcher":                                                 return ICON_APPS
	case "github":                                                   return ICON_GITHUB
	}
	return ICON_TUNE
}

cur_panel :: proc() -> ^Panel {
	return &panels[current_panel]
}

// Parse every [panel.*] section, in file order.
panels_load :: proc(src: string, m: ini.Map) {
	order: [dynamic]string
	order.allocator = context.temp_allocator
	text := src
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "[panel.") && strings.has_suffix(l, "]") {
			append(&order, l[1:len(l) - 1])
		}
	}
	for section in order {
		kv := m[section]
		p := Panel {
			name   = strings.clone(section[len("panel."):]),
			title  = strings.clone(unquote(strings.trim_space(kv["title"]))),
			width  = i32(strconv.parse_int(strings.trim_space(kv["width"])) or_else int(config.width)),
			header = strings.trim_space(kv["header"]) == "true",
			tab    = strings.trim_space(kv["tab"]) != "false",
		}
		for col in strings.split(unquote(strings.trim_space(kv["columns"])), "|", context.temp_allocator) {
			c: [dynamic]string
			for mod in strings.fields(col, context.temp_allocator) {
				if module_find(mod) == nil {
					log.warnf("panel %s: unknown module %q", p.name, mod)
					continue
				}
				append(&c, strings.clone(mod))
			}
			if len(c) > 0 {append(&p.columns, c)}
		}
		if len(p.columns) == 0 {
			log.warnf("panel %s has no modules; skipped", p.name)
			continue
		}
		p.width = clamp(p.width, 360, 2400)
		append(&panels, p)
	}
}

// The launcher's key bindings ("toggle launch", "toggle run", "toggle
// emoji") work with any panel set: add the built-in panels when the config
// doesn't define them.
panels_ensure_launcher :: proc() {
	// The bar's audio module opens this one (hidden from the tab strip).
	if panel_find("audio") < 0 {
		p := Panel{name = strings.clone("audio"), title = strings.clone("Audio"), width = 520, tab = false}
		col: [dynamic]string
		append(&col, strings.clone("audio"))
		append(&p.columns, col)
		append(&panels, p)
	}
	for name in ([]string{"launch", "run", "emoji"}) {
		if panel_find(name) >= 0 {continue}
		p := Panel{name = strings.clone(name), width = 680, tab = false}
		col: [dynamic]string
		append(&col, strings.clone("launcher"))
		append(&p.columns, col)
		append(&panels, p)
	}
}

// Remove a module from every panel; panels left without modules go too.
panels_drop_module :: proc(module: string) {
	for i := len(panels) - 1; i >= 0; i -= 1 {
		p := &panels[i]
		for ci := len(p.columns) - 1; ci >= 0; ci -= 1 {
			col := &p.columns[ci]
			for mi := len(col) - 1; mi >= 0; mi -= 1 {
				if col[mi] == module {ordered_remove(col, mi)}
			}
			if len(col) == 0 {ordered_remove(&p.columns, ci)}
		}
		if len(p.columns) == 0 {ordered_remove(&panels, i)}
	}
	current_panel = clamp(current_panel, 0, max(len(panels) - 1, 0))
}

// Does the panel on screen contain this module? (services use it to decide
// whether to sample).
panel_shows :: proc(module: string) -> bool {
	if len(panels) == 0 {return false}
	for col in cur_panel().columns {
		for m in col {if m == module {return true}}
	}
	return false
}
