// `wlwidgets status`: a tiny standalone loop for a waybar custom module
// ("return-type": "json"). It draws attention when memory runs low.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
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
