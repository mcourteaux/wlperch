// Wallpaper sets: a folder of images ([wallpapers] directory), each marked for
// the dark theme, the light theme or both in the setup window's Wallpapers tab.
// A theme switch shows a random one of the mode's set (not the one already
// showing); with an empty set, [theme.<mode>] wallpaper applies as before.
//
// The marks live in wallpapers.tsv next to config.ini, not in config.ini:
// one line per file, "modes<TAB>fingerprint<TAB>path", since file names can
// hold anything INI keys can't ('=', ';', '[', commas for a list). The path
// keeps the marks of each folder apart; the fingerprint (size and a hash of
// the first 64 KiB) follows a file renamed within its folder; a removed file
// is skipped.
package main

import "core:fmt"
import "core:hash"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"

Wallpaper_Entry :: struct {
	dir:         string, // the folder, "~" expanded, no trailing '/'
	name:        string, // file name in it
	print:       string, // wallpaper_fingerprint
	dark, light: bool,
}

WALLPAPER_SETS_NAME :: "wallpapers.tsv"

// wallpapers.tsv, next to config.ini.
wallpaper_sets_path :: proc() -> string {
	cp := config_path()
	defer delete(cp)
	return strings.concatenate({cp[:strings.last_index_byte(cp, '/') + 1], WALLPAPER_SETS_NAME}, context.temp_allocator)
}

wallpaper_sets_parse :: proc(text: string, allocator := context.temp_allocator) -> [dynamic]Wallpaper_Entry {
	out := make([dynamic]Wallpaper_Entry, allocator)
	for line in strings.split_lines(text, context.temp_allocator) {
		if line == "" || line[0] == '#' {continue}
		f := strings.split_n(line, "\t", 3, context.temp_allocator)
		if len(f) != 3 || f[2] == "" {continue}
		path := f[2]
		if strings.has_prefix(path, "~/") {path = strings.concatenate({os.get_env("HOME", context.temp_allocator), path[1:]}, context.temp_allocator)}
		slash := strings.last_index_byte(path, '/')
		if slash < 0 || slash == len(path) - 1 {continue}
		e := Wallpaper_Entry{dir = strings.clone(path[:slash], allocator), name = strings.clone(path[slash + 1:], allocator), print = strings.clone(f[1], allocator)}
		for m in strings.split(f[0], ",", context.temp_allocator) {
			switch strings.trim_space(m) {
			case "dark":  e.dark = true
			case "light": e.light = true
			}
		}
		if e.dark || e.light {append(&out, e)}
	}
	return out
}

wallpaper_sets_format :: proc(entries: []Wallpaper_Entry) -> string {
	sorted := slice.clone(entries, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: Wallpaper_Entry) -> bool {return a.dir < b.dir || a.dir == b.dir && a.name < b.name})
	h := os.get_env("HOME", context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# wlperch wallpapers (the setup window's Wallpapers tab): which images in\n")
	strings.write_string(&b, "# [wallpapers] directory go with the dark and the light theme.\n")
	strings.write_string(&b, "# modes<TAB>size-hash (follows a renamed file)<TAB>path\n")
	for e in sorted {
		if !e.dark && !e.light {continue}
		modes := e.dark && e.light ? "dark,light" : e.dark ? "dark" : "light"
		dir := e.dir
		if h != "" && strings.has_prefix(dir, h) && (len(dir) == len(h) || dir[len(h)] == '/') {dir = strings.concatenate({"~", dir[len(h):]}, context.temp_allocator)}
		fmt.sbprintf(&b, "%s\t%s\t%s/%s\n", modes, e.print, dir, e.name)
	}
	return strings.to_string(b)
}

wallpaper_sets_load :: proc(allocator := context.temp_allocator) -> [dynamic]Wallpaper_Entry {
	data, err := os.read_entire_file(wallpaper_sets_path(), context.temp_allocator)
	if err != nil {return make([dynamic]Wallpaper_Entry, allocator)}
	return wallpaper_sets_parse(string(data), allocator)
}

wallpaper_sets_save :: proc(entries: []Wallpaper_Entry) -> bool {
	return write_through(wallpaper_sets_path(), wallpaper_sets_format(entries))
}

wallpaper_is_image :: proc(name: string) -> bool {
	if strings.has_prefix(name, ".") {return false}
	lower := strings.to_lower(name, context.temp_allocator)
	return strings.has_suffix(lower, ".jpg") || strings.has_suffix(lower, ".jpeg") || strings.has_suffix(lower, ".png")
}

// The jpg and png files in `dir` (not its subfolders), sorted by name.
wallpaper_files :: proc(dir: string, allocator := context.temp_allocator) -> []string {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return nil}
	out := make([dynamic]string, allocator)
	for e in entries {
		if e.type == .Directory || !wallpaper_is_image(e.name) {continue}
		append(&out, strings.clone(e.name, allocator))
	}
	slice.sort(out[:])
	return out[:]
}

// "<size>-<fnv64 of the first 64 KiB>": the same file under another name.
wallpaper_fingerprint :: proc(path: string) -> string {
	f, err := os.open(path)
	if err != nil {return ""}
	defer os.close(f)
	size, _ := os.file_size(f)
	buf := make([]u8, 64 * 1024, context.temp_allocator)
	n, _ := os.read(f, buf)
	return fmt.tprintf("%d-%016x", size, hash.fnv64a(buf[:max(n, 0)]))
}

// Entries of `dir` whose file is gone, while a file no entry names has the
// same fingerprint: the file was renamed, the entry follows it. True when one did.
wallpaper_follow_renames :: proc(entries: []Wallpaper_Entry, dir: string, files: []string, allocator := context.temp_allocator) -> bool {
	named := make(map[string]bool, len(entries), context.temp_allocator)
	for e in entries {if e.dir == dir {named[e.name] = true}}
	lost := false
	for e in entries {if e.dir == dir && !slice.contains(files, e.name) {lost = true}}
	if !lost {return false}
	// Fingerprint only the files no entry names (a few, usually).
	prints := make(map[string]string, 8, context.temp_allocator)
	for f in files {if !named[f] {prints[f] = wallpaper_fingerprint(fmt.tprintf("%s/%s", dir, f))}}
	changed := false
	for &e in entries {
		if e.dir != dir || slice.contains(files, e.name) || e.print == "" {continue}
		for f, p in prints {
			if p != e.print {continue}
			e.name = strings.clone(f, allocator)
			delete_key(&prints, f)
			changed = true
			break
		}
	}
	return changed
}

// A random file name of the mode's set in `dir` (its `files`), other than
// `current` (unless it's the only one); "" for an empty set.
wallpaper_pick :: proc(entries: []Wallpaper_Entry, dir: string, files: []string, m: Theme_Mode, current: string, gen := context.random_generator) -> string {
	cands := make([dynamic]string, context.temp_allocator)
	for e in entries {
		if e.dir == dir && (m == .Dark ? e.dark : e.light) && slice.contains(files, e.name) {append(&cands, e.name)}
	}
	if len(cands) > 1 {
		for c, i in cands {
			if c == current {
				ordered_remove(&cands, i)
				break
			}
		}
	}
	if len(cands) == 0 {return ""}
	return cands[rand.int_max(len(cands), gen)]
}

WALLPAPER_STATE_NAME :: "wallpaper"

// The data dir's "wallpaper": the picture wlperch shows (a full path). The
// wallpaper process (wallpaper_proc.odin) watches it.
wallpaper_state_path :: proc() -> string {
	dir := data_dir()
	defer delete(dir)
	return fmt.tprintf("%s/%s", dir, WALLPAPER_STATE_NAME)
}

// The image wlperch last showed (a full path, or "").
wallpaper_current :: proc() -> string {
	data, err := os.read_entire_file(wallpaper_state_path(), context.temp_allocator)
	return err == nil ? strings.trim_space(string(data)) : ""
}

// Replaced in one go (a rename), so the watcher never reads half a path.
wallpaper_state_save :: proc(path: string) -> bool {
	dir := data_dir()
	defer delete(dir)
	os.make_directory_all(dir)
	return write_file_atomic(wallpaper_state_path(), fmt.tprintf("%s\n", path))
}

// For a theme switch to `m`: the full path of a random image of its set, or
// "" (no folder, or an empty set).
wallpaper_for_mode :: proc(m: Theme_Mode) -> string {
	dir := config.wallpapers_dir
	if dir == "" {return ""}
	files := wallpaper_files(dir)
	if len(files) == 0 {return ""}
	entries := wallpaper_sets_load()
	wallpaper_follow_renames(entries[:], dir, files)
	cur := wallpaper_current()
	cur_name := strings.has_prefix(cur, dir) && len(cur) > len(dir) && cur[len(dir)] == '/' ? cur[len(dir) + 1:] : ""
	t := time.now()._nsec
	gen_state := rand.create(u64(t))
	pick := wallpaper_pick(entries[:], dir, files, m, cur_name, rand.default_random_generator(&gen_state))
	return pick == "" ? "" : fmt.tprintf("%s/%s", dir, pick)
}

// Show `path` on every output: through wlperch's wallpaper process when it's
// set up (it crossfades; started if it isn't running), else with sway's
// `output * bg` (swaybg). Safe off the main thread.
wallpaper_apply :: proc(path: string) -> bool {
	running := wallpaper_running() > 0
	if running || wallpaper_conf_installed() {
		if !wallpaper_state_save(path) {return false}
		if !running {launch_detached({wallpaper_exe(), "wallpaper"})}
		return true
	}
	return wallpaper_apply_sway(path)
}

// With sway's own `output * bg` (sway starts swaybg for it).
wallpaper_apply_sway :: proc(path: string) -> bool {
	if os.get_env("SWAYSOCK", context.temp_allocator) == "" {return false}
	// Quoted twice: swaymsg joins its arguments into one command (a space
	// would split the path), and sway expands the path with wordexp, which
	// refuses ';', '|', '&', … unless they're in single quotes. A name that
	// single quotes can't carry (', ", \\, $, `) goes through a symlink.
	target := path
	if strings.contains_any(path, "'\"\\$`") {
		dir := data_dir()
		defer delete(dir)
		os.make_directory_all(dir)
		// One name per file: sway restarts swaybg only for a new path.
		if old, err := os.read_all_directory_by_path(dir, context.temp_allocator); err == nil {
			for f in old {if strings.has_prefix(f.name, "wallpaper-link-") {os.remove(f.fullpath)}}
		}
		dot := strings.last_index_byte(path, '.')
		ext := dot > strings.last_index_byte(path, '/') ? path[dot:] : ""
		link := fmt.tprintf("%s/wallpaper-link-%016x%s", dir, hash.fnv64a(transmute([]u8)path), ext)
		tmp := fmt.tprintf("%s.tmp", link)
		os.remove(tmp)
		if posix.symlink(strings.clone_to_cstring(path, context.temp_allocator), strings.clone_to_cstring(tmp, context.temp_allocator)) != .OK || os.rename(tmp, link) != nil {return false}
		target = link
	}
	quoted := fmt.tprintf("\"'%s'\"", target)
	_, c := run_code({"swaymsg", "output", "*", "bg", quoted, "fill"}, allocator = context.temp_allocator)
	if c == 0 {wallpaper_state_save(path)}
	return c == 0
}
