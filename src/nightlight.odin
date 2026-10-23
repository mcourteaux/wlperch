// wlsunset on/off.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"

Nightlight :: struct {
	running: bool,
	pids:    [dynamic]posix.pid_t,
	pending: bool, // toggled, waiting for the process state to follow
}
nightlight: Nightlight

// Scan /proc for wlsunset processes owned by us.
nightlight_poll :: proc() {
	clear(&nightlight.pids)
	d, err := os.open("/proc")
	if err != nil {return}
	defer os.close(d)
	entries, _ := os.read_all_directory(d, context.temp_allocator)
	uid := posix.getuid()
	for e in entries {
		pid, ok := strconv.parse_int(e.name)
		if !ok {continue}
		comm, cerr := os.read_entire_file(fmt.tprintf("/proc/%d/comm", pid), context.temp_allocator)
		if cerr != nil || strings.trim_space(string(comm)) != "wlsunset" {continue}
		st: posix.stat_t
		if posix.stat(strings.clone_to_cstring(fmt.tprintf("/proc/%d", pid), context.temp_allocator), &st) == .OK && st.st_uid != uid {continue}
		append(&nightlight.pids, posix.pid_t(pid))
	}
	running := len(nightlight.pids) > 0
	if running != nightlight.running {nightlight.pending = false}
	nightlight.running = running
}

nightlight_command :: proc() -> (cmd: string, ok: bool) {
	cmd = config.nightlight_cmd
	if strings.contains(cmd, "{lat}") || strings.contains(cmd, "{lon}") {
		sync.guard(&weather.mu)
		if !weather.have_loc {return "", false}
		cmd, _ = strings.replace_all(cmd, "{lat}", fmt.tprintf("%.4f", weather.lat), context.temp_allocator)
		cmd, _ = strings.replace_all(cmd, "{lon}", fmt.tprintf("%.4f", weather.lon), context.temp_allocator)
	}
	return cmd, true
}

nightlight_set :: proc(on: bool) {
	if on {
		cmd, ok := nightlight_command()
		if !ok {return}
		launch_shell(cmd)
	} else {
		for pid in nightlight.pids {posix.kill(pid, .SIGTERM)}
	}
	nightlight.pending = true
	nightlight.running = on
}
