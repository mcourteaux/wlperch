// Bridging short breaks (bridge_breaks): which breaks count as work, and that
// the panel's totals, the CSV export and the bar's timer agree.
// local_region is nil in tests, so "local" is UTC.
package main

import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
T0 :: i64(1792800000) // 2026-10-24T00:00:00Z

@(private = "file")
H :: i64(3600)
@(private = "file")
M :: i64(60)

@(private = "file")
RULES :: Bridge_Rules {
	default_secs = 0,
	names        = {"P", "Q"},
	secs         = {10 * 60, 0},
}

@(private = "file")
w :: proc(s, e: i64, p := "P") -> Time_Entry {return {T0 + s, T0 + e, p, false, false, false}}
@(private = "file")
b :: proc(s, e: i64, p := "P") -> Time_Entry {return {T0 + s, T0 + e, p, true, false, false}}

@(private = "file")
bridged :: proc(entries: []Time_Entry, rules := RULES) -> []bool {
	out := tracker_bridge(entries, rules)
	m := make([]bool, len(out), context.temp_allocator)
	for e, i in out {m[i] = e.bridged}
	return m
}

@(test)
test_bridge_rules :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// Same project, short gap: bridged. Long gap: not.
	m := bridged({w(9 * H, 10 * H), b(10 * H, 10 * H + 5 * M), w(10 * H + 5 * M, 11 * H)})
	testing.expect(t, m[1])
	m = bridged({w(9 * H, 10 * H), b(10 * H, 10 * H + 15 * M), w(10 * H + 15 * M, 11 * H)})
	testing.expect(t, !m[1])
	// Exactly the limit is not shorter than it.
	m = bridged({w(9 * H, 10 * H), b(10 * H, 10 * H + 10 * M), w(10 * H + 10 * M, 11 * H)})
	testing.expect(t, !m[1])
	// Between two projects: a break.
	m = bridged({w(9 * H, 10 * H), b(10 * H, 10 * H + 5 * M), w(10 * H + 5 * M, 11 * H, "Q")})
	testing.expect(t, !m[1])
	// A project with bridging off (Q), and the default for unknown names.
	m = bridged({w(9 * H, 10 * H, "Q"), b(10 * H, 10 * H + 5 * M, "Q"), w(10 * H + 5 * M, 11 * H, "Q")})
	testing.expect(t, !m[1])
	with_default := RULES
	with_default.default_secs = 20 * M
	m = bridged({w(9 * H, 10 * H, "Old"), b(10 * H, 10 * H + 15 * M, "Old"), w(10 * H + 15 * M, 11 * H, "Old")}, with_default)
	testing.expect(t, m[1])
	// End of the day: no work on P after it (or only much later).
	m = bridged({w(9 * H, 10 * H), b(10 * H, 10 * H + 5 * M)})
	testing.expect(t, !m[1])
	m = bridged({w(17 * H, 18 * H), b(18 * H, 18 * H + 5 * M), w(33 * H, 34 * H)})
	testing.expect(t, !m[1])
	// Work on another project in between: the second break follows Q, not P.
	m = bridged({w(9 * H, 10 * H), w(10 * H, 10 * H + 2 * M, "Q"), b(10 * H + 2 * M, 10 * H + 5 * M, "Q"), w(10 * H + 5 * M, 11 * H)})
	testing.expect(t, !m[2])
	// A small hole (an unlogged visit, a restart) still counts as back to back.
	m = bridged({w(9 * H, 10 * H), b(10 * H + 20, 10 * H + 5 * M), w(10 * H + 5 * M + 30, 11 * H)})
	testing.expect(t, m[1])
	// A break still in progress (nothing after it yet) stays a break.
	m = bridged({w(9 * H, 10 * H), b(10 * H, 10 * H + 1 * M)})
	testing.expect(t, !m[1])
}

@(test)
test_bridge_consecutive :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// Two short breaks with a minute of work between them: both bridged.
	m := bridged({w(9 * H, 10 * H), b(10 * H, 10 * H + 3 * M), w(10 * H + 3 * M, 10 * H + 4 * M), b(10 * H + 4 * M, 10 * H + 7 * M), w(10 * H + 7 * M, 11 * H)})
	testing.expect(t, m[1] && m[3])
	// Back-to-back breaks (e.g. split by a restart) count as one: 3 + 3 min, bridged...
	m = bridged({w(9 * H, 10 * H), b(10 * H, 10 * H + 3 * M), b(10 * H + 3 * M, 10 * H + 6 * M), w(10 * H + 6 * M, 11 * H)})
	testing.expect(t, m[1] && m[2])
	// ...6 + 6 min is 12: neither.
	m = bridged({w(9 * H, 10 * H), b(10 * H, 10 * H + 6 * M), b(10 * H + 6 * M, 10 * H + 12 * M), w(10 * H + 12 * M, 11 * H)})
	testing.expect(t, !m[1] && !m[2])
	// Order in the log doesn't matter.
	m = bridged({w(10 * H + 5 * M, 11 * H), b(10 * H, 10 * H + 5 * M), w(9 * H, 10 * H)})
	testing.expect(t, m[1] && !m[0] && !m[2])
	// No rules at all: nothing bridged.
	m = bridged({w(9 * H, 10 * H), b(10 * H, 10 * H + 5 * M), w(10 * H + 5 * M, 11 * H)}, Bridge_Rules{})
	testing.expect(t, !m[1])
}

// Across midnight, and the export's per-day cutting of a bridged gap.
@(test)
test_bridge_export :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	e :: proc(s, en: i64, idle: bool) -> Export_Entry {return {T0 + s, T0 + en, "P", "ACME", idle, false, false}}
	entries := []Export_Entry {
		e(23 * H, 23 * H + 58 * M, false),
		e(23 * H + 58 * M, 24 * H + 4 * M, true), // 6 min over midnight
		e(24 * H + 4 * M, 25 * H, false),
		e(25 * H, 25 * H + 30 * M, true), // 30 min: a real break
		e(25 * H + 30 * M, 26 * H, false),
	}
	// Per day: the gap is work, split at midnight (58+2 and 4+56 min).
	csv, work, _ := export_csv(entries, {group = .Day, bridge = RULES}, context.temp_allocator)
	testing.expect_value(t, work, i64(2 * H + 30 * M))
	testing.expect(t, strings.contains(csv, "2026-10-24,P,ACME,60,1.00,work,,\n"))
	testing.expect(t, strings.contains(csv, "2026-10-25,P,ACME,90,1.50,work,,\n"))
	testing.expect(t, !strings.contains(csv, "break"))
	// Bridging off: the 6 minutes are a break.
	_, work, _ = export_csv(entries, {group = .Day}, context.temp_allocator)
	testing.expect_value(t, work, i64(2 * H + 24 * M))
	// Per entry with --breaks: the gap is type bridged, the long break type break.
	csv, work, _ = export_csv(entries, {group = .Entries, breaks = true, bridge = RULES}, context.temp_allocator)
	testing.expect_value(t, work, i64(2 * H + 30 * M))
	testing.expect(t, strings.contains(csv, "2026-10-24,23:58,24:00,2,0.03,P,ACME,bridged,,\n"))
	testing.expect(t, strings.contains(csv, "2026-10-25,00:00,00:04,4,0.07,P,ACME,bridged,,\n"))
	testing.expect(t, strings.contains(csv, "2026-10-25,01:00,01:30,30,0.50,P,ACME,break,,\n"))
	// Without --breaks, per entry: the gap is plain work.
	csv, _, _ = export_csv(entries, {group = .Entries, bridge = RULES}, context.temp_allocator)
	testing.expect(t, strings.contains(csv, "2026-10-24,23:58,24:00,2,0.03,P,ACME,work,,\n"))
	// Per day with --breaks: the gap is in the work row, not among the breaks.
	csv, _, _ = export_csv(entries, {group = .Day, breaks = true, bridge = RULES}, context.temp_allocator)
	testing.expect(t, strings.contains(csv, "2026-10-25,P,ACME,90,1.50,work,,\n"))
	testing.expect(t, strings.contains(csv, "2026-10-25,P,ACME,30,0.50,break,,\n"))
	testing.expect(t, !strings.contains(csv, "2026-10-24,P,ACME,2,0.03,break"))
	// A range that starts after the work before the gap still sees it.
	_, work, _ = export_csv(entries, {from = T0 + 24 * H, to = T0 + 48 * H, bridge = RULES}, context.temp_allocator)
	testing.expect_value(t, work, i64(90 * M))
}

// The Time panel (tracker_totals), the export and the bar's timer show the
// same total for today, with a bridged break and a segment counting now.
@(test)
test_bridge_totals_agree :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	DIR :: "/tmp/wlperch-test-bridge"
	dir := DIR
	os.remove_all(dir)
	os.make_directory_all(DIR + "/wlperch")
	defer os.remove_all(dir)
	saved := tracker
	saved_xdg := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	defer {
		tracker = saved
		bridge_rules_update()
		os.set_env("XDG_DATA_HOME", saved_xdg)
	}
	os.set_env("XDG_DATA_HOME", DIR)
	tracker = Tracker{running = -1, last = -1, pinned = -1}
	append(&tracker.projects, Project{key = "p", name = "P", bridge = 10})
	append(&tracker.projects, Project{key = "q", name = "Q", bridge = -1})
	bridge_rules_update()

	now := time.to_unix_seconds(time.now())
	day := local_day_start(now)
	// Relative to now; anything before midnight is clipped the same way everywhere.
	log_lines := [?]struct {
		s, e:  i64,
		p:     string,
		idle:  bool,
	} {
		{now - 2 * H, now - 90 * M, "P", false},
		{now - 90 * M, now - 85 * M, "P", true}, // 5 min: bridged
		{now - 85 * M, now - 60 * M, "P", false},
		{now - 60 * M, now - 40 * M, "P", true}, // 20 min: a break
		{now - 40 * M, now - 20 * M, "P", false},
		{now - 20 * M, now - 17 * M, "P", true}, // 3 min: bridged once P resumes (running)
	}
	lb := strings.builder_make()
	for l in log_lines {
		fmt.sbprintf(&lb, "%s\t%s\t%s\t\t%s\n", iso_utc(l.s), iso_utc(l.e), l.p, l.idle ? "idle" : "")
		append(&tracker.entries, Time_Entry{l.s, l.e, l.p, l.idle, false, false})
	}
	cur := fmt.tprintf("%d\t%d\tP\t\n", now - 17 * M, now)
	testing.expect(t, os.write_entire_file(DIR + "/wlperch/timelog.tsv", strings.to_string(lb)) == nil)
	testing.expect(t, os.write_entire_file(DIR + "/wlperch/timetracker.current", cur) == nil)
	tracker.running = 0
	tracker.seg_start = now - 17 * M

	clip :: proc(s, e, day: i64) -> i64 {return max(e - max(s, day), 0)}
	want := clip(now - 2 * H, now - 60 * M, day) + clip(now - 40 * M, now, day)

	panel := tracker_totals(day, now + 1)["P"]
	testing.expect(t, abs(panel - want) <= 1, fmt.tprintf("panel %d, want %d", panel, want))

	entries: [dynamic]Export_Entry
	entries.allocator = context.temp_allocator
	export_parse(strings.to_string(lb), cur, &entries)
	_, exported, _ := export_csv(entries[:], {project = "P", from = day, to = day + 86400, bridge = bridge_rules()}, context.temp_allocator)
	testing.expect(t, abs(exported - want) <= 1, fmt.tprintf("export %d, want %d", exported, want))

	it := status_timer_item()
	testing.expect_value(t, it.class, "running")
	testing.expect_value(t, it.project, "P") // the bar colours it by P
	testing.expect_value(t, it.text, fmt.tprintf("%s P %s", ICON_CLOCK, fmt_duration(want)))

	// The panel's counter: the stretch since the 20-minute break, gap included.
	testing.expect_value(t, tracker_stretch_start(tracker_view(now)), now - 40 * M)

	// Away from P now, within the window: the bar waits (not ticking), the
	// panel says so, and the totals leave the gap out until P resumes.
	os.remove(DIR + "/wlperch/timetracker.current")
	tracker.running = -1
	tracker.away = true
	tracker.away_start = now - 2 * M
	tracker.away_project = "P"
	testing.expect(t, os.write_entire_file(DIR + "/wlperch/timetracker.away", fmt.tprintf("%d\t%d\tP\t\n", now - 2 * M, now)) == nil)
	left, waiting := tracker_waiting(now)
	testing.expect(t, waiting)
	testing.expect_value(t, left, 8 * M)
	it = status_timer_item()
	testing.expect_value(t, it.class, "waiting")
	// Past the window: a real break.
	tracker.away_start = now - 11 * M
	_, waiting = tracker_waiting(now)
	testing.expect(t, !waiting)
	testing.expect(t, os.write_entire_file(DIR + "/wlperch/timetracker.away", fmt.tprintf("%d\t%d\tP\t\n", now - 11 * M, now)) == nil)
	it = status_timer_item()
	testing.expect_value(t, it.class, "idle")
}

@(test)
test_bridge_config :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	saved := tracker
	defer {
		tracker = saved
		bridge_rules_update()
	}
	tracker = Tracker{running = -1, last = -1, pinned = -1}
	INI :: "[timetracker]\nbridge_breaks = 5\n\n[project.a]\nname = A\nbridge_breaks = 15\n\n[project.b]\nname = B\n\n[project.c]\nname = C\nbridge_breaks = 500\n\n[project.d]\nname = D\nbridge_breaks = 0\n"
	m, _ := ini.load_map_from_string(INI, context.temp_allocator)
	projects_load(INI, m)
	testing.expect_value(t, len(tracker.projects), 4)
	testing.expect_value(t, tracker.bridge_default, 5)
	r := bridge_rules()
	testing.expect_value(t, bridge_limit(r, "A"), i64(15 * 60))
	testing.expect_value(t, bridge_limit(r, "B"), i64(5 * 60)) // the default
	testing.expect_value(t, bridge_limit(r, "C"), i64(120 * 60)) // clamped
	testing.expect_value(t, bridge_limit(r, "D"), i64(0)) // off for D only
	testing.expect_value(t, bridge_limit(r, "Gone"), i64(5 * 60))
	testing.expect_value(t, bridge_limit(r, NO_PROJECT), i64(0))
}

// The export's preview: worked time with and without bridging, an override
// (`--bridge`, the panel's slider), and that it matches the CSV's total.
@(test)
test_bridge_preview :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	e :: proc(s, en: i64, idle: bool, p := "P") -> Export_Entry {return {T0 + s, T0 + en, p, "", idle, false, false}}
	entries := []Export_Entry {
		e(9 * H, 10 * H, false),
		e(10 * H, 10 * H + 4 * M, true), // 4 min
		e(10 * H + 4 * M, 11 * H, false),
		e(11 * H, 11 * H + 12 * M, true), // 12 min
		e(11 * H + 12 * M, 12 * H, false),
		e(12 * H, 12 * H + 3 * M, true, "Q"), // attributed to Q, but after P's work
		e(12 * H + 3 * M, 13 * H, false, "Q"),
		e(13 * H, 13 * H + 2 * M, true, "Q"), // the end of Q's day
	}
	work := i64(3 * H - 16 * M)
	o := Export_Opts{project = "P", bridge = RULES} // P: 10 min
	sm := export_bridge_summary(entries, o)
	without, with, gaps := sm.without, sm.with, sm.gaps
	testing.expect_value(t, without, work)
	testing.expect_value(t, with, work + 4 * M)
	testing.expect_value(t, gaps, 1)
	_, csv_work, _ := export_csv(entries, o, context.temp_allocator)
	testing.expect_value(t, csv_work, with)
	testing.expect_value(t, fmt_bridge_summary(without, with, gaps), "2:44 h → 2:48 h (+0:04 h from 1 bridged gap)")

	// Override: 15 min for every project bridges P's 12-minute break too.
	o.bridge = bridge_rules_override(15)
	sm = export_bridge_summary(entries, o)
	without, with, gaps = sm.without, sm.with, sm.gaps
	testing.expect_value(t, with, work + 16 * M)
	testing.expect_value(t, gaps, 2)
	_, csv_work, _ = export_csv(entries, o, context.temp_allocator)
	testing.expect_value(t, csv_work, with)
	// All projects: Q's breaks don't count: the first follows P's work (between
	// two projects), the last has no work after it.
	o.project = ""
	sm = export_bridge_summary(entries, o)
	without, with, gaps = sm.without, sm.with, sm.gaps
	testing.expect_value(t, with - without, i64(16 * M))
	testing.expect_value(t, gaps, 2)
	// 0 = no bridging, whatever the config says; values are clamped.
	o.bridge = bridge_rules_override(0)
	sm = export_bridge_summary(entries, o)
	without, with, gaps = sm.without, sm.with, sm.gaps
	testing.expect_value(t, with, without)
	testing.expect_value(t, gaps, 0)
	testing.expect_value(t, fmt_bridge_summary(without, with, gaps), "3:41 h worked")
	testing.expect_value(t, bridge_rules_override(500).default_secs, i64(120 * 60))
	// A range cut: only the part of a bridged gap inside it counts.
	o = {project = "P", from = T0 + 10 * H + 2 * M, to = T0 + 11 * H, bridge = RULES}
	sm = export_bridge_summary(entries, o)
	without, with, gaps = sm.without, sm.with, sm.gaps
	testing.expect_value(t, without, i64(56 * M))
	testing.expect_value(t, with, i64(58 * M))
}
