// Time export: cutting at the range and at midnights, grouping, CSV quoting.
// local_region is nil in tests, so "local" is UTC.
package main

import "core:strings"
import "core:testing"

@(private = "file")
T0 :: i64(1792800000) // 2026-10-24T00:00:00Z

@(test)
test_export_csv :: proc(t: ^testing.T) {
	entries := []Export_Entry {
		{T0 + 9 * 3600, T0 + 10 * 3600 + 30 * 60, "site", "ACME, Inc.", false}, // 1:30
		{T0 + 10 * 3600 + 30 * 60, T0 + 10 * 3600 + 45 * 60, "site", "ACME, Inc.", true}, // a break
		{T0 + 23 * 3600, T0 + 25 * 3600, "app", "", false}, // over midnight: 1 h each day
		{T0 - 3600, T0 + 3600, "site", "ACME, Inc.", false}, // starts the day before
	}
	day := Export_Opts{from = T0, to = T0 + 86400, group = .Entries}
	csv, work, rows := export_csv(entries, day, context.temp_allocator)
	testing.expect_value(t, rows, 3)
	testing.expect_value(t, work, i64(3600 + 5400 + 3600)) // clipped to the 24th
	testing.expect(t, strings.contains(csv, "2026-10-24,00:00,01:00,60,1.00,site,\"ACME, Inc.\",work\n"))
	testing.expect(t, strings.contains(csv, "2026-10-24,23:00,24:00,60,1.00,app,,work\n"))
	testing.expect(t, !strings.contains(csv, "break"))

	all := Export_Opts{group = .Day, breaks = true}
	csv, work, rows = export_csv(entries, all, context.temp_allocator)
	testing.expect_value(t, work, i64(2 * 3600 + 5400 + 2 * 3600))
	testing.expect(t, strings.contains(csv, "2026-10-23,site,\"ACME, Inc.\",60,1.00,work\n"))
	testing.expect(t, strings.contains(csv, "2026-10-24,site,\"ACME, Inc.\",150,2.50,work\n"))
	testing.expect(t, strings.contains(csv, "2026-10-24,site,\"ACME, Inc.\",15,0.25,break\n"))
	testing.expect(t, strings.contains(csv, "2026-10-25,app,,60,1.00,work\n"))

	one := Export_Opts{project = "app", group = .Project}
	csv, work, rows = export_csv(entries, one, context.temp_allocator)
	testing.expect_value(t, csv, "project,client,minutes,hours,days,type\napp,,120,2.00,2,work\n")
	testing.expect_value(t, rows, 1)
}

@(test)
test_export_ranges :: proc(t: ^testing.T) {
	from, to, lbl, ok := month_range("2026-12", 0)
	testing.expect(t, ok)
	testing.expect_value(t, lbl, "2026-12")
	testing.expect_value(t, to - from, i64(31 * 86400))
	_, _, _, ok = month_range("2026-13", 0)
	testing.expect(t, !ok)
	_, _, lbl, ok = month_range("last", T0) // asked on 2026-10-24
	testing.expect_value(t, lbl, "2026-09")
	d, dok := parse_local_date("2026-10-24")
	testing.expect(t, dok)
	testing.expect_value(t, d, T0)
	_, dok = parse_local_date("24-10-2026")
	testing.expect(t, !dok)
	parsed: [dynamic]Export_Entry
	parsed.allocator = context.temp_allocator
	export_parse("2026-10-24T09:00:00Z\t2026-10-24T10:00:00Z\tsite\tACME\n2026-10-24T10:00:00Z\t2026-10-24T10:05:00Z\tsite\tACME\tidle\n", "1792818000\t1792818600\tapp\t", &parsed)
	testing.expect_value(t, len(parsed), 3)
	if len(parsed) == 3 {
		testing.expect_value(t, parsed[0].client, "ACME")
		testing.expect(t, parsed[1].idle)
		testing.expect_value(t, parsed[2].project, "app")
	}
	testing.expect_value(t, export_file_name("Dent Office/2", "2026-10"), "wlperch-hours-Dent_Office_2-2026-10.csv")
}
