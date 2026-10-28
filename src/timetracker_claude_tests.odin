// Claude's background work: detection from window titles, the log, and
// counting it once (tracker_fold) in the panel, export and bar.
package main

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
RULES := Bridge_Rules {
	names  = {"P", "Q"},
	secs   = {10 * 60, 0},
	claude = {true, false},
}

@(private = "file")
w :: proc(s, e: i64, p := "P") -> Time_Entry {return {T0 + s, T0 + e, p, false, false, false}}
@(private = "file")
b :: proc(s, e: i64, p := "P") -> Time_Entry {return {T0 + s, T0 + e, p, true, false, false}}
@(private = "file")
c :: proc(s, e: i64, p := "P") -> Time_Entry {return {T0 + s, T0 + e, p, false, false, true}}

// Seconds per project that count, the way tracker_totals adds them up.
@(private = "file")
counted :: proc(entries: []Time_Entry, rules: Bridge_Rules) -> map[string]i64 {
	out := make(map[string]i64, 4, context.temp_allocator)
	for e in tracker_fold(entries, rules) {
		if e.idle && !e.bridged {continue}
		out[e.project] += e.end - e.start
	}
	return out
}

@(test)
test_claude_fold :: proc(t: ^testing.T) {
	// Claude alone (you're on Q, or away): counts for P.
	got := counted({w(9 * H, 10 * H, "Q"), c(9 * H, 10 * H)}, RULES)
	testing.expect_value(t, got["P"], H)
	testing.expect_value(t, got["Q"], H)

	// Overlapping your own work on P: once.
	got = counted({w(9 * H, 10 * H), c(9 * H + 30 * M, 11 * H)}, RULES)
	testing.expect_value(t, got["P"], 2 * H)

	// Your work in the middle of Claude's stretch splits it.
	f := tracker_fold([]Time_Entry{c(9 * H, 12 * H), w(10 * H, 11 * H)}, RULES)
	testing.expect_value(t, len(f), 3)
	testing.expect(t, f[0].claude && f[0].start == T0 + 9 * H && f[0].end == T0 + 10 * H)
	testing.expect(t, !f[1].claude)
	testing.expect(t, f[2].claude && f[2].start == T0 + 11 * H && f[2].end == T0 + 12 * H)

	// During a long break on P: the break stays, Claude's part counts.
	got = counted({w(9 * H, 10 * H), b(10 * H, 11 * H), c(10 * H, 10 * H + 40 * M)}, RULES)
	testing.expect_value(t, got["P"], H + 40 * M)
	// During a bridged break: once, not twice.
	got = counted({w(9 * H, 10 * H), b(10 * H, 10 * H + 5 * M), w(10 * H + 5 * M, 11 * H), c(10 * H, 10 * H + 5 * M)}, RULES)
	testing.expect_value(t, got["P"], 2 * H)
	// Claude's stretches don't split a break's neighbours: still bridged.
	got = counted({w(9 * H, 10 * H), b(10 * H, 10 * H + 5 * M), w(10 * H + 5 * M, 11 * H), c(9 * H + 50 * M, 9 * H + 55 * M, "Q")}, RULES)
	testing.expect_value(t, got["P"], 2 * H)

	// Two terminals (or a restart): overlapping stretches merge.
	got = counted({c(9 * H, 10 * H), c(9 * H + 30 * M, 10 * H + 30 * M)}, RULES)
	testing.expect_value(t, got["P"], 90 * M)

	// Q doesn't count Claude: dropped.
	got = counted({c(9 * H, 10 * H, "Q")}, RULES)
	testing.expect_value(t, got["Q"], 0)
	testing.expect_value(t, len(tracker_fold([]Time_Entry{c(9 * H, 10 * H, "Q")}, RULES)), 0)
	// Nor does a project the rules don't know.
	testing.expect_value(t, counted({c(9 * H, 10 * H, "X")}, RULES)["X"], 0)
}

@(test)
test_claude_log :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := fmt.tprintf("%s\t%s\tP\tACME\tclaude\n%s\t%s\tP\tACME\n", iso_utc(T0), iso_utc(T0 + H), iso_utc(T0 + H), iso_utc(T0 + 2 * H))
	entries: [dynamic]Time_Entry
	timelog_parse(text, &entries)
	testing.expect_value(t, len(entries), 2)
	testing.expect(t, entries[0].claude && !entries[0].idle)
	testing.expect(t, !entries[1].claude)

	// A rename keeps the tag; Claude's stretches are trimmed only against each other.
	out, st := timelog_rename(text, "P", "R")
	testing.expect(t, strings.contains(out, "\tR\tACME\tclaude\n"))
	testing.expect_value(t, st.work_entries, 1)

	// The open stretches' state file.
	segs := claude_state_parse("100\t160\tP\tACME\nbad\n200\t150\tQ\t\n")
	testing.expect_value(t, len(segs), 1)
	testing.expect(t, segs[0].start == 100 && segs[0].last == 160 && segs[0].project == "P" && segs[0].client == "ACME")

	testing.expect(t, claude_spinning("◐ hours tracking code survey"))
	testing.expect(t, claude_spinning("◑ hours tracking code survey"))
	testing.expect(t, !claude_spinning("✳ contract obligations"))
	testing.expect(t, !claude_spinning("…/backup/project/wlwidgets"))
}

@(test)
test_claude_export_and_rates :: proc(t: ^testing.T) {
	saved := tracker
	defer {
		tracker = saved
		bridge_rules_update()
	}
	tracker = Tracker{running = -1, last = -1, pinned = -1, currency = "€"}
	append(&tracker.projects, Project{key = "p", name = "P", bridge = -1, paying = true, rate = 80, claude = true})
	append(&tracker.projects, Project{key = "q", name = "Q", bridge = -1, rate = 50}) // not paying: no amount
	bridge_rules_update()
	rules := bridge_rules()

	entries := []Export_Entry {
		{T0 + 9 * H, T0 + 10 * H, "P", "ACME", false, false, false},
		{T0 + 9 * H + 30 * M, T0 + 11 * H, "P", "ACME", false, false, true}, // +1 h by Claude
		{T0 + 12 * H, T0 + 13 * H, "Q", "", false, false, false},
	}
	csv, work, _ := export_csv(entries, {group = .Entries, bridge = rules}, context.temp_allocator)
	testing.expect_value(t, work, 3 * H)
	testing.expect(t, strings.contains(csv, "date,start,end,minutes,hours,project,client,type,rate,amount\n"))
	testing.expect(t, strings.contains(csv, "2026-10-24,09:00,10:00,60,1.00,P,ACME,work,80.00,80.00\n"))
	testing.expect(t, strings.contains(csv, "2026-10-24,10:00,11:00,60,1.00,P,ACME,claude,80.00,80.00\n"))
	testing.expect(t, strings.contains(csv, "2026-10-24,12:00,13:00,60,1.00,Q,,work,,\n"))
	csv, _, _ = export_csv(entries, {group = .Project, bridge = rules}, context.temp_allocator)
	testing.expect(t, strings.contains(csv, "P,ACME,120,2.00,1,work,80.00,160.00\n"))

	sum := export_bridge_summary(entries, {bridge = rules})
	testing.expect_value(t, sum.with, 3 * H)
	testing.expect_value(t, sum.without, 3 * H)
	testing.expect_value(t, sum.claude, H)
	testing.expect_value(t, sum.amount, 160.0)
	testing.expect_value(t, fmt_summary_extra(sum), "incl. 1:00 h by Claude  ·  €160.00")
	// The slider's override keeps Claude's counting.
	testing.expect_value(t, export_bridge_summary(entries, {bridge = bridge_rules_override(5)}).claude, H)

	testing.expect_value(t, fmt_money(1234.5), "€1,234.50")
	tracker.currency = "EUR"
	testing.expect_value(t, fmt_money(99.999), "100.00 EUR")
	testing.expect_value(t, fmt_rate(92.5), "92.5")
	testing.expect_value(t, fmt_rate(85), "85")
}

// The daemon side: a spinning title on a project's workspace opens a
// stretch, the panel counts it, the bar shows it, and it closes at the
// last frame once the spinner stops.
@(test)
test_claude_tracking :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	DIR :: "/tmp/wlperch-test-claude"
	dir := DIR
	os.remove_all(dir)
	os.make_directory_all(DIR + "/wlperch")
	defer os.remove_all(dir)
	saved := tracker
	saved_views := sway.views
	saved_ws := sway.focused_ws
	saved_xdg := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	defer {
		tracker = saved
		sway.views = saved_views
		sway.focused_ws = saved_ws
		bridge_rules_update()
		os.set_env("XDG_DATA_HOME", saved_xdg)
	}
	os.set_env("XDG_DATA_HOME", DIR)
	tracker = Tracker{running = -1, last = -1, pinned = -1, currency = "€"}
	append(&tracker.projects, Project{key = "p", name = "P", bridge = -1, claude = true, paying = true})
	bridge_rules_update()
	tracker_paths()
	sway.focused_ws = "1" // you're elsewhere

	now := time.to_unix_seconds(time.now())
	sway.views = make(map[i64]Sway_View)
	sway.views[7] = Sway_View{ws = "P 2", spin = now - 1}
	sway.views[8] = Sway_View{ws = "1"} // not Claude
	tracker_tick()
	testing.expect_value(t, len(tracker.claude_segs), 1)
	testing.expect(t, tracker_claude_active("P"))
	testing.expect(t, os.exists(tracker.claude_path))

	// Counted for P after a minute, though you're not there.
	tracker.claude_segs[0].start = now - 60
	tracker.claude_beat = {} // the heartbeat is due: the state file follows
	tracker_tick()
	testing.expect_value(t, tracker_totals(now - H, now + 1)["P"], 60)
	it := status_timer_item()
	testing.expect_value(t, it.class, "claude")
	testing.expect_value(t, it.text, fmt.tprintf("%s P %s %s 0:01", ICON_CLOCK, ICON_PAYING, ICON_CLAUDE))

	// The spinner stopped (✳ / no more frames): closed at its last frame.
	sway.views[7] = Sway_View{ws = "P 2", spin = 0}
	tracker.claude_segs[0].last = now - 2
	tracker_tick()
	testing.expect_value(t, len(tracker.claude_segs), 0)
	testing.expect(t, !os.exists(tracker.claude_path))
	testing.expect_value(t, len(tracker.entries), 1)
	if len(tracker.entries) == 1 {
		e := tracker.entries[0]
		testing.expect(t, e.claude && e.start == now - 60 && e.end == now - 2)
	}
	log_text, _ := os.read_entire_file(tracker.log_path, context.temp_allocator)
	testing.expect(t, strings.has_suffix(string(log_text), "\tP\t\tclaude\n"))

	// A stale spinner (Claude died mid-frame) doesn't open a stretch.
	sway.views[7] = Sway_View{ws = "P 2", spin = now - CLAUDE_STALE - 5}
	tracker_tick()
	testing.expect_value(t, len(tracker.claude_segs), 0)
}
