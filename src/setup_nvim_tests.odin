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
	text := nvim_plugin_text("/home/u/.vimrc.color")
	testing.expect(t, strings.has_prefix(text, NVIM_PLUGIN_MARK + "; remove there"))
	testing.expect(t, strings.contains(text, "local path = [==[/home/u/.vimrc.color]==]\n"))
	testing.expect(t, !strings.contains(text, "@NVIM_FILE@"))
	// Sources it at startup and re-arms its watch after every event.
	testing.expect(t, strings.contains(text, "pcall(vim.cmd.source, path)"))
	testing.expect(t, strings.contains(text, "watch:stop()"))
	testing.expect(t, strings.contains(text, "vim.g.loaded_wlperch_theme"))
	testing.expect(t, nvim_plugin_text("/x") != text)
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

@(test)
test_nvim_card_states :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/wlperch-test/nvim-card-%d", posix.getpid())
	os.remove_all(root)
	defer os.remove_all(root)
	cfg := fmt.tprintf("%s/config/nvim", root)
	testing.expect(t, os.make_directory_all(cfg) == nil)
	plugin := fmt.tprintf("%s/data/nvim/site/plugin/%s", root, NVIM_PLUGIN_NAME)
	colour := fmt.tprintf("%s/vimrc.color", root)
	_ = os.write_entire_file(colour, "set background=dark\n")
	check :: proc(plugin, colour, cfg: string, have_nvim := true) -> Component {
		c: Component
		c.detail.allocator = context.temp_allocator
		nvim_check_at(&c, nvim_test_detail, plugin, colour, cfg, have_nvim)
		return c
	}

	testing.expect_value(t, check(plugin, colour, cfg, have_nvim = false).state, Comp_State.Unavailable)
	testing.expect_value(t, check(plugin, "", cfg).state, Comp_State.Unavailable)
	c := check(plugin, colour, cfg)
	testing.expect_value(t, c.state, Comp_State.Missing)
	// The user's config already sources it.
	_ = os.write_entire_file(fmt.tprintf("%s/init.lua", cfg), "\nvim.cmd.source(vim.env.HOME .. '/vimrc.color')\n")
	c = check(plugin, colour, cfg)
	testing.expect_value(t, c.state, Comp_State.Custom)
	testing.expect(t, len(c.detail) > 0 && strings.contains(c.detail[0], "(init.lua:2)"))

	ok, _ := nvim_install_at(plugin, colour)
	testing.expect(t, ok)
	data, _ := os.read_entire_file(plugin, context.temp_allocator)
	testing.expect_value(t, string(data), nvim_plugin_text(colour))
	c = check(plugin, colour, cfg)
	testing.expect_value(t, c.state, Comp_State.Installed)
	// Installed stays installed even where nvim has gone (Remove stays).
	testing.expect_value(t, check(plugin, colour, cfg, have_nvim = false).state, Comp_State.Installed)
	// Another colour file (or an older template): Outdated.
	testing.expect_value(t, check(plugin, fmt.tprintf("%s/other.color", root), cfg).state, Comp_State.Outdated)

	ok, _ = nvim_remove_at(plugin)
	testing.expect(t, ok)
	testing.expect(t, !os.exists(plugin))
	init, _ := os.read_entire_file(fmt.tprintf("%s/init.lua", cfg), context.temp_allocator)
	testing.expect_value(t, string(init), "\nvim.cmd.source(vim.env.HOME .. '/vimrc.color')\n")

	// Someone else's file of that name: left alone.
	_ = os.write_entire_file(plugin, "-- mine\n")
	testing.expect_value(t, check(plugin, colour, cfg).state, Comp_State.Custom)
	ok, _ = nvim_install_at(plugin, colour)
	testing.expect(t, !ok)
	ok, _ = nvim_remove_at(plugin)
	testing.expect(t, !ok)
	data, _ = os.read_entire_file(plugin, context.temp_allocator)
	testing.expect_value(t, string(data), "-- mine\n")
}
