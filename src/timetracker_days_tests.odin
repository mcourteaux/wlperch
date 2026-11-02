// Browsing past days in the Time panel: which [from, to) a day is, its label,
// and that a past day's totals match the CSV export for that day.
package main

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "core:time/timezone"

@(private = "file")
H :: i64(3600)
@(private = "file")
M :: i64(60)

// With local_region nil (tests), "local" is UTC: whole 24 h days.
@(test)
test_day_range_utc :: proc(t: ^testing.T) {
	now := i64(1792800000) + 15 * H // 2026-10-24 15:00 UTC, a Saturday
	from, to := local_day_range(now, 0)
	testing.expect_value(t, from, i64(1792800000))
	testing.expect_value(t, to, i64(1792800000) + 86400)
	from, to = local_day_range(now, 3)
	testing.expect_value(t, from, i64(1792800000) - 3 * 86400)
	testing.expect_value(t, to, i64(1792800000) - 2 * 86400)
	testing.expect_value(t, day_label(now, 0), "Today")
	testing.expect_value(t, day_label(now, 1), "Yesterday")
	testing.expect_value(t, day_label(now, 3), "Wed 21 Oct")
	testing.expect_value(t, day_label(now, 300), "Sun 28 Dec 2025")
}

// Across the end of summer time (Brussels, 2026-10-25 03:00 CEST -> 02:00
// CET), that Sunday is 25 hours, and every day starts at local midnight.
@(test)
test_day_range_dst :: proc(t: ^testing.T) {
	reg, ok := timezone.region_load("Europe/Brussels")
	if !ok || reg == nil {
		testing.expect(t, false, "no Europe/Brussels zone data")
		return
	}
	saved := local_region
	local_region = reg
	defer {
		local_region = saved
		timezone.region_destroy(reg)
	}
	// Tuesday 2026-10-27 10:00 CET = 09:00 UTC.
	now := i64(1792800000) + 3 * 86400 + 9 * H
	mon_from, mon_to := local_day_range(now, 1)
	testing.expect_value(t, mon_from, i64(1792800000) + 2 * 86400 - 1 * H) // Mon 00:00 CET
	testing.expect_value(t, mon_to - mon_from, i64(86400))
	sun_from, sun_to := local_day_range(now, 2)
	testing.expect_value(t, sun_to, mon_from)
	testing.expect_value(t, sun_from, i64(1792800000) + 86400 - 2 * H) // Sun 00:00 CEST
	testing.expect_value(t, sun_to - sun_from, i64(25 * H))
	sat_from, sat_to := local_day_range(now, 3)
	testing.expect_value(t, sat_to, sun_from)
	testing.expect_value(t, sat_to - sat_from, i64(86400))
	testing.expect_value(t, day_label(now, 2), "Sun 25 Oct")
	// Back across the start of summer time (2026-03-29: 23 hours).
	from, to := local_day_range(now, 212)
	testing.expect_value(t, day_label(now, 212), "Sun 29 Mar")
	testing.expect_value(t, to - from, i64(23 * H))
}

// A past day in the panel (tracker_totals over local_day_range) counts the
// same as the CSV export for that day, bridged break and Claude included.
@(test)
test_past_day_totals_match_export :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	saved := tracker
	defer {
		tracker = saved
		bridge_rules_update()
	}
	tracker = Tracker{running = -1, last = -1, pinned = -1}
	append(&tracker.projects, Project{key = "p", name = "P", bridge = 10, claude = true})
	append(&tracker.projects, Project{key = "q", name = "Q", bridge = -1})
	bridge_rules_update()

	now := time.to_unix_seconds(time.now())
	from, to := local_day_range(now, 2)
	lines := [?]struct {
		s, e:         i64,
		p:            string,
		idle, claude: bool,
	} {
		{from - 1 * H, from + 1 * H, "P", false, false}, // over midnight: 1 h on the day
		{from + 9 * H, from + 10 * H, "P", false, false},
		{from + 10 * H, from + 10 * H + 5 * M, "P", true, false}, // bridged
		{from + 10 * H + 5 * M, from + 11 * H, "P", false, false},
		{from + 11 * H, from + 12 * H, "P", false, true}, // Claude, counts
		{from + 13 * H, from + 14 * H, "Q", false, false},
		{to - 30 * M, to + 1 * H, "Q", false, false}, // over the next midnight: 30 min
	}
	lb := strings.builder_make()
	for l in lines {
		fmt.sbprintf(&lb, "%s\t%s\t%s\t\t%s\n", iso_utc(l.s), iso_utc(l.e), l.p, l.idle ? "idle" : l.claude ? "claude" : "")
		append(&tracker.entries, Time_Entry{l.s, l.e, l.p, l.idle, false, l.claude})
	}
	totals := tracker_totals(from, to)
	testing.expect_value(t, totals["P"], 4 * H)
	testing.expect_value(t, totals["Q"], 1 * H + 30 * M)

	entries: [dynamic]Export_Entry
	export_parse(strings.to_string(lb), "", &entries)
	for name in ([]string{"P", "Q"}) {
		_, exported, _ := export_csv(entries[:], {project = name, from = from, to = to, bridge = bridge_rules()}, context.temp_allocator)
		testing.expect_value(t, exported, totals[name])
	}
	// The day before only has the hour before midnight.
	pf, pt := local_day_range(now, 3)
	q := tracker_totals(pf, pt)
	testing.expect_value(t, q["P"], 1 * H)
	testing.expect_value(t, q["Q"], i64(0))
}
