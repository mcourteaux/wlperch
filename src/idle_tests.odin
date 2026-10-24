// Unit tests for the time tracker's idle handling: the timeout config key and
// how a break splits the timeline (work up to the last input, break after).
package main

import "core:encoding/ini"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_config_idle_seconds :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defaults, _ := ini.load_map_from_string(DEFAULT_CONFIG, context.temp_allocator)
	cases := []struct {ini: string, want: time.Duration} {
		{"[popup]\nwidth = 860\n", 5 * time.Minute},                          // default
		{"[timetracker]\nidle_minutes = 2\n", 2 * time.Minute},               // old key
		{"[timetracker]\nidle_seconds = 60\n", time.Minute},
		{"[timetracker]\nidle_minutes = 5\nidle_seconds = 60\n", time.Minute}, // new key wins
		{"[timetracker]\nidle_seconds = 1\n", 5 * time.Second},               // clamped
	}
	for c in cases {
		m, _ := ini.load_map_from_string(c.ini, context.temp_allocator)
		testing.expect_value(t, tracker_idle_timeout(m, defaults), c.want)
	}
}

// Idle is reported a timeout after the last input: the work segment ends and
// the break starts at that last input, and the break ends on the next input.
@(test)
test_idle_break_timeline :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	DIR :: "/tmp/wlperch-test-idle-timeline"
	dir := DIR
	os.make_directory_all(DIR)
	defer os.remove_all(dir)
	saved_tr := tracker
	saved_idle, saved_since := plat.idle, plat.idle_since
	saved_ws := sway.focused_ws
	defer {
		tracker = saved_tr
		plat.idle, plat.idle_since = saved_idle, saved_since
		sway.focused_ws = saved_ws
	}
	tracker = Tracker{running = -1, last = -1, pinned = -1}
	tracker.log_path = DIR + "/timelog.tsv"
	tracker.cur_path = DIR + "/timetracker.current"
	tracker.away_path = DIR + "/timetracker.away"
	append(&tracker.projects, Project{key = "neon", name = "NeonRAW", client = "Zec"})

	sway.focused_ws = "NeonRAW 1"
	plat.idle = false
	tracker_tick()
	testing.expect_value(t, tracker.running, 0)
	now := time.to_unix_seconds(time.now())
	tracker.seg_start = now - 600 // working for 10 minutes

	// Last input a minute ago; the compositor reports idle now.
	plat.idle = true
	plat.idle_since = time.unix(now - 60, 0)
	tracker_tick()
	testing.expect_value(t, tracker.running, -1)
	testing.expect(t, tracker.away)
	testing.expect(t, tracker.paused_idle)
	testing.expect_value(t, len(tracker.entries), 1)
	if len(tracker.entries) == 1 {
		e := tracker.entries[0]
		testing.expect(t, !e.idle)
		testing.expect_value(t, e.start, now - 600)
		testing.expect_value(t, e.end, now - 60) // not counted past the last input
	}

	// Input again: the break is logged from the last input to now, work resumes.
	plat.idle = false
	tracker_tick()
	testing.expect(t, !tracker.away)
	testing.expect(t, !tracker.paused_idle)
	testing.expect_value(t, tracker.running, 0)
	testing.expect_value(t, len(tracker.entries), 2)
	if len(tracker.entries) == 2 {
		b := tracker.entries[1]
		testing.expect(t, b.idle)
		testing.expect_value(t, b.project, "NeonRAW")
		testing.expect_value(t, b.start, now - 60)
		testing.expect(t, b.end >= now && b.end <= now + 2)
	}
	data, _ := os.read_entire_file(tracker.log_path, context.temp_allocator)
	testing.expect_value(t, strings.count(string(data), "\n"), 2)
	testing.expect(t, strings.contains(string(data), "\tidle\n"))
	tracker_shutdown()
}
