// Time tracking by workspace: every project gets one workspace per monitor
// ("NeonRAW 1", "NeonRAW 2"). Time counts while one of them is focused and
// the user isn't idle; numbered workspaces are not counted.
//
// Log: <data>/timelog.tsv, one finished segment per line:
//   2026-10-23T11:05:00Z<TAB>2026-10-23T12:40:10Z<TAB>Project<TAB>Client[<TAB>idle]
// Breaks (no input for idle_minutes) are logged too, marked "idle", and
// attributed to the project whose workspace was focused when you walked away.
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
	project:    string, // NO_PROJECT for breaks taken outside project workspaces
	idle:       bool,   // a break (away from keyboard), not work
}

NO_PROJECT :: "(no project)"

Tracker :: struct {
	projects:   [dynamic]Project,
	entries:    [dynamic]Time_Entry,
	running:    int, // index into projects, -1 = not counting
	seg_start:  i64,
	last_beat:  time.Tick,
	paused_idle: bool,

	// The break in progress (away from keyboard).
	away:         bool,
	away_start:   i64,
	away_project: string,
	away_client:  string,
	away_beat:    time.Tick,
	away_path:    string,
	log_path:   string,
	cur_path:   string,
	idle:       time.Duration,

	// Group lock: monitors follow each other into and out of project workspaces.
	lock:         bool,
	lock_path:    string,
	last_visible: map[string]string, // output -> workspace at the previous tick
	return_ws:    map[string]string, // output -> workspace to go back to when leaving
	sync_at:      time.Tick,         // our own switch; ignore the events it causes
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
	line := fmt.tprintf("%s\t%s\t%s\t%s%s\n", iso_utc(e.start), iso_utc(e.end), e.project, client, e.idle ? "\tidle" : "")
	f, err := os.open(tracker.log_path, {.Write, .Create, .Append}, os.Permissions_Default_File)
	if err != nil {
		log.errorf("time log %s: %v", tracker.log_path, err)
		return
	}
	defer os.close(f)
	os.write_string(f, line)
	append(&tracker.entries, Time_Entry{e.start, e.end, strings.clone(e.project), e.idle})
}

timelog_parse :: proc(data: string, out: ^[dynamic]Time_Entry) {
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 3 {continue}
		s, ok1 := parse_iso_utc(f[0])
		e, ok2 := parse_iso_utc(f[1])
		if !ok1 || !ok2 || e <= s {continue}
		append(out, Time_Entry{s, e, strings.clone(f[2]), len(f) > 4 && f[4] == "idle"})
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
		append_entry({tracker.seg_start, end, p.name, false}, p.client)
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
	tracker.lock_path = strings.concatenate({dir, "/timetracker.lock"})
	tracker.away_path = strings.concatenate({dir, "/timetracker.away"})
	tracker.lock = os.exists(tracker.lock_path)
	if data, err := os.read_entire_file(tracker.log_path, context.temp_allocator); err == nil {
		timelog_parse(string(data), &tracker.entries)
	}
	if data, err := os.read_entire_file(tracker.cur_path, context.temp_allocator); err == nil {
		f := strings.split(strings.trim_space(string(data)), "\t", context.temp_allocator)
		if len(f) >= 3 {
			s, _ := strconv.parse_i64(f[0])
			e, _ := strconv.parse_i64(f[1])
			client := len(f) > 3 ? f[3] : ""
			if e - s >= MIN_SEGMENT {append_entry({s, e, f[2], false}, client)}
		}
		os.remove(tracker.cur_path)
	}
	// A break that was in progress when we stopped: keep it up to the last heartbeat.
	if data, err := os.read_entire_file(tracker.away_path, context.temp_allocator); err == nil {
		f := strings.split(strings.trim_space(string(data)), "\t", context.temp_allocator)
		if len(f) >= 3 {
			s, _ := strconv.parse_i64(f[0])
			e, _ := strconv.parse_i64(f[1])
			if e > s {append_entry({s, e, f[2], true}, len(f) > 3 ? f[3] : "")}
		}
		os.remove(tracker.away_path)
	}
	if len(tracker.projects) > 0 && !platform_watch_idle(tracker.idle) {
		log.warn("compositor lacks ext-idle-notify-v1: idle time will be counted")
	}
}

// Called every main-loop iteration: follow workspace focus and idleness.
tracker_tick :: proc() {
	if len(tracker.projects) == 0 {return}
	tracker_sync()
	ws: string
	{
		sync.guard(&sway.mu)
		ws = strings.clone(sway.focused_ws, context.temp_allocator)
	}
	want := plat.idle ? -1 : project_for_workspace(ws)
	now := time.to_unix_seconds(time.now())
	track_away(ws, now)
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

// Breaks: start when the compositor reports idle, end on the next input.
@(private = "file")
track_away :: proc(ws: string, now: i64) {
	if plat.idle && !tracker.away {
		tracker.away = true
		tracker.away_start = time.to_unix_seconds(plat.idle_since)
		delete(tracker.away_project)
		delete(tracker.away_client)
		if p := project_for_workspace(ws); p >= 0 {
			tracker.away_project = strings.clone(tracker.projects[p].name)
			tracker.away_client = strings.clone(tracker.projects[p].client)
		} else {
			tracker.away_project = strings.clone(NO_PROJECT)
			tracker.away_client = ""
		}
		write_away(now)
	} else if !plat.idle && tracker.away {
		close_away(now)
	} else if tracker.away && time.tick_since(tracker.away_beat) >= HEARTBEAT {
		write_away(now)
	}
}

@(private = "file")
write_away :: proc(now: i64) {
	tracker.away_beat = time.tick_now()
	_ = os.write_entire_file(tracker.away_path, fmt.tprintf("%d\t%d\t%s\t%s\n", tracker.away_start, now, tracker.away_project, tracker.away_client))
}

@(private = "file")
close_away :: proc(end: i64) {
	if !tracker.away {return}
	tracker.away = false
	if end > tracker.away_start {
		append_entry({tracker.away_start, end, tracker.away_project, true}, tracker.away_client)
	}
	os.remove(tracker.away_path)
	request_redraw()
}

// How long the main loop may sleep before the next heartbeat is due.
tracker_timeout :: proc() -> time.Duration {
	t: time.Duration = -1
	if tracker.running >= 0 {t = max(HEARTBEAT - time.tick_since(tracker.last_beat), 0)}
	if tracker.away {
		a := max(HEARTBEAT - time.tick_since(tracker.away_beat), 0)
		t = t < 0 ? a : min(t, a)
	}
	return t
}

tracker_shutdown :: proc() {
	now := time.to_unix_seconds(time.now())
	close_segment(now)
	close_away(now)
}

// Active outputs, left to right; a project's workspace "<name> N" lives on the N-th.
project_outputs :: proc() -> (names: []string, focused: string) {
	Out :: struct {
		name: string,
		x:    i32,
	}
	outs: [dynamic]Out
	outs.allocator = context.temp_allocator
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
	names = make([]string, len(outs), context.temp_allocator)
	for o, i in outs {names[i] = o.name}
	return
}

// Create (or recreate) the project's workspaces, one per active output in
// left-to-right order, pin them to their outputs and show them.
tracker_start :: proc(index: int) {
	if index < 0 || index >= len(tracker.projects) {return}
	p := tracker.projects[index]
	outs, focused := project_outputs()
	remember_return_workspaces()
	b := strings.builder_make(context.temp_allocator)
	for o, i in outs {
		fmt.sbprintf(&b, "workspace \"%s\" output %s; ", project_workspace(p, i + 1), o)
	}
	// Visit the others first and end on the output the user was on.
	last := ""
	for o, i in outs {
		if o == focused {
			last = fmt.tprintf("focus output %s; workspace \"%s\"", o, project_workspace(p, i + 1))
			continue
		}
		fmt.sbprintf(&b, "focus output %s; workspace \"%s\"; ", o, project_workspace(p, i + 1))
	}
	strings.write_string(&b, last)
	tracker.sync_at = time.tick_now()
	sway_command(strings.to_string(b))
}

tracker_set_lock :: proc(on: bool) {
	tracker.lock = on
	if on {
		_ = os.write_entire_file(tracker.lock_path, "on\n")
		// Apply right away: already on a project workspace -> group the monitors.
		ws: string
		{
			sync.guard(&sway.mu)
			ws = strings.clone(sway.focused_ws, context.temp_allocator)
		}
		if p := project_for_workspace(ws); p >= 0 {tracker_start(p)}
	} else {
		os.remove(tracker.lock_path)
	}
	request_redraw()
}

// Remember what each output shows (if it's not a project workspace) so the
// group lock can send it back there when the project is left.
@(private = "file")
remember_return_workspaces :: proc() {
	sync.guard(&sway.mu)
	for v in sway.visible {
		if project_for_workspace(v.ws) >= 0 {continue}
		if old, had := tracker.return_ws[v.output]; had {
			delete(old)
			tracker.return_ws[v.output] = strings.clone(v.ws)
		} else {
			tracker.return_ws[strings.clone(v.output)] = strings.clone(v.ws)
		}
	}
}

Sync_Move :: struct {
	output, workspace: string,
	pin:               bool, // also pin the workspace to the output (project workspaces)
}

// Group-lock decision, without side effects except remembering return
// workspaces. Given what the focused output showed before (`prev`) and now
// (`cur`): entering a project brings the other outputs to its workspaces;
// leaving it sends the outputs still showing it back where they came from.
plan_sync :: proc(prev, cur, focused_out: string, outs: []string, visible: map[string]string, return_ws: ^map[string]string) -> []Sync_Move {
	moves: [dynamic]Sync_Move
	moves.allocator = context.temp_allocator
	if prev == cur || prev == "" {return nil}
	p_prev := project_for_workspace(prev)
	p_cur := project_for_workspace(cur)
	if p_prev == p_cur {return nil}
	for o, i in outs {
		if o == focused_out {continue}
		shown := visible[o]
		shown_p := project_for_workspace(shown)
		if p_cur >= 0 {
			if shown_p == p_cur {continue}
			if shown_p < 0 && shown != "" {
				if old, had := return_ws[o]; had {
					delete(old)
					return_ws[o] = strings.clone(shown)
				} else {
					return_ws[strings.clone(o)] = strings.clone(shown)
				}
			}
			append(&moves, Sync_Move{o, project_workspace(tracker.projects[p_cur], i + 1), true})
		} else {
			if shown_p != p_prev {continue}
			if ret, had := return_ws[o]; had {append(&moves, Sync_Move{o, ret, false})}
		}
	}
	return moves[:]
}

// Group lock: apply plan_sync to sway, keeping focus on the output the user acted on.
@(private = "file")
tracker_sync :: proc() {
	visible := make(map[string]string, 8, context.temp_allocator)
	focused_out: string
	{
		sync.guard(&sway.mu)
		for v in sway.visible {visible[strings.clone(v.output, context.temp_allocator)] = strings.clone(v.ws, context.temp_allocator)}
		focused_out = strings.clone(sway.focused_output, context.temp_allocator)
	}
	defer {
		for k, v in tracker.last_visible {
			delete(k)
			delete(v)
		}
		clear(&tracker.last_visible)
		for k, v in visible {tracker.last_visible[strings.clone(k)] = strings.clone(v)}
	}
	if !tracker.lock || focused_out == "" {return}
	// Our own switching produces a burst of events: let it settle.
	if time.tick_since(tracker.sync_at) < 400 * time.Millisecond {return}

	outs, _ := project_outputs()
	moves := plan_sync(tracker.last_visible[focused_out], visible[focused_out], focused_out, outs, visible, &tracker.return_ws)
	if len(moves) == 0 {return}
	b := strings.builder_make(context.temp_allocator)
	for m in moves {
		if m.pin {fmt.sbprintf(&b, "workspace \"%s\" output %s; ", m.workspace, m.output)}
		fmt.sbprintf(&b, "focus output %s; workspace \"%s\"; ", m.output, m.workspace)
	}
	fmt.sbprintf(&b, "focus output %s", focused_out)
	tracker.sync_at = time.tick_now()
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
	for e in tracker.entries {
		if !e.idle {add(&out, e.project, e.start, e.end, from, to)}
	}
	if tracker.running >= 0 {
		add(&out, tracker.projects[tracker.running].name, tracker.seg_start, time.to_unix_seconds(time.now()), from, to)
	}
	return out
}

Break_Stats :: struct {
	count: int, // breaks that started in the range
	secs:  i64, // time away within the range
}

// Breaks per project (NO_PROJECT for breaks outside project workspaces),
// including the one in progress.
tracker_breaks :: proc(from, to: i64) -> map[string]Break_Stats {
	out := make(map[string]Break_Stats, 16, context.temp_allocator)
	add :: proc(out: ^map[string]Break_Stats, project: string, s, e, from, to: i64) {
		b := out[project]
		if s >= from && s < to {b.count += 1}
		lo, hi := max(s, from), min(e, to)
		if hi > lo {b.secs += hi - lo}
		if b.count > 0 || b.secs > 0 {out[project] = b}
	}
	for e in tracker.entries {
		if e.idle {add(&out, e.project, e.start, e.end, from, to)}
	}
	if tracker.away {add(&out, tracker.away_project, tracker.away_start, time.to_unix_seconds(time.now()), from, to)}
	return out
}
