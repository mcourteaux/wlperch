package main

import "core:math"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
T0 :: i64(1_789_999_980) // a whole minute

@(test)
test_perf_history_gap :: proc(t: ^testing.T) {
	h := new(History)
	defer free(h)
	for i in 0 ..< i64(120) {history_push_at(h, 10, T0 + i)}
	// Daemon down for 10 minutes, then back.
	back := T0 + 119 + 600
	for i in 0 ..< i64(5) {history_push_at(h, 50, back + i)}
	now := back + 4

	avg, _, ok := history_stats(h, 0, 4, now)
	testing.expect(t, ok && avg == 50)
	// Inside the gap: nothing in either tier.
	_, _, ok = history_stats(h, 100, 500, now)
	testing.expect(t, !ok, "gap in the 1 Hz tier")
	// Before the gap: the old samples, not squeezed against the new ones.
	avg, _, ok = history_stats(h, 610, 700, now)
	testing.expect(t, ok && avg == 10)
	// Jitter of a second or two is not a gap.
	j := new(History)
	defer free(j)
	history_push_at(j, 1, T0)
	history_push_at(j, 1, T0 + 2)
	testing.expect_value(t, j.count, 2)

	// Minute tier: a gap of more than an hour leaves the 1 Hz tier all gap
	// and keeps the old minutes at their true age.
	later := now + 3 * 3600
	history_push_at(h, 30, later)
	testing.expect_value(t, h.count, HISTORY_MAX)
	_, _, ok = history_stats(h, 1, HISTORY_MAX - 1, later)
	testing.expect(t, !ok, "1 Hz tier is all gap")
	avg, _, ok = history_stats(h, later - T0 - 120, later - T0, later) // the first two minutes
	testing.expect(t, ok && avg == 10)
	_, _, ok = history_stats(h, 3600 + 60, 3 * 3600 - 60, later)
	testing.expect(t, !ok, "gap in the minute tier")
	testing.expect(t, history_oldest_age(h, later) >= later - T0)
}

@(test)
test_perf_history_seven_days :: proc(t: ^testing.T) {
	h := new(History)
	defer free(h)
	for i in 0 ..< i64(600) {history_push_at(h, 42, T0 + i)}
	testing.expect_value(t, h.mcount, 9)
	// Eight days later nothing old is left in either tier.
	now := T0 + 8 * 86400
	history_push_at(h, 7, now)
	testing.expect_value(t, h.mcount, HISTORY_MINUTES)
	for k in 0 ..< h.mcount {
		v := h.mins[k]
		testing.expect(t, math.is_nan(v), "old minute survived")
		if !math.is_nan(v) {break}
	}
	_, mx, ok := history_stats(h, 0, HISTORY_SPAN_MAX, now)
	testing.expect(t, ok && mx == 7)
}

@(test)
test_perf_file_roundtrip :: proc(t: ^testing.T) {
	a := make([]History, 3)
	defer delete(a)
	for i in 0 ..< i64(4000) {history_push_at(&a[0], f32(i % 100), T0 + i)} // wraps the 1 Hz ring
	for i in 0 ..< i64(30) {history_push_at(&a[1], 12345.5, T0 + i)} // e.g. MiB
	// a[2] stays empty (no GPU).
	src := []Perf_Series{{"cpu", &a[0]}, {"mem", &a[1]}, {"gpu", &a[2]}}
	data := perf_encode(src, T0 + 5000)
	defer delete(data)

	b := make([]History, 4)
	defer delete(b)
	// Order differs, one series unknown to the file, one in the file unknown here.
	dst := []Perf_Series{{"mem", &b[0]}, {"cpu", &b[1]}, {"gpu", &b[2]}, {"new", &b[3]}}
	saved, ok := perf_decode(data, dst[:2])
	testing.expect(t, ok)
	testing.expect_value(t, saved, T0 + 5000)
	saved, ok = perf_decode(data, dst)
	testing.expect(t, ok)
	for p in ([][2]^History{{&a[0], &b[1]}, {&a[1], &b[0]}, {&a[2], &b[2]}}) {
		x, y := p[0], p[1]
		testing.expect_value(t, y.count, x.count)
		testing.expect_value(t, y.mcount, x.mcount)
		testing.expect_value(t, y.last, x.last)
		testing.expect_value(t, y.minute, x.minute)
		testing.expect_value(t, y.acc_n, x.acc_n)
		for i in 0 ..< x.count {
			if history_get(x, x.count, i) != history_get(y, y.count, i) {
				testing.expectf(t, false, "sample %d differs", i)
				break
			}
		}
		now := x.last + 10
		ax, mx, okx := history_stats(x, 0, 5000, now)
		ay, my, oky := history_stats(y, 0, 5000, now)
		testing.expect(t, okx == oky && ax == ay && mx == my)
	}
	testing.expect_value(t, b[3].count, 0)
	// Leading gaps aren't stored.
	g := new(History)
	defer free(g)
	history_push_at(g, 1, T0)
	history_push_at(g, 2, T0 + 5000) // the 1 Hz tier is all gap but this one
	gd := perf_encode([]Perf_Series{{"x", g}}, T0)
	defer delete(gd)
	testing.expect_value(t, g.count, HISTORY_MAX)
	testing.expect(t, len(gd) < 20 + 2 + 36 + 4 * 100, "gaps take no room")
}

@(test)
test_perf_file_damaged :: proc(t: ^testing.T) {
	h := new(History)
	defer free(h)
	for i in 0 ..< i64(100) {history_push_at(h, 3, T0 + i)}
	data := perf_encode([]Perf_Series{{"cpu", h}}, T0 + 100)
	defer delete(data)
	out := new(History)
	defer free(out)
	dst := []Perf_Series{{"cpu", out}}
	for cut in ([]int{0, 3, 19, 30, len(data) - 1}) {
		_, ok := perf_decode(data[:cut], dst)
		testing.expectf(t, !ok, "truncated at %d accepted", cut)
	}
	bad := make([]byte, len(data))
	defer delete(bad)
	copy(bad, data)
	bad[4] = 99 // version
	_, ok := perf_decode(bad, dst)
	testing.expect(t, !ok, "foreign version accepted")
	copy(bad, data)
	bad[0] = 'X'
	_, ok = perf_decode(bad, dst)
	testing.expect(t, !ok, "wrong magic accepted")
	_, ok = perf_decode(transmute([]byte)string("not a perf file at all, really"), dst)
	testing.expect(t, !ok)

	// On disk: a damaged file is moved aside, the histories stay as they were.
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if !strings.has_prefix(tmp, "/") {tmp = "/tmp"}
	dir := strings.concatenate({tmp, "/wlperch-perf-test"}, context.temp_allocator)
	os.make_directory_all(dir)
	path := strings.concatenate({dir, "/perf.bin"}, context.temp_allocator)
	_ = os.write_entire_file(path, data[:len(data) - 7])
	sysmon.cpu.last = 4242
	testing.expect(t, !perf_load_from(path, T0 + 200))
	testing.expect_value(t, sysmon.cpu.last, 4242)
	testing.expect(t, !os.exists(path))
	testing.expect(t, os.exists(strings.concatenate({path, ".bad"}, context.temp_allocator)))
	// A good file older than 7 days is ignored.
	_ = os.write_entire_file(path, data)
	testing.expect(t, !perf_load_from(path, T0 + 8 * 86400))
	testing.expect(t, perf_load_from(path, T0 + 200))
	testing.expect_value(t, sysmon.cpu.last, T0 + 99)
	sysmon.cpu = {}
	_ = os.remove(path)
	_ = os.remove(strings.concatenate({path, ".bad"}, context.temp_allocator))
	_ = os.remove(dir)
}
