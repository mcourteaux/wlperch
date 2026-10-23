// App launcher (the "launch" and "run" panels): desktop entries from the XDG
// data dirs, fuzzy matched and ranked by how often / recently each was
// started, plus commands from $PATH, the calculator and wlperch's panels.
// `wlperch toggle launch --center` replaces rofi/wofi's drun mode,
// `wlperch toggle run --center` their run mode.
package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

App_Entry :: struct {
	id:       string, // desktop file id ("org.gnome.Nautilus.desktop"), + "#action"
	name:     string, // "Firefox", or "Firefox: New Private Window" for an action
	generic:  string,
	comment:  string,
	keywords: string, // lower case, ";"-separated
	exec:     string,
	icon:     string,
	path:     string, // working directory
	terminal: bool,
	action:   bool, // a desktop action (only listed when searching)
	// Lower-case copies for matching.
	name_lc, generic_lc, comment_lc, bin_lc, categories_lc: string,
	// Icon, loaded when first shown.
	tex:      ^Notif_Icon,
	tried:    bool,
}

Launch_Use :: struct {
	count: int,
	last:  i64, // unix seconds
}

Launcher :: struct {
	arena:     virtual.Arena, // entries and their strings; reset on rescan
	apps:      [dynamic]App_Entry,
	scanned:   bool,
	stamp:     i64, // newest mtime of the application dirs at the last scan
	bins:      [dynamic]string, // executables on $PATH (in arena)
	bins_stamp: i64,
	uses:      map[string]Launch_Use, // keys owned by the map
	uses_loaded: bool,
	terminal:  []string, // command prefix for Terminal=true entries
}
launcher: Launcher

// ---- Desktop entries --------------------------------------------------------

@(private = "file")
data_dirs :: proc() -> []string {
	out: [dynamic]string
	out.allocator = context.temp_allocator
	home := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if home == "" {home = strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.local/share"}, context.temp_allocator)}
	append(&out, home)
	xdg := os.get_env("XDG_DATA_DIRS", context.temp_allocator)
	if xdg == "" {xdg = "/usr/local/share:/usr/share"}
	for d in strings.split(xdg, ":", context.temp_allocator) {
		if d != "" && !slice.contains(out[:], d) {append(&out, d)}
	}
	return out[:]
}

@(private = "file")
mtime_of :: proc(path: string) -> i64 {
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK {return 0}
	return i64(st.st_mtim.tv_sec) * 1_000_000_000 + i64(st.st_mtim.tv_nsec)
}

// Newest mtime of the application dirs (and their subdirectories): entries
// added or removed change it.
@(private = "file")
apps_stamp :: proc() -> i64 {
	newest: i64
	for d in data_dirs() {
		dir := strings.concatenate({d, "/applications"}, context.temp_allocator)
		newest = max(newest, mtime_of(dir))
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {continue}
		for e in entries {
			if e.type == .Directory {newest = max(newest, mtime_of(strings.concatenate({dir, "/", e.name}, context.temp_allocator)))}
		}
	}
	return newest
}

// Desktop entry string values: \s \n \t \r \\.
desktop_unescape :: proc(s: string, allocator := context.temp_allocator) -> string {
	if strings.index_byte(s, '\\') < 0 {return strings.clone(s, allocator)}
	b := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] {
			case 's': strings.write_byte(&b, ' ')
			case 'n': strings.write_byte(&b, '\n')
			case 't': strings.write_byte(&b, '\t')
			case 'r': strings.write_byte(&b, '\r')
			case:     strings.write_byte(&b, s[i])
			}
			continue
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

// Locale suffixes to try for Name[..], most specific first ("nl_BE", "nl").
@(private = "file")
locale_keys :: proc() -> []string {
	lang := ""
	for v in ([]string{"LC_ALL", "LC_MESSAGES", "LANG"}) {
		if lang = os.get_env(v, context.temp_allocator); lang != "" {break}
	}
	if i := strings.index_any(lang, ".@"); i >= 0 {lang = lang[:i]}
	if lang == "" || lang == "C" || lang == "POSIX" {return nil}
	out: [dynamic]string
	out.allocator = context.temp_allocator
	append(&out, lang)
	if i := strings.index_byte(lang, '_'); i >= 0 {append(&out, lang[:i])}
	return out[:]
}

@(private = "file")
on_path :: proc(prog: string) -> bool {
	if prog == "" {return false}
	if strings.index_byte(prog, '/') >= 0 {
		return posix.access(strings.clone_to_cstring(prog, context.temp_allocator), {.X_OK}) == .OK
	}
	for d in strings.split(os.get_env("PATH", context.temp_allocator), ":", context.temp_allocator) {
		if d == "" {continue}
		if posix.access(strings.clone_to_cstring(strings.concatenate({d, "/", prog}, context.temp_allocator), context.temp_allocator), {.X_OK}) == .OK {return true}
	}
	return false
}

@(private = "file")
listed_for_desktop :: proc(only, not: string) -> bool {
	current := strings.split(strings.to_lower(os.get_env("XDG_CURRENT_DESKTOP", context.temp_allocator), context.temp_allocator), ":", context.temp_allocator)
	has :: proc(list: string, current: []string) -> bool {
		for d in strings.split(strings.to_lower(list, context.temp_allocator), ";", context.temp_allocator) {
			if d != "" && slice.contains(current, d) {return true}
		}
		return false
	}
	if only != "" && !has(only, current) {return false}
	return not == "" || !has(not, current)
}

Desktop_Group :: map[string]string

// Groups of a desktop file: "Desktop Entry", "Desktop Action new-window", …
// Localized keys are resolved to the best match for the locale.
desktop_parse :: proc(text: string, locales: []string) -> map[string]Desktop_Group {
	groups := make(map[string]Desktop_Group, context.temp_allocator)
	// Rank of the locale a key's value came from: 0 = unlocalized.
	ranks := make(map[string]int, context.temp_allocator)
	cur := ""
	t := text
	for line in strings.split_lines_iterator(&t) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		if l[0] == '[' && l[len(l) - 1] == ']' {
			cur = l[1:len(l) - 1]
			if cur not_in groups {groups[cur] = make(Desktop_Group, context.temp_allocator)}
			continue
		}
		if cur == "" {continue}
		eq := strings.index_byte(l, '=')
		if eq < 0 {continue}
		key := strings.trim_space(l[:eq])
		val := strings.trim_space(l[eq + 1:])
		rank := 0
		if b := strings.index_byte(key, '['); b >= 0 && strings.has_suffix(key, "]") {
			loc := key[b + 1:len(key) - 1]
			key = key[:b]
			rank = -1
			for want, i in locales {
				if loc == want {rank = len(locales) - i}
			}
			if rank < 0 {continue}
		}
		rkey := strings.concatenate({cur, "\x00", key}, context.temp_allocator)
		if old, ok := ranks[rkey]; ok && old > rank {continue}
		ranks[rkey] = rank
		g := &groups[cur]
		g[key] = val
	}
	return groups
}

// Split an Exec value into arguments and expand its field codes (no files or
// URLs are passed: %f %F %u %U go). Values are already string-unescaped.
desktop_exec_argv :: proc(exec, name, icon, file: string, allocator := context.temp_allocator) -> []string {
	args: [dynamic]string
	args.allocator = allocator
	b := strings.builder_make(context.temp_allocator)
	in_word, quoted := false, false
	flush :: proc(args: ^[dynamic]string, b: ^strings.Builder, in_word: ^bool, name, icon, file: string, allocator := context.temp_allocator) {
		if !in_word^ {return}
		in_word^ = false
		w := strings.to_string(b^)
		defer strings.builder_reset(b)
		switch w {
		case "%f", "%F", "%u", "%U", "%d", "%D", "%n", "%N", "%v", "%m": return
		case "%i":
			if icon != "" {append(args, strings.clone("--icon", allocator), strings.clone(icon, allocator))}
			return
		}
		// Field codes inside a word: %c %k expand, %% is a %, the rest go.
		out := strings.builder_make(allocator)
		for i := 0; i < len(w); i += 1 {
			if w[i] == '%' && i + 1 < len(w) {
				i += 1
				switch w[i] {
				case '%': strings.write_byte(&out, '%')
				case 'c': strings.write_string(&out, name)
				case 'k': strings.write_string(&out, file)
				}
				continue
			}
			strings.write_byte(&out, w[i])
		}
		append(args, strings.to_string(out))
	}
	for i := 0; i < len(exec); i += 1 {
		c := exec[i]
		switch {
		case quoted && c == '\\' && i + 1 < len(exec):
			i += 1
			strings.write_byte(&b, exec[i])
		case c == '"':
			quoted = !quoted
			in_word = true
		case !quoted && (c == ' ' || c == '\t'):
			flush(&args, &b, &in_word, name, icon, file, allocator)
		case:
			strings.write_byte(&b, c)
			in_word = true
		}
	}
	flush(&args, &b, &in_word, name, icon, file, allocator)
	return args[:]
}

@(private = "file")
scan_dir :: proc(dir, prefix: string, seen: ^map[string]bool, locales: []string, a := context.allocator) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return}
	for e in entries {
		full := strings.concatenate({dir, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			scan_dir(full, strings.concatenate({prefix, e.name, "-"}, context.temp_allocator), seen, locales, a)
			continue
		}
		if !strings.has_suffix(e.name, ".desktop") {continue}
		id := strings.concatenate({prefix, e.name}, context.temp_allocator)
		// Earlier data dirs win, also when they hide the entry.
		if id in seen {continue}
		seen[strings.clone(id, context.temp_allocator)] = true
		data, rerr := os.read_entire_file(full, context.temp_allocator)
		if rerr != nil {continue}
		groups := desktop_parse(string(data), locales)
		g, ok := groups["Desktop Entry"]
		if !ok || g["Type"] != "Application" || g["NoDisplay"] == "true" || g["Hidden"] == "true" {continue}
		if !listed_for_desktop(g["OnlyShowIn"], g["NotShowIn"]) {continue}
		if te := desktop_unescape(g["TryExec"]); te != "" && !on_path(te) {continue}
		exec := desktop_unescape(g["Exec"])
		if exec == "" && g["DBusActivatable"] != "true" {continue}
		app := App_Entry {
			id       = strings.clone(id, a),
			name     = desktop_unescape(g["Name"], a),
			generic  = desktop_unescape(g["GenericName"], a),
			comment  = desktop_unescape(g["Comment"], a),
			keywords = strings.to_lower(desktop_unescape(g["Keywords"]), a),
			exec     = strings.clone(exec, a),
			icon     = desktop_unescape(g["Icon"], a),
			path     = desktop_unescape(g["Path"], a),
			terminal = g["Terminal"] == "true",
		}
		if app.name == "" {continue}
		if app.exec == "" {
			// D-Bus activated only: gapplication starts it by its id.
			app.exec = fmt.aprintf("gapplication launch %s", strings.trim_suffix(id, ".desktop"), allocator = a)
		}
		cats := strings.to_lower(g["Categories"], context.temp_allocator)
		fill_lc :: proc(app: ^App_Entry, cats: string, a := context.allocator) {
			app.name_lc = strings.to_lower(app.name, a)
			app.generic_lc = strings.to_lower(app.generic, a)
			app.comment_lc = strings.to_lower(app.comment, a)
			app.categories_lc = strings.clone(cats, a)
			argv := desktop_exec_argv(app.exec, "", "", "")
			if len(argv) > 0 {
				bin := argv[0]
				// env FOO=1 prog, flatpak run org.x.Y: match on the program.
				for k := 0; k < len(argv) - 1 && (argv[k] == "env" || strings.contains(argv[k], "=")); k += 1 {bin = argv[k + 1]}
				app.bin_lc = strings.to_lower(bin[strings.last_index_byte(bin, '/') + 1:], a)
			}
		}
		fill_lc(&app, cats, a)
		append(&launcher.apps, app)

		// Desktop actions ("New Private Window"): searchable, not in the default list.
		for act in strings.split(g["Actions"], ";", context.temp_allocator) {
			if act == "" {continue}
			ag, aok := groups[strings.concatenate({"Desktop Action ", act}, context.temp_allocator)]
			if !aok || ag["Exec"] == "" || ag["Name"] == "" {continue}
			sub := app
			sub.id = strings.concatenate({app.id, "#", act}, a)
			sub.name = strings.concatenate({app.name, ": ", desktop_unescape(ag["Name"])}, a)
			sub.exec = desktop_unescape(ag["Exec"], a)
			if ic := desktop_unescape(ag["Icon"]); ic != "" {sub.icon = strings.clone(ic, a)}
			sub.action = true
			fill_lc(&sub, cats, a)
			append(&launcher.apps, sub)
		}
	}
}

// (Re)read the desktop entries when an application dir changed.
launcher_refresh :: proc() {
	stamp := apps_stamp()
	if launcher.scanned && stamp == launcher.stamp {return}
	start := time.tick_now()
	for &app in launcher.apps {app.tex = nil} // icons stay in icon_cache
	if launcher.scanned {
		clear(&launcher.apps)
		clear(&launcher.bins)
		virtual.arena_free_all(&launcher.arena)
	} else if err := virtual.arena_init_growing(&launcher.arena); err != nil {
		log.warnf("launcher: no arena: %v", err)
		return
	}
	launcher.scanned, launcher.stamp, launcher.bins_stamp = true, stamp, 0
	a := virtual.arena_allocator(&launcher.arena)
	seen := make(map[string]bool, context.temp_allocator)
	locales := locale_keys()
	for d in data_dirs() {scan_dir(strings.concatenate({d, "/applications"}, context.temp_allocator), "", &seen, locales, a)}
	log.debugf("launcher: %d entries in %v", len(launcher.apps), time.tick_since(start))
	launcher_load_uses()
	launcher.terminal = launcher_terminal(a)
}

// Executables on $PATH, for the run mode (read when the PATH dirs changed).
launcher_bins :: proc() -> []string {
	dirs := strings.split(os.get_env("PATH", context.temp_allocator), ":", context.temp_allocator)
	stamp: i64
	for d in dirs {stamp = max(stamp, mtime_of(d))}
	if stamp == launcher.bins_stamp && len(launcher.bins) > 0 {return launcher.bins[:]}
	if !launcher.scanned {launcher_refresh()}
	clear(&launcher.bins)
	a := virtual.arena_allocator(&launcher.arena)
	seen := make(map[string]bool, context.temp_allocator)
	for d in dirs {
		if d == "" {continue}
		entries, err := os.read_all_directory_by_path(d, context.temp_allocator)
		if err != nil {continue}
		for e in entries {
			if e.type == .Directory || e.name in seen || strings.has_prefix(e.name, ".") {continue}
			full := strings.concatenate({d, "/", e.name}, context.temp_allocator)
			if posix.access(strings.clone_to_cstring(full, context.temp_allocator), {.X_OK}) != .OK {continue}
			seen[e.name] = true
			append(&launcher.bins, strings.clone(e.name, a))
		}
	}
	slice.sort(launcher.bins[:])
	launcher.bins_stamp = stamp
	return launcher.bins[:]
}

// ---- Terminal ---------------------------------------------------------------

// The command prefix that runs a program in a terminal: [launcher] terminal,
// $TERMINAL, sway's $term, or the first known terminal installed.
launcher_terminal :: proc(a := context.allocator) -> []string {
	words :: proc(s: string, a := context.allocator) -> []string {
		f := strings.fields(s, context.temp_allocator)
		out := make([]string, len(f), a)
		for w, i in f {out[i] = strings.clone(w, a)}
		return out
	}
	if config.launcher_terminal != "" {return words(config.launcher_terminal, a)}
	cmd := os.get_env("TERMINAL", context.temp_allocator)
	if cmd == "" {
		// `set $term kitty` in the main sway config.
		if cfg, ok := sway_request(9, ""); ok {
			if i := strings.index(cfg, `set $term `); i >= 0 {
				rest := cfg[i + len("set $term "):]
				if nl := strings.index_any(rest, "\\\n"); nl >= 0 {rest = rest[:nl]}
				cmd = strings.trim_space(rest)
			}
		}
	}
	if cmd == "" {
		for t in ([]string{"foot", "kitty", "alacritty", "wezterm", "ghostty", "gnome-terminal", "konsole", "xterm"}) {
			if on_path(t) {
				cmd = t
				break
			}
		}
	}
	if cmd == "" {return nil}
	// How each terminal takes a command to run.
	exe := strings.fields(cmd, context.temp_allocator)
	base := len(exe) > 0 ? exe[0][strings.last_index_byte(exe[0], '/') + 1:] : ""
	switch base {
	case "foot", "kitty", "ghostty": // the command follows directly
	case "wezterm":                  cmd = strings.concatenate({cmd, " start --"}, context.temp_allocator)
	case "gnome-terminal", "kgx":    cmd = strings.concatenate({cmd, " --"}, context.temp_allocator)
	case:                            cmd = strings.concatenate({cmd, " -e"}, context.temp_allocator)
	}
	return words(cmd, a)
}

// ---- Usage (frecency) -------------------------------------------------------

@(private = "file")
uses_path :: proc() -> string {
	d := data_dir()
	defer delete(d)
	return strings.concatenate({d, "/launcher.tsv"}, context.temp_allocator)
}

// One line per launched entry: "count<TAB>last unix time<TAB>id".
launcher_load_uses :: proc() {
	if launcher.uses_loaded {return}
	launcher.uses_loaded = true
	data, err := os.read_entire_file(uses_path(), context.temp_allocator)
	if err != nil {return}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		f := strings.split_n(line, "\t", 3, context.temp_allocator)
		if len(f) != 3 || f[2] == "" {continue}
		u := Launch_Use{strconv.parse_int(f[0]) or_else 0, i64(strconv.parse_int(f[1]) or_else 0)}
		if u.count > 0 {launcher.uses[strings.clone(f[2])] = u}
	}
}

@(private = "file")
save_uses :: proc() {
	b := strings.builder_make(context.temp_allocator)
	for id, u in launcher.uses {fmt.sbprintf(&b, "%d\t%d\t%s\n", u.count, u.last, id)}
	d := data_dir()
	defer delete(d)
	os.make_directory_all(d)
	tmp := strings.concatenate({uses_path(), ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, strings.to_string(b)) == nil {os.rename(tmp, uses_path())}
}

launcher_note_use :: proc(id: string) {
	launcher_load_uses()
	now := time.to_unix_seconds(time.now())
	if u, ok := &launcher.uses[id]; ok {
		u.count += 1
		u.last = now
	} else {
		launcher.uses[strings.clone(id)] = {1, now}
	}
	// Forget what wasn't used for half a year.
	stale := make([dynamic]string, context.temp_allocator)
	for k, u in launcher.uses {
		if now - u.last > 183 * 86400 {append(&stale, k)}
	}
	for k in stale {
		delete_key(&launcher.uses, k)
		delete(k)
	}
	save_uses()
}

// 0 (never) to about 30: more for frequent and recent use.
launcher_frecency :: proc(id: string, now: i64) -> f32 {
	u, ok := launcher.uses[id]
	if !ok {return 0}
	age := f32(now - u.last) / 86400
	recency: f32 = age < 1 ? 1 : age < 7 ? 0.7 : age < 30 ? 0.45 : 0.25
	return 10 * math.sqrt(f32(min(u.count, 60))) * recency / math.sqrt(f32(60)) * 3
}

// ---- Matching ---------------------------------------------------------------

@(private = "file")
is_boundary :: proc(s: string, i: int) -> bool {
	if i == 0 {return true}
	p := s[i - 1]
	return p == ' ' || p == '-' || p == '_' || p == '.' || p == '/' || p == ':' || p == '(' || p == ';'
}

// How well `pat` (lower case) matches `text` (lower case); < 0: no match.
// Substrings beat scattered letters; starts of the text / of words count most.
fuzzy_score :: proc(pat, text: string, fuzzy := true) -> f32 {
	if pat == "" {return 0}
	if len(text) == 0 {return -1}
	if i := strings.index(text, pat); i >= 0 {
		s: f32 = 60
		if i == 0 {
			s += 40
			if len(pat) == len(text) {s += 20}
		} else if is_boundary(text, i) {
			s += 25
		} else {
			// A later occurrence may start a word.
			for j := i + 1; j + len(pat) <= len(text); j += 1 {
				if is_boundary(text, j) && strings.has_prefix(text[j:], pat) {
					s += 25
					break
				}
			}
		}
		return s - min(f32(i), 20) * 0.5 - f32(len(text) - len(pat)) * 0.05
	}
	if !fuzzy {return -1}
	// Letters in order: reward runs and word starts, punish gaps.
	s: f32 = 0
	ti := 0
	run := 0
	first := -1
	for pi := 0; pi < len(pat); pi += 1 {
		c := pat[pi]
		found := -1
		// Prefer a word start ahead of the plain next occurrence.
		for j := ti; j < len(text); j += 1 {
			if text[j] == c {
				if found < 0 {found = j}
				if is_boundary(text, j) {
					if run == 0 || j != ti {found = j}
					break
				}
				if run > 0 && j == ti {break} // continuing a run
			}
		}
		if found < 0 {return -1}
		if first < 0 {first = found}
		if found == ti && pi > 0 {
			run += 1
			s += 4 + f32(run)
		} else {
			run = 0
			s += is_boundary(text, found) ? 8 : 1
			if pi > 0 {s -= min(f32(found - ti), 10) * 0.3}
		}
		ti = found + 1
	}
	if first == 0 {s += 6}
	return s
}

// Score of an entry for the whole query (each word must match something).
launcher_score :: proc(app: ^App_Entry, words: []string) -> f32 {
	total: f32 = 0
	for w in words {
		best := fuzzy_score(w, app.name_lc) * 1.0
		best = max(best, fuzzy_score(w, app.bin_lc) * 0.8)
		best = max(best, fuzzy_score(w, app.generic_lc, false) * 0.7)
		best = max(best, fuzzy_score(w, app.keywords, false) * 0.65)
		best = max(best, fuzzy_score(w, app.comment_lc, false) * 0.35)
		best = max(best, fuzzy_score(w, app.categories_lc, false) * 0.3)
		if best < 0 {return -1}
		total += best
	}
	if app.action {total -= 12} // the app itself first
	return total
}

// ---- Launching --------------------------------------------------------------

// Start an entry: detached, in its working directory, in a terminal if it
// asks for one.
launcher_start :: proc(app: ^App_Entry) -> bool {
	argv := desktop_exec_argv(app.exec, app.name, app.icon, "")
	if len(argv) == 0 {return false}
	if app.terminal {argv = with_terminal(argv)}
	if app.path != "" {
		full := make([dynamic]string, context.temp_allocator)
		append(&full, "sh", "-c", `cd "$1" && shift && exec "$@"`, "sh", app.path)
		append(&full, ..argv)
		argv = full[:]
	}
	ok := launch_detached(argv)
	if ok {launcher_note_use(app.id)}
	return ok
}

@(private = "file")
with_terminal :: proc(argv: []string) -> []string {
	if len(launcher.terminal) == 0 {return argv}
	full := make([dynamic]string, context.temp_allocator)
	append(&full, ..launcher.terminal)
	append(&full, ..argv)
	return full[:]
}

// A command line typed in the run mode, through the shell (in a terminal).
launcher_run :: proc(cmdline: string, terminal: bool) -> bool {
	argv := []string{"sh", "-c", cmdline}
	if terminal {argv = with_terminal(argv)}
	ok := launch_detached(argv)
	if ok {
		f := strings.fields(cmdline, context.temp_allocator)
		// Remembered for the run list when it's a program (not a typo).
		if len(f) > 0 && on_path(f[0]) {launcher_note_use(strings.concatenate({"run:", f[0]}, context.temp_allocator))}
	}
	return ok
}
