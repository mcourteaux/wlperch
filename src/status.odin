// `wlperch status`: tiny standalone loops for waybar custom modules
// ("return-type": "json"). The *_item procs compute what they show; the bar
// (bar_modules.odin) uses the same ones.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

// One module's state: tooltip lines are separated by real newlines.
Status_Item :: struct {
	text, tooltip, class: string,
	project:              string, // the timer's, for the bar's colour
}

// A waybar JSON line for it.
status_json :: proc(it: Status_Item) -> string {
	esc :: proc(s: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		for r in s {
			switch r {
			case '"':  strings.write_string(&b, `\"`)
			case '\\': strings.write_string(&b, `\\`)
			case '\n': strings.write_string(&b, `\n`)
			case:      if r >= 0x20 {strings.write_rune(&b, r)}
			}
		}
		return strings.to_string(b)
	}
	return fmt.tprintf(`{{"text": "%s", "tooltip": "%s", "class": "%s"}}` + "\n", esc(it.text), esc(it.tooltip), esc(it.class))
}

read_meminfo :: proc() -> (used, total: u64, ok: bool) {
	data, err := os.read_entire_file("/proc/meminfo", context.temp_allocator)
	if err != nil {return}
	avail: u64
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 2 {continue}
		v, _ := strconv.parse_u64(f[1])
		switch f[0] {
		case "MemTotal:":     total = v * 1024
		case "MemAvailable:": avail = v * 1024
		}
	}
	if total == 0 {return}
	mem_test_override(total, &avail)
	return total - avail, total, true
}

memory_warning :: proc(used, total: u64) -> bool {
	return total > 0 && f64(used) / f64(total) * 100 >= f64(config.memory_warn_pct)
}

// The quick-settings button: red with the percentage when memory runs low.
status_main_item :: proc() -> (it: Status_Item, pct: int) {
	GiB :: f64(1 << 30)
	used, total, ok := read_meminfo()
	pct = ok ? int(f64(used) / f64(total) * 100 + 0.5) : 0
	warn := ok && memory_warning(used, total)
	it.text = warn ? fmt.tprintf("%s %d%%", ICON_TUNE_BAR, pct) : ICON_TUNE_BAR
	it.tooltip = fmt.tprintf("Quick settings\nMemory %.1f / %.1f GiB (%d%%)", f64(used) / GiB, f64(total) / GiB, pct)
	it.class = warn ? "memory-warning" : "normal"
	return
}

status_loop :: proc() {
	for {
		it, pct := status_main_item()
		line := status_json(it)
		line = fmt.tprintf("%s, \"percentage\": %d}}\n", line[:len(line) - 2], pct)
		if _, err := os.write_string(os.stdout, line); err != nil {return} // waybar went away
		free_all(context.temp_allocator)
		time.sleep(2 * time.Second)
	}
}

// "󰔏 20.4°  ● 439": the bar_room temperature and the freshest CO2 reading;
// class co2-warn / co2-high when the air gets stale, "none" when no sensors
// are configured. Callers set sensors_read_only first.
status_sensors_item :: proc() -> (it: Status_Item) {
	if !sensors_configured() {return {class = "none"}}
	sensors_reload()
	temp_s, co2_s: string
	it.class = "normal"
	{
		sync.guard(&sensors.mu)
		room: ^Sensor_Device
		for &d in sensors.devices {
			if d.kind != .Climate {continue}
			if room == nil || strings.equal_fold(d.name, config.sensors_bar_room) {room = &d}
			if strings.equal_fold(d.name, config.sensors_bar_room) {break}
		}
		if room != nil {
			if v, ok := sensor_value(room, "va_temperature"); ok && v.is_num {
				temp_s = fmt.tprintf("%s %.1f°", ICON_THERMOMETER, v.num)
			}
		}
		best_t: f64
		lines: [dynamic]string
		lines.allocator = context.temp_allocator
		for &d in sensors.devices {
			t, tok := sensor_value(&d, "va_temperature")
			if !tok {t, tok = sensor_value(&d, "temp_current")}
			h, hok := sensor_value(&d, "humidity_value")
			if tok && t.is_num {
				line := fmt.tprintf("%s: %.1f°", d.name, t.num)
				if hok && h.is_num {line = fmt.tprintf("%s  %.0f%%", line, h.num)}
				append(&lines, fmt.tprintf("%s  (%s)", line, age_text(d.last_t)))
			}
			if c, ok := sensor_value(&d, "co2_value"); ok && c.is_num && c.t > best_t {
				best_t = c.t
				co2_s = fmt.tprintf("%.0f ppm", c.num)
				switch {
				case c.num > 1200: it.class = "co2-high"
				case c.num > 800:  it.class = "co2-warn"
				case:              it.class = "normal"
				}
			}
		}
		it.tooltip = strings.join(lines[:], "\n", context.temp_allocator)
	}
	it.text = temp_s
	if co2_s != "" {it.text = fmt.tprintf("%s  %s", it.text, co2_s) if it.text != "" else co2_s}
	if it.text == "" {it.text = ICON_THERMOMETER}
	return
}

// `wlperch status sensors`.
status_sensors_loop :: proc() {
	sensors_read_only = true
	for {
		it := status_sensors_item()
		// Nothing to show: an empty text hides the waybar module.
		if _, err := os.write_string(os.stdout, status_json(it)); err != nil {return}
		free_all(context.temp_allocator)
		time.sleep(it.class == "none" ? time.Minute : 20 * time.Second)
	}
}

// A bell with the unread count; bell-off under do not disturb.
status_notifications_item :: proc() -> (it: Status_Item) {
	it = {text = ICON_BELL, class = "none", tooltip = "Notifications"}
	if reply, ok := ipc_query("notify status"); ok {
		f := strings.fields(reply, context.temp_allocator)
		if len(f) >= 3 {
			unread, _ := strconv.parse_int(f[0])
			dnd := f[1] == "1"
			owner := f[2] == "1"
			switch {
			case !owner:
				it.class = "off"
				it.tooltip = "Another program shows notifications (see wlperch setup)"
			case dnd:
				it.text = unread > 0 ? fmt.tprintf("%s %d", ICON_BELL_OFF, unread) : ICON_BELL_OFF
				it.class = "dnd"
				it.tooltip = unread > 0 ? fmt.tprintf("Do not disturb · %d new", unread) : "Do not disturb"
			case unread > 0:
				it.text = fmt.tprintf("%s %d", ICON_BELL, unread)
				it.class = "unread"
				it.tooltip = fmt.tprintf("%d new notification%s", unread, unread == 1 ? "" : "s")
			case:
				it.tooltip = "No new notifications"
			}
			// A fullscreen game keeps popups off its monitor: a small gamepad.
			if owner && len(f) >= 6 && f[4] != "-" {
				held, _ := strconv.parse_int(f[3])
				what := f[4] == "game" ? "a game is" : "an app is"
				outs, _ := strings.replace_all(f[5], ",", ", ", context.temp_allocator)
				it.text = fmt.tprintf("%s %s", it.text, f[4] == "game" ? ICON_GAMEPAD : ICON_FULLSCREEN)
				if held > 0 {
					it.tooltip = fmt.tprintf("%s\n%d popup%s held while %s fullscreen on %s", it.tooltip, held, held == 1 ? "" : "s", what, outs)
				} else {
					it.tooltip = fmt.tprintf("%s\nPopups keep off %s while %s fullscreen there", it.tooltip, outs, what)
				}
			}
		}
	} else {
		it.class = "off"
		it.tooltip = "wlperch is not running"
	}
	it.tooltip = strings.concatenate({it.tooltip, "\nClick: notifications · right click: do not disturb"}, context.temp_allocator)
	return
}

// `wlperch status notifications`.
status_notifications_loop :: proc() {
	for {
		if _, err := os.write_string(os.stdout, status_json(status_notifications_item())); err != nil {return}
		free_all(context.temp_allocator)
		time.sleep(time.Second)
	}
}

// "⏱ NeonRAW 1:23" (today's time on the project being counted), or a dim
// clock when nothing is counted. While you're away from a project that
// bridges short breaks and might still come back in time, it shows the
// project dimmed ("waiting"): the gap is added when you're back, not ticked
// up meanwhile. With nothing of yours counting, a project Claude is working
// on (with claude_counts) shows instead ("claude"). Paid jobs get ICON_PAYING
// and Claude at work on the shown project ICON_CLAUDE. Needs clocks_init
// (local day start) and the projects loaded (bridge_rules).
status_timer_item :: proc() -> (it: Status_Item) {
	dir := data_dir()
	defer delete(dir)
	cur_path := strings.concatenate({dir, "/timetracker.current"}, context.temp_allocator)
	away_path := strings.concatenate({dir, "/timetracker.away"}, context.temp_allocator)
	claude_path := strings.concatenate({dir, "/timetracker.claude"}, context.temp_allocator)
	log_path := strings.concatenate({dir, "/timelog.tsv"}, context.temp_allocator)
	it = {text = ICON_CLOCK, class = "idle", tooltip = "Time tracking: not on a project workspace"}
	now := time.to_unix_seconds(time.now())
	// A fresh heartbeat: the daemon is counting (or away, for the break file).
	read_state :: proc(path: string, now: i64) -> (start: i64, project: string, ok: bool) {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {return}
		f := strings.split(strings.trim_space(string(data)), "\t", context.temp_allocator)
		if len(f) < 3 {return}
		s, _ := strconv.parse_i64(f[0])
		beat, _ := strconv.parse_i64(f[1])
		return s, f[2], now - beat < 90
	}
	start, project, running := read_state(cur_path, now)
	away_start, away_project, away := read_state(away_path, now)
	rules := bridge_rules()
	waiting := !running && away && away_project != NO_PROJECT && bridge_limit(rules, away_project) > now - away_start
	// Claude's open stretches, rewritten at least every heartbeat.
	claude_data, _ := os.read_entire_file(claude_path, context.temp_allocator)
	claude: [dynamic]Claude_Seg
	claude.allocator = context.temp_allocator
	for c in claude_state_parse(string(claude_data)) {
		if now - c.last < 90 && claude_counts(rules, c.project) {append(&claude, c)}
	}
	if !running && !waiting {
		if len(claude) == 0 {return}
		project = claude[0].project
	}
	entries: [dynamic]Time_Entry
	entries.allocator = context.temp_allocator
	if ld, lerr := os.read_entire_file(log_path, context.temp_allocator); lerr == nil {
		context.allocator = context.temp_allocator // the project names too
		timelog_parse(string(ld), &entries)
	}
	if running {append(&entries, Time_Entry{start, now, project, false, false, false})}
	if waiting {
		project = away_project
		append(&entries, Time_Entry{away_start, now, project, true, false, false})
	}
	claude_here := false
	for c in claude {
		append(&entries, Time_Entry{c.start, now, c.project, false, false, true})
		claude_here ||= c.project == project
	}
	day := local_day_start(now)
	total: i64
	for e in tracker_fold(entries[:], rules) {
		if e.project == project && (!e.idle || e.bridged) && e.end > day {total += e.end - max(e.start, day)}
	}
	it.project = project
	marks := fmt.tprintf("%s%s", rules_paying(rules, project) ? " " + ICON_PAYING : "", claude_here ? " " + ICON_CLAUDE : "")
	it.text = fmt.tprintf("%s %s%s %s", ICON_CLOCK, project, marks, fmt_duration(total))
	claude_line := claude_here ? "\nClaude is working on it: that counts too" : ""
	// Paying: the money made today, in every tooltip.
	money := ""
	if rate := project_rate(project); rate > 0 {money = fmt.tprintf(" · %s", fmt_money(f64(total) / 3600 * rate))}
	switch {
	case running:
		it.class = "running"
		it.tooltip = fmt.tprintf("%s: %s today%s%s", project, fmt_duration(total), money, claude_line)
	case waiting:
		limit := bridge_limit(rules, project)
		it.class = "waiting"
		it.tooltip = fmt.tprintf("%s: %s today%s\nAway %s: back within %s and it counts as work\n(breaks under %d min bridge on %s)%s", project, fmt_duration(total), money, fmt_duration(now - away_start, true), fmt_duration(limit - (now - away_start), true), limit / 60, project, claude_line)
	case:
		it.class = "claude"
		it.tooltip = fmt.tprintf("%s: %s today%s\nClaude is working on it, so it counts while you're elsewhere", project, fmt_duration(total), money)
	}
	return
}

// `wlperch status timer`.
status_timer_loop :: proc() {
	for {
		if _, err := os.write_string(os.stdout, status_json(status_timer_item())); err != nil {return}
		free_all(context.temp_allocator)
		time.sleep(2 * time.Second)
	}
}
