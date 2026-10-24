// Unit tests for renaming time-tracking projects (timetracker_rename.odin).
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
day_totals :: proc(log_text: string) -> map[string]i64 {
	saved := tracker
	defer tracker = saved
	tracker = Tracker{running = -1}
	timelog_parse(log_text, &tracker.entries)
	day, _ := time.datetime_to_time(2026, 10, 23, 0, 0, 0)
	from := time.to_unix_seconds(day)
	return tracker_totals(from, from + 86400)
}

@(test)
test_timelog_rename_plain :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	LOG :: "2026-10-23T08:00:00Z\t2026-10-23T09:00:00Z\twlwidgets\t\n" +
		"2026-10-23T09:00:00Z\t2026-10-23T09:10:00Z\twlwidgets\t\tidle\n" +
		"garbage line\n" +
		"2026-10-23T09:10:00Z\t2026-10-23T09:40:00Z\tNeonRAW\tZec\n" +
		"2026-10-23T10:00:00Z\t2026-10-23T10:30:00Z\twl\t\n" + // a prefix of wlwidgets
		"2026-10-23T11:00:00Z\t2026-10-23T11:30:00Z\twlwidgets2\t\n" + // has it as a prefix
		"2026-10-23T12:00:00Z\t2026-10-23T12:20:00Z\tWLWidgets\t\n" + // differs in case only
		"2026-10-23T13:00:00Z\t2026-10-23T14:00:00Z\twlwidgets\t\n"
	out, st := timelog_rename(LOG, "wlwidgets", "wlperch")
	testing.expect_value(t, st.entries, 3)
	testing.expect_value(t, st.work_entries, 2)
	testing.expect_value(t, st.work_secs, 2 * 3600)
	testing.expect_value(t, st.breaks, 1)
	testing.expect_value(t, st.break_secs, 600)
	testing.expect_value(t, st.target, 0)
	testing.expect_value(t, st.other_case, 1)
	testing.expect_value(t, st.other_name, "WLWidgets")
	want := "2026-10-23T08:00:00Z\t2026-10-23T09:00:00Z\twlperch\t\n" +
		"2026-10-23T09:00:00Z\t2026-10-23T09:10:00Z\twlperch\t\tidle\n" +
		"garbage line\n" +
		"2026-10-23T09:10:00Z\t2026-10-23T09:40:00Z\tNeonRAW\tZec\n" +
		"2026-10-23T10:00:00Z\t2026-10-23T10:30:00Z\twl\t\n" +
		"2026-10-23T11:00:00Z\t2026-10-23T11:30:00Z\twlwidgets2\t\n" +
		"2026-10-23T12:00:00Z\t2026-10-23T12:20:00Z\tWLWidgets\t\n" +
		"2026-10-23T13:00:00Z\t2026-10-23T14:00:00Z\twlperch\t\n"
	testing.expect_value(t, out, want)

	// A name that is a substring of another only matches itself.
	out2, st2 := timelog_rename(LOG, "wl", "x")
	testing.expect_value(t, st2.entries, 1)
	testing.expect(t, strings.contains(out2, "\tx\t\n"))
	testing.expect_value(t, strings.count(out2, "\twlwidgets\t"), 3)
	testing.expect(t, strings.contains(out2, "\twlwidgets2\t"))

	// Unknown names change nothing; a log without a final newline keeps it so.
	out3, st3 := timelog_rename(LOG, "nope", "x")
	testing.expect_value(t, st3.entries, 0)
	testing.expect_value(t, out3, LOG)
	out4, _ := timelog_rename("2026-10-23T08:00:00Z\t2026-10-23T09:00:00Z\ta\t", "a", "b")
	testing.expect_value(t, out4, "2026-10-23T08:00:00Z\t2026-10-23T09:00:00Z\tb\t")
	// Project names with spaces are one tab-separated field.
	out5, st5 := timelog_rename("2026-10-23T08:00:00Z\t2026-10-23T09:00:00Z\tHome Lab\t\n", "Home Lab", "Home Lab Two")
	testing.expect_value(t, st5.entries, 1)
	testing.expect_value(t, out5, "2026-10-23T08:00:00Z\t2026-10-23T09:00:00Z\tHome Lab Two\t\n")
}

@(test)
test_timelog_rename_merge_overlaps :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// The same morning tracked under both names (e.g. two machines' logs).
	LOG :: "2026-10-23T08:00:00Z\t2026-10-23T10:00:00Z\twlwidgets\t\n" +
		"2026-10-23T09:00:00Z\t2026-10-23T11:00:00Z\twlperch\t\n" + // overlaps 1 h
		"2026-10-23T09:15:00Z\t2026-10-23T09:45:00Z\twlwidgets\t\n" + // wholly covered
		"2026-10-23T12:00:00Z\t2026-10-23T13:00:00Z\twlwidgets\t\n" + // no overlap
		"2026-10-23T11:00:00Z\t2026-10-23T11:10:00Z\twlperch\t\tidle\n" + // breaks are their own kind
		"2026-10-23T11:05:00Z\t2026-10-23T11:20:00Z\twlwidgets\t\tidle\n" +
		"2026-10-23T09:30:00Z\t2026-10-23T10:30:00Z\tNeonRAW\t\n" // other projects aren't touched
	before := day_totals(LOG)
	testing.expect_value(t, before["wlwidgets"] + before["wlperch"], 2 * 3600 + 1800 + 3600 + 2 * 3600)

	out, st := timelog_rename(LOG, "wlwidgets", "wlperch")
	testing.expect_value(t, st.entries, 4)
	testing.expect_value(t, st.target, 2)
	testing.expect_value(t, st.dropped, 1)
	testing.expect_value(t, st.trimmed, 2) // the 09:00 work entry, the 11:05 break
	testing.expect_value(t, st.overlap_secs, 3600 + 1800)
	after := day_totals(out)
	// 08:00-11:00 and 12:00-13:00: four hours, each counted once.
	testing.expect_value(t, after["wlperch"], 4 * 3600)
	testing.expect_value(t, after["wlwidgets"], 0)
	testing.expect_value(t, after["NeonRAW"], 3600)
	testing.expect(t, strings.contains(out, "2026-10-23T10:00:00Z\t2026-10-23T11:00:00Z\twlperch\t\n"))
	testing.expect(t, strings.contains(out, "2026-10-23T11:10:00Z\t2026-10-23T11:20:00Z\twlperch\t\tidle\n"))
	testing.expect(t, !strings.contains(out, "09:15:00Z"))
	testing.expect(t, strings.contains(out, "2026-10-23T09:30:00Z\t2026-10-23T10:30:00Z\tNeonRAW\t\n"))

	// A plain rename (nothing under the new name) never trims.
	_, st2 := timelog_rename(LOG, "NeonRAW", "Neon")
	testing.expect_value(t, st2.trimmed + st2.dropped, 0)
}

@(private = "file")
CFG :: `# wlperch configuration

[popup]
width = 860

# Projects
[project.wlwidgets]
name = wlwidgets
color = #73daca

[project.silvernode]
# my side project
name = SilverNode
color = #bb9af7

[project.Gump]
color = #ff7eb6

[sensors]
dir = ~/x
`

@(test)
test_config_rename_project :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	out, info := config_rename_project(CFG, "wlwidgets", "wlperch")
	testing.expect(t, info.found)
	testing.expect_value(t, info.section, "project.wlwidgets")
	testing.expect_value(t, info.new_section, "project.wlperch")
	want, _ := strings.replace(CFG, "[project.wlwidgets]\nname = wlwidgets", "[project.wlperch]\nname = wlperch", 1)
	testing.expect_value(t, out, want)

	// Mixed-case name, lowercase key: the key becomes the lowercased new name.
	out, info = config_rename_project(CFG, "SilverNode", "Silver Node")
	testing.expect_value(t, info.new_section, "project.silver-node")
	testing.expect(t, strings.contains(out, "[project.silver-node]\n# my side project\nname = Silver Node\ncolor = #bb9af7\n"))

	// No name key: the key is the name; it gets a name line and keeps its case style.
	out, info = config_rename_project(CFG, "Gump", "Gumpy")
	testing.expect_value(t, info.new_section, "project.Gumpy")
	testing.expect(t, strings.contains(out, "[project.Gumpy]\ncolor = #ff7eb6\nname = Gumpy\n"))

	// Case-sensitive: "WLWIDGETS" is not the project.
	out, info = config_rename_project(CFG, "WLWIDGETS", "x")
	testing.expect(t, !info.found)
	testing.expect_value(t, out, CFG)

	// Onto an existing project (any case): a merge, the old section goes.
	out, info = config_rename_project(CFG, "wlwidgets", "silvernode")
	testing.expect_value(t, info.merged_into, "project.silvernode")
	testing.expect_value(t, info.new_name, "SilverNode")
	testing.expect(t, !strings.contains(out, "wlwidgets"))
	testing.expect(t, !strings.contains(out, "#73daca"))
	testing.expect(t, strings.contains(out, "# Projects\n[project.silvernode]\n# my side project\n"))
	testing.expect(t, strings.contains(out, "[sensors]\ndir = ~/x\n"))
}

@(test)
test_project_rename_names_and_workspaces :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, project_name_problem("wlperch"), "")
	testing.expect_value(t, project_name_problem("Home Lab"), "")
	testing.expect(t, project_name_problem("") != "")
	testing.expect(t, project_name_problem(" x") != "")
	testing.expect(t, project_name_problem("a\tb") != "")
	testing.expect(t, project_name_problem("3D") != "")
	testing.expect(t, project_name_problem("[x]") != "")
	testing.expect(t, project_name_problem(NO_PROJECT) != "")

	ws := []string{"1", "wlwidgets 1", "wlwidgets 2", "wlwidgets", "wl 1", "wlwidgets x", "wlperch 2"}
	moves, blocked := workspace_rename_plan(ws, "wlwidgets", "wlperch")
	testing.expect_value(t, len(moves), 1)
	if len(moves) == 1 {
		testing.expect_value(t, moves[0][0], "wlwidgets 1")
		testing.expect_value(t, moves[0][1], "wlperch 1")
	}
	testing.expect_value(t, len(blocked), 1) // "wlperch 2" exists already
	moves, _ = workspace_rename_plan(ws, "wl", "x")
	testing.expect_value(t, len(moves), 1)
	testing.expect_value(t, fmt_thousands(1234567), "1,234,567")
	testing.expect_value(t, fmt_thousands(12), "12")
}

// The whole thing on files: backups, atomic rewrite, the merge needing --merge.
@(test)
test_tracker_rename_files :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fmt.tprintf("/tmp/wlperch-rename-test-%d", os.get_pid())
	os.make_directory_all(fmt.tprintf("%s/config/wlperch", dir))
	os.make_directory_all(fmt.tprintf("%s/data/wlperch", dir))
	defer os.remove_all(dir)
	keep := []string{"XDG_CONFIG_HOME", "XDG_DATA_HOME", "SWAYSOCK"}
	old_env: [3]string
	for k, i in keep {old_env[i] = strings.clone(os.get_env(k, context.temp_allocator))}
	defer for k, i in keep {os.set_env(k, old_env[i])}
	os.set_env("XDG_CONFIG_HOME", fmt.tprintf("%s/config", dir))
	os.set_env("XDG_DATA_HOME", fmt.tprintf("%s/data", dir))
	os.set_env("SWAYSOCK", "") // never the real session

	saved := tracker
	defer tracker = saved
	tracker = Tracker{running = -1, last = -1, pinned = -1}
	tracker_paths()
	append(&tracker.projects, Project{key = "wlwidgets", name = "wlwidgets"}, Project{key = "silvernode", name = "SilverNode"})
	LOG :: "2026-10-23T08:00:00Z\t2026-10-23T09:00:00Z\twlwidgets\t\n" +
		"2026-10-23T09:00:00Z\t2026-10-23T10:00:00Z\tSilverNode\t\n"
	cfg_path := config_path()
	testing.expect(t, os.write_entire_file(tracker.log_path, LOG) == nil)
	testing.expect(t, os.write_entire_file(cfg_path, CFG) == nil)
	testing.expect(t, os.write_entire_file(tracker.cur_path, "1\t2\twlwidgets\t\n") == nil)

	// Dry run: a report, nothing written.
	report, ok := tracker_rename("wlwidgets", "wlperch", {dry_run = true}, true)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(report, "dry run: Rename wlwidgets → wlperch: 1 entries, 1:00 h"), report)
	data, _ := os.read_entire_file(tracker.log_path, context.temp_allocator)
	testing.expect_value(t, string(data), LOG)

	// Unknown names and bad new names are refused.
	report, ok = tracker_rename("nope", "x", {}, true)
	testing.expect(t, !ok && strings.contains(report, "error:"))
	report, ok = tracker_rename("wlwidgets", "a\tb", {}, true)
	testing.expect(t, !ok)

	// The rename: backups hold the old files.
	report, ok = tracker_rename("wlwidgets", "wlperch", {}, true)
	testing.expect(t, ok, report)
	data, _ = os.read_entire_file(tracker.log_path, context.temp_allocator)
	testing.expect_value(t, string(data), "2026-10-23T08:00:00Z\t2026-10-23T09:00:00Z\twlperch\t\n2026-10-23T09:00:00Z\t2026-10-23T10:00:00Z\tSilverNode\t\n")
	cfg, _ := os.read_entire_file(cfg_path, context.temp_allocator)
	testing.expect(t, strings.contains(string(cfg), "[project.wlperch]\nname = wlperch\n"))
	cur, _ := os.read_entire_file(tracker.cur_path, context.temp_allocator)
	testing.expect_value(t, string(cur), "1\t2\twlperch\t\n")
	backups := 0
	for d in ([]string{fmt.tprintf("%s/data/wlperch", dir), fmt.tprintf("%s/config/wlperch", dir)}) {
		fis, _ := os.read_all_directory_by_path(d, context.temp_allocator)
		for fi in fis {
			if !strings.contains(fi.name, ".before-rename-") {continue}
			backups += 1
			b, _ := os.read_entire_file(fi.fullpath, context.temp_allocator)
			if strings.has_prefix(fi.name, "timelog.tsv") {testing.expect_value(t, string(b), LOG)}
			if strings.has_prefix(fi.name, "config.ini") {testing.expect_value(t, string(b), CFG)}
			testing.expect(t, strings.contains(report, fi.name), report)
		}
		testing.expect(t, !os.exists(fmt.tprintf("%s/timelog.tsv.wlperch-tmp", d)))
	}
	testing.expect_value(t, backups, 2)
	// The running tracker follows.
	testing.expect_value(t, tracker.projects[0].name, "wlperch")
	testing.expect_value(t, tracker.projects[0].key, "wlperch")
	testing.expect_value(t, tracker.entries[0].project, "wlperch")

	// Onto an existing project: refused without --merge, then merged.
	report, ok = tracker_rename("wlperch", "silvernode", {}, true)
	testing.expect(t, !ok && strings.contains(report, "--merge"), report)
	tracker.running = 0
	report, ok = tracker_rename("wlperch", "silvernode", {merge = true}, true)
	testing.expect(t, ok, report)
	data, _ = os.read_entire_file(tracker.log_path, context.temp_allocator)
	testing.expect_value(t, strings.count(string(data), "\tSilverNode\t"), 2)
	testing.expect_value(t, len(tracker.projects), 1)
	testing.expect_value(t, tracker.running, 0) // now counts SilverNode
	testing.expect_value(t, tracker.projects[0].name, "SilverNode")
}
