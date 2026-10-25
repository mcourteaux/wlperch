// Switching other tools' commands in the user's sway files over to wlperch,
// and back (setup components "Lock screen" and "Launcher").
//
// switch_apply rewrites every candidate file with the component's rewrite
// proc, copying the original to ~/.local/share/wlperch/<backup>/ first;
// symlinked files (dotfiles) are edited through the link. When nothing needs
// rewriting it can write a file of its own instead. A manifest lists what
// changed, so switch_back can restore the copies (keeping the current file
// next to the backup when it was edited since).
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

Config_Switch :: struct {
	backup:   string, // subdirectory of the data dir: backups + manifest
	files:    proc() -> []string,
	rewrite:  proc(text: string, allocator := context.temp_allocator) -> (out: string, changes: int),
	new_path: string, // written when nothing needed rewriting (allow_new)
	new_text: string,
}

sway_config_home :: proc() -> string {
	if x := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); x != "" {return x}
	return strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.config"}, context.temp_allocator)
}

@(private = "file")
data_home_dir :: proc() -> string {
	if x := os.get_env("XDG_DATA_HOME", context.temp_allocator); x != "" {return strings.concatenate({x, "/wlperch"}, context.temp_allocator)}
	return strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.local/share/wlperch"}, context.temp_allocator)
}

switch_backup_dir :: proc(s: Config_Switch) -> string {
	return strings.concatenate({data_home_dir(), "/", s.backup}, context.temp_allocator)
}

// One line per changed file: "edit<TAB>path<TAB>backup" or "new<TAB>path".
@(private = "file")
manifest_path :: proc(s: Config_Switch) -> string {
	return strings.concatenate({switch_backup_dir(s), "/manifest"}, context.temp_allocator)
}

// The sway config, config.d/* and, with scripts, ~/.config/sway/*.sh.
sway_candidate_files :: proc(scripts: bool) -> [dynamic]string {
	out: [dynamic]string
	out.allocator = context.temp_allocator
	sway := strings.concatenate({sway_config_home(), "/sway"}, context.temp_allocator)
	append(&out, strings.concatenate({sway, "/config"}, context.temp_allocator))
	dirs := []string{strings.concatenate({sway, "/config.d"}, context.temp_allocator), sway}
	for dir in (scripts ? dirs : dirs[:1]) {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {continue}
		for e in entries {
			if dir == sway && !strings.has_suffix(e.name, ".sh") {continue}
			if strings.contains(e.name, ".before-wlperch") || strings.has_suffix(e.name, "~") {continue}
			full := strings.concatenate({dir, "/", e.name}, context.temp_allocator)
			if os.is_dir(full) {continue}
			append(&out, full)
		}
	}
	return out
}

switch_manifest :: proc(s: Config_Switch) -> (entries: [][3]string, ok: bool) {
	data, err := os.read_entire_file(manifest_path(s), context.temp_allocator)
	if err != nil {return nil, false}
	out: [dynamic][3]string
	out.allocator = context.temp_allocator
	for line in strings.split_lines(string(data), context.temp_allocator) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) >= 2 {append(&out, [3]string{f[0], f[1], len(f) > 2 ? f[2] : ""})}
	}
	return out[:], true
}

// "file (line …)" for each file with lines the rewrite would change; ours:
// some active line contains `marker`.
switch_uses :: proc(s: Config_Switch, marker: string) -> (uses: []string, ours: bool) {
	out: [dynamic]string
	out.allocator = context.temp_allocator
	for f in s.files() {
		data, err := os.read_entire_file(f, context.temp_allocator)
		if err != nil {continue}
		lines := strings.builder_make(context.temp_allocator)
		for line, n in strings.split_lines(string(data), context.temp_allocator) {
			t := strings.trim_space(line)
			if strings.has_prefix(t, "#") {continue}
			if strings.contains(t, marker) {ours = true}
			if _, c := s.rewrite(line); c > 0 {
				if strings.builder_len(lines) > 0 {strings.write_string(&lines, ", ")}
				fmt.sbprintf(&lines, "%d", n + 1)
			}
		}
		if strings.builder_len(lines) > 0 {append(&out, fmt.tprintf("%s (line %s)", f, strings.to_string(lines)))}
	}
	return out[:], ours
}

// Write through a symlink (dotfiles) instead of replacing it.
write_through :: proc(path, content: string) -> bool {
	target := path
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if rp := posix.realpath(cpath, nil); rp != nil {
		target = strings.clone(string(rp), context.temp_allocator)
		posix.free(rp)
	}
	tmp := strings.concatenate({target, ".wlperch-tmp"}, context.temp_allocator)
	mode := os.Permissions_Default_File
	if fi, err := os.stat(target, context.temp_allocator); err == nil {mode = fi.mode}
	if os.write_entire_file(tmp, content, mode) != nil {return false}
	return os.rename(tmp, target) == nil
}

// Overwrite a file's contents in place (same inode, through symlinks), for
// files an editor watches: an inotify watch follows the inode, so the
// rename in write_through would be seen once and then never again (nvim's
// fs_event watch on ~/.vimrc.color stops after the first theme switch).
// Only for small files, where a reader seeing it half-written is no concern.
write_in_place :: proc(path, content: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd := posix.open(cpath, {.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 {return false}
	defer posix.close(fd)
	data := transmute([]u8)content
	for len(data) > 0 {
		n := posix.write(fd, raw_data(data), uint(len(data)))
		if n <= 0 {return false}
		data = data[n:]
	}
	return true
}

// base, or base.2, base.3…: never overwrite a backup.
free_name :: proc(base: string) -> string {
	if !os.exists(base) {return base}
	for n := 2; ; n += 1 {
		p := fmt.tprintf("%s.%d", base, n)
		if !os.exists(p) {return p}
	}
}

// Rewrite the files (backing each up first). With nothing to rewrite, no
// earlier switch and allow_new, write new_path instead. err is "" on success.
switch_apply :: proc(s: Config_Switch, allow_new: bool) -> (changed: int, err: string) {
	os.make_directory_all(switch_backup_dir(s))
	old, had := switch_manifest(s)
	manifest := strings.builder_make(context.temp_allocator)
	for e in old {fmt.sbprintf(&manifest, "%s\t%s\t%s\n", e[0], e[1], e[2])}
	for f in s.files() {
		data, rerr := os.read_entire_file(f, context.temp_allocator)
		if rerr != nil {continue}
		text, n := s.rewrite(string(data))
		if n == 0 {continue}
		// The first switch keeps the original; a later one (new lines) its own copy.
		name, _ := strings.replace_all(strings.trim_prefix(f, "/"), "/", "%", context.temp_allocator)
		bk := free_name(fmt.tprintf("%s/%s", switch_backup_dir(s), name))
		if os.write_entire_file(bk, data) != nil || !write_through(f, text) {
			return changed, fmt.tprintf("couldn't change %s", f)
		}
		fmt.sbprintf(&manifest, "edit\t%s\t%s\n", f, bk)
		changed += 1
	}
	if changed == 0 && !had && allow_new && s.new_path != "" {
		os.make_directory_all(s.new_path[:strings.last_index_byte(s.new_path, '/')])
		if os.write_entire_file(s.new_path, s.new_text) != nil {
			return 0, fmt.tprintf("couldn't write %s", s.new_path)
		}
		fmt.sbprintf(&manifest, "new\t%s\n", s.new_path)
		changed += 1
	}
	if changed == 0 {return 0, ""}
	if os.write_entire_file(manifest_path(s), strings.to_string(manifest)) != nil {
		return changed, "couldn't write the backup list"
	}
	return changed, ""
}

// Undo switch_apply from the backups. kept: files edited since the switch,
// whose current version was saved as <backup>.edited.
switch_back :: proc(s: Config_Switch) -> (kept: int, err: string) {
	entries, ok := switch_manifest(s)
	if !ok {return 0, "no backups found"}
	#reverse for e in entries {
		switch e[0] {
		case "new":
			os.remove(e[1])
		case "edit":
			orig, rerr := os.read_entire_file(e[2], context.temp_allocator)
			if rerr != nil {return kept, fmt.tprintf("backup of %s is missing", e[1])}
			if cur, cerr := os.read_entire_file(e[1], context.temp_allocator); cerr == nil {
				if want, _ := s.rewrite(string(orig)); string(cur) != want {
					_ = os.write_entire_file(strings.concatenate({e[2], ".edited"}, context.temp_allocator), cur)
					kept += 1
				}
			}
			if !write_through(e[1], string(orig)) {return kept, fmt.tprintf("couldn't restore %s", e[1])}
			os.remove(e[2])
		}
	}
	os.remove(manifest_path(s))
	return kept, ""
}
