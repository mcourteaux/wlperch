// Exporting tracked hours as CSV, for invoicing or other post-processing:
// `wlperch track export` or the Export section of the Time panel.
//
// The rows come from the time log (timelog.tsv: start, end, project,
// client, optional "idle" or "claude") plus the segment that is still
// counting and what Claude is doing now. Each entry is cut to the date range
// and at local midnights, so every row belongs to one calendar day. Three shapes:
//   entries  date,start,end,minutes,hours,project,client,type,rate,amount
//   day      date,project,client,minutes,hours,type,rate,amount
//   project  project,client,minutes,hours,days,type,rate,amount
// Times are local; hours have two decimals and are computed from seconds
// (sum them, don't sum the rounded minutes). type is work or break (breaks
// only with --breaks). Short breaks bridged as work (bridge_breaks) count as
// work; with --breaks, entry rows mark them type bridged (still worked hours),
// day and project rows fold them into the work rows. Claude's background
// work (claude_counts) is worked time too: entry rows mark it type claude,
// day and project rows fold it into work. rate and amount (hours × rate, two
// decimals) are filled in for work rows of paying projects with a rate.
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
	claude:          bool, // Claude working on it (see tracker_fold)
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
		append(out, Export_Entry{s, e, f[2], len(f) > 3 ? f[3] : "", len(f) > 4 && f[4] == "idle", false, len(f) > 4 && f[4] == "claude"})
	}
	if f := strings.split(strings.trim_space(current_text), "\t", context.temp_allocator); len(f) >= 3 {
		s, ok1 := strconv.parse_i64(f[0])
		e, ok2 := strconv.parse_i64(f[1])
		// Just started (no heartbeat yet) still counts: it decides whether the
		// break before it is bridged.
		if ok1 && ok2 && e >= s {append(out, Export_Entry{s, e, f[2], len(f) > 3 ? f[3] : "", false, false, false})}
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
	// Claude's open stretches (the daemon's, or its last heartbeat).
	now := time.to_unix_seconds(time.now())
	segs := tracker.claude_segs[:]
	if !live {
		data, _ := os.read_entire_file(tracker.claude_path, context.temp_allocator)
		segs = claude_state_parse(string(data))
	}
	for c in segs {append(out, Export_Entry{c.start, live ? max(now, c.last) : c.last, c.project, c.client, false, false, true})}
}

// The hourly rate a project's work is billed at: 0 unless it's paying and has one.
project_rate :: proc(name: string) -> f64 {
	if i := project_find(name); i >= 0 && tracker.projects[i].paying {return tracker.projects[i].rate}
	return 0
}

// "€1,234.50", or "1,234.50 EUR" for a currency code.
fmt_money :: proc(amount: f64) -> string {
	cents := i64(amount * 100 + (amount >= 0 ? 0.5 : -0.5))
	whole := abs(cents) / 100
	b := strings.builder_make(context.temp_allocator)
	if cents < 0 {strings.write_byte(&b, '-')}
	digits := fmt.tprintf("%d", whole)
	for r, i in digits {
		if i > 0 && (len(digits) - i) % 3 == 0 {strings.write_byte(&b, ',')}
		strings.write_rune(&b, r)
	}
	num := fmt.tprintf("%s.%02d", strings.to_string(b), abs(cents) % 100)
	cur := tracker.currency
	code := len(cur) == 3
	for c in transmute([]u8)cur {code &&= c >= 'A' && c <= 'Z'}
	return code ? fmt.tprintf("%s %s", num, cur) : fmt.tprintf("%s%s", cur, num)
}

@(private = "file")
Export_Piece :: struct {
	start, end:      i64,
	day:             i64, // local midnight
	project, client: string,
	idle:            bool, // a break (not bridged)
	bridged:         bool, // a short break counted as work
	claude:          bool, // Claude's work counted for the project
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
	for e in tracker_fold(entries, o.bridge) {
		e := e
		if e.bridged {e.idle = false}
		if e.idle && !o.breaks {continue}
		if o.project != "" && e.project != o.project {continue}
		a := max(e.start, o.from)
		b := o.to > 0 ? min(e.end, o.to) : e.end
		for a < b {
			day := local_day_start(a)
			end := min(b, next_local_day(day))
			append(&out, Export_Piece{a, end, day, e.project, e.client, e.idle, e.bridged, e.claude})
			a = end
		}
	}
	slice.sort_by(out[:], proc(x, y: Export_Piece) -> bool {return x.start < y.start})
	return out[:]
}

Export_Summary :: struct {
	without, with: i64, // worked seconds without bridging and with o.bridge
	gaps:          int, // bridged breaks making the difference
	claude:        i64, // of `with`: Claude's background work
	amount:        f64, // `with` at the paying projects' rates
}

// Worked seconds in the range (and project) without bridging and with
// o.bridge, and how many bridged breaks make the difference. The same
// clipping as export_csv, so `with` equals its work_secs.
export_bridge_summary :: proc(entries: []Export_Entry, o: Export_Opts) -> (sum: Export_Summary) {
	clip :: proc(e: Export_Entry, o: Export_Opts) -> i64 {
		if o.project != "" && e.project != o.project {return 0}
		a := max(e.start, o.from)
		b := o.to > 0 ? min(e.end, o.to) : e.end
		return max(b - a, 0)
	}
	for e in tracker_fold(entries, o.bridge) {
		d := clip(e, o)
		if d == 0 || (e.idle && !e.bridged) {continue}
		sum.with += d
		if e.bridged {sum.gaps += 1}
		if e.claude {sum.claude += d}
		sum.amount += f64(d) / 3600 * project_rate(e.project)
	}
	// Without bridging, Claude may fill some of what bridging counted.
	nb := o.bridge
	nb.default_secs = 0
	nb.secs = make([]i64, len(o.bridge.secs), context.temp_allocator)
	for e in tracker_fold(entries, nb) {
		if !e.idle {sum.without += clip(e, o)}
	}
	return
}

// Every project bridges breaks shorter than `minutes` (an override, e.g.
// `--bridge` or the export's slider), whatever config.ini says. Claude's
// counting stays as configured.
bridge_rules_override :: proc(minutes: int) -> Bridge_Rules {
	base := bridge_rules()
	m := i64(clamp(minutes, LIM_BRIDGE_BREAKS.lo, LIM_BRIDGE_BREAKS.hi)) * 60
	r := Bridge_Rules{default_secs = m, names = base.names, claude = base.claude, gen = -1}
	r.secs = make([]i64, len(base.names), context.temp_allocator)
	for &x in r.secs {x = m}
	return r
}

// "19:24 h → 20:05 h (+0:41 h from 12 bridged gaps)", or one total when
// bridging changes nothing.
fmt_bridge_summary :: proc(without, with: i64, gaps: int) -> string {
	if with == without {return fmt.tprintf("%s h worked", fmt_duration(with))}
	// The difference of the minutes shown, so the line adds up.
	diff := (with / 60 - without / 60) * 60
	return fmt.tprintf("%s h → %s h (+%s h from %d bridged gap%s)", fmt_duration(without), fmt_duration(with), fmt_duration(diff), gaps, gaps == 1 ? "" : "s")
}

// What follows the bridging line: "incl. 3:10 h by Claude · €1,234.50".
fmt_summary_extra :: proc(s: Export_Summary) -> string {
	parts: [dynamic]string
	parts.allocator = context.temp_allocator
	if s.claude > 0 {append(&parts, fmt.tprintf("incl. %s h by Claude", fmt_duration(s.claude)))}
	if s.amount > 0 {append(&parts, fmt_money(s.amount))}
	return strings.join(parts[:], "  ·  ", context.temp_allocator)
}

// The CSV text, plus the exported work time (breaks excluded) and row count.
export_csv :: proc(entries: []Export_Entry, o: Export_Opts, allocator := context.allocator) -> (csv: string, work_secs: i64, rows: int) {
	pieces := export_pieces(entries, o)
	for p in pieces {if !p.idle {work_secs += p.end - p.start}}
	kind :: proc(idle: bool, bridged := false, claude := false) -> string {return idle ? "break" : bridged ? "bridged" : claude ? "claude" : "work"}
	// rate and amount: work of a paying project with a rate.
	money :: proc(project: string, idle: bool, secs: i64) -> (rate, amount: string) {
		r := project_rate(project)
		if idle || r <= 0 {return "", ""}
		return fmt.tprintf("%.2f", r), fmt.tprintf("%.2f", f64(secs) / 3600 * r)
	}
	b := strings.builder_make(allocator)
	switch o.group {
	case .Entries:
		csv_row(&b, "date", "start", "end", "minutes", "hours", "project", "client", "type", "rate", "amount")
		for p in pieces {
			end := p.end == next_local_day(p.day) ? "24:00" : fmt_hm(p.end)
			rate, amount := money(p.project, p.idle, p.end - p.start)
			csv_row(&b, fmt_date(p.day), fmt_hm(p.start), end, fmt_minutes(p.end - p.start), fmt_hours(p.end - p.start), p.project, p.client, kind(p.idle, p.bridged && o.breaks, p.claude), rate, amount)
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
			csv_row(&b, "date", "project", "client", "minutes", "hours", "type", "rate", "amount")
		} else {
			csv_row(&b, "project", "client", "minutes", "hours", "days", "type", "rate", "amount")
		}
		for k in keys {
			s := sums[k]
			rate, amount := money(k.project, k.idle, s.secs)
			if o.group == .Day {
				csv_row(&b, fmt_date(k.day), k.project, k.client, fmt_minutes(s.secs), fmt_hours(s.secs), kind(k.idle), rate, amount)
			} else {
				csv_row(&b, k.project, k.client, fmt_minutes(s.secs), fmt_hours(s.secs), fmt.tprintf("%d", len(s.days)), kind(k.idle), rate, amount)
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
	sum := export_bridge_summary(entries[:], o)
	if out_path == "" {
		fmt.print(csv)
	} else if os.write_entire_file(out_path, csv) != nil {
		fmt.eprintfln("wlperch track export: can't write %s", out_path)
		return 1
	}
	fmt.eprintfln("%d rows, %s h worked (%s h)%s", rows, fmt_duration(work), fmt_hours(work), out_path != "" ? fmt.tprintf(" -> %s", out_path) : "")
	how := bridge_s != "" ? fmt.tprintf("--bridge %s", bridge_s) : "bridge_breaks from config.ini"
	fmt.eprintfln("bridging (%s): %s", how, fmt_bridge_summary(sum.without, sum.with, sum.gaps))
	if extra := fmt_summary_extra(sum); extra != "" {fmt.eprintln(extra)}
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
