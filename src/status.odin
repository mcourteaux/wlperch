// `wlwidgets status`: a tiny standalone loop for a waybar custom module
// ("return-type": "json"). It draws attention when memory runs low.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

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

status_loop :: proc() {
	GiB :: f64(1 << 30)
	for {
		used, total, ok := read_meminfo()
		pct := ok ? int(f64(used) / f64(total) * 100 + 0.5) : 0
		warn := ok && memory_warning(used, total)
		text := warn ? fmt.tprintf("%s %d%%", ICON_TUNE_BAR, pct) : ICON_TUNE_BAR
		tooltip := fmt.tprintf("Quick settings\\nMemory %.1f / %.1f GiB (%d%%)", f64(used) / GiB, f64(total) / GiB, pct)
		class := warn ? "memory-warning" : "normal"
		line := fmt.tprintf(`{{"text": "%s", "tooltip": "%s", "class": "%s", "percentage": %d}}` + "\n", text, tooltip, class, pct)
		if _, err := os.write_string(os.stdout, line); err != nil {return} // waybar went away
		free_all(context.temp_allocator)
		time.sleep(2 * time.Second)
	}
}

// `wlwidgets status sensors`: "󰔏 20.4°  ● 439" — the bar_room temperature and
// the freshest CO2 reading; class co2-warn / co2-high when the air gets stale.
status_sensors_loop :: proc() {
	for {
		sensors_reload()
		temp_s, co2_s, tip: string
		class := "normal"
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
					case c.num > 1200: class = "co2-high"
					case c.num > 800:  class = "co2-warn"
					case:              class = "normal"
					}
				}
			}
			tip = strings.join(lines[:], "\\n", context.temp_allocator)
		}
		text := temp_s
		if co2_s != "" {text = fmt.tprintf("%s  %s", text, co2_s) if text != "" else co2_s}
		if text == "" {text = ICON_THERMOMETER}
		line := fmt.tprintf(`{{"text": "%s", "tooltip": "%s", "class": "%s"}}` + "\n", text, tip, class)
		if _, err := os.write_string(os.stdout, line); err != nil {return}
		free_all(context.temp_allocator)
		time.sleep(20 * time.Second)
	}
}
