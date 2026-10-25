package main

import "core:encoding/ini"
import "core:testing"

@(test)
test_cpu_jiffies :: proc(t: ^testing.T) {
	// user nice system idle iowait irq softirq steal guest guest_nice
	a, ok := cpu_jiffies_parse("cpu  100 0 50 800 50 0 0 0 30 0")
	testing.expect(t, ok)
	testing.expect_value(t, a.total, 1000) // guest is part of user: not counted twice
	testing.expect_value(t, a.busy, 150) // idle and iowait aren't busy
	b, _ := cpu_jiffies_parse("cpu  160 0 70 860 60 10 0 0 0 0")
	// +90 busy (user, system, irq) of +160 total
	testing.expect(t, abs(cpu_busy_pct(a, b) - 100 * 90.0 / 160) < 0.01)
	core, cok := cpu_jiffies_parse("cpu3 1 2 3 4 5 6 7 8")
	testing.expect(t, cok)
	testing.expect_value(t, core.total, 36)
	_, bad := cpu_jiffies_parse("intr 12 34")
	testing.expect(t, !bad)
	// No baseline, a counter that went back, no time passed: 0.
	testing.expect_value(t, cpu_busy_pct({}, b), 0)
	testing.expect_value(t, cpu_busy_pct(b, a), 0)
	testing.expect_value(t, cpu_busy_pct(a, a), 0)
}

@(test)
test_cpu_graph_ring :: proc(t: ^testing.T) {
	testing.expect_value(t, cpu_graph_samples(2), 60)
	testing.expect_value(t, cpu_graph_samples(1), 120)
	testing.expect_value(t, cpu_graph_samples(30), 4)
	testing.expect_value(t, cpu_graph_samples(7), 17)
	testing.expect_value(t, cpu_graph_samples(0), 120) // clamped to 1 s
	testing.expect_value(t, cpu_graph_samples(99), 4) // clamped to 30 s

	saved := bar_cpu
	defer bar_cpu = saved
	bar_cpu = {}
	cpu_graph_configure(true, 30)
	g := &bar_cpu
	testing.expect_value(t, g.cap, 4)
	for v in ([]f32{10, 20, 30, 40, 50, 60}) {cpu_graph_push(g, v)}
	testing.expect_value(t, g.n, 4)
	testing.expect_value(t, g.vals[0], 30) // oldest kept
	testing.expect_value(t, g.vals[3], 60)
	now, avg, peak := cpu_graph_stats(g)
	testing.expect_value(t, now, 60)
	testing.expect_value(t, avg, 45)
	testing.expect_value(t, peak, 60)
	// The same interval keeps the history; another one starts afresh.
	cpu_graph_configure(true, 30)
	testing.expect_value(t, g.n, 4)
	cpu_graph_configure(true, 5)
	testing.expect_value(t, g.n, 0)
	testing.expect_value(t, g.cap, 24)
	cpu_graph_configure(false, 5)
	testing.expect_value(t, g.interval, 0)
	testing.expect_value(t, cpu_graph_timeout(), -1)
	testing.expect(t, !cpu_graph_tick())
}

@(test)
test_cpu_graph_config :: proc(t: ^testing.T) {
	saved := bar_cfg
	defer bar_cfg = saved
	defaults, _ := ini.load_map_from_string(DEFAULT_CONFIG, context.temp_allocator)
	bar_cfg = {}
	bar_config_load(defaults, defaults)
	testing.expect(t, bar_cfg.cpu_graph)
	testing.expect_value(t, bar_cfg.cpu_interval, 2)
	testing.expect_value(t, bar_cfg.cpu_width, 48)
	user, _ := ini.load_map_from_string("[bar]\ncpu_graph = off\ncpu_graph_interval = 90\n", context.temp_allocator)
	bar_cfg = {}
	bar_config_load(user, defaults)
	testing.expect(t, !bar_cfg.cpu_graph)
	testing.expect_value(t, bar_cfg.cpu_interval, 30)
}
