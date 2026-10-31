// Setup component "Neovim theme": the generated plugin file, finding the
// colour file in a user's nvim config, and the card's states.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(test)
test_nvim_plugin_text :: proc(t: ^testing.T) {
	text := nvim_plugin_text("/home/u/.local/share/wlperch/theme", "/home/u/.config/wlperch/config.ini")
	testing.expect(t, strings.has_prefix(text, NVIM_PLUGIN_MARK + "; remove there"))
	testing.expect(t, strings.contains(text, "local mode_file = [==[/home/u/.local/share/wlperch/theme]==]\n"))
	testing.expect(t, strings.contains(text, "local config_file = [==[/home/u/.config/wlperch/config.ini]==]\n"))
	testing.expect(t, !strings.contains(text, "@MODE_FILE@") && !strings.contains(text, "@CONFIG_FILE@"))
	// No colour file any more: it applies the mode itself.
	testing.expect(t, !strings.contains(text, "vim.cmd.source"))
	testing.expect(t, strings.contains(text, "pcall(vim.cmd.colorscheme, scheme)"))
	testing.expect(t, strings.contains(text, "'nvim_colorscheme'") && strings.contains(text, "'nvim_background'"))
	// Watches the directory and re-arms after every event.
	testing.expect(t, strings.contains(text, "watch:stop()") && strings.contains(text, "watch:start(dir, {}, on_event)"))
	testing.expect(t, strings.contains(text, "vim.g.loaded_wlperch_theme"))
	testing.expect(t, nvim_plugin_text("/x/theme", "/x/config.ini") != text)
}

@(private = "file")
nvim_test_detail :: proc(c: ^Component, line: string) {append(&c.detail, strings.clone(line, context.temp_allocator))}

@(test)
test_nvim_config_ref :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/wlperch-test/nvim-ref-%d", posix.getpid())
	os.remove_all(root)
	defer os.remove_all(root)
	dots := fmt.tprintf("%s/dotfiles/nvim", root)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/lua/me", dots)) == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/home/.config", root)) == nil)
	cfg := fmt.tprintf("%s/home/.config/nvim", root)
	// The config dir is a symlink into dotfiles, like ~/.config/nvim often is.
	testing.expect(t, posix.symlink(strings.clone_to_cstring(dots, context.temp_allocator), strings.clone_to_cstring(cfg, context.temp_allocator)) == .OK)
	home := fmt.tprintf("%s/home", root)
	colour := fmt.tprintf("%s/.vimrc.color", home)
	write :: proc(path, text: string) {_ = os.write_entire_file(path, text)}

	write(fmt.tprintf("%s/init.lua", dots), "vim.o.number = true\n")
	_, _, found := nvim_config_ref(cfg, colour, home)
	testing.expect(t, !found)
	// Comments don't count.
	write(fmt.tprintf("%s/init.lua", dots), "-- source ~/.vimrc.color some day\nvim.o.number = true\n")
	_, _, found = nvim_config_ref(cfg, colour, home)
	testing.expect(t, !found)
	// By file name: `vim.env.HOME .. '/.vimrc.color'`.
	write(fmt.tprintf("%s/init.lua", dots), "-- colours\nlocal function init()\n  local f = vim.env.HOME .. '/.vimrc.color'\nend\n")
	file, line, ok := nvim_config_ref(cfg, colour, home)
	testing.expect(t, ok)
	testing.expect_value(t, file, "init.lua")
	testing.expect_value(t, line, 3)
	// The config dir's own files before its subdirectories.
	write(fmt.tprintf("%s/lua/me/aaa.lua", dots), "local f = vim.fn.expand('~/.vimrc.color')\n")
	file, line, ok = nvim_config_ref(cfg, colour, home)
	testing.expect_value(t, file, "init.lua")
	os.remove(fmt.tprintf("%s/lua/me/aaa.lua", dots))
	// The ~ form, in a nested module; vimscript too.
	write(fmt.tprintf("%s/init.lua", dots), "require('me.theme')\n")
	write(fmt.tprintf("%s/lua/me/theme.lua", dots), "\n\nvim.cmd('source ~/.vimrc.color')\n")
	file, line, ok = nvim_config_ref(cfg, colour, home)
	testing.expect(t, ok)
	testing.expect_value(t, file, "lua/me/theme.lua")
	testing.expect_value(t, line, 3)
	os.remove(fmt.tprintf("%s/lua/me/theme.lua", dots))
	write(fmt.tprintf("%s/init.vim", dots), "\" theme\nsource ~/.vimrc.color\n")
	file, line, ok = nvim_config_ref(cfg, colour, home)
	testing.expect_value(t, file, "init.vim")
	testing.expect_value(t, line, 2)
	// Other files (lazy-lock.json, spell…) aren't read.
	os.remove(fmt.tprintf("%s/init.vim", dots))
	write(fmt.tprintf("%s/notes.txt", dots), ".vimrc.color\n")
	_, _, found = nvim_config_ref(cfg, colour, home)
	testing.expect(t, !found)
}

@(private = "file")
nvim_test_paths :: proc(root: string) -> Nvim_Paths {
	home := fmt.tprintf("%s/home", root)
	return {
		plugin      = fmt.tprintf("%s/.local/share/nvim/site/plugin/%s", home, NVIM_PLUGIN_NAME),
		mode_file   = fmt.tprintf("%s/.local/share/wlperch/theme", home),
		config_file = fmt.tprintf("%s/.config/wlperch/config.ini", home),
		config_dir  = fmt.tprintf("%s/.config/nvim", home),
		home        = home,
	}
}

@(test)
test_nvim_card_states :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/wlperch-test/nvim-card-%d", posix.getpid())
	os.remove_all(root)
	defer os.remove_all(root)
	ps := nvim_test_paths(root)
	testing.expect(t, os.make_directory_all(ps.config_dir) == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/.config/wlperch", ps.home)) == nil)
	_ = os.write_entire_file(ps.config_file, "[theme]\n# the colour file\nnvim_file = ~/.vimrc.color\n\n[theme.dark]\nnvim_colorscheme = gruvbox\n")
	check :: proc(ps: Nvim_Paths, have_nvim := true) -> Component {
		c: Component
		c.detail.allocator = context.temp_allocator
		nvim_check_at(&c, nvim_test_detail, ps, have_nvim)
		return c
	}
	has :: proc(c: Component, s: string) -> bool {
		for d in c.detail {if strings.contains(d, s) {return true}}
		return false
	}

	testing.expect_value(t, check(ps, have_nvim = false).state, Comp_State.Unavailable)
	c := check(ps)
	testing.expect_value(t, c.state, Comp_State.Missing)
	testing.expect(t, !has(c, "nvim_file"))
	// The user's config still sources the old colour file: a hint, nothing more.
	init_lua := "\nvim.cmd.source(vim.env.HOME .. '/.vimrc.color')\n"
	_ = os.write_entire_file(fmt.tprintf("%s/init.lua", ps.config_dir), init_lua)
	c = check(ps)
	testing.expect_value(t, c.state, Comp_State.Missing)
	testing.expect(t, has(c, "no longer writes") && has(c, "(init.lua:2)"))

	// An install from before (sourcing the colour file): Outdated.
	testing.expect(t, os.make_directory_all(ps.plugin[:strings.last_index_byte(ps.plugin, '/')]) == nil)
	_ = os.write_entire_file(ps.plugin, NVIM_PLUGIN_MARK + "; remove there.\nlocal path = [==[/x/.vimrc.color]==]\n")
	c = check(ps)
	testing.expect_value(t, c.state, Comp_State.Outdated)

	ok, _ := nvim_install_at(ps)
	testing.expect(t, ok)
	data, _ := os.read_entire_file(ps.plugin, context.temp_allocator)
	testing.expect_value(t, string(data), nvim_plugin_text(ps.mode_file, ps.config_file))
	c = check(ps)
	testing.expect_value(t, c.state, Comp_State.Installed)
	// The old colour file is still named in init.lua: said so, init.lua untouched.
	testing.expect(t, has(c, "your config still sources") && has(c, "(init.lua:2)"))
	init, _ := os.read_entire_file(fmt.tprintf("%s/init.lua", ps.config_dir), context.temp_allocator)
	testing.expect_value(t, string(init), init_lua)
	// Installed stays installed even where nvim has gone (Remove stays).
	testing.expect_value(t, check(ps, have_nvim = false).state, Comp_State.Installed)
	// Other paths (another XDG dir) or an older template: Outdated.
	other := ps
	other.mode_file = "/elsewhere/theme"
	testing.expect_value(t, check(other).state, Comp_State.Outdated)

	ok, _ = nvim_remove_at(ps)
	testing.expect(t, ok)
	testing.expect(t, !os.exists(ps.plugin))

	// Someone else's file of that name: left alone.
	_ = os.write_entire_file(ps.plugin, "-- mine\n")
	testing.expect_value(t, check(ps).state, Comp_State.Custom)
	ok, _ = nvim_install_at(ps)
	testing.expect(t, !ok)
	ok, _ = nvim_remove_at(ps)
	testing.expect(t, !ok)
	data, _ = os.read_entire_file(ps.plugin, context.temp_allocator)
	testing.expect_value(t, string(data), "-- mine\n")
}

// Install and Remove leave config.ini alone, an old nvim_file key included.
@(test)
test_nvim_install_config :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/wlperch-test/nvim-config-%d", posix.getpid())
	os.remove_all(root)
	defer os.remove_all(root)
	ps := nvim_test_paths(root)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/.config/wlperch", ps.home)) == nil)
	orig := "[theme]\n# where nvim looks\nnvim_file = ~/colours.vim\nnvim_background = false\n"
	_ = os.write_entire_file(ps.config_file, orig)
	ok, _ := nvim_install_at(ps)
	testing.expect(t, ok)
	data, _ := os.read_entire_file(ps.config_file, context.temp_allocator)
	testing.expect_value(t, string(data), orig)
	ok, _ = nvim_remove_at(ps)
	testing.expect(t, ok)
	data, _ = os.read_entire_file(ps.config_file, context.temp_allocator)
	testing.expect_value(t, string(data), orig)
}
