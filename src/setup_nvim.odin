// Setup component "Neovim theme": one plugin file that makes running nvims
// follow `wlperch theme`, without touching the user's nvim config.
//
// The file goes into stdpath('data')/site/plugin/
// (~/.local/share/nvim/site/plugin/wlperch-theme.lua): on nvim's default
// runtimepath, kept there by lazy.nvim's rtp reset, and outside
// ~/.config/nvim, which is often a dotfiles repo. It reads wlperch's own
// state, the mode file (~/.local/share/wlperch/theme) and the [theme] nvim
// keys of config.ini, so it needs no colour file (contrib/nvim/wlperch-theme.lua).
//
// Install also empties [theme] nvim_file, so wlperch theme stops writing
// ~/.vimrc.color (unless plain Vim reads it); the old value is kept in
// ~/.local/share/wlperch/nvim-backup/nvim_file and Remove puts it back.
// The colour file itself is never deleted: the user's config may source it.
package main

import "core:encoding/ini"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"

NVIM_PLUGIN_TEMPLATE :: #load("../contrib/nvim/wlperch-theme.lua", string)
NVIM_PLUGIN_MARK :: "-- Installed by wlperch setup"
NVIM_PLUGIN_NAME :: "wlperch-theme.lua"

// The plugin for this user, as of the last check (the card's file preview).
nvim_plugin_preview: string

// What the installer writes: the template with the absolute paths of
// wlperch's mode file and config.ini.
nvim_plugin_text :: proc(mode_file, config_file: string, allocator := context.temp_allocator) -> string {
	out, _ := strings.replace(NVIM_PLUGIN_TEMPLATE, "@MODE_FILE@", mode_file, 1, context.temp_allocator)
	out, _ = strings.replace(out, "@CONFIG_FILE@", config_file, 1, allocator)
	return out
}

@(private = "file")
nvim_appname :: proc() -> string {
	if a := os.get_env("NVIM_APPNAME", context.temp_allocator); a != "" {return a}
	return "nvim"
}

// stdpath('data')/site/plugin/wlperch-theme.lua
nvim_plugin_path :: proc() -> string {
	base := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if base == "" {base = strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.local/share"}, context.temp_allocator)}
	return fmt.tprintf("%s/%s/site/plugin/%s", base, nvim_appname(), NVIM_PLUGIN_NAME)
}

// stdpath('config')
nvim_config_dir :: proc() -> string {
	return fmt.tprintf("%s/%s", sway_config_home(), nvim_appname())
}

// Where Install keeps the [theme] nvim_file it emptied.
nvim_backup_path :: proc() -> string {
	dir := data_dir()
	defer delete(dir)
	return fmt.tprintf("%s/nvim-backup/nvim_file", dir)
}

// The paths of this user's setup.
Nvim_Paths :: struct {plugin, mode_file, config_file, backup, config_dir, home: string}

@(private = "file")
nvim_paths :: proc() -> Nvim_Paths {
	cfg := config_path()
	defer delete(cfg)
	return {nvim_plugin_path(), theme_mode_path(), strings.clone(cfg, context.temp_allocator), nvim_backup_path(), nvim_config_dir(), os.get_env("HOME", context.temp_allocator)}
}

// [theme] nvim_file in config_file: as written (`set`: the key is there)
// and ~-expanded, as wlperch theme uses it ("" = no colour file).
nvim_file_setting :: proc(config_file, home: string) -> (raw: string, set: bool, path: string) {
	defaults, _ := ini.load_map_from_string(DEFAULT_CONFIG, context.temp_allocator)
	m, _, ok := ini.load_map_from_path(config_file, context.temp_allocator)
	if !ok {m = defaults}
	if s, has := m["theme"]; has && ok {_, set = s["nvim_file"]}
	raw = config_value(m, defaults, "theme", "nvim_file")
	path = raw
	if strings.has_prefix(path, "~/") {path = strings.concatenate({home, path[1:]}, context.temp_allocator)}
	return
}

// The emptied value Install kept: "unset" (the key wasn't in config.ini) or
// "value\t<raw>". ok = false: none kept.
@(private = "file")
nvim_backup_read :: proc(backup: string) -> (raw: string, set, ok: bool) {
	data, err := os.read_entire_file(backup, context.temp_allocator)
	if err != nil {return}
	t := strings.trim_right(string(data), "\n")
	if strings.has_prefix(t, "value\t") {return t[len("value\t"):], true, true}
	return "", false, true
}

// The first line of the user's nvim config (.lua / .vim files under dir,
// symlinks followed) that names the colour file: its full path, the ~ form
// or its file name (`vim.env.HOME .. '/.vimrc.color'`). Comment lines don't
// count. file is relative to dir.
nvim_config_ref :: proc(dir, colour_file, home: string) -> (file: string, line: int, found: bool) {
	needles := colour_needles(colour_file, home)
	budget := 2000 // files: a config with a vendored plugin tree is not searched forever
	walk :: proc(dir, rel: string, needles: []string, depth: int, budget: ^int) -> (file: string, line: int, found: bool) {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {return}
		slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		// This directory's files first (init.lua before an unused lua/ module).
		for pass in 0 ..< 2 {
			for e in entries {
				if strings.has_prefix(e.name, ".") {continue}
				full := strings.concatenate({dir, "/", e.name}, context.temp_allocator)
				name := rel == "" ? e.name : strings.concatenate({rel, "/", e.name}, context.temp_allocator)
				if os.is_dir(full) {
					if pass == 1 && depth < 6 {
						if f, l, ok := walk(full, name, needles, depth + 1, budget); ok {return f, l, true}
					}
					continue
				}
				if pass == 1 || !strings.has_suffix(e.name, ".lua") && !strings.has_suffix(e.name, ".vim") {continue}
				budget^ -= 1
				if budget^ < 0 {return}
				data, rerr := os.read_entire_file(full, context.temp_allocator)
				if rerr != nil || len(data) > 1 << 20 {continue}
				if l, ok := text_ref(string(data), needles); ok {return name, l, true}
			}
		}
		return
	}
	return walk(dir, "", needles, 0, &budget)
}

// How a config can name the colour file: its full path, the ~ form, or its
// file name (`vim.env.HOME .. '/.vimrc.color'`).
@(private = "file")
colour_needles :: proc(colour_file, home: string) -> []string {
	needles: [dynamic]string
	needles.allocator = context.temp_allocator
	append(&needles, colour_file)
	if home != "" && len(colour_file) > len(home) && strings.has_prefix(colour_file, home) && colour_file[len(home)] == '/' {append(&needles, strings.concatenate({"~", colour_file[len(home):]}, context.temp_allocator))}
	if base := colour_file[strings.last_index_byte(colour_file, '/') + 1:]; len(base) >= 4 {append(&needles, base)}
	return needles[:]
}

// The first non-comment line (1-based) of text with one of the needles.
@(private = "file")
text_ref :: proc(text: string, needles: []string) -> (line: int, found: bool) {
	for l, n in strings.split_lines(text, context.temp_allocator) {
		t := strings.trim_space(l)
		if strings.has_prefix(t, "--") || strings.has_prefix(t, "\"") {continue}
		for nd in needles {
			if strings.contains(t, nd) {return n + 1, true}
		}
	}
	return
}

// Plain Vim reading the colour file (~/.vimrc, ~/.vim/): then wlperch keeps
// writing it, since the nvim plugin doesn't help Vim. "" = no.
vim_colour_ref :: proc(colour_file, home: string) -> string {
	if colour_file == "" || home == "" {return ""}
	needles := colour_needles(colour_file, home)
	if data, err := os.read_entire_file(fmt.tprintf("%s/.vimrc", home), context.temp_allocator); err == nil {
		if l, ok := text_ref(string(data), needles); ok {return fmt.tprintf("~/.vimrc:%d", l)}
	}
	if f, l, ok := nvim_config_ref(fmt.tprintf("%s/.vim", home), colour_file, home); ok {return fmt.tprintf("~/.vim/%s:%d", f, l)}
	return ""
}

nvim_setup_check :: proc(p: ^Component, add_detail: proc(c: ^Component, line: string)) {
	ps := nvim_paths()
	delete(nvim_plugin_preview)
	nvim_plugin_preview = strings.clone(nvim_plugin_text(ps.mode_file, ps.config_file))
	nvim_check_at(p, add_detail, ps, nvim_installed())
}

// The card for these paths.
nvim_check_at :: proc(p: ^Component, add_detail: proc(c: ^Component, line: string), ps: Nvim_Paths, have_nvim: bool) {
	cur, rerr := os.read_entire_file(ps.plugin, context.temp_allocator)
	have := rerr == nil
	ours := have && strings.has_prefix(string(cur), NVIM_PLUGIN_MARK)
	_, _, colour := nvim_file_setting(ps.config_file, ps.home)
	// The colour file the user's config may still source: wlperch's, or the
	// one Install emptied.
	old := colour
	if old == "" {
		if raw, set, ok := nvim_backup_read(ps.backup); ok {
			if !set {
				defaults, _ := ini.load_map_from_string(DEFAULT_CONFIG, context.temp_allocator)
				raw = config_value(defaults, defaults, "theme", "nvim_file")
			}
			old = strings.has_prefix(raw, "~/") ? strings.concatenate({ps.home, raw[1:]}, context.temp_allocator) : raw
		}
	}
	ref_file, ref_line, ref := "", 0, false
	if old != "" {ref_file, ref_line, ref = nvim_config_ref(ps.config_dir, old, ps.home)}
	vim_ref := vim_colour_ref(colour, ps.home)
	switch {
	case ours:
		p.state = string(cur) == nvim_plugin_text(ps.mode_file, ps.config_file) ? .Installed : .Outdated
		add_detail(p, ps.plugin)
		if p.state == .Outdated {
			add_detail(p, "from an older wlperch (one that sourced the nvim colour file); Update replaces it")
		} else {
			add_detail(p, fmt.tprintf("nvim reads %s and the [theme] nvim keys of %s whenever the mode changes", ps.mode_file, ps.config_file))
		}
		switch {
		case colour != "" && vim_ref != "":
			add_detail(p, fmt.tprintf("[theme] nvim_file stays %s: Vim reads it (%s)", colour, vim_ref))
		case colour != "" && p.state == .Outdated:
			add_detail(p, fmt.tprintf("Update also empties [theme] nvim_file, so wlperch theme stops writing %s (Remove restores it)", colour))
		case colour != "":
			add_detail(p, fmt.tprintf("[theme] nvim_file is set again: wlperch theme also writes %s; not needed, harmless", colour))
		}
		if ref {add_detail(p, fmt.tprintf("your config still sources %s (%s:%d): harmless, this plugin applies the current mode at VimEnter, after it; remove those lines and the file when you like", old, ref_file, ref_line))}
	case have:
		p.state = .Custom
		add_detail(p, fmt.tprintf("%s exists but isn't wlperch's; left alone", ps.plugin))
	case !have_nvim:
		p.state = .Unavailable
		add_detail(p, "nvim isn't installed")
	case ref:
		p.state = .Custom
		add_detail(p, fmt.tprintf("your config sources %s (%s:%d), which wlperch theme writes", old, ref_file, ref_line))
		add_detail(p, fmt.tprintf("Install replaces that: %s reads wlperch's mode and settings directly (your config is left alone)", ps.plugin))
		if colour != "" && vim_ref == "" {add_detail(p, "Install also empties [theme] nvim_file, so wlperch theme stops writing it (Remove restores it)")}
	case:
		p.state = .Missing
		add_detail(p, fmt.tprintf("adds %s (outside your nvim config; nvim loads it at startup)", ps.plugin))
		if colour != "" && vim_ref == "" {add_detail(p, fmt.tprintf("and empties [theme] nvim_file: no %s needed (Remove restores it)", colour))}
	}
	if colour != "" && vim_ref != "" && !ours {add_detail(p, fmt.tprintf("[theme] nvim_file stays: Vim reads %s (%s)", colour, vim_ref))}
}

@(private = "file")
nvim_installed :: proc() -> bool {
	for d in strings.split(os.get_env("PATH", context.temp_allocator), ":", context.temp_allocator) {
		if d == "" {continue}
		if posix.access(strings.clone_to_cstring(strings.concatenate({d, "/nvim"}, context.temp_allocator), context.temp_allocator), {.X_OK}) == .OK {return true}
	}
	return false
}

@(private = "file")
nvim_done :: proc(ok: bool, msg: string) {
	sync.guard(&setup.mu)
	c := &setup.comps[.Nvim]
	c.busy = false
	c.msg_ok = ok
	delete(c.message)
	c.message = strings.clone(msg)
	log.infof("setup nvim: %s", msg)
}

// Never over a file of someone else's with the same name.
nvim_install_at :: proc(ps: Nvim_Paths) -> (ok: bool, msg: string) {
	if cur, err := os.read_entire_file(ps.plugin, context.temp_allocator); err == nil && !strings.has_prefix(string(cur), NVIM_PLUGIN_MARK) {
		return false, "a file of that name exists and isn't wlperch's; left alone"
	}
	os.make_directory_all(ps.plugin[:strings.last_index_byte(ps.plugin, '/')])
	if !write_through(ps.plugin, nvim_plugin_text(ps.mode_file, ps.config_file)) {return false, fmt.tprintf("couldn't write %s", ps.plugin)}
	msg = "installed: nvims started from now on follow wlperch theme (restart running ones)"
	raw, set, colour := nvim_file_setting(ps.config_file, ps.home)
	if colour == "" {return true, msg}
	if vim_colour_ref(colour, ps.home) != "" {return true, fmt.tprintf("%s; [theme] nvim_file kept, Vim reads it", msg)}
	// The old value first, so Remove can put it back.
	os.make_directory_all(ps.backup[:strings.last_index_byte(ps.backup, '/')])
	if !write_through(ps.backup, set ? fmt.tprintf("value\t%s\n", raw) : "unset\n") {return true, fmt.tprintf("%s; couldn't keep [theme] nvim_file, so left it", msg)}
	text: string
	if data, err := os.read_entire_file(ps.config_file, context.temp_allocator); err == nil {text = string(data)} else {text = default_config_text()}
	os.make_directory_all(ps.config_file[:strings.last_index_byte(ps.config_file, '/')])
	if !write_through(ps.config_file, ini_set_value(text, "theme", "nvim_file", "")) {
		os.remove(ps.backup)
		return true, fmt.tprintf("%s; couldn't empty [theme] nvim_file in config.ini", msg)
	}
	return true, fmt.tprintf("%s; [theme] nvim_file emptied (was %s), %s is no longer written", msg, raw, colour)
}

// Deletes the plugin and puts back the nvim_file Install emptied, when it is
// still empty. Nothing else is changed.
nvim_remove_at :: proc(ps: Nvim_Paths) -> (ok: bool, msg: string) {
	cur, err := os.read_entire_file(ps.plugin, context.temp_allocator)
	if err == nil {
		if !strings.has_prefix(string(cur), NVIM_PLUGIN_MARK) {return false, "that file isn't wlperch's; left alone"}
		if os.remove(ps.plugin) != nil {return false, fmt.tprintf("couldn't remove %s", ps.plugin)}
	}
	msg = err == nil ? "removed; running nvims keep following until restarted" : "already gone"
	raw, set, kept := nvim_backup_read(ps.backup)
	if !kept {return true, msg}
	if _, _, now := nvim_file_setting(ps.config_file, ps.home); now == "" {
		data, rerr := os.read_entire_file(ps.config_file, context.temp_allocator)
		if rerr == nil {
			text := string(data)
			out := set ? ini_set_value(text, "theme", "nvim_file", raw) : ini_remove_key(text, "theme", "nvim_file")
			if !write_through(ps.config_file, out) {return true, fmt.tprintf("%s; couldn't restore [theme] nvim_file", msg)}
			_, _, back := nvim_file_setting(ps.config_file, ps.home)
			msg = fmt.tprintf("%s; [theme] nvim_file is %s again (written from the next switch)", msg, back)
		}
	}
	os.remove(ps.backup)
	return true, msg
}

setup_install_nvim :: proc() {nvim_done(nvim_install_at(nvim_paths()))}
setup_remove_nvim :: proc() {nvim_done(nvim_remove_at(nvim_paths()))}
