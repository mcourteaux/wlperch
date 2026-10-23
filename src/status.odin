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
// clock when nothing is counted. Needs clocks_init (local day start).
status_timer_item :: proc() -> (it: Status_Item) {
	dir := data_dir()
	defer delete(dir)
	cur_path := strings.concatenate({dir, "/timetracker.current"}, context.temp_allocator)
	log_path := strings.concatenate({dir, "/timelog.tsv"}, context.temp_allocator)
	it = {text = ICON_CLOCK, class = "idle", tooltip = "Time tracking: not on a project workspace"}
	if data, err := os.read_entire_file(cur_path, context.temp_allocator); err == nil {
		f := strings.split(strings.trim_space(string(data)), "\t", context.temp_allocator)
		if len(f) >= 3 {
			start, _ := strconv.parse_i64(f[0])
			beat, _ := strconv.parse_i64(f[1])
			now := time.to_unix_seconds(time.now())
			if now - beat < 90 { // heartbeat is fresh: the daemon is counting
				project := f[2]
				total := now - start
				entries: [dynamic]Time_Entry
				entries.allocator = context.temp_allocator
				if ld, lerr := os.read_entire_file(log_path, context.temp_allocator); lerr == nil {
					timelog_parse(string(ld), &entries)
				}
				day := local_day_start(now)
				for e in entries {
					if e.project == project && !e.idle && e.end > day {total += e.end - max(e.start, day)}
					delete(e.project)
				}
				it.text = fmt.tprintf("%s %s %s", ICON_CLOCK, project, fmt_duration(total))
				it.class = "running"
				it.tooltip = fmt.tprintf("%s: %s today", project, fmt_duration(total))
			}
		}
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
