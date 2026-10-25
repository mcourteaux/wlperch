// The bar's CPU graph: a sparkline of the last two minutes of CPU usage in
// the memory module's pill. The bar runs without the daemon, so it reads
// /proc/stat itself, on the main thread, once per [bar] cpu_graph_interval
// (aligned to the wall clock, so it shares wake-ups with the clock). One
// history serves every output's bar.
package main

import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

// Jiffies of one "cpu" line of /proc/stat.
Cpu_Jiffies :: struct {
	busy, total: u64,
}

// "cpu  4705 356 584 3699 23 23 0 0 0 0" -> busy / total jiffies. Idle and
// iowait are not busy; guest time (fields 9, 10) is already part of user.
cpu_jiffies_parse :: proc(line: string) -> (t: Cpu_Jiffies, ok: bool) {
	if !strings.has_prefix(line, "cpu") {return}
	rest := line
	i := 0
	first := true
	for f in strings.fields_iterator(&rest) {
		if first {first = false; continue} // "cpu" / "cpu3"
		if i >= 8 {break}
		v := strconv.parse_u64(f) or_else 0
		t.total += v
		if i != 3 && i != 4 {t.busy += v}
		i += 1
	}
	return t, i >= 4
}

// Busy percentage between two readings; 0 without a usable baseline.
cpu_busy_pct :: proc(prev, cur: Cpu_Jiffies) -> f32 {
	if prev.total == 0 || cur.total <= prev.total || cur.busy < prev.busy {return 0}
	return clamp(100 * f32(cur.busy - prev.busy) / f32(cur.total - prev.total), 0, 100)
}

CPU_GRAPH_SPAN :: 120 // seconds of history
LIM_BAR_CPU_INTERVAL :: Int_Limits{1, 30, 2}
LIM_BAR_CPU_WIDTH :: Int_Limits{20, 160, 48}

// Samples that cover the span at this interval (at least 2: a line needs two).
cpu_graph_samples :: proc(interval: int) -> int {
	return max(CPU_GRAPH_SPAN / clamp(interval, LIM_BAR_CPU_INTERVAL.lo, LIM_BAR_CPU_INTERVAL.hi), 2)
}

Cpu_Graph :: struct {
	vals:      [CPU_GRAPH_SPAN]f32, // oldest first
	n, cap:    int,
	interval:  int, // seconds; 0 = not sampling
	prev:      Cpu_Jiffies,
	next_at:   i64, // unix ns of the next sample
}
bar_cpu: Cpu_Graph

cpu_graph_push :: proc(g: ^Cpu_Graph, v: f32) {
	if g.cap <= 0 {return}
	if g.n >= g.cap {
		copy(g.vals[:], g.vals[g.n - g.cap + 1:g.n])
		g.n = g.cap - 1
	}
	g.vals[g.n] = v
	g.n += 1
}

cpu_graph_stats :: proc(g: ^Cpu_Graph) -> (now, avg, peak: f32) {
	if g.n == 0 {return}
	for v in g.vals[:g.n] {
		avg += v
		peak = max(peak, v)
	}
	return g.vals[g.n - 1], avg / f32(g.n), peak
}

// Starts, stops or re-times sampling to match the config. A new interval
// starts a new history (the old samples have another spacing).
cpu_graph_configure :: proc(on: bool, interval: int) {
	g := &bar_cpu
	iv := on ? clamp(interval, LIM_BAR_CPU_INTERVAL.lo, LIM_BAR_CPU_INTERVAL.hi) : 0
	if iv == g.interval {return}
	g^ = {}
	g.interval = iv
	g.cap = iv > 0 ? cpu_graph_samples(iv) : 0
}

@(private = "file")
cpu_read_total :: proc() -> (t: Cpu_Jiffies, ok: bool) {
	fd := posix.open("/proc/stat", {.CLOEXEC})
	if fd < 0 {return}
	defer posix.close(fd)
	buf: [256]u8 // the first line, the total, is all we need
	n := posix.read(fd, &buf[0], len(buf))
	if n <= 0 {return}
	s := string(buf[:n])
	if nl := strings.index_byte(s, '\n'); nl >= 0 {s = s[:nl]}
	return cpu_jiffies_parse(s)
}

// Time until the next sample; -1 while not sampling.
cpu_graph_timeout :: proc() -> time.Duration {
	g := &bar_cpu
	if g.interval == 0 {return -1}
	return max(time.Duration(g.next_at - time.to_unix_nanoseconds(time.now())), 0)
}

// Samples when due; true when the graph changed (redraw).
cpu_graph_tick :: proc() -> bool {
	g := &bar_cpu
	if g.interval == 0 {return false}
	now := time.to_unix_nanoseconds(time.now())
	if now < g.next_at {return false}
	iv := i64(g.interval) * i64(time.Second)
	g.next_at = (now / iv + 1) * iv
	cur, ok := cpu_read_total()
	if !ok {return false}
	first := g.prev.total == 0
	v := cpu_busy_pct(g.prev, cur)
	g.prev = cur
	if first {
		// The baseline: nothing to show yet, and the first sample spans at least half an interval.
		if g.next_at - now < iv / 2 {g.next_at += iv}
		return false
	}
	cpu_graph_push(g, v)
	return true
}
