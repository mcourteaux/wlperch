// Setup component "Neovim theme": one plugin file that makes running nvims
// follow `wlperch theme`, without touching the user's nvim config.
//
// The file goes into stdpath('data')/site/plugin/
// (~/.local/share/nvim/site/plugin/wlperch-theme.lua): on nvim's default
// runtimepath, kept there by lazy.nvim's rtp reset, and outside
// ~/.config/nvim, which is often a dotfiles repo. Remove deletes it again;
// nothing else is changed. It sources [theme] nvim_file at startup and
// whenever it changes (contrib/nvim/wlperch-theme.lua).
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

// [theme] nvim_file as of the last check (for the card's file preview).
nvim_theme_file: string

// What the installer writes for this colour file.
nvim_plugin_text :: proc(colour_file: string, allocator := context.temp_allocator) -> string {
	out, _ := strings.replace(NVIM_PLUGIN_TEMPLATE, "@NVIM_FILE@", colour_file, 1, allocator)
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

// [theme] nvim_file from config.ini (the setup process doesn't load the
// config), ~ expanded; "" = wlperch doesn't write one.
nvim_colour_file :: proc() -> string {
	defaults, _ := ini.load_map_from_string(DEFAULT_CONFIG, context.temp_allocator)
	path := config_path()
	defer delete(path)
	m, _, ok := ini.load_map_from_path(path, context.temp_allocator)
	if !ok {m = defaults}
	v := config_value(m, defaults, "theme", "nvim_file")
	if strings.has_prefix(v, "~/") {v = strings.concatenate({os.get_env("HOME", context.temp_allocator), v[1:]}, context.temp_allocator)}
	return v
}

// The first line of the user's nvim config (.lua / .vim files under dir,
// symlinks followed) that names the colour file: its full path, the ~ form
// or its file name (`vim.env.HOME .. '/.vimrc.color'`). Comment lines don't
// count. file is relative to dir.
nvim_config_ref :: proc(dir, colour_file, home: string) -> (file: string, line: int, found: bool) {
	needles: [dynamic]string
	needles.allocator = context.temp_allocator
	append(&needles, colour_file)
	if home != "" && len(colour_file) > len(home) && strings.has_prefix(colour_file, home) && colour_file[len(home)] == '/' {append(&needles, strings.concatenate({"~", colour_file[len(home):]}, context.temp_allocator))}
	if base := colour_file[strings.last_index_byte(colour_file, '/') + 1:]; len(base) >= 4 {append(&needles, base)}
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
				for l, n in strings.split_lines(string(data), context.temp_allocator) {
					t := strings.trim_space(l)
					if strings.has_prefix(t, "--") || strings.has_prefix(t, "\"") {continue}
					for nd in needles {
						if strings.contains(t, nd) {return name, n + 1, true}
					}
				}
			}
		}
		return
	}
	return walk(dir, "", needles[:], 0, &budget)
}

nvim_setup_check :: proc(p: ^Component, add_detail: proc(c: ^Component, line: string)) {
	colour := nvim_colour_file()
	delete(nvim_theme_file)
	nvim_theme_file = strings.clone(colour)
	nvim_check_at(p, add_detail, nvim_plugin_path(), colour, nvim_config_dir(), nvim_installed())
}

// The card for plugin file `path`, colour file `colour` and nvim config dir.
nvim_check_at :: proc(p: ^Component, add_detail: proc(c: ^Component, line: string), path, colour, config_dir: string, have_nvim: bool) {
	cur, rerr := os.read_entire_file(path, context.temp_allocator)
	have := rerr == nil
	ours := have && strings.has_prefix(string(cur), NVIM_PLUGIN_MARK)
	ref_file, ref_line, ref := "", 0, false
	if colour != "" {ref_file, ref_line, ref = nvim_config_ref(config_dir, colour, os.get_env("HOME", context.temp_allocator))}
	switch {
	case ours:
		p.state = string(cur) == nvim_plugin_text(colour) ? .Installed : .Outdated
		add_detail(p, path)
		if p.state == .Outdated {
			add_detail(p, "from an older wlperch, or [theme] nvim_file changed since; Update rewrites it")
		} else {
			add_detail(p, fmt.tprintf("nvim re-sources %s whenever it changes", colour))
		}
		if ref {add_detail(p, fmt.tprintf("your config sources it too (%s:%d); twice is harmless", ref_file, ref_line))}
	case have:
		p.state = .Custom
		add_detail(p, fmt.tprintf("%s exists but isn't wlperch's; left alone", path))
	case colour == "":
		p.state = .Unavailable
		add_detail(p, "[theme] nvim_file is empty: wlperch theme doesn't write an nvim colour file")
	case !have_nvim:
		p.state = .Unavailable
		add_detail(p, "nvim isn't installed")
	case ref:
		p.state = .Custom
		add_detail(p, fmt.tprintf("your config already sources %s (%s:%d)", colour, ref_file, ref_line))
		add_detail(p, "probably fine: wlperch theme rewrites it in place, so a watch on it keeps firing; Install adds one that also survives the file being replaced")
		add_detail(p, fmt.tprintf("Install adds %s (outside your nvim config)", path))
	case:
		p.state = .Missing
		add_detail(p, fmt.tprintf("adds %s (outside your nvim config; nvim loads it at startup)", path))
	}
	if colour != "" && p.state != .Unavailable && !os.exists(colour) {
		add_detail(p, fmt.tprintf("%s doesn't exist yet: wlperch theme writes it once nvim_colorscheme is set under [theme.dark] / [theme.light]", colour))
	}
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
nvim_install_at :: proc(path, colour: string) -> (ok: bool, msg: string) {
	if colour == "" {return false, "[theme] nvim_file is empty"}
	if cur, err := os.read_entire_file(path, context.temp_allocator); err == nil && !strings.has_prefix(string(cur), NVIM_PLUGIN_MARK) {
		return false, "a file of that name exists and isn't wlperch's; left alone"
	}
	os.make_directory_all(path[:strings.last_index_byte(path, '/')])
	if !write_through(path, nvim_plugin_text(colour)) {return false, fmt.tprintf("couldn't write %s", path)}
	return true, "installed: nvims started from now on follow wlperch theme (restart running ones)"
}

nvim_remove_at :: proc(path: string) -> (ok: bool, msg: string) {
	cur, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return true, "already gone"}
	if !strings.has_prefix(string(cur), NVIM_PLUGIN_MARK) {return false, "that file isn't wlperch's; left alone"}
	if os.remove(path) != nil {return false, fmt.tprintf("couldn't remove %s", path)}
	return true, "removed (nothing else was changed); running nvims keep following until restarted"
}

setup_install_nvim :: proc() {nvim_done(nvim_install_at(nvim_plugin_path(), nvim_colour_file()))}
setup_remove_nvim :: proc() {nvim_done(nvim_remove_at(nvim_plugin_path()))}
