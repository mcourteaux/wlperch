// The bar's modules: what each shows (bar_build) and does when clicked or
// scrolled (bar_click / bar_scroll). Slow data (MPRIS, battery, power
// profile, sensors, the daemon's notification count…) is gathered by a worker
// thread into bar_data; sway state comes from bar_sway.odin, the tray from
// bar_tray.odin.
package main

import "core:c"
import "core:fmt"
import "core:encoding/ini"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "core:time/datetime"

Bar_Mod :: enum u8 {
	Workspaces, Mode, Scratchpad, Window,
	Idle, Power_Profile, Backlight, Battery, Media, Timer, Sensors, Memory, Clock, Tray, Notifications, Wlperch,
}

@(private = "file")
MOD_NAMES := [Bar_Mod]string {
	.Workspaces = "workspaces", .Mode = "mode", .Scratchpad = "scratchpad", .Window = "window",
	.Idle = "idle", .Power_Profile = "power-profile", .Backlight = "backlight", .Battery = "battery",
	.Media = "media", .Timer = "timer", .Sensors = "sensors", .Memory = "memory", .Clock = "clock",
	.Tray = "tray", .Notifications = "notifications", .Wlperch = "wlperch",
}

Bar_Config :: struct {
	bottom:      bool,
	height:      i32,
	outputs:     [dynamic]string,
	sides:       [3][dynamic]Bar_Mod, // left, center, right
	clock:       string,
	tray_size:   f32,
}
bar_cfg: Bar_Config

bar_config_load :: proc(m, defaults: ini.Map) {
	get :: proc(m, d: ini.Map, key: string) -> string {
		if s, ok := m["bar"]; ok {
			if v, vok := s[key]; vok {return unquote(strings.trim_space(v))}
		}
		return unquote(strings.trim_space(d["bar"][key]))
	}
	b := &bar_cfg
	b.bottom = get(m, defaults, "position") == "bottom"
	b.height = i32(clamp(strconv.parse_int(get(m, defaults, "height")) or_else 34, 20, 80))
	for o in strings.fields(get(m, defaults, "outputs"), context.temp_allocator) {append(&b.outputs, strings.clone(o))}
	for side, i in ([]string{"left", "center", "right"}) {
		for name in strings.fields(get(m, defaults, side), context.temp_allocator) {
			found := false
			for n, mod in MOD_NAMES {
				if n == name {
					append(&b.sides[i], mod)
					found = true
				}
			}
			// waybar names, so a copied module list works too.
			switch name {
			case "sway/workspaces":       append(&b.sides[i], Bar_Mod.Workspaces); found = true
			case "sway/mode":             append(&b.sides[i], Bar_Mod.Mode); found = true
			case "sway/scratchpad":       append(&b.sides[i], Bar_Mod.Scratchpad); found = true
			case "sway/window":           append(&b.sides[i], Bar_Mod.Window); found = true
			case "idle_inhibitor":        append(&b.sides[i], Bar_Mod.Idle); found = true
			case "power-profiles-daemon": append(&b.sides[i], Bar_Mod.Power_Profile); found = true
			}
			if !found {fmt.eprintfln("wlperch bar: unknown module %q", name)}
		}
	}
	b.clock = strings.clone(get(m, defaults, "clock_format"))
	b.tray_size = f32(clamp(strconv.parse_int(get(m, defaults, "tray_icon_size")) or_else 20, 12, 48))
}

// ---- Data gathered off the main thread ----------------------------------------------

Bar_Data :: struct {
	mu:             sync.Mutex,
	main:           Status_Item,
	mem_used:       u64,
	mem_total:      u64,
	sensors:        Status_Item,
	timer:          Status_Item,
	notif:          Status_Item,
	media_bus:      string, // "" = no player
	media_status:   Media_Status,
	media_track:    string,
	media_tip:      string,
	media_prev:     bool,
	media_next:     bool,
	bat_pct:        int, // -1: no battery
	bat_status:     string,
	bat_time:       string,
	bl_pct:         int, // -1: no backlight
	bl_dev:         string,
	bl_max:         int,
	ppd:            string, // "" = no power-profiles-daemon
	// Requests from the main thread.
	cmd_media:      string,
	cmd_ppd:        int, // +1 / -1: cycle
	cmd_bl:         int, // percent change
	media_poke:     bool,
	wake:           sync.Sema,
}
bar_data: Bar_Data

// Main loop wake-up (the worker writes here).
bar_wake_w: posix.FD

bar_data_poke :: proc() {
	sync.guard(&bar_data.mu)
	bar_data.media_poke = true
	sync.sema_post(&bar_data.wake)
}

@(private = "file")
set_s :: proc(dst: ^string, v: string) -> bool {
	if dst^ == v {return false}
	delete(dst^)
	dst^ = strings.clone(v)
	return true
}

@(private = "file")
set_item :: proc(dst: ^Status_Item, v: Status_Item) -> bool {
	c := set_s(&dst.text, v.text)
	c |= set_s(&dst.tooltip, v.tooltip)
	c |= set_s(&dst.class, v.class)
	return c
}

@(private = "file")
read_sys :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? strings.trim_space(string(data)) : ""
}

// System battery: percent, status and time left ("2:15"), or -1.
@(private = "file")
read_battery :: proc() -> (pct: int, status, left: string) {
	pct = -1
	dir := "/sys/class/power_supply"
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return}
	for e in entries {
		base := fmt.tprintf("%s/%s", dir, e.name)
		if read_sys(fmt.tprintf("%s/type", base)) != "Battery" {continue}
		if read_sys(fmt.tprintf("%s/scope", base)) == "Device" {continue}
		v, ok := strconv.parse_int(read_sys(fmt.tprintf("%s/capacity", base)))
		if !ok {continue}
		status = read_sys(fmt.tprintf("%s/status", base))
		now, nok := strconv.parse_f64(read_sys(fmt.tprintf("%s/energy_now", base)))
		full, _ := strconv.parse_f64(read_sys(fmt.tprintf("%s/energy_full", base)))
		rate, rok := strconv.parse_f64(read_sys(fmt.tprintf("%s/power_now", base)))
		if !nok {
			now, nok = strconv.parse_f64(read_sys(fmt.tprintf("%s/charge_now", base)))
			full, _ = strconv.parse_f64(read_sys(fmt.tprintf("%s/charge_full", base)))
			rate, rok = strconv.parse_f64(read_sys(fmt.tprintf("%s/current_now", base)))
		}
		if nok && rok && rate > 0 {
			hours := status == "Charging" ? (full - now) / rate : now / rate
			if hours > 0 && hours < 100 {left = fmt.tprintf("%d:%02d", int(hours), int(hours * 60) % 60)}
		}
		return v, status, left
	}
	return
}

@(private = "file")
read_backlight :: proc() -> (pct: int, dev: string, maxv: int) {
	pct = -1
	dir := "/sys/class/backlight"
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil || len(entries) == 0 {return}
	e := entries[0]
	cur, ok1 := strconv.parse_int(read_sys(fmt.tprintf("%s/%s/brightness", dir, e.name)))
	mx, ok2 := strconv.parse_int(read_sys(fmt.tprintf("%s/%s/max_brightness", dir, e.name)))
	if !ok1 || !ok2 || mx <= 0 {return}
	return int(f64(cur) / f64(mx) * 100 + 0.5), e.name, mx
}

@(private = "file") PPD := [2][3]cstring {
	{"net.hadess.PowerProfiles", "/net/hadess/PowerProfiles", "net.hadess.PowerProfiles"},
	{"org.freedesktop.UPower.PowerProfiles", "/org/freedesktop/UPower/PowerProfiles", "org.freedesktop.UPower.PowerProfiles"},
}

@(private = "file")
read_ppd :: proc(sys: ^Sd_Bus) -> string {
	if sys == nil {return ""}
	for p in PPD {
		err: Sd_Bus_Error
		ret: cstring
		r := sd_bus_get_property_string(sys, p[0], p[1], p[2], "ActiveProfile", &err, &ret)
		sd_bus_error_free(&err)
		if r >= 0 && ret != nil {
			s := strings.clone(string(ret), context.temp_allocator)
			c_free(rawptr(ret))
			return s
		}
	}
	return ""
}

@(private = "file")
set_ppd :: proc(sys: ^Sd_Bus, cur: string, dir: int) {
	order := []string{"power-saver", "balanced", "performance"}
	at := 1
	for o, i in order {if o == cur {at = i}}
	// Try the next one; a machine without "performance" refuses it.
	for step in 1 ..< len(order) {
		next := order[(at + dir * step + len(order) * 2) % len(order)]
		for p in PPD {
			err: Sd_Bus_Error
			r := sd_bus_set_property(sys, p[0], p[1], p[2], "ActiveProfile", &err, "s", strings.clone_to_cstring(next, context.temp_allocator))
			sd_bus_error_free(&err)
			if r >= 0 {return}
		}
	}
}

@(private = "file")
set_backlight :: proc(sys: ^Sd_Bus, dev: string, maxv, pct: int) {
	if sys == nil || dev == "" {return}
	v := u32(clamp(pct, 1, 100) * maxv / 100)
	err: Sd_Bus_Error
	sd_bus_call_method(sys, "org.freedesktop.login1", "/org/freedesktop/login1/session/auto", "org.freedesktop.login1.Session", "SetBrightness", &err, nil,
		"ssu", cstring("backlight"), strings.clone_to_cstring(dev, context.temp_allocator), c.uint(v))
	sd_bus_error_free(&err)
}

bar_data_start :: proc() {
	bar_data.bat_pct, bar_data.bl_pct = -1, -1
	thread.create_and_start(proc() {
		bus := media_open_bus()
		sys: ^Sd_Bus
		if sd_bus_open_system(&sys) < 0 {sys = nil}
		if sys != nil {sd_bus_set_method_call_timeout(sys, 800_000)}
		last_playing: string
		tick := 0
		for {
			changed := false
			cmd_media: string
			cmd_ppd, cmd_bl: int
			poke := false
			{
				sync.guard(&bar_data.mu)
				cmd_media, bar_data.cmd_media = bar_data.cmd_media, ""
				cmd_ppd, bar_data.cmd_ppd = bar_data.cmd_ppd, 0
				cmd_bl, bar_data.cmd_bl = bar_data.cmd_bl, 0
				poke, bar_data.media_poke = bar_data.media_poke, false
			}
			if cmd_media != "" && bus != nil {
				media_call(bus, bar_data.media_bus, cmd_media)
				delete(cmd_media)
				time.sleep(120 * time.Millisecond) // let the player update
				poke = true
			}
			if cmd_ppd != 0 && sys != nil {
				set_ppd(sys, bar_data.ppd, cmd_ppd)
				tick = 0 // read it back now
			}
			if cmd_bl != 0 {
				set_backlight(sys, bar_data.bl_dev, bar_data.bl_max, bar_data.bl_pct + cmd_bl)
			}

			notif := status_notifications_item()
			main, _ := status_main_item()
			used, total, _ := read_meminfo()
			bl, bl_dev, bl_max := read_backlight()
			{
				sync.guard(&bar_data.mu)
				changed |= set_item(&bar_data.notif, notif)
				changed |= set_item(&bar_data.main, main)
				// Memory: redraw when the shown value (0.1 GiB) changes.
				if used / (100 << 20) != bar_data.mem_used / (100 << 20) || total != bar_data.mem_total {changed = true}
				bar_data.mem_used, bar_data.mem_total = used, total
				if bl != bar_data.bl_pct {changed = true}
				bar_data.bl_pct, bar_data.bl_max = bl, bl_max
				set_s(&bar_data.bl_dev, bl_dev)
			}
			if tick % 2 == 0 || poke {
				timer := status_timer_item()
				media_bus, track, tip: string
				status := Media_Status.Stopped
				can_prev, can_next := false, false
				if bus != nil {
					players := media_scan(bus)
					for p in players {
						if p.status == .Playing && p.bus_name != last_playing {
							delete(last_playing)
							last_playing = strings.clone(p.bus_name)
						}
					}
					if i := media_pick(players[:], "", last_playing); i >= 0 {
						p := players[i]
						media_bus = strings.clone(p.bus_name, context.temp_allocator)
						status = p.status
						track = p.title != "" ? p.title : p.identity
						if p.artist != "" && p.title != "" {track = fmt.tprintf("%s — %s", p.artist, p.title)}
						class := p.status == .Playing ? "playing" : p.status == .Paused ? "paused" : "stopped"
						tip = fmt.tprintf("%s · %s\n%s%s", p.identity, class, track, p.album != "" ? fmt.tprintf("\n%s", p.album) : "")
						track = strings.clone(track, context.temp_allocator)
						can_prev, can_next = p.can_prev, p.can_next
					}
					for &p in players {media_player_free(&p)}
					delete(players)
				}
				sync.guard(&bar_data.mu)
				changed |= set_item(&bar_data.timer, timer)
				changed |= set_s(&bar_data.media_bus, media_bus)
				changed |= set_s(&bar_data.media_track, track)
				changed |= set_s(&bar_data.media_tip, tip)
				if status != bar_data.media_status || can_prev != bar_data.media_prev || can_next != bar_data.media_next {changed = true}
				bar_data.media_status, bar_data.media_prev, bar_data.media_next = status, can_prev, can_next
			}
			if tick % 5 == 0 {
				pct, st, left := read_battery()
				ppd := read_ppd(sys)
				sync.guard(&bar_data.mu)
				if pct != bar_data.bat_pct {changed = true}
				bar_data.bat_pct = pct
				changed |= set_s(&bar_data.bat_status, st)
				changed |= set_s(&bar_data.bat_time, left)
				changed |= set_s(&bar_data.ppd, ppd)
			}
			if tick % 20 == 0 {
				s := status_sensors_item()
				sync.guard(&bar_data.mu)
				changed |= set_item(&bar_data.sensors, s)
			}
			if changed {
				b := u8(1)
				posix.write(bar_wake_w, &b, 1)
			}
			free_all(context.temp_allocator)
			tick += 1
			sync.sema_wait_with_timeout(&bar_data.wake, time.Second)
		}
	})
}

// ---- Items ------------------------------------------------------------------------------

Bar_Seg :: struct {
	text:  string,
	font:  Bar_Font,
	px:    f32,
	color: u32,
	alpha: f32,
}

Bar_Item :: struct {
	mod:        Bar_Mod,
	key:        string, // workspace name, tray item id, media part
	segs:       [dynamic]Bar_Seg,
	icon:       ^Notif_Icon,
	icon_alpha: f32,
	icon_size:  f32,
	pad:        f32, // inside, left and right
	margin:     f32, // outside, left and right
	space:      [2]f32, // extra room before / after (around project pills)
	min_w:      f32,
	inset:      f32, // from the bar's top and bottom
	bg:         u32,
	bg_alpha:   f32,
	line:       u32, // underline (visible workspace)
	line_alpha: f32,
	hover:      bool, // reacts to the pointer
	group:      int,  // project pill it belongs to (-1)
	tooltip:    string,
	calendar:   bool, // tooltip is this month's calendar
	tip_mono:   bool,
	// Layout.
	x, w:       f32,
}

Bar_Group :: struct {
	first, last: int, // item indices
	color:       u32,
	level:       int, // 0 plain, 1 visible, 2 focused
}

Bar_Layout :: struct {
	items:  [dynamic]Bar_Item,
	groups: [dynamic]Bar_Group,
	blocks: [3]Bar_Rect, // left, center, right (w = 0: empty)
	side_end: [3]int, // item count at the end of each side
}

@(private = "file") PX :: f32(14)
@(private = "file") ICON_EYE_ON :: ""
@(private = "file") ICON_EYE_OFF :: ""
@(private = "file") ICON_PERF :: ""
@(private = "file") ICON_BALANCED :: ""
@(private = "file") ICON_SAVER :: ""
@(private = "file") ICON_PLUG :: ""
@(private = "file") ICON_CHARGING :: "\U000F0084"
@(private = "file") ICON_WINDOWS :: ""
@(private = "file") ICON_MEM :: "\U000F035B"
@(private = "file") BATTERY_ICONS := [5]string{"", "", "", "", ""}
@(private = "file") BRIGHT_ICONS := [3]string{"\U000F00DE", "\U000F00DF", "\U000F00E0"}

@(private = "file")
seg :: proc(it: ^Bar_Item, text: string, color: u32, font := Bar_Font.Regular, px := PX, alpha: f32 = 1) {
	if it.segs == nil {it.segs.allocator = context.temp_allocator}
	// A copy: bar_data's strings change under the worker once the lock is let go.
	append(&it.segs, Bar_Seg{strings.clone(text, context.temp_allocator), font, px, color, alpha})
}

@(private = "file")
module_item :: proc(mod: Bar_Mod) -> Bar_Item {
	return {mod = mod, pad = 10, margin = 1, inset = 3, hover = true, group = -1, icon_alpha = 1}
}

idle_inhibit_on: bool

// Everything one output's bar shows, in order.
bar_build :: proc(output: string, lay: ^Bar_Layout) {
	lay.items = make([dynamic]Bar_Item, context.temp_allocator)
	lay.groups = make([dynamic]Bar_Group, context.temp_allocator)
	sync.guard(&bar_data.mu)
	for side in 0 ..< 3 {
		for mod in bar_cfg.sides[side] {
			first := len(lay.items)
			build_module(mod, output, lay)
			for &it in lay.items[first:] {
				it.key = strings.clone(it.key, context.temp_allocator)
				it.tooltip = strings.clone(it.tooltip, context.temp_allocator)
			}
		}
		lay.side_end[side] = len(lay.items)
	}
}

@(private = "file")
build_module :: proc(mod: Bar_Mod, output: string, lay: ^Bar_Layout) {
	p := &bar_pal
	add :: proc(lay: ^Bar_Layout, it: Bar_Item) {append(&lay.items, it)}
	switch mod {
	case .Workspaces:
		for g in bar_ws_groups(output) {
			if g.project < 0 {
				w := g.ws[0]
				it := Bar_Item{mod = .Workspaces, key = w.name, pad = 9, margin = 2, min_w = 12, inset = 4, hover = true, group = -1, icon_alpha = 1}
				switch {
				case w.urgent:
					it.bg, it.bg_alpha = p.red, 0.85
					seg(&it, w.name, p.on_accent, .Bold)
				case w.focused:
					it.bg, it.bg_alpha = p.accent, 1
					seg(&it, w.name, p.on_accent, .Bold)
				case w.visible:
					it.line, it.line_alpha = p.accent, 0.6
					seg(&it, w.name, p.text)
				case:
					seg(&it, w.name, p.muted)
				}
				add(lay, it)
				continue
			}
			// A project: its workspaces in one pill of the project's colour.
			proj := tracker.projects[g.project]
			col := proj.color
			grp := Bar_Group{first = len(lay.items), color = col}
			for w in g.ws {
				if w.focused {grp.level = 2} else if w.visible && grp.level < 1 {grp.level = 1}
			}
			if len(g.ws) == 1 {
				w := g.ws[0]
				it := Bar_Item{mod = .Workspaces, key = w.name, pad = 10, margin = 3, inset = 6, hover = true, group = len(lay.groups), icon_alpha = 1}
				ws_style(&it, w, proj.name, col)
				add(lay, it)
			} else {
				label := Bar_Item{mod = .Workspaces, key = g.ws[0].name, pad = 8, margin = 2, inset = 6, hover = false, group = len(lay.groups), icon_alpha = 1}
				seg(&label, proj.name, bar_ink(col), grp.level == 2 ? .Bold : .Regular)
				label.tooltip = fmt.tprintf("%s: %d workspaces on this monitor", proj.name, len(g.ws))
				add(lay, label)
				for w in g.ws {
					n := w.name[strings.last_index_byte(w.name, ' ') + 1:]
					it := Bar_Item{mod = .Workspaces, key = w.name, pad = 7, margin = 1, min_w = 10, inset = 7, hover = true, group = len(lay.groups), icon_alpha = 1}
					ws_style(&it, w, n, col)
					add(lay, it)
				}
			}
			grp.last = len(lay.items) - 1
			lay.items[grp.first].space[0] = 3
			lay.items[grp.last].space[1] = 3
			append(&lay.groups, grp)
		}
	case .Mode:
		if bsway.mode == "" {return}
		it := module_item(.Mode)
		it.hover = false
		it.inset = 4
		it.bg, it.bg_alpha = p.red, 0.9
		seg(&it, bsway.mode, p.on_accent, .Bold)
		add(lay, it)
	case .Scratchpad:
		if len(bsway.scratch) == 0 {return}
		it := module_item(.Scratchpad)
		it.pad = 8
		seg(&it, ICON_WINDOWS, p.muted)
		seg(&it, fmt.tprintf(" %d", len(bsway.scratch)), p.muted)
		b := strings.builder_make(context.temp_allocator)
		for s, i in bsway.scratch {
			if i > 0 {strings.write_byte(&b, '\n')}
			fmt.sbprintf(&b, "%s: %s", s.app, s.title)
		}
		it.tooltip = strings.to_string(b)
		add(lay, it)
	case .Window:
		title := bsway.titles[output]
		if title == "" {return}
		it := module_item(.Window)
		it.hover = false
		it.pad = 8
		it.margin = 4
		seg(&it, clip_runes_bar(title, 90), p.soft)
		add(lay, it)
	case .Idle:
		it := module_item(.Idle)
		if idle_inhibit_on {
			it.bg, it.bg_alpha = p.yellow, 0.18
			seg(&it, ICON_EYE_ON, p.yellow)
			it.tooltip = "Idle inhibitor: on (the screen stays awake)"
		} else {
			seg(&it, ICON_EYE_OFF, p.muted)
			it.tooltip = "Idle inhibitor: off"
		}
		add(lay, it)
	case .Power_Profile:
		if bar_data.ppd == "" {return}
		it := module_item(.Power_Profile)
		switch bar_data.ppd {
		case "performance": seg(&it, ICON_PERF, p.red)
		case "power-saver": seg(&it, ICON_SAVER, p.green)
		case:               seg(&it, ICON_BALANCED, p.accent)
		}
		it.tooltip = fmt.tprintf("Power profile: %s\nClick: next · right click: previous", bar_data.ppd)
		add(lay, it)
	case .Backlight:
		if bar_data.bl_pct < 0 {return}
		it := module_item(.Backlight)
		seg(&it, fmt.tprintf("%d%% ", bar_data.bl_pct), p.yellow)
		seg(&it, BRIGHT_ICONS[clamp(bar_data.bl_pct * 3 / 101, 0, 2)], p.yellow)
		it.tooltip = "Brightness: scroll to change"
		add(lay, it)
	case .Battery:
		if bar_data.bat_pct < 0 {return}
		it := module_item(.Battery)
		pct := bar_data.bat_pct
		charging := bar_data.bat_status == "Charging"
		plugged := bar_data.bat_status == "Full" || bar_data.bat_status == "Not charging"
		col := p.green
		if !charging && pct <= 15 {
			col = p.red
			it.bg, it.bg_alpha = p.red, 0.25
		} else if !charging && pct <= 30 {
			col = p.orange
		}
		icon := BATTERY_ICONS[clamp(pct * 5 / 101, 0, 4)]
		if charging {icon = ICON_CHARGING} else if plugged {icon = ICON_PLUG}
		if battery_alt && bar_data.bat_time != "" {
			seg(&it, fmt.tprintf("%s ", bar_data.bat_time), col)
		} else {
			seg(&it, fmt.tprintf("%d%% ", pct), col)
		}
		seg(&it, icon, col)
		it.tooltip = fmt.tprintf("Battery %d%% · %s%s", pct, strings.to_lower(bar_data.bat_status, context.temp_allocator),
			bar_data.bat_time != "" ? fmt.tprintf("\n%s %s", bar_data.bat_time, charging ? "until full" : "left") : "")
		add(lay, it)
	case .Media:
		if bar_data.media_bus == "" {return}
		playing := bar_data.media_status == .Playing
		if bar_data.media_prev {
			it := module_item(.Media)
			it.key, it.pad, it.margin = "prev", 6, 0
			seg(&it, ICON_SKIP_PREV, p.muted)
			it.tooltip = "Previous"
			add(lay, it)
		}
		it := module_item(.Media)
		it.key = "track"
		seg(&it, playing ? ICON_PAUSE : ICON_PLAY, playing ? p.green : p.muted)
		seg(&it, "  ", p.muted)
		seg(&it, clip_runes_bar(bar_data.media_track, 40), playing ? p.green : p.muted)
		it.tooltip = fmt.tprintf("%s\nClick: play/pause · right click: panel · scroll: skip", bar_data.media_tip)
		add(lay, it)
		if bar_data.media_next {
			n := module_item(.Media)
			n.key, n.pad, n.margin = "next", 6, 0
			seg(&n, ICON_SKIP_NEXT, p.muted)
			n.tooltip = "Next"
			add(lay, n)
		}
	case .Timer:
		it := module_item(.Timer)
		t := bar_data.timer
		if t.text == "" {return}
		if t.class == "running" {
			it.bg, it.bg_alpha = p.teal, 0.12
			seg(&it, t.text, p.teal, .Bold)
		} else {
			seg(&it, t.text, p.faint)
		}
		it.tooltip = t.tooltip
		add(lay, it)
	case .Sensors:
		s := bar_data.sensors
		if s.class == "none" || s.text == "" {return}
		it := module_item(.Sensors)
		switch s.class {
		case "co2-high":
			it.bg, it.bg_alpha = p.red, 1
			seg(&it, s.text, p.on_accent)
		case "co2-warn":
			seg(&it, s.text, p.orange)
		case:
			seg(&it, s.text, p.teal)
		}
		it.tooltip = s.tooltip
		add(lay, it)
	case .Memory:
		if bar_data.mem_total == 0 {return}
		GiB :: f64(1 << 30)
		it := module_item(.Memory)
		used, total := f64(bar_data.mem_used) / GiB, f64(bar_data.mem_total) / GiB
		seg(&it, fmt.tprintf("%.1f", used), p.cyan)
		seg(&it, fmt.tprintf(" / %.0f GiB", total), p.cyan, .Regular, PX * 0.82)
		seg(&it, "  ", p.cyan)
		seg(&it, ICON_MEM, p.cyan)
		it.tooltip = fmt.tprintf("%.0f%% used", f64(bar_data.mem_used) / f64(bar_data.mem_total) * 100)
		add(lay, it)
	case .Clock:
		it := module_item(.Clock)
		clock_segs(&it, bar_cfg.clock, p.soft)
		it.calendar = true
		it.tip_mono = true
		add(lay, it)
	case .Tray:
		for t in tray.items {
			if !t.loaded || t.status == "Passive" {continue}
			it := module_item(.Tray)
			it.key = t.id
			it.pad, it.margin = 5, 0
			it.icon = t.status == "NeedsAttention" && t.att_icon != nil ? t.att_icon : t.icon
			it.icon_size = bar_cfg.tray_size
			if it.icon == nil {seg(&it, t.title != "" ? strings.to_upper(t.title[:1], context.temp_allocator) : "?", p.muted, .Bold)}
			if t.status == "NeedsAttention" {it.bg, it.bg_alpha = p.red, 0.35}
			it.tooltip = t.tooltip != "" ? t.tooltip : t.title
			add(lay, it)
		}
	case .Notifications:
		n := bar_data.notif
		it := module_item(.Notifications)
		switch n.class {
		case "unread":
			it.bg, it.bg_alpha = p.purple, 0.14
			seg(&it, n.text, p.purple, .Bold, 15)
		case "dnd": seg(&it, n.text, p.faint, .Regular, 15)
		case "off": seg(&it, n.text, p.off, .Regular, 15)
		case:       seg(&it, n.text, p.muted, .Regular, 15)
		}
		it.tooltip = n.tooltip
		add(lay, it)
	case .Wlperch:
		it := module_item(.Wlperch)
		if bar_data.main.class == "memory-warning" {
			it.bg, it.bg_alpha = p.red, 1
			seg(&it, bar_data.main.text, p.on_accent, .Bold, 14)
		} else {
			it.bg, it.bg_alpha = p.accent, 0.16
			seg(&it, ICON_TUNE_BAR, p.accent, .Regular, 17)
		}
		it.pad = 11
		it.margin = 2
		it.tooltip = bar_data.main.tooltip
		add(lay, it)
	}
}

@(private = "file")
ws_style :: proc(it: ^Bar_Item, w: Bar_Ws, label: string, col: u32) {
	p := &bar_pal
	switch {
	case w.urgent:
		it.bg, it.bg_alpha = p.red, 0.85
		seg(it, label, p.on_accent, .Bold)
	case w.focused:
		it.bg, it.bg_alpha = col, 1
		seg(it, label, bar_on(col), .Bold)
	case w.visible:
		it.line, it.line_alpha = bar_ink(col), 0.9
		seg(it, label, p.text)
	case:
		seg(it, label, bar_ink(col))
	}
}

battery_alt: bool

clip_runes_bar :: proc(s: string, n: int) -> string {
	i := 0
	for _, off in s {
		if i == n {return strings.concatenate({strings.trim_right_space(s[:off]), "…"}, context.temp_allocator)}
		i += 1
	}
	return s
}

// ---- Clock ------------------------------------------------------------------------------

@(private = "file") BAR_DAYS := [7]string{"Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"}
@(private = "file") BAR_MONTHS := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}

bar_now :: proc() -> datetime.DateTime {
	if r, ok := clock_read(local_region, time.now()); ok {return r.dt}
	dt, _ := time.time_to_datetime(time.now())
	return dt
}

// The clock format: strftime-like, with <b>…</b> for bold.
bar_clock_text :: proc(format: string, dt: datetime.DateTime) -> (runs: [dynamic][2]string) {
	runs.allocator = context.temp_allocator
	b := strings.builder_make(context.temp_allocator)
	bold := false
	flush :: proc(runs: ^[dynamic][2]string, b: ^strings.Builder, bold: bool) {
		if strings.builder_len(b^) == 0 {return}
		append(runs, [2]string{strings.clone(strings.to_string(b^), context.temp_allocator), bold ? "b" : ""})
		strings.builder_reset(b)
	}
	wd := (weekday_of(dt) + 6) % 7 // 0 = Monday
	for i := 0; i < len(format); i += 1 {
		ch := format[i]
		if ch == '<' {
			if strings.has_prefix(format[i:], "<b>") {flush(&runs, &b, bold); bold = true; i += 2; continue}
			if strings.has_prefix(format[i:], "</b>") {flush(&runs, &b, bold); bold = false; i += 3; continue}
		}
		if ch != '%' || i + 1 >= len(format) {
			strings.write_byte(&b, ch)
			continue
		}
		i += 1
		h12 := int(dt.hour) % 12
		if h12 == 0 {h12 = 12}
		switch format[i] {
		case 'a': strings.write_string(&b, BAR_DAYS[wd][:3])
		case 'A': strings.write_string(&b, BAR_DAYS[wd])
		case 'b': strings.write_string(&b, BAR_MONTHS[dt.month - 1][:3])
		case 'B': strings.write_string(&b, BAR_MONTHS[dt.month - 1])
		case 'd': fmt.sbprintf(&b, "%02d", dt.day)
		case 'e': fmt.sbprintf(&b, "%s%d", dt.day < 10 ? " " : "", dt.day)
		case 'm': fmt.sbprintf(&b, "%02d", dt.month)
		case 'Y': fmt.sbprintf(&b, "%d", dt.year)
		case 'H': fmt.sbprintf(&b, "%02d", dt.hour)
		case 'I': fmt.sbprintf(&b, "%02d", h12)
		case 'M': fmt.sbprintf(&b, "%02d", dt.minute)
		case 'S': fmt.sbprintf(&b, "%02d", dt.second)
		case 'p': strings.write_string(&b, dt.hour < 12 ? "AM" : "PM")
		case '%': strings.write_byte(&b, '%')
		case:     strings.write_byte(&b, '%'); strings.write_byte(&b, format[i])
		}
	}
	flush(&runs, &b, bold)
	return
}

bar_clock_has_seconds :: proc() -> bool {return strings.contains(bar_cfg.clock, "%S")}

@(private = "file")
clock_segs :: proc(it: ^Bar_Item, format: string, col: u32) {
	for r in bar_clock_text(format, bar_now()) {
		seg(it, r[0], r[1] == "b" ? bar_pal.text : col, r[1] == "b" ? .Bold : .Regular)
	}
}

// This month as lines of text: title, weekday header, weeks (Monday first).
bar_calendar :: proc(dt: datetime.DateTime) -> (lines: [dynamic]string, today_line, today_col: int) {
	lines.allocator = context.temp_allocator
	append(&lines, fmt.tprintf("%s %d", BAR_MONTHS[dt.month - 1], dt.year))
	append(&lines, "Mo Tu We Th Fr Sa Su")
	first := dt
	first.day = 1
	start := (weekday_of(first) + 6) % 7
	days := 31
	for d := 31; d >= 28; d -= 1 {
		x := first
		x.day = i8(d)
		if _, err := datetime.date_to_ordinal(x.date); err == nil {days = d; break}
	}
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< start {strings.write_string(&b, "   ")}
	col := start
	for d in 1 ..= days {
		if d == int(dt.day) {today_line, today_col = len(lines), col}
		fmt.sbprintf(&b, "%s%d", d < 10 ? " " : "", d) // (%2d pads with zeros)
		col += 1
		if col == 7 {
			append(&lines, strings.clone(strings.to_string(b), context.temp_allocator))
			strings.builder_reset(&b)
			col = 0
		} else if d < days {
			strings.write_byte(&b, ' ')
		}
	}
	if strings.builder_len(b) > 0 {append(&lines, strings.clone(strings.to_string(b), context.temp_allocator))}
	return
}

// ---- Actions -------------------------------------------------------------------------------

Bar_Click :: struct {
	output:  string,
	center:  f32, // the item's centre, logical x on the output
	width:   f32, // the output's (bar's) width
	button:  u32,
	serial:  u32,
}

// Open (or close) a panel of the daemon under the clicked item.
@(private = "file")
toggle_panel :: proc(panel: string, ck: Bar_Click) {
	cmd := fmt.tprintf("toggle %s --at %s:%d:%d", panel, ck.output, int(ck.center), int(ck.width))
	if ipc_send(cmd) {return}
	// No daemon: start one with this panel.
	args := strings.fields(cmd, context.temp_allocator)
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, self_exe())
	append(&argv, ..args)
	launch_detached(argv[:])
}

self_exe :: proc() -> string {
	buf: [4096]u8
	n := posix.readlink("/proc/self/exe", &buf[0], len(buf))
	if n > 0 {return strings.clone(string(buf[:n]), context.temp_allocator)}
	return "wlperch"
}

bar_click :: proc(it: ^Bar_Item, ck: Bar_Click, open_menu: proc(t: ^Tray_Item, ck: Bar_Click)) {
	BTN_LEFT, BTN_RIGHT, BTN_MIDDLE :: 0x110, 0x111, 0x112
	switch it.mod {
	case .Workspaces:
		if ck.button == BTN_LEFT {sway_command(fmt.tprintf("workspace \"%s\"", sway_quote(it.key)))}
	case .Mode, .Window:
	case .Scratchpad:
		sway_command("scratchpad show")
	case .Idle:
		idle_inhibit_on = !idle_inhibit_on
	case .Power_Profile:
		sync.guard(&bar_data.mu)
		bar_data.cmd_ppd = ck.button == BTN_RIGHT ? -1 : 1
		sync.sema_post(&bar_data.wake)
	case .Backlight:
	case .Battery:
		battery_alt = !battery_alt
	case .Media:
		member := ""
		switch it.key {
		case "prev": member = "Previous"
		case "next": member = "Next"
		case:
			switch ck.button {
			case BTN_LEFT:   member = "PlayPause"
			case BTN_RIGHT:  toggle_panel("main", ck)
			}
		}
		if member != "" {
			sync.guard(&bar_data.mu)
			delete(bar_data.cmd_media)
			bar_data.cmd_media = strings.clone(member)
			sync.sema_post(&bar_data.wake)
		}
	case .Timer:
		toggle_panel("time", ck)
	case .Sensors:
		toggle_panel("sensors", ck)
	case .Memory:
		toggle_panel("system", ck)
	case .Clock, .Wlperch:
		toggle_panel("main", ck)
	case .Notifications:
		if ck.button == BTN_RIGHT {
			if !ipc_send("notify dnd") {return}
			bar_data_poke()
		} else {
			toggle_panel("notifications", ck)
		}
	case .Tray:
		t, _ := tray_find(it.key)
		if t == nil {return}
		x, y := i32(ck.center), i32(0)
		switch ck.button {
		case BTN_LEFT:
			pending_menu_click = ck
			tray_activate(t, x, y, proc(t: ^Tray_Item) {open_tray_menu_cb(t)})
		case BTN_MIDDLE:
			tray_secondary(t, x, y)
		case BTN_RIGHT:
			if t.menu != "" {open_menu(t, ck)} else {tray_secondary(t, x, y)}
		}
	}
}

// The click a tray Activate fallback (menu) belongs to.
pending_menu_click: Bar_Click
open_tray_menu_cb: proc(t: ^Tray_Item)

bar_scroll :: proc(it: ^Bar_Item, steps: int, horizontal: bool, output: string) {
	if steps == 0 {return}
	switch it.mod {
	case .Workspaces:
		if horizontal {return}
		sway_command(steps > 0 ? fmt.tprintf("focus output %s; workspace next_on_output", output) : fmt.tprintf("focus output %s; workspace prev_on_output", output))
	case .Backlight:
		sync.guard(&bar_data.mu)
		bar_data.cmd_bl += steps > 0 ? -5 : 5
		sync.sema_post(&bar_data.wake)
	case .Media:
		if it.key != "track" {return}
		sync.guard(&bar_data.mu)
		delete(bar_data.cmd_media)
		bar_data.cmd_media = strings.clone(steps > 0 ? "Next" : "Previous")
		sync.sema_post(&bar_data.wake)
	case .Tray:
		if t, _ := tray_find(it.key); t != nil {tray_scroll(t, i32(steps), horizontal)}
	case .Mode, .Scratchpad, .Window, .Idle, .Power_Profile, .Battery, .Timer, .Sensors, .Memory, .Clock, .Notifications, .Wlperch:
	}
}

sway_quote :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, `"`, `\"`, context.temp_allocator)
	return out
}
