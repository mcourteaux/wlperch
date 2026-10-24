// Performance histories (CPU, GPU, memory, VRAM, swap, temperatures, power)
// in two tiers: the last hour at 1 Hz, and one-minute averages for 7 days.
// Missing time (suspend, daemon not running, reboot) is stored as NaN, so the
// graphs show it as a gap. Persisted in perf.bin next to the other data files:
// periodically, on exit, before a re-exec, and on SIGTERM.
package main

import "core:encoding/endian"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

HISTORY_MAX :: 3600 // 1 h at 1 Hz
HISTORY_MINUTES :: 7 * 24 * 60 // 7 days of 1-minute averages
HISTORY_SPAN_MAX :: HISTORY_MINUTES * 60 // seconds: how far the graphs zoom out
PERF_MIB :: f64(1 << 20) // memory, swap and VRAM histories are in MiB
HISTORY_GAP :: 3 // seconds without a sample before that counts as a gap

History :: struct {
	data:   [HISTORY_MAX]f32, // 1 Hz, NaN = no sample
	head:   int, // index of next write
	count:  int,
	last:   i64, // unix second of the newest sample (0 = none yet)
	mins:   [HISTORY_MINUTES]f32, // per-minute averages, NaN = no sample
	mhead:  int,
	mcount: int,
	minute: i64, // unix minute being accumulated (acc / acc_n)
	acc:    f32,
	acc_n:  i32,
}

@(private = "file")
push_fine :: proc(h: ^History, v: f32) {
	h.data[h.head] = v
	h.head = (h.head + 1) % HISTORY_MAX
	h.count = min(h.count + 1, HISTORY_MAX)
}

@(private = "file")
push_minute :: proc(h: ^History, v: f32) {
	h.mins[h.mhead] = v
	h.mhead = (h.mhead + 1) % HISTORY_MINUTES
	h.mcount = min(h.mcount + 1, HISTORY_MINUTES)
}

history_push :: proc(h: ^History, v: f32) {
	history_push_at(h, v, time.to_unix_seconds(time.now()))
}

// `t`: unix seconds. Time since the previous sample beyond a few seconds is
// filled with NaN (in both tiers) so it draws as a gap.
history_push_at :: proc(h: ^History, v: f32, t: i64) {
	if h.last != 0 && t - h.last > HISTORY_GAP {
		for _ in 0 ..< min(t - h.last - 1, HISTORY_MAX) {push_fine(h, math.nan_f32())}
	}
	m := t / 60
	if h.minute == 0 {
		h.minute = m
	} else if m > h.minute { 	// (a clock going back keeps filling the current minute)
		push_minute(h, h.acc_n > 0 ? h.acc / f32(h.acc_n) : math.nan_f32())
		for _ in 0 ..< min(m - h.minute - 1, HISTORY_MINUTES) {push_minute(h, math.nan_f32())}
		h.minute, h.acc, h.acc_n = m, 0, 0
	}
	if !math.is_nan(v) {
		h.acc += v
		h.acc_n += 1
	}
	push_fine(h, v)
	h.last = t
}

// i = 0 is the oldest of the last n samples (1 Hz tier).
history_get :: proc(h: ^History, n, i: int) -> f32 {
	idx := (h.head - n + i + HISTORY_MAX * 2) % HISTORY_MAX
	return h.data[idx]
}

// k = 0 is the newest completed minute.
@(private = "file")
minute_get :: proc(h: ^History, k: int) -> f32 {
	return h.mins[(h.mhead - 1 - k + HISTORY_MINUTES * 2) % HISTORY_MINUTES]
}

// Average and maximum of the samples aged lo..hi seconds (inclusive) before
// `now`. The 1 Hz tier serves whatever it covers, older stretches come from
// the minute averages. ok = false: nothing but gaps in there.
history_stats :: proc(h: ^History, lo, hi: i64, now: i64) -> (avg, mx: f32, ok: bool) {
	if h.last == 0 || hi < lo {return}
	sum: f32
	n := 0
	mx = -max(f32)
	add :: proc(v: f32, sum, mx: ^f32, n: ^int) {
		if math.is_nan(v) {return}
		sum^ += v
		mx^ = max(mx^, v)
		n^ += 1
	}
	off := now - h.last // age of the newest sample
	if off <= HISTORY_GAP {off = 0} // live, this second's sample isn't in yet
	if hi - off <= i64(h.count) - 1 {
		for j in max(lo - off, 0) ..= hi - off {
			add(history_get(h, h.count, h.count - 1 - int(j)), &sum, &mx, &n)
		}
	} else {
		m_new, m_old := (now - lo) / 60, (now - hi) / 60
		if m_new >= h.minute && h.acc_n > 0 {add(h.acc / f32(h.acc_n), &sum, &mx, &n)}
		for m := min(m_new, h.minute - 1); m >= m_old; m -= 1 {
			k := h.minute - 1 - m
			if k >= i64(h.mcount) {break}
			add(minute_get(h, int(k)), &sum, &mx, &n)
		}
	}
	if n == 0 {return 0, 0, false}
	return sum / f32(n), mx, true
}

// Age in seconds (before `now`) of the oldest stored sample.
history_oldest_age :: proc(h: ^History, now: i64) -> i64 {
	if h.last == 0 {return 0}
	return max(now - h.last + i64(h.count), now - h.minute * 60 + i64(h.mcount) * 60)
}

// ---- perf.bin ------------------------------------------------------------------
//
// "WLP1", u32 version, i64 saved-at (unix s), u32 series count, then per
// series: u8 name length + name, i64 last, i64 minute, f32 acc, u32 acc_n,
// u32 n + n f32 (1 Hz tier, oldest first), u32 n + n f32 (minute tier,
// oldest first). Little-endian. Leading gaps are left out. Series are matched
// by name, so unknown ones are skipped and missing ones (no GPU) stay empty.
// Memory, swap and VRAM are absolute MiB, so a different RAM size after a
// reboot doesn't distort the old data.

PERF_MAGIC :: "WLP1"
PERF_VERSION :: 1

Perf_Series :: struct {
	name: string,
	h:    ^History,
}

perf_series :: proc() -> [9]Perf_Series {
	return {
		{"cpu", &sysmon.cpu},
		{"gpu", &sysmon.gpu},
		{"mem", &sysmon.mem},
		{"swap", &sysmon.swap},
		{"vram", &sysmon.vram},
		{"cpu_temp", &thermals.cpu_temp_h},
		{"gpu_temp", &thermals.gpu_temp_h},
		{"cpu_power", &thermals.cpu_power_h},
		{"gpu_power", &thermals.gpu_power_h},
	}
}

perf_encode :: proc(series: []Perf_Series, saved_at: i64, allocator := context.allocator) -> []byte {
	out: [dynamic]byte
	out.allocator = allocator
	put_u32 :: proc(out: ^[dynamic]byte, v: u32) {b: [4]byte; endian.put_u32(b[:], .Little, v); append(out, ..b[:])}
	put_i64 :: proc(out: ^[dynamic]byte, v: i64) {b: [8]byte; endian.put_i64(b[:], .Little, v); append(out, ..b[:])}
	put_f32 :: proc(out: ^[dynamic]byte, v: f32) {b: [4]byte; endian.put_f32(b[:], .Little, v); append(out, ..b[:])}
	reserve(&out, 64 + len(series) * 64)
	append(&out, PERF_MAGIC)
	put_u32(&out, PERF_VERSION)
	put_i64(&out, saved_at)
	put_u32(&out, u32(len(series)))
	for s in series {
		h := s.h
		append(&out, u8(len(s.name)))
		append(&out, s.name)
		put_i64(&out, h.last)
		put_i64(&out, h.minute)
		put_f32(&out, h.acc)
		put_u32(&out, u32(h.acc_n))
		skip := 0
		for skip < h.count && math.is_nan(history_get(h, h.count, skip)) {skip += 1}
		put_u32(&out, u32(h.count - skip))
		for i in skip ..< h.count {put_f32(&out, history_get(h, h.count, i))}
		skip = 0
		for skip < h.mcount && math.is_nan(minute_get(h, h.mcount - 1 - skip)) {skip += 1}
		put_u32(&out, u32(h.mcount - skip))
		for k := h.mcount - 1 - skip; k >= 0; k -= 1 {put_f32(&out, minute_get(h, k))}
	}
	return out[:]
}

// Fills the histories whose names match; false on a wrong magic/version or a
// damaged file (the histories may then be partly written: decode into scratch).
perf_decode :: proc(data: []byte, series: []Perf_Series) -> (saved_at: i64, ok: bool) {
	if len(data) < 20 || string(data[:4]) != PERF_MAGIC {return}
	if v, _ := endian.get_u32(data[4:8], .Little); v != PERF_VERSION {return}
	saved_at, _ = endian.get_i64(data[8:16], .Little)
	n_series, _ := endian.get_u32(data[16:20], .Little)
	pos := 20
	need :: proc(data: []byte, pos, n: int) -> bool {return n >= 0 && pos + n <= len(data)}
	for _ in 0 ..< n_series {
		if !need(data, pos, 1) {return}
		nlen := int(data[pos])
		pos += 1
		if !need(data, pos, nlen + 28) {return}
		name := string(data[pos:pos + nlen])
		pos += nlen
		h: ^History
		for s in series {if s.name == name {h = s.h}}
		last, _ := endian.get_i64(data[pos:], .Little)
		minute, _ := endian.get_i64(data[pos + 8:], .Little)
		acc, _ := endian.get_f32(data[pos + 16:], .Little)
		acc_n, _ := endian.get_u32(data[pos + 20:], .Little)
		nf, _ := endian.get_u32(data[pos + 24:], .Little)
		pos += 28
		if nf > HISTORY_MAX || !need(data, pos, int(nf) * 4 + 4) {return}
		fine := data[pos:pos + int(nf) * 4]
		pos += int(nf) * 4
		nm, _ := endian.get_u32(data[pos:], .Little)
		pos += 4
		if nm > HISTORY_MINUTES || !need(data, pos, int(nm) * 4) {return}
		mins := data[pos:pos + int(nm) * 4]
		pos += int(nm) * 4
		if h == nil {continue}
		h^ = {}
		for i in 0 ..< int(nf) {push_fine(h, endian.get_f32(fine[i * 4:], .Little) or_else 0)}
		for i in 0 ..< int(nm) {push_minute(h, endian.get_f32(mins[i * 4:], .Little) or_else 0)}
		h.last, h.minute, h.acc, h.acc_n = last, minute, acc, i32(acc_n)
	}
	return saved_at, pos == len(data)
}

@(private = "file")
perf_path_buf: string

perf_path :: proc() -> string {
	if perf_path_buf == "" {
		dir := data_dir()
		perf_path_buf = strings.concatenate({dir, "/perf.bin"})
		delete(dir)
	}
	return perf_path_buf
}

@(private = "file")
perf_save_mu: sync.Mutex

// Write the histories to `path` (tmp + rename). Safe from any thread.
perf_save_to :: proc(path: string) -> bool {
	sync.guard(&perf_save_mu)
	series := perf_series()
	data: []byte
	{
		sync.guard(&sysmon.mu)
		sync.guard(&thermals.mu)
		data = perf_encode(series[:], time.to_unix_seconds(time.now()))
	}
	defer delete(data)
	if dir, _ := os.split_path(path); dir != "" {os.make_directory_all(dir)}
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, data); err != nil {
		log.warnf("cannot write %s: %v", tmp, err)
		return false
	}
	if os.rename(tmp, path) != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}

perf_save :: proc() {perf_save_to(perf_path())}

// Load the histories from `path`. A damaged or foreign-version file is moved
// aside to <path>.bad; one older than the 7-day window is dropped.
perf_load_from :: proc(path: string, now: i64) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {return false}
	defer delete(data)
	scratch := make([]History, 9)
	defer delete(scratch)
	series := perf_series()
	tmp_series: [9]Perf_Series
	for s, i in series {tmp_series[i] = {s.name, &scratch[i]}}
	saved_at, ok := perf_decode(data, tmp_series[:])
	if !ok {
		bad := strings.concatenate({path, ".bad"}, context.temp_allocator)
		log.warnf("%s is damaged or from another version; moved to %s", path, bad)
		_ = os.rename(path, bad)
		return false
	}
	if now - saved_at > HISTORY_SPAN_MAX {
		log.infof("%s is older than 7 days; starting afresh", path)
		return false
	}
	sync.guard(&sysmon.mu)
	sync.guard(&thermals.mu)
	for s, i in series {s.h^ = scratch[i]}
	return true
}

perf_load :: proc() {perf_load_from(perf_path(), time.to_unix_seconds(time.now()))}

PERF_SAVE_EVERY :: 5 * time.Minute

// Saves every few minutes from its own thread: no UI wakeups.
perf_start_saver :: proc() {
	thread.create_and_start(proc() {
		for {
			time.sleep(PERF_SAVE_EVERY)
			perf_save()
			free_all(context.temp_allocator)
		}
	})
}

// Set by resume_from_args when the histories came over from the previous image.
perf_resumed: bool
