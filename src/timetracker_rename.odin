// Renaming a time-tracking project: `wlperch track rename OLD NEW` or the
// pencil on a project row in the Time panel.
//
// A project's name lives in three places: config.ini ([project.KEY] name =,
// which decides the name new time is logged under), the time log (one name
// per line, tab-separated, matched exactly, case-sensitive) and the sway
// workspaces "<name> N" that count as the project. A rename changes the
// first two (backing up both files first) and, when asked, renames the
// workspaces too: otherwise the old workspaces stop counting until the
// project is reopened under its new name.
//
// Renaming onto a name that already exists merges the two projects; where
// their entries overlap in time, the overlap is counted once (later entries
// are trimmed, wholly covered ones dropped).
//
// The daemon owns the log, so the CLI asks it over IPC; with no daemon
// running the CLI does the same work itself.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

Rename_Stats :: struct {
	entries:      int, // log lines renamed
	work_entries: int,
	work_secs:    i64,
	breaks:       int,
	break_secs:   i64,
	first, last:  i64, // time span of the renamed entries
	target:       int, // lines already under the new name (a merge)
	trimmed:      int, // merged entries shortened: they overlapped another
	dropped:      int, // merged entries removed: wholly covered by another
	overlap_secs: i64, // work time that would have been counted twice
	other_case:   int, // lines whose name differs from `old` only in case (left alone)
	other_name:   string,
}

// Rewrite the log text: every line whose project field is exactly `old` gets
// `new`. Other lines (and unparseable ones) are kept byte for byte. When
// `new` already has entries, overlapping entries of the merged project (work
// with work, breaks with breaks) are trimmed so no time counts twice.
timelog_rename :: proc(data, old, new: string, allocator := context.temp_allocator) -> (out: string, st: Rename_Stats) {
	Rec :: struct {
		fields:     []string,
		start, end: i64,
		ok, idle:   bool,
		target:     bool, // under `new` after the rename
		changed:    bool,
		drop:       bool,
	}
	lines := strings.split_after(data, "\n", context.temp_allocator)
	recs := make([]Rec, len(lines), context.temp_allocator)
	for raw, i in lines {
		line := strings.trim_right(raw, "\r\n")
		f := strings.split(line, "\t", context.temp_allocator)
		r := &recs[i]
		r.fields = f
		if len(f) < 3 {continue}
		s, ok1 := parse_iso_utc(f[0])
		e, ok2 := parse_iso_utc(f[1])
		r.ok = ok1 && ok2 && e > s
		r.start, r.end = s, e
		r.idle = len(f) > 4 && f[4] == "idle"
		switch {
		case f[2] == old:
			f[2] = new
			r.target, r.changed = true, true
			st.entries += 1
			if !r.ok {continue}
			if r.idle {
				st.breaks += 1
				st.break_secs += e - s
			} else {
				st.work_entries += 1
				st.work_secs += e - s
			}
			st.first = st.first == 0 ? s : min(st.first, s)
			st.last = max(st.last, e)
		case f[2] == new:
			r.target = true
			st.target += 1
		case strings.equal_fold(f[2], old):
			st.other_case += 1
			st.other_name = f[2]
		}
	}
	if st.entries > 0 && st.target > 0 {
		for idle in ([]bool{false, true}) {
			idx: [dynamic]int
			idx.allocator = context.temp_allocator
			for r, i in recs {if r.target && r.ok && r.idle == idle {append(&idx, i)}}
			// Stable insertion sort by start (logs are nearly sorted already).
			for i in 1 ..< len(idx) {
				for j := i; j > 0 && recs[idx[j]].start < recs[idx[j - 1]].start; j -= 1 {idx[j], idx[j - 1] = idx[j - 1], idx[j]}
			}
			covered := min(i64)
			for k in idx {
				r := &recs[k]
				if r.end <= covered {
					r.drop = true
					st.dropped += 1
					if !idle {st.overlap_secs += r.end - r.start}
					continue
				}
				if r.start < covered {
					if !idle {st.overlap_secs += covered - r.start}
					r.start = covered
					r.fields[0] = iso_utc(covered)
					r.changed = true
					st.trimmed += 1
				}
				covered = r.end
			}
		}
	}
	b := strings.builder_make(allocator)
	for r, i in recs {
		if r.drop {continue}
		if !r.changed {
			strings.write_string(&b, lines[i])
			continue
		}
		line := strings.trim_right(lines[i], "\r\n")
		for f, j in r.fields {
			if j > 0 {strings.write_byte(&b, '\t')}
			strings.write_string(&b, f)
		}
		strings.write_string(&b, lines[i][len(line):])
	}
	return strings.to_string(b), st
}

// Why `name` can't be a project name ("" = it can). Names are one field of
// the tab-separated log, a value and a section key in config.ini, and the
// part before " N" of sway workspace names.
project_name_problem :: proc(name: string) -> string {
	if name == "" {return "the name is empty"}
	if strings.trim_space(name) != name {return "the name starts or ends with a space"}
	if len(name) > 64 {return "the name is longer than 64 characters"}
	if name == NO_PROJECT {return "that name is reserved for breaks outside projects"}
	if name[0] >= '0' && name[0] <= '9' {return "the name starts with a digit (sway would treat its workspaces as numbered ones)"}
	for r in name {
		if r < ' ' || r == 0x7f {return "the name contains a tab or another control character"}
		if strings.contains_rune(`[]=;#"\`, r) {return fmt.tprintf("the name contains %q", r)}
	}
	return ""
}

// Sway workspaces of the project: "old N" -> "new N". A target that already
// exists (merging) can't be renamed onto and is listed in `blocked`.
workspace_rename_plan :: proc(names: []string, old, new: string) -> (moves: [][2]string, blocked: []string) {
	mv: [dynamic][2]string
	mv.allocator = context.temp_allocator
	bl: [dynamic]string
	bl.allocator = context.temp_allocator
	for n in names {
		if !strings.has_prefix(n, old) || len(n) < len(old) + 2 || n[len(old)] != ' ' {continue}
		num := n[len(old) + 1:]
		if _, ok := strconv.parse_int(num); !ok {continue}
		to := fmt.tprintf("%s %s", new, num)
		if slice.contains(names, to) {
			append(&bl, n)
		} else {
			append(&mv, [2]string{n, to})
		}
	}
	return mv[:], bl[:]
}

@(private = "file")
sway_workspace_names :: proc() -> []string {
	out: [dynamic]string
	out.allocator = context.temp_allocator
	reply, ok := sway_request(IPC_GET_WORKSPACES, "")
	if !ok {return nil}
	v, _ := jparse(reply)
	for ws in jarr(v) {append(&out, strings.clone(jstr(jobj(ws, "name")), context.temp_allocator))}
	return out[:]
}

Rename_Opts :: struct {
	dry_run:    bool,
	merge:      bool, // allowed to merge into an existing project
	workspaces: bool, // also rename the sway workspaces
}

Rename_Plan :: struct {
	old, new:        string,
	err:             string,
	note:            string, // e.g. the old name was matched ignoring case
	log_in, log_out: string,
	stats:           Rename_Stats,
	cfg_in, cfg_out: string,
	cfg:             Config_Rename,
	cfg_exists:      bool,
	merge:           bool,
	ws_moves:        [][2]string,
	ws_blocked:      []string,
}

// What renaming `old` to `new` would do, from the files as they are now
// (temp allocator). Nothing is written.
rename_plan :: proc(old_in, new_in: string) -> (p: Rename_Plan) {
	p.old = strings.trim_space(old_in)
	p.new = strings.trim_space(new_in)
	if why := project_name_problem(p.new); why != "" {
		p.err = fmt.tprintf("can't rename to %q: %s", p.new, why)
		return
	}
	if data, err := os.read_entire_file(tracker.log_path, context.temp_allocator); err == nil {p.log_in = string(data)}
	cfg_path := config_path()
	defer delete(cfg_path)
	if data, err := os.read_entire_file(cfg_path, context.temp_allocator); err == nil {
		p.cfg_in = string(data)
		p.cfg_exists = true
	}

	// The old name: exactly as configured or logged; else a unique match ignoring case.
	known: [dynamic]string
	known.allocator = context.temp_allocator
	for pr in tracker.projects {append(&known, pr.name)}
	{
		entries: [dynamic]Time_Entry
		entries.allocator = context.temp_allocator
		context.allocator = context.temp_allocator
		timelog_parse(p.log_in, &entries)
		for e in entries {if e.project != NO_PROJECT && !slice.contains(known[:], e.project) {append(&known, e.project)}}
	}
	if !slice.contains(known[:], p.old) {
		match := ""
		n := 0
		for k in known {
			if strings.equal_fold(k, p.old) && k != match {
				match = k
				n += 1
			}
		}
		if n != 1 {
			p.err = fmt.tprintf("no project or time-log entries named %q (names are case-sensitive)", p.old)
			return
		}
		p.note = fmt.tprintf("matched %q as %q", p.old, match)
		p.old = match
	}
	if p.old == p.new {
		p.err = fmt.tprintf("%q already has that name", p.old)
		return
	}
	// Merging into an existing project uses its spelling.
	for k in known {
		if k != p.old && strings.equal_fold(k, p.new) {p.new = k}
	}
	p.cfg_out, p.cfg = config_rename_project(p.cfg_in, p.old, p.new)
	p.new = p.cfg.new_name
	p.log_out, p.stats = timelog_rename(p.log_in, p.old, p.new)
	p.merge = p.stats.target > 0 || p.cfg.merged_into != ""
	for k in known {if k == p.new {p.merge = true}}
	p.ws_moves, p.ws_blocked = workspace_rename_plan(sway_workspace_names(), p.old, p.new)
	return
}

// "1,234"
fmt_thousands :: proc(n: int) -> string {
	s := fmt.tprintf("%d", abs(n))
	b := strings.builder_make(context.temp_allocator)
	if n < 0 {strings.write_byte(&b, '-')}
	for c, i in s {
		if i > 0 && (len(s) - i) % 3 == 0 {strings.write_byte(&b, ',')}
		strings.write_rune(&b, c)
	}
	return strings.to_string(b)
}

@(private = "file")
fmt_hours :: proc(secs: i64) -> string {
	return fmt.tprintf("%s h", fmt_duration(secs))
}

@(private = "file")
fmt_date :: proc(t: i64) -> string {
	if r, ok := clock_read(local_region, time.unix(t, 0)); ok {return fmt.tprintf("%04d-%02d-%02d", r.dt.year, r.dt.month, r.dt.day)}
	dt, _ := time.time_to_datetime(time.unix(t, 0))
	return fmt.tprintf("%04d-%02d-%02d", dt.year, dt.month, dt.day)
}

// One line for confirm buttons and toasts: "wlwidgets → wlperch: 338 entries, 41:23 h".
rename_headline :: proc(p: Rename_Plan) -> string {
	verb := p.merge ? "Merge" : "Rename"
	return fmt.tprintf("%s %s → %s: %s entries, %s", verb, p.old, p.new, fmt_thousands(p.stats.entries), fmt_hours(p.stats.work_secs))
}

// What the rename changes, one item per line.
rename_details :: proc(p: Rename_Plan, opts: Rename_Opts) -> []string {
	out: [dynamic]string
	out.allocator = context.temp_allocator
	st := p.stats
	if p.note != "" {append(&out, p.note)}
	if st.entries > 0 {
		append(&out, fmt.tprintf("time log: %s entries renamed (%s work, %s of it; %s breaks, %s), %s to %s",
			fmt_thousands(st.entries), fmt_thousands(st.work_entries), fmt_hours(st.work_secs), fmt_thousands(st.breaks), fmt_hours(st.break_secs),
			fmt_date(st.first), fmt_date(st.last)))
	} else {
		append(&out, fmt.tprintf("time log: no entries under %q", p.old))
	}
	if p.merge {
		append(&out, fmt.tprintf("merge: %q already has %s entries; both become one project", p.new, fmt_thousands(st.target)))
		if st.trimmed + st.dropped > 0 {
			append(&out, fmt.tprintf("overlaps: %d entries trimmed, %d dropped, %s no longer counted twice", st.trimmed, st.dropped, fmt_hours(st.overlap_secs)))
		} else if st.entries > 0 && st.target > 0 {
			append(&out, "overlaps: none")
		}
	}
	if st.other_case > 0 {
		append(&out, fmt.tprintf("left alone: %s entries under %q (names are case-sensitive)", fmt_thousands(st.other_case), st.other_name))
	}
	switch {
	case !p.cfg.found:
		append(&out, fmt.tprintf("config.ini: no [project.*] named %q", p.old))
	case p.cfg.merged_into != "":
		append(&out, fmt.tprintf("config.ini: [%s] removed; [%s] stays (its colour and client)", p.cfg.section, p.cfg.merged_into))
	case p.cfg.new_section != "":
		append(&out, fmt.tprintf("config.ini: [%s] becomes [%s], name = %s (colour and client kept)", p.cfg.section, p.cfg.new_section, p.new))
	case:
		append(&out, fmt.tprintf("config.ini: [%s] name = %s (colour and client kept)", p.cfg.section, p.new))
	}
	if len(p.ws_moves) > 0 {
		names: [dynamic]string
		names.allocator = context.temp_allocator
		for m in p.ws_moves {append(&names, fmt.tprintf("%s → %s", m[0], m[1]))}
		list := strings.join(names[:], ", ", context.temp_allocator)
		if opts.workspaces {
			append(&out, fmt.tprintf("sway workspaces: %s", list))
		} else if p.cfg.found {
			append(&out, fmt.tprintf("sway workspaces NOT renamed: %s. They stop counting as %s until they're renamed too (--workspaces) or you reopen the project", list, p.new))
		}
	}
	if len(p.ws_blocked) > 0 {
		append(&out, fmt.tprintf("sway workspaces left as they are (%q exists already): %s", p.new, strings.join(p.ws_blocked, ", ", context.temp_allocator)))
	}
	return out[:]
}

@(private = "file")
backup_stamp :: proc() -> string {
	now := time.to_unix_seconds(time.now())
	dt, _ := time.time_to_datetime(time.unix(now, 0))
	if r, ok := clock_read(local_region, time.unix(now, 0)); ok {dt = r.dt}
	return fmt.tprintf("%04d%02d%02d-%02d%02d%02d", dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second)
}

// Copy `data` (the file's current content) to "<path>.before-rename-<stamp>".
@(private = "file")
write_backup :: proc(path, data, stamp: string) -> (string, bool) {
	bak := fmt.tprintf("%s.before-rename-%s", path, stamp)
	for i := 2; os.exists(bak); i += 1 {bak = fmt.tprintf("%s.before-rename-%s-%d", path, stamp, i)}
	mode := os.Permissions_Default_File
	if fi, err := os.stat(path, context.temp_allocator); err == nil {mode = fi.mode & os.Permissions_All}
	if err := os.write_entire_file(bak, data, mode); err != nil {return bak, false}
	return bak, true
}

// The crash-recovery files hold "start<TAB>beat<TAB>project<TAB>client".
@(private = "file")
rename_state_file :: proc(path, old, new: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return}
	f := strings.split(strings.trim_right(string(data), "\n"), "\t", context.temp_allocator)
	if len(f) < 3 || f[2] != old {return}
	f[2] = new
	write_file_atomic(path, strings.concatenate({strings.join(f, "\t", context.temp_allocator), "\n"}, context.temp_allocator))
}

// Plan, and unless it's a dry run, apply. Returns the report for the user.
// `in_daemon`: also update the running tracker's state.
tracker_rename :: proc(old, new: string, opts: Rename_Opts, in_daemon: bool) -> (report: string, ok: bool) {
	p := rename_plan(old, new)
	if p.err != "" {return fmt.tprintf("error: %s\n", p.err), false}
	b := strings.builder_make(context.temp_allocator)
	head := rename_headline(p)
	if opts.dry_run {fmt.sbprintf(&b, "dry run: %s\n", head)} else {fmt.sbprintf(&b, "%s\n", head)}
	for l in rename_details(p, opts) {fmt.sbprintf(&b, "  %s\n", l)}
	if p.stats.entries == 0 && !p.cfg.found {
		return fmt.tprintf("error: nothing is named %q\n", p.old), false
	}
	if p.merge && !opts.merge {
		fmt.sbprintf(&b, "error: %q already exists: renaming merges both projects into one. Add --merge to do that.\n", p.new)
		return strings.to_string(b), false
	}
	if opts.dry_run {
		strings.write_string(&b, "nothing changed (dry run)\n")
		return strings.to_string(b), true
	}

	stamp := backup_stamp()
	cfg_path := config_path()
	defer delete(cfg_path)
	if p.log_out != p.log_in {
		bak, bok := write_backup(tracker.log_path, p.log_in, stamp)
		if !bok {return fmt.tprintf("error: could not write the backup %s; nothing changed\n", bak), false}
		if !write_file_atomic(tracker.log_path, p.log_out) {return fmt.tprintf("error: could not rewrite %s; nothing changed\n", tracker.log_path), false}
		fmt.sbprintf(&b, "backup of the time log: %s\n", bak)
	}
	if p.cfg_exists && p.cfg_out != p.cfg_in {
		bak, bok := write_backup(cfg_path, p.cfg_in, stamp)
		if !bok || !write_file_atomic(cfg_path, p.cfg_out) {
			fmt.sbprintf(&b, "error: could not update %s (the log was renamed; rename the project there by hand)\n", cfg_path)
			return strings.to_string(b), false
		}
		fmt.sbprintf(&b, "backup of the config: %s\n", bak)
	}
	rename_state_file(tracker.cur_path, p.old, p.new)
	rename_state_file(tracker.away_path, p.old, p.new)
	if in_daemon {tracker_apply_rename(p)}
	if opts.workspaces {
		for m in p.ws_moves {
			if !sway_command(fmt.tprintf(`rename workspace "%s" to "%s"`, sway_quote(m[0]), sway_quote(m[1]))) {
				fmt.sbprintf(&b, "sway refused to rename workspace %q\n", m[0])
			}
		}
		// Know the new names before the next tick, so the running segment
		// carries on instead of stopping on a workspace that "left" the project.
		if in_daemon && len(p.ws_moves) > 0 {sway_refresh_workspaces()}
	}
	log.infof("time tracking: %s", head)
	strings.write_string(&b, "undo: copy the backups back over the files, then wlperch restart\n")
	return strings.to_string(b), true
}

// The running tracker after a rename: entries reread, the project renamed
// (or, merged, dropped in favour of the existing one), indices kept valid.
@(private = "file")
tracker_apply_rename :: proc(p: Rename_Plan) {
	for e in tracker.entries {delete(e.project)}
	clear(&tracker.entries)
	timelog_parse(p.log_out, &tracker.entries)
	si, di := -1, -1
	for pr, i in tracker.projects {
		if pr.name == p.old {si = i}
		if pr.name == p.new {di = i}
	}
	if si >= 0 && di >= 0 {
		fix :: proc(i: ^int, si, di: int) {
			if i^ == si {i^ = di}
			if i^ > si {i^ -= 1}
		}
		fix(&tracker.running, si, di)
		fix(&tracker.last, si, di)
		fix(&tracker.pinned, si, di)
		ordered_remove(&tracker.projects, si)
	} else if si >= 0 {
		pr := &tracker.projects[si]
		pr.name = strings.clone(p.new)
		if p.cfg.new_section != "" {pr.key = strings.clone(p.cfg.new_section[len("project."):])}
	}
	bridge_rules_update() // its threshold goes by name
	if tracker.away && tracker.away_project == p.old {
		delete(tracker.away_project)
		tracker.away_project = strings.clone(p.new)
	}
	request_redraw()
}

// IPC: "track rename" + "\x1f"-separated arguments (names may hold spaces).
track_rename_ipc :: proc(line: string) -> string {
	rest := line[len("track rename"):]
	args: []string
	if strings.has_prefix(rest, "\x1f") {
		args = strings.split(rest[1:], "\x1f", context.temp_allocator)
	} else {
		args = strings.fields(rest, context.temp_allocator)
	}
	opts, old, new, err := parse_rename_args(args)
	if err != "" {return err}
	report, _ := tracker_rename(old, new, opts, true)
	return report
}

RENAME_USAGE :: "usage: wlperch track rename [--dry-run] [--merge] [--workspaces] <old> <new>\n"

parse_rename_args :: proc(args: []string) -> (opts: Rename_Opts, old, new: string, err: string) {
	names: [dynamic]string
	names.allocator = context.temp_allocator
	for a in args {
		switch a {
		case "-n", "--dry-run":     opts.dry_run = true
		case "--merge":             opts.merge = true
		case "-w", "--workspaces":  opts.workspaces = true
		case "--no-workspaces":     opts.workspaces = false
		case:
			if strings.has_prefix(a, "--") {return opts, "", "", fmt.tprintf("unknown option %s\n%s", a, RENAME_USAGE)}
			append(&names, a)
		}
	}
	if len(names) != 2 {return opts, "", "", RENAME_USAGE}
	return opts, names[0], names[1], ""
}

// `wlperch track rename …`: through the daemon when it runs, else here.
track_rename_cli :: proc(args: []string) -> int {
	opts, old, new, err := parse_rename_args(args)
	if err != "" {
		fmt.eprint(err)
		return 2
	}
	line := strings.join({"track rename", strings.join(args, "\x1f", context.temp_allocator)}, "\x1f", context.temp_allocator)
	if reply, ok := ipc_query(line); ok {
		fmt.print(reply)
		return strings.contains(reply, "error:") ? 1 : 0
	}
	config_load()
	tracker_paths()
	report, rok := tracker_rename(old, new, opts, false)
	fmt.print(report)
	return rok ? 0 : 1
}
