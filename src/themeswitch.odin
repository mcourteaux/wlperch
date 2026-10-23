// Dark / light theme: "wlperch theme dark|light|toggle|status" and the quick
// settings tile. Switches wlperch's own palette, then the rest of the desktop
// as configured in [theme], [theme.dark] and [theme.light]: the gsettings
// color-scheme (GTK, libadwaita and, through the settings portal, most apps),
// the GTK theme, an existing gtk-3.0/gtk-4.0 settings.ini, dark/light symlink
// twins (waybar / wofi colors.css, reloading waybar), sway's wallpaper, kitty,
// an nvim colour file, Kvantum, VS Code and a free-form command.
//
// The mode is kept in ~/.local/share/wlperch/theme; the lock screen reads it
// at start. Without a saved mode the gsettings color-scheme decides.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

Theme_Mode :: enum {Dark, Light}

Theme_Targets :: struct {
	gtk_theme:        string, // "auto": Adwaita <-> Adwaita-dark while one is in use
	icon_theme:       string,
	kitty_theme:      string,
	wallpaper:        string,
	nvim_colorscheme: string,
	kvantum_theme:    string,
	vscode_theme:     string,
	command:          string,
}

@(private = "file")
Theme_State :: struct {
	mu:      sync.Mutex,
	busy:    bool, // the desktop part is being switched
	pending: Maybe(Theme_Mode), // asked for while busy: switch again after
}
@(private = "file") theme_state: Theme_State

theme_mode_name :: proc(m: Theme_Mode) -> string {return m == .Light ? "light" : "dark"}

@(private = "file")
theme_mode_path :: proc() -> string {
	dir := data_dir()
	defer delete(dir)
	return strings.concatenate({dir, "/theme"}, context.temp_allocator)
}

// The saved mode, else the desktop's color-scheme (dark unless it prefers light).
theme_mode_load :: proc() -> Theme_Mode {
	if data, err := os.read_entire_file(theme_mode_path(), context.temp_allocator); err == nil {
		return strings.trim_space(string(data)) == "light" ? .Light : .Dark
	}
	out, ok := run({"gsettings", "get", "org.gnome.desktop.interface", "color-scheme"}, 2 * time.Second, context.temp_allocator)
	return ok && strings.contains(out, "prefer-light") ? .Light : .Dark
}

@(private = "file")
theme_mode_save :: proc(m: Theme_Mode) {
	dir := data_dir()
	defer delete(dir)
	os.make_directory_all(dir)
	_ = os.write_entire_file(theme_mode_path(), fmt.tprintf("%s\n", theme_mode_name(m)))
}

// Daemon start: wlperch's own colours, from the saved mode.
theme_init_mode :: proc() {
	theme_set_palette(theme_mode_load() == .Light)
}

// In the daemon: switch wlperch now, the desktop on a worker thread.
theme_switch :: proc(m: Theme_Mode) {
	theme_set_palette(m == .Light)
	icons_retint()
	theme_mode_save(m)
	notify_popups_restyle()
	request_redraw()
	{
		sync.guard(&theme_state.mu)
		if theme_state.busy {
			theme_state.pending = m
			return
		}
		theme_state.busy = true
	}
	ctx := new(Theme_Mode)
	ctx^ = m
	thread.create_and_start_with_data(ctx, proc(data: rawptr) {
		m := (cast(^Theme_Mode)data)^
		free(data)
		for {
			theme_apply_desktop(m)
			free_all(context.temp_allocator)
			sync.guard(&theme_state.mu)
			next, again := theme_state.pending.?
			theme_state.pending = nil
			if !again || next == m {
				theme_state.busy = false
				return
			}
			m = next
		}
	}, init_context = context, self_cleanup = true)
}

// IPC: theme [dark|light|toggle|status].
theme_command :: proc(args: []string) -> string {
	sub := len(args) > 0 ? args[0] : "status"
	cur: Theme_Mode = theme_light ? .Light : .Dark
	switch sub {
	case "status":
		return fmt.tprintf("%s\n", theme_mode_name(cur))
	case "dark":
		theme_switch(.Dark)
	case "light":
		theme_switch(.Light)
	case "toggle":
		theme_switch(cur == .Light ? .Dark : .Light)
	case:
		return "usage: theme [dark|light|toggle|status]\n"
	}
	return fmt.tprintf("%s\n", theme_light ? "light" : "dark")
}

// CLI: through the daemon, or (not running) switch the desktop directly.
theme_cli :: proc(args: []string) -> int {
	if len(args) > 1 || len(args) == 1 && args[0] != "dark" && args[0] != "light" && args[0] != "toggle" && args[0] != "status" {
		fmt.eprintln("usage: wlperch theme [dark|light|toggle|status]")
		return 2
	}
	cmd := strings.join({"theme", len(args) > 0 ? args[0] : "status"}, " ", context.temp_allocator)
	if reply, ok := ipc_query(cmd); ok {
		fmt.print(reply)
		return 0
	}
	cur := theme_mode_load()
	sub := len(args) > 0 ? args[0] : "status"
	m := cur
	switch sub {
	case "status":
		fmt.println(theme_mode_name(cur))
		return 0
	case "dark":   m = .Dark
	case "light":  m = .Light
	case "toggle": m = cur == .Light ? .Dark : .Light
	}
	config_load()
	theme_mode_save(m)
	for line in theme_apply_desktop(m) {fmt.println(" ", line)}
	fmt.println(theme_mode_name(m))
	return 0
}

// ---- The desktop ------------------------------------------------------------

@(private = "file")
have_program :: proc(name: string) -> bool {
	for dir in strings.split(os.get_env("PATH", context.temp_allocator), ":", context.temp_allocator) {
		if dir != "" && os.exists(strings.concatenate({dir, "/", name}, context.temp_allocator)) {return true}
	}
	return false
}

// Everything outside wlperch. Returns one line per thing switched (or failed).
theme_apply_desktop :: proc(m: Theme_Mode) -> []string {
	done: [dynamic]string
	done.allocator = context.temp_allocator
	note :: proc(done: ^[dynamic]string, ok: bool, what: string) {
		line := ok ? what : fmt.tprintf("%s: failed", what)
		append(done, line)
		if ok {log.infof("theme: %s", line)} else {log.warnf("theme: %s", line)}
	}
	light := m == .Light
	t := config.theme_targets[m]

	// GTK / libadwaita / portal.
	if have_program("gsettings") {
		IFACE :: "org.gnome.desktop.interface"
		scheme := light ? "prefer-light" : "prefer-dark"
		_, code := run_code({"gsettings", "set", IFACE, "color-scheme", scheme}, allocator = context.temp_allocator)
		if code != 0 && light {
			scheme = "default" // older schemas have no prefer-light
			_, code = run_code({"gsettings", "set", IFACE, "color-scheme", scheme}, allocator = context.temp_allocator)
		}
		note(&done, code == 0, fmt.tprintf("color-scheme %s", scheme))

		gtk := t.gtk_theme
		if gtk == "auto" {
			gtk = ""
			cur, ok := run({"gsettings", "get", IFACE, "gtk-theme"}, allocator = context.temp_allocator)
			cur = strings.trim(strings.trim_space(cur), "'")
			if ok && (cur == "Adwaita" || cur == "Adwaita-dark") {gtk = light ? "Adwaita" : "Adwaita-dark"}
		}
		if gtk != "" {
			_, c := run_code({"gsettings", "set", IFACE, "gtk-theme", gtk}, allocator = context.temp_allocator)
			note(&done, c == 0, fmt.tprintf("GTK theme %s", gtk))
		}
		if t.icon_theme != "" {
			_, c := run_code({"gsettings", "set", IFACE, "icon-theme", t.icon_theme}, allocator = context.temp_allocator)
			note(&done, c == 0, fmt.tprintf("icon theme %s", t.icon_theme))
		}
		for v in ([]string{"gtk-3.0", "gtk-4.0"}) {
			path := fmt.tprintf("%s/%s/settings.ini", sway_config_home(), v)
			if changed, ok := gtk_ini_update(path, light, gtk); changed {note(&done, ok, fmt.tprintf("%s settings.ini", v))}
		}
	}

	// Symlink twins (colors.css -> *-dark.css / *-light.css).
	waybar := false
	for link in config.theme_links {
		target, changed, ok := theme_swap_link(link, light)
		if !changed {continue}
		note(&done, ok, fmt.tprintf("%s -> %s", link, filepath.base(target)))
		if ok && strings.contains(link, "/waybar/") {waybar = true}
	}
	if waybar {
		n := reload_waybar()
		if n > 0 {note(&done, true, "waybar reloaded")}
	}

	// swaymsg, not sway_command: this runs off the main thread.
	if t.wallpaper != "" && os.get_env("SWAYSOCK", context.temp_allocator) != "" {
		_, c := run_code({"swaymsg", "output", "*", "bg", t.wallpaper, "fill"}, allocator = context.temp_allocator)
		note(&done, c == 0, fmt.tprintf("wallpaper %s", filepath.base(t.wallpaper)))
	}
	if t.kitty_theme != "" && have_program("kitty") {
		_, c := run_code({"kitty", "+kitten", "themes", "--reload-in=all", t.kitty_theme}, 30 * time.Second, context.temp_allocator)
		note(&done, c == 0, fmt.tprintf("kitty %s", t.kitty_theme))
	}
	if t.nvim_colorscheme != "" && config.theme_nvim_file != "" {
		text := fmt.tprintf("\"Generated by wlperch theme\nset background=%s\ncolorscheme %s\n", theme_mode_name(m), t.nvim_colorscheme)
		note(&done, write_through(config.theme_nvim_file, text), fmt.tprintf("nvim %s", t.nvim_colorscheme))
	}
	if t.kvantum_theme != "" && have_program("kvantummanager") {
		_, c := run_code({"kvantummanager", "--set", t.kvantum_theme}, allocator = context.temp_allocator)
		note(&done, c == 0, fmt.tprintf("Kvantum %s", t.kvantum_theme))
	}
	if t.vscode_theme != "" {
		for app in ([]string{"Code", "Code - OSS", "VSCodium"}) {
			path := fmt.tprintf("%s/%s/User/settings.json", sway_config_home(), app)
			if changed, ok := vscode_set_theme(path, t.vscode_theme); changed {note(&done, ok, fmt.tprintf("%s %s", app, t.vscode_theme))}
		}
	}
	if t.command != "" {
		_, c := run_code({"sh", "-c", t.command}, 30 * time.Second, context.temp_allocator)
		note(&done, c == 0, fmt.tprintf("command: %s", t.command))
	}
	return done[:]
}

// A symlink whose target's name has "dark"/"light": point it at the twin
// for the mode, when that file exists. Replaced atomically.
theme_swap_link :: proc(link: string, light: bool) -> (target: string, changed, ok: bool) {
	buf: [4096]u8
	clink := strings.clone_to_cstring(link, context.temp_allocator)
	n := posix.readlink(clink, &buf[0], len(buf))
	if n <= 0 {return}
	cur := string(buf[:n])
	slash := strings.last_index_byte(cur, '/') + 1
	dir, base := cur[:slash], cur[slash:]
	from, to := light ? "dark" : "light", light ? "light" : "dark"
	if !strings.contains(base, from) {return cur, false, true}
	new_base, _ := strings.replace_all(base, from, to, context.temp_allocator)
	target = strings.concatenate({dir, new_base}, context.temp_allocator)
	// Relative targets resolve from the link's directory.
	check := target
	if !filepath.is_abs(target) {check = strings.concatenate({link[:strings.last_index_byte(link, '/') + 1], target}, context.temp_allocator)}
	if !os.exists(check) {return target, false, true}
	changed = true
	tmp := strings.concatenate({link, ".wlperch-tmp"}, context.temp_allocator)
	os.remove(tmp)
	ctmp := strings.clone_to_cstring(tmp, context.temp_allocator)
	if posix.symlink(strings.clone_to_cstring(target, context.temp_allocator), ctmp) != .OK {return}
	if posix.rename(ctmp, clink) != 0 {
		os.remove(tmp)
		return
	}
	ok = true
	return
}

// Set gtk-application-prefer-dark-theme (and gtk-theme-name, when given) in
// an existing settings.ini that has them; never creates the file or keys.
gtk_ini_update :: proc(path: string, light: bool, gtk_theme: string) -> (changed, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return}
	b := strings.builder_make(context.temp_allocator)
	for line in strings.split_after(string(data), "\n", context.temp_allocator) {
		key := strings.trim_space(line[:strings.index_byte(line, '=') >= 0 ? strings.index_byte(line, '=') : 0])
		nl := strings.has_suffix(line, "\n") ? "\n" : ""
		switch {
		case key == "gtk-application-prefer-dark-theme":
			fmt.sbprintf(&b, "gtk-application-prefer-dark-theme=%s%s", light ? "0" : "1", nl)
		case key == "gtk-theme-name" && gtk_theme != "":
			fmt.sbprintf(&b, "gtk-theme-name=%s%s", gtk_theme, nl)
		case:
			strings.write_string(&b, line)
		}
	}
	out := strings.to_string(b)
	if out == string(data) {return false, true}
	return true, write_through(path, out)
}

// "workbench.colorTheme": "…" in a VS Code settings.json that sets it.
vscode_set_theme :: proc(path, theme: string) -> (changed, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return}
	text := string(data)
	KEY :: `"workbench.colorTheme"`
	i := strings.index(text, KEY)
	if i < 0 {return}
	rest := text[i + len(KEY):]
	q1 := strings.index_byte(rest, '"')
	if q1 < 0 || strings.trim_space(rest[:q1]) != ":" {return}
	q2 := strings.index_byte(rest[q1 + 1:], '"')
	if q2 < 0 {return}
	start := i + len(KEY) + q1 + 1
	if text[start:start + q2] == theme {return false, true}
	out := strings.concatenate({text[:start], theme, text[start + q2:]}, context.temp_allocator)
	return true, write_through(path, out)
}

// SIGUSR2 (reload config and style) to the waybars of this Wayland display.
reload_waybar :: proc() -> int {
	display := os.get_env("WAYLAND_DISPLAY", context.temp_allocator)
	entries, err := os.read_all_directory_by_path("/proc", context.temp_allocator)
	if err != nil {return 0}
	n := 0
	for e in entries {
		if len(e.name) == 0 || e.name[0] < '0' || e.name[0] > '9' {continue}
		comm, cerr := os.read_entire_file(fmt.tprintf("/proc/%s/comm", e.name), context.temp_allocator)
		if cerr != nil || strings.trim_space(string(comm)) != "waybar" {continue}
		env, eerr := os.read_entire_file(fmt.tprintf("/proc/%s/environ", e.name), context.temp_allocator)
		if eerr != nil {continue}
		theirs := ""
		for kv in strings.split(string(env), "\x00", context.temp_allocator) {
			if strings.has_prefix(kv, "WAYLAND_DISPLAY=") {theirs = kv[len("WAYLAND_DISPLAY="):]}
		}
		if theirs != display {continue}
		pid := 0
		for ch in e.name {pid = pid * 10 + int(ch - '0')}
		if posix.kill(posix.pid_t(pid), .SIGUSR2) == .OK {n += 1}
	}
	return n
}
