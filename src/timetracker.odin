// Time tracking by workspace: every project gets one workspace per monitor
// ("NeonRAW 1", "NeonRAW 2"). Time counts while one of them is focused and
// the user isn't idle; numbered workspaces are not counted.
//
// Log: <data>/timelog.tsv, one finished segment per line:
//   2026-10-23T11:05:00Z<TAB>2026-10-23T12:40:10Z<TAB>Project<TAB>Client
// The open segment is kept in <data>/timetracker.current (start, last heartbeat,
// project) so a crash loses at most one heartbeat interval.
package main

import "core:encoding/ini"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

HEARTBEAT :: 30 * time.Second
MIN_SEGMENT :: 5 // seconds; shorter visits aren't logged

Project :: struct {
	key:    string, // section name: [project.KEY]
	name:   string,
	client: string, // "" = personal
	color:  u32,
}

Time_Entry :: struct {
	start, end: i64, // unix seconds
	project:    string,
}

Tracker :: struct {
	projects:   [dynamic]Project,
	entries:    [dynamic]Time_Entry,
	running:    int, // index into projects, -1 = not counting
	seg_start:  i64,
	last_beat:  time.Tick,
	paused_idle: bool,
	log_path:   string,
	cur_path:   string,
	idle:       time.Duration,
}
tracker := Tracker{running = -1}

PROJECT_COLORS := [?]u32{C_BLUE, C_GREEN, C_ORANGE, C_PURPLE, C_CYAN, C_YELLOW, C_TEAL, C_RED}

data_dir :: proc() -> string {
	base := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if base == "" {base = strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.local/share"}, context.temp_allocator)}
	return strings.concatenate({base, "/wlwidgets"})
}

parse_hex_color :: proc(s: string) -> (u32, bool) {
	h := strings.trim_prefix(strings.trim_space(s), "#")
	if len(h) != 6 {return 0, false}
	v, ok := strconv.parse_u64_of_base(h, 16)
	return u32(v), ok
}

// [project.*] sections in file order.
projects_load :: proc(src: string, m: ini.Map) {
	text := src
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if !strings.has_prefix(l, "[project.") || !strings.has_suffix(l, "]") {continue}
		section := l[1:len(l) - 1]
		kv := m[section]
		p := Project {
			key    = strings.clone(section[len("project."):]),
			name   = strings.clone(unquote(strings.trim_space(kv["name"]))),
			client = strings.clone(unquote(strings.trim_space(kv["client"]))),
			color  = PROJECT_COLORS[len(tracker.projects) % len(PROJECT_COLORS)],
		}
		if p.name == "" {p.name = p.key}
		if c, ok := parse_hex_color(unquote(kv["color"])); ok {p.color = c}
		append(&tracker.projects, p)
	}
}

project_find :: proc(name: string) -> int {
	for p, i in tracker.projects {
		if strings.equal_fold(p.name, name) || strings.equal_fold(p.key, name) {return i}
	}
	return -1
}

// "NeonRAW 2" -> index of NeonRAW
project_for_workspace :: proc(ws: string) -> int {
	for p, i in tracker.projects {
		if !strings.has_prefix(ws, p.name) {continue}
		rest := ws[len(p.name):]
		if len(rest) >= 2 && rest[0] == ' ' {
			if _, ok := strconv.parse_int(rest[1:]); ok {return i}
		}
	}
	return -1
}

project_workspace :: proc(p: Project, n: int) -> string {
	return fmt.tprintf("%s %d", p.name, n)
}

// ---- Time formatting -----------------------------------------------------

@(private = "file")
iso_utc :: proc(t: i64) -> string {
	dt, _ := time.time_to_datetime(time.unix(t, 0))
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second)
}

@(private = "file")
parse_iso_utc :: proc(s: string) -> (unix: i64, ok: bool) {
	if len(s) < 20 {return 0, false}
	y := strconv.parse_int(s[0:4]) or_return
	mo := strconv.parse_int(s[5:7]) or_return
	d := strconv.parse_int(s[8:10]) or_return
	h := strconv.parse_int(s[11:13]) or_return
	mi := strconv.parse_int(s[14:16]) or_return
	se := strconv.parse_int(s[17:19]) or_return
	t := time.datetime_to_time(y, mo, d, h, mi, se) or_return
	return time.to_unix_seconds(t), true
}

fmt_duration :: proc(secs: i64, with_seconds := false) -> string {
	s := max(secs, 0)
	if with_seconds {return fmt.tprintf("%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)}
	return fmt.tprintf("%d:%02d", s / 3600, (s / 60) % 60)
}

// ---- Log -----------------------------------------------------------------

@(private = "file")
append_entry :: proc(e: Time_Entry, client: string) {
	line := fmt.tprintf("%s\t%s\t%s\t%s\n", iso_utc(e.start), iso_utc(e.end), e.project, client)
	f, err := os.open(tracker.log_path, {.Write, .Create, .Append}, os.Permissions_Default_File)
	if err != nil {
		log.errorf("time log %s: %v", tracker.log_path, err)
		return
	}
	defer os.close(f)
	os.write_string(f, line)
	append(&tracker.entries, Time_Entry{e.start, e.end, strings.clone(e.project)})
}

timelog_parse :: proc(data: string, out: ^[dynamic]Time_Entry) {
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 3 {continue}
		s, ok1 := parse_iso_utc(f[0])
		e, ok2 := parse_iso_utc(f[1])
		if !ok1 || !ok2 || e <= s {continue}
		append(out, Time_Entry{s, e, strings.clone(f[2])})
	}
}

@(private = "file")
write_current :: proc(now: i64) {
	p := tracker.projects[tracker.running]
	_ = os.write_entire_file(tracker.cur_path, fmt.tprintf("%d\t%d\t%s\t%s\n", tracker.seg_start, now, p.name, p.client))
}

@(private = "file")
close_segment :: proc(end: i64) {
	if tracker.running < 0 {return}
	p := tracker.projects[tracker.running]
	if end - tracker.seg_start >= MIN_SEGMENT {
		append_entry({tracker.seg_start, end, p.name}, p.client)
	}
	os.remove(tracker.cur_path)
	tracker.running = -1
}

// Read the log and recover a segment left open by a crash.
tracker_init :: proc() {
	dir := data_dir()
	os.make_directory_all(dir)
	tracker.log_path = strings.concatenate({dir, "/timelog.tsv"})
	tracker.cur_path = strings.concatenate({dir, "/timetracker.current"})
	if data, err := os.read_entire_file(tracker.log_path, context.temp_allocator); err == nil {
		timelog_parse(string(data), &tracker.entries)
	}
	if data, err := os.read_entire_file(tracker.cur_path, context.temp_allocator); err == nil {
		f := strings.split(strings.trim_space(string(data)), "\t", context.temp_allocator)
		if len(f) >= 3 {
			s, _ := strconv.parse_i64(f[0])
			e, _ := strconv.parse_i64(f[1])
			client := len(f) > 3 ? f[3] : ""
			if e - s >= MIN_SEGMENT {append_entry({s, e, f[2]}, client)}
		}
		os.remove(tracker.cur_path)
	}
	if len(tracker.projects) > 0 && !platform_watch_idle(tracker.idle) {
		log.warn("compositor lacks ext-idle-notify-v1: idle time will be counted")
	}
}

// Called every main-loop iteration: follow workspace focus and idleness.
tracker_tick :: proc() {
	if len(tracker.projects) == 0 {return}
	ws: string
	{
		sync.guard(&sway.mu)
		ws = strings.clone(sway.focused_ws, context.temp_allocator)
	}
	want := plat.idle ? -1 : project_for_workspace(ws)
	now := time.to_unix_seconds(time.now())
	if want != tracker.running {
		if tracker.running >= 0 {
			end := now
			if plat.idle {end = max(time.to_unix_seconds(plat.idle_since), tracker.seg_start)}
			close_segment(end)
		}
		tracker.paused_idle = plat.idle && project_for_workspace(ws) >= 0
		if want >= 0 {
			tracker.running = want
			tracker.seg_start = now
			tracker.last_beat = time.tick_now()
			write_current(now)
		}
		request_redraw()
	} else if tracker.running >= 0 && time.tick_since(tracker.last_beat) >= HEARTBEAT {
		tracker.last_beat = time.tick_now()
		write_current(now)
	}
	if !plat.idle {tracker.paused_idle = false}
}

// How long the main loop may sleep before the next heartbeat is due.
tracker_timeout :: proc() -> time.Duration {
	if tracker.running < 0 {return -1}
	return max(HEARTBEAT - time.tick_since(tracker.last_beat), 0)
}

tracker_shutdown :: proc() {
	close_segment(time.to_unix_seconds(time.now()))
}

// Create (or recreate) the project's workspaces, one per active output in
// left-to-right order, pin them to their outputs and show them.
tracker_start :: proc(index: int) {
	if index < 0 || index >= len(tracker.projects) {return}
	p := tracker.projects[index]
	Out :: struct {
		name: string,
		x:    i32,
	}
	outs: [dynamic]Out
	outs.allocator = context.temp_allocator
	focused := ""
	{
		sync.guard(&sway.mu)
		for o in sway.outputs {
			if !o.active {continue}
			append(&outs, Out{strings.clone(o.name, context.temp_allocator), o.x})
			if o.focused {focused = strings.clone(o.name, context.temp_allocator)}
		}
	}
	for i in 1 ..< len(outs) {
		for j := i; j > 0 && outs[j].x < outs[j - 1].x; j -= 1 {outs[j], outs[j - 1] = outs[j - 1], outs[j]}
	}
	b := strings.builder_make(context.temp_allocator)
	for o, i in outs {
		fmt.sbprintf(&b, "workspace \"%s\" output %s; ", project_workspace(p, i + 1), o.name)
	}
	// Visit the others first and end on the output the user was on.
	last := ""
	for o, i in outs {
		if o.name == focused {
			last = fmt.tprintf("focus output %s; workspace \"%s\"", o.name, project_workspace(p, i + 1))
			continue
		}
		fmt.sbprintf(&b, "focus output %s; workspace \"%s\"; ", o.name, project_workspace(p, i + 1))
	}
	strings.write_string(&b, last)
	sway_command(strings.to_string(b))
}

// ---- Aggregation ---------------------------------------------------------

// Local midnight (unix) of the day containing `t`, using the current UTC offset.
local_day_start :: proc(t: i64) -> i64 {
	off: i64
	if r, ok := clock_read(local_region, time.unix(t, 0)); ok {off = i64(r.offset_min) * 60}
	return (t + off) / 86400 * 86400 - off
}

// Seconds per project between [from, to), including the running segment.
tracker_totals :: proc(from, to: i64) -> map[string]i64 {
	out := make(map[string]i64, 16, context.temp_allocator)
	add :: proc(out: ^map[string]i64, project: string, s, e, from, to: i64) {
		a := max(s, from)
		b := min(e, to)
		if b > a {out[project] = out[project] + (b - a)}
	}
	for e in tracker.entries {add(&out, e.project, e.start, e.end, from, to)}
	if tracker.running >= 0 {
		add(&out, tracker.projects[tracker.running].name, tracker.seg_start, time.to_unix_seconds(time.now()), from, to)
	}
	return out
}
