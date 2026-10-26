// Exporting tracked hours as CSV, for invoicing or other post-processing:
// `wlperch track export` or the Export section of the Time panel.
//
// The rows come from the time log (timelog.tsv: start, end, project,
// client, optional "idle") plus the segment that is still counting. Each
// entry is cut to the date range and at local midnights, so every row
// belongs to one calendar day. Three shapes:
//   entries  date,start,end,minutes,hours,project,client,type
//   day      date,project,client,minutes,hours,type
//   project  project,client,minutes,hours,days,type
// Times are local; hours have two decimals and are computed from seconds
// (sum them, don't sum the rounded minutes). type is work or break (breaks
// only with --breaks). Short breaks bridged as work (bridge_breaks) count as
// work; with --breaks, entry rows mark them type bridged (still worked hours),
// day and project rows fold them into the work rows.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

Export_Group :: enum {Entries, Day, Project}

EXPORT_GROUP_NAMES := [Export_Group]string {
	.Entries = "entries",
	.Day     = "day",
	.Project = "project",
}

Export_Entry :: struct {
	start, end:      i64,
	project, client: string,
	idle:            bool,
	bridged:         bool, // set by export_csv: a short break counted as work
}

Export_Opts :: struct {
	project: string, // "" = all projects
	from:    i64, // inclusive, unix seconds
	to:      i64, // exclusive; 0 = no end
	group:   Export_Group,
	breaks:  bool, // also the time away from the keyboard
	bridge:  Bridge_Rules, // which breaks count as work (bridge_rules())
}

// The time log's lines (and a still-counting segment: "start\tend\tproject\tclient").
export_parse :: proc(log_text, current_text: string, out: ^[dynamic]Export_Entry) {
	text := log_text
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 3 {continue}
		s, ok1 := parse_iso_utc(f[0])
		e, ok2 := parse_iso_utc(f[1])
		if !ok1 || !ok2 || e <= s {continue}
		append(out, Export_Entry{s, e, f[2], len(f) > 3 ? f[3] : "", len(f) > 4 && f[4] == "idle", false})
	}
	if f := strings.split(strings.trim_space(current_text), "\t", context.temp_allocator); len(f) >= 3 {
		s, ok1 := strconv.parse_i64(f[0])
		e, ok2 := strconv.parse_i64(f[1])
		// Just started (no heartbeat yet) still counts: it decides whether the
		// break before it is bridged.
		if ok1 && ok2 && e >= s {append(out, Export_Entry{s, e, f[2], len(f) > 3 ? f[3] : "", false, false})}
	}
}

// Everything to export, read from disk; `live` (the daemon) adds the
// segment that is counting right now instead of the last heartbeat's.
export_collect :: proc(live: bool, out: ^[dynamic]Export_Entry) {
	if tracker.log_path == "" {tracker_paths()}
	log_text, _ := os.read_entire_file(tracker.log_path, context.temp_allocator)
	cur: string
	if live {
		if tracker.running >= 0 {
			pr := tracker.projects[tracker.running]
			cur = fmt.tprintf("%d\t%d\t%s\t%s", tracker.seg_start, time.to_unix_seconds(time.now()), pr.name, pr.client)
		}
	} else if data, err := os.read_entire_file(tracker.cur_path, context.temp_allocator); err == nil {
		cur = string(data)
	}
	export_parse(string(log_text), cur, out)
}

@(private = "file")
Export_Piece :: struct {
	start, end:      i64,
	day:             i64, // local midnight
	project, client: string,
	idle:            bool, // a break (not bridged)
	bridged:         bool, // a short break counted as work
}

// Local midnight of the day after the one starting at `day` (DST-safe).
@(private = "file")
next_local_day :: proc(day: i64) -> i64 {return local_day_start(day + 86400 + 7200)}

@(private = "file")
local_dt :: proc(t: i64) -> (y, mo, d, h, mi: int) {
	if r, ok := clock_read(local_region, time.unix(t, 0)); ok {
		return int(r.dt.year), int(r.dt.month), int(r.dt.day), int(r.dt.hour), int(r.dt.minute)
	}
	return
}

@(private = "file")
fmt_date :: proc(t: i64) -> string {
	y, mo, d, _, _ := local_dt(t)
	return fmt.tprintf("%04d-%02d-%02d", y, mo, d)
}

@(private = "file")
fmt_hm :: proc(t: i64) -> string {
	_, _, _, h, mi := local_dt(t)
	return fmt.tprintf("%02d:%02d", h, mi)
}

@(private = "file")
csv_field :: proc(b: ^strings.Builder, s: string) {
	if strings.contains_any(s, ",\"\n\r") {
		q, _ := strings.replace_all(s, "\"", "\"\"", context.temp_allocator)
		fmt.sbprintf(b, "\"%s\"", q)
	} else {
		strings.write_string(b, s)
	}
}

@(private = "file")
csv_row :: proc(b: ^strings.Builder, fields: ..string) {
	for f, i in fields {
		if i > 0 {strings.write_byte(b, ',')}
		csv_field(b, f)
	}
	strings.write_byte(b, '\n')
}

@(private = "file")
fmt_hours :: proc(secs: i64) -> string {return fmt.tprintf("%.2f", f64(secs) / 3600)}

@(private = "file")
fmt_minutes :: proc(secs: i64) -> string {return fmt.tprintf("%d", (secs + 30) / 60)}

// The entries in range, cut at local midnights, oldest first. Bridging looks
// at the whole log (the work around a break may be outside the range or
// another project's filter).
@(private = "file")
export_pieces :: proc(entries: []Export_Entry, o: Export_Opts) -> []Export_Piece {
	out: [dynamic]Export_Piece
	out.allocator = context.temp_allocator
	bridged := bridge_mask(entries, o.bridge)
	for e, i in entries {
		e := e
		if bridged[i] {e.idle, e.bridged = false, true}
		if e.idle && !o.breaks {continue}
		if o.project != "" && e.project != o.project {continue}
		a := max(e.start, o.from)
		b := o.to > 0 ? min(e.end, o.to) : e.end
		for a < b {
			day := local_day_start(a)
			end := min(b, next_local_day(day))
			append(&out, Export_Piece{a, end, day, e.project, e.client, e.idle, e.bridged})
			a = end
		}
	}
	slice.sort_by(out[:], proc(x, y: Export_Piece) -> bool {return x.start < y.start})
	return out[:]
}

// Worked seconds in the range (and project) without bridging and with
// o.bridge, and how many bridged breaks make the difference. The same
// clipping as export_csv, so `with` equals its work_secs.
export_bridge_summary :: proc(entries: []Export_Entry, o: Export_Opts) -> (without, with: i64, gaps: int) {
	mask := bridge_mask(entries, o.bridge)
	for e, i in entries {
		if o.project != "" && e.project != o.project {continue}
		a := max(e.start, o.from)
		b := o.to > 0 ? min(e.end, o.to) : e.end
		if b <= a {continue}
		if !e.idle {
			without += b - a
			with += b - a
		} else if mask[i] {
			with += b - a
			gaps += 1
		}
	}
	return
}

// Every project bridges breaks shorter than `minutes` (an override, e.g.
// `--bridge` or the export's slider), whatever config.ini says.
bridge_rules_override :: proc(minutes: int) -> Bridge_Rules {
	return {default_secs = i64(clamp(minutes, LIM_BRIDGE_BREAKS.lo, LIM_BRIDGE_BREAKS.hi)) * 60, gen = -1}
}

// "19:24 h → 20:05 h (+0:41 h from 12 bridged gaps)", or one total when
// bridging changes nothing.
fmt_bridge_summary :: proc(without, with: i64, gaps: int) -> string {
	if with == without {return fmt.tprintf("%s h worked", fmt_duration(with))}
	// The difference of the minutes shown, so the line adds up.
	diff := (with / 60 - without / 60) * 60
	return fmt.tprintf("%s h → %s h (+%s h from %d bridged gap%s)", fmt_duration(without), fmt_duration(with), fmt_duration(diff), gaps, gaps == 1 ? "" : "s")
}

// The CSV text, plus the exported work time (breaks excluded) and row count.
export_csv :: proc(entries: []Export_Entry, o: Export_Opts, allocator := context.allocator) -> (csv: string, work_secs: i64, rows: int) {
	pieces := export_pieces(entries, o)
	for p in pieces {if !p.idle {work_secs += p.end - p.start}}
	kind :: proc(idle: bool, bridged := false) -> string {return idle ? "break" : bridged ? "bridged" : "work"}
	b := strings.builder_make(allocator)
	switch o.group {
	case .Entries:
		csv_row(&b, "date", "start", "end", "minutes", "hours", "project", "client", "type")
		for p in pieces {
			end := p.end == next_local_day(p.day) ? "24:00" : fmt_hm(p.end)
			csv_row(&b, fmt_date(p.day), fmt_hm(p.start), end, fmt_minutes(p.end - p.start), fmt_hours(p.end - p.start), p.project, p.client, kind(p.idle, p.bridged && o.breaks))
			rows += 1
		}
	case .Day, .Project:
		Key :: struct {day: i64, project, client: string, idle: bool}
		Sum :: struct {secs: i64, days: map[i64]bool}
		sums := make(map[Key]Sum, 64, context.temp_allocator)
		keys: [dynamic]Key
		keys.allocator = context.temp_allocator
		for p in pieces {
			k := Key{o.group == .Day ? p.day : 0, p.project, p.client, p.idle}
			s, seen := sums[k]
			if !seen {
				append(&keys, k)
				s.days = make(map[i64]bool, 8, context.temp_allocator)
			}
			s.secs += p.end - p.start
			s.days[p.day] = true
			sums[k] = s
		}
		slice.sort_by(keys[:], proc(x, y: Key) -> bool {
			if x.day != y.day {return x.day < y.day}
			if x.project != y.project {return x.project < y.project}
			if x.client != y.client {return x.client < y.client}
			return !x.idle && y.idle
		})
		if o.group == .Day {
			csv_row(&b, "date", "project", "client", "minutes", "hours", "type")
		} else {
			csv_row(&b, "project", "client", "minutes", "hours", "days", "type")
		}
		for k in keys {
			s := sums[k]
			if o.group == .Day {
				csv_row(&b, fmt_date(k.day), k.project, k.client, fmt_minutes(s.secs), fmt_hours(s.secs), kind(k.idle))
			} else {
				csv_row(&b, k.project, k.client, fmt_minutes(s.secs), fmt_hours(s.secs), fmt.tprintf("%d", len(s.days)), kind(k.idle))
			}
			rows += 1
		}
	}
	return strings.to_string(b), work_secs, rows
}

// ---- Date ranges ---------------------------------------------------------

// Local midnight starting the given calendar day.
local_date_start :: proc(y, m, d: int) -> (t: i64, ok: bool) {
	guess := time.to_unix_seconds(time.datetime_to_time(y, m, d, 0, 0, 0) or_return)
	off :: proc(t: i64) -> i64 {
		if r, ok := clock_read(local_region, time.unix(t, 0)); ok {return i64(r.offset_min) * 60}
		return 0
	}
	t = guess - off(guess)
	if o2 := off(t); guess - o2 != t {t = guess - o2}
	return t, true
}

// "2026-10-31" -> local midnight of that day.
parse_local_date :: proc(s: string) -> (t: i64, ok: bool) {
	s := strings.trim_space(s)
	if len(s) != 10 || s[4] != '-' || s[7] != '-' {return}
	y := strconv.parse_int(s[0:4]) or_return
	m := strconv.parse_int(s[5:7]) or_return
	d := strconv.parse_int(s[8:10]) or_return
	return local_date_start(y, m, d)
}

// A calendar month: "2026-10", or "this" / "last" (relative to now).
month_range :: proc(s: string, now: i64) -> (from, to: i64, label: string, ok: bool) {
	y, m: int
	switch s {
	case "this", "last":
		r := clock_read(local_region, time.unix(now, 0)) or_return
		y, m = int(r.dt.year), int(r.dt.month)
		if s == "last" {
			m -= 1
			if m == 0 {y, m = y - 1, 12}
		}
	case:
		if len(s) != 7 || s[4] != '-' {return}
		y = strconv.parse_int(s[0:4]) or_return
		m = strconv.parse_int(s[5:7]) or_return
		if m < 1 || m > 12 {return}
	}
	ny, nm := y, m + 1
	if nm == 13 {ny, nm = y + 1, 1}
	from = local_date_start(y, m, 1) or_return
	to = local_date_start(ny, nm, 1) or_return
	return from, to, fmt.tprintf("%04d-%02d", y, m), true
}

// ---- CLI -----------------------------------------------------------------

EXPORT_USAGE :: `usage: wlperch track export [options]
  Tracked hours as CSV (stdout, or -o FILE), e.g. for invoicing.
  --month YYYY-MM|this|last   one calendar month
  --from YYYY-MM-DD           first day (inclusive)
  --to YYYY-MM-DD             last day (inclusive)
                              (no range: everything in the log)
  --project NAME              one project (default: all)
  --by entries|day|project    one row per entry (default), per day, or per project
  --bridge MINUTES            count breaks shorter than this (0-120) as work
                              for every project, instead of config.ini's
                              bridge_breaks; 0 = no bridging
  --breaks                    also the time away from the keyboard (type=break);
                              entry rows of short breaks counted as work
                              ([timetracker] bridge_breaks) get type=bridged
  -o FILE                     write to FILE instead of stdout
`

// The project as the log spells it: exact, else a unique case-insensitive match.
@(private = "file")
resolve_project :: proc(entries: []Export_Entry, name: string) -> (string, bool) {
	match := ""
	for e in entries {
		if e.project == name {return name, true}
	}
	for e in entries {
		if strings.equal_fold(e.project, name) {
			if match != "" && match != e.project {return "", false}
			match = e.project
		}
	}
	return match, match != ""
}

track_export_cli :: proc(args: []string) -> int {
	o: Export_Opts
	out_path, month, from_s, to_s, bridge_s: string
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		val :: proc(args: []string, i: ^int) -> (string, bool) {
			if i^ + 1 >= len(args) {return "", false}
			i^ += 1
			return args[i^], true
		}
		ok := true
		switch a {
		case "--month":   month, ok = val(args, &i)
		case "--from":    from_s, ok = val(args, &i)
		case "--to":      to_s, ok = val(args, &i)
		case "--project": o.project, ok = val(args, &i)
		case "-o":        out_path, ok = val(args, &i)
		case "--breaks":  o.breaks = true
		case "--bridge":  bridge_s, ok = val(args, &i)
		case "--by":
			g: string
			g, ok = val(args, &i)
			found := false
			for name, k in EXPORT_GROUP_NAMES {if name == g {o.group, found = k, true}}
			ok = ok && found
		case "-h", "--help":
			fmt.print(EXPORT_USAGE)
			return 0
		case:
			ok = false
		}
		if !ok {
			fmt.eprint(EXPORT_USAGE)
			return 2
		}
	}
	now := time.to_unix_seconds(time.now())
	if month != "" {
		f, t, _, ok := month_range(month, now)
		if !ok {
			fmt.eprintfln("wlperch track export: not a month: %q (YYYY-MM, this or last)", month)
			return 2
		}
		o.from, o.to = f, t
	}
	if from_s != "" {
		t, ok := parse_local_date(from_s)
		if !ok {
			fmt.eprintfln("wlperch track export: not a date: %q (YYYY-MM-DD)", from_s)
			return 2
		}
		o.from = t
	}
	if to_s != "" {
		t, ok := parse_local_date(to_s)
		if !ok {
			fmt.eprintfln("wlperch track export: not a date: %q (YYYY-MM-DD)", to_s)
			return 2
		}
		o.to = next_local_day(t) // the last day is included
	}
	if o.to > 0 && o.to <= o.from {
		fmt.eprintln("wlperch track export: the range is empty")
		return 2
	}

	entries: [dynamic]Export_Entry
	entries.allocator = context.temp_allocator
	export_collect(false, &entries)
	if o.project != "" {
		name, ok := resolve_project(entries[:], o.project)
		if !ok {
			fmt.eprintfln("wlperch track export: no project %q in the time log", o.project)
			return 1
		}
		o.project = name
	}
	o.bridge = bridge_rules()
	if bridge_s != "" {
		m, mok := strconv.parse_int(bridge_s)
		if !mok || m < LIM_BRIDGE_BREAKS.lo || m > LIM_BRIDGE_BREAKS.hi {
			fmt.eprintfln("wlperch track export: --bridge takes minutes, 0 to %d: %q", LIM_BRIDGE_BREAKS.hi, bridge_s)
			return 2
		}
		o.bridge = bridge_rules_override(m)
	}
	csv, work, rows := export_csv(entries[:], o, context.temp_allocator)
	without, with, gaps := export_bridge_summary(entries[:], o)
	if out_path == "" {
		fmt.print(csv)
	} else if os.write_entire_file(out_path, csv) != nil {
		fmt.eprintfln("wlperch track export: can't write %s", out_path)
		return 1
	}
	fmt.eprintfln("%d rows, %s h worked (%s h)%s", rows, fmt_duration(work), fmt_hours(work), out_path != "" ? fmt.tprintf(" -> %s", out_path) : "")
	how := bridge_s != "" ? fmt.tprintf("--bridge %s", bridge_s) : "bridge_breaks from config.ini"
	fmt.eprintfln("bridging (%s): %s", how, fmt_bridge_summary(without, with, gaps))
	return 0
}

// ---- Where the panel saves ----------------------------------------------

// XDG_DOCUMENTS_DIR (user-dirs.dirs), else ~/Documents, else home.
export_dir :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	cfg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if cfg == "" {cfg = strings.concatenate({home, "/.config"}, context.temp_allocator)}
	if data, err := os.read_entire_file(strings.concatenate({cfg, "/user-dirs.dirs"}, context.temp_allocator), context.temp_allocator); err == nil {
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			l := strings.trim_space(line)
			if !strings.has_prefix(l, "XDG_DOCUMENTS_DIR=") {continue}
			v := strings.trim(l[len("XDG_DOCUMENTS_DIR="):], "\"")
			v, _ = strings.replace_all(v, "$HOME", home, context.temp_allocator)
			if os.is_dir(v) {return v}
		}
	}
	docs := strings.concatenate({home, "/Documents"}, context.temp_allocator)
	return os.is_dir(docs) ? docs : home
}

// "wlperch-hours-wlperch-2026-10.csv"; the project part keeps letters,
// digits, - and _.
export_file_name :: proc(project, range_label: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "wlperch-hours-")
	if project == "" {
		strings.write_string(&b, "all")
	} else {
		for r in project {
			switch r {
			case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_': strings.write_rune(&b, r)
			case:                                                 strings.write_byte(&b, '_')
			}
		}
	}
	fmt.sbprintf(&b, "-%s.csv", range_label)
	return strings.to_string(b)
}
