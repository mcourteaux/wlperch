// Panels: named popups composed of modules laid out in columns.
//
//   [panel.perf]
//   width   = 780
//   title   = Performance            ; compact title row (when there's no header)
//   header  = false                  ; big clock + night light + keyboard layouts
//   columns = cpu gpu memory | processes
//
// `wlwidgets toggle perf` opens it; the first panel in the file is the default.
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
	{"audio", draw_audio},
	{"system", draw_system},
	{"network", draw_network},
	{"weather", draw_weather},
	{"clocks", draw_clocks},
	{"displays", draw_displays},
	{"bluetooth", draw_bluetooth},
	{"cpu", draw_cpu_card},
	{"gpu", draw_gpu_card},
	{"memory", draw_memory_card},
	{"processes", draw_processes},
	{"sensors", draw_sensors},
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
	columns:     [dynamic][dynamic]string,
	last_height: i32,
}

panels: [dynamic]Panel
current_panel: int

panel_find :: proc(name: string) -> int {
	for p, i in panels {
		if p.name == name {return i}
	}
	return -1
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

// Does the panel on screen contain this module? (services use it to decide
// whether to sample).
panel_shows :: proc(module: string) -> bool {
	if len(panels) == 0 {return false}
	for col in cur_panel().columns {
		for m in col {if m == module {return true}}
	}
	return false
}
