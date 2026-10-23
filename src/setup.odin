// `wlperch setup`: the program installs and manages its own components.
// Started from a download (not installed yet, no daemon running), plain
// `wlperch` opens this too.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

import "wl"

SWAY_FILE :: #load("../contrib/sway/wlperch.conf", string)
WAYBAR_JSONC :: #load("../contrib/waybar/wlperch.jsonc", string)
WAYBAR_CSS :: #load("../contrib/waybar/wlperch.css", string)

RAPL_RULE :: `SUBSYSTEM=="powercap", ACTION=="add", RUN+="/bin/chmod 0444 /sys%p/energy_uj"`
RAPL_RULE_PATH :: "/etc/udev/rules.d/90-wlperch-rapl.rules"
RAPL_RULE_PATH_OLD :: "/etc/udev/rules.d/90-wlwidgets-rapl.rules" // from before the rename

Comp_State :: enum {
	Missing,
	Installed,
	Outdated,
	Custom,      // set up by hand elsewhere; we leave it alone
	Unavailable, // doesn't apply to this machine
	Running,
	Stopped,
	Partial,
}

Comp_Id :: enum {
	Program,
	Service,
	Config,
	Sway,
	Waybar,
	Rapl,
	Notifications,
	Launcher,
}

Component :: struct {
	state:   Comp_State,
	detail:  [dynamic]string, // paths / notes shown under the description
	busy:    bool,
	message: string,          // result of the last action
	msg_ok:  bool,
}

Setup :: struct {
	mu:        sync.Mutex,
	comps:     [Comp_Id]Component,
	checked:   time.Tick,
	self_path: string, // the running binary
	bin_path:  string, // ~/.local/bin/wlperch
	strs:      [dynamic]string,
}
setup: Setup

@(private = "file")
home :: proc() -> string {return os.get_env("HOME", context.temp_allocator)}

@(private = "file")
config_home :: proc() -> string {
	if x := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); x != "" {return x}
	return strings.concatenate({home(), "/.config"}, context.temp_allocator)
}

@(private = "file")
read_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return string(data), err == nil
}

@(private = "file")
detail :: proc(c: ^Component, line: string) {
	h := home()
	shown := line
	if h != "" && strings.contains(line, h) {shown, _ = strings.replace_all(line, h, "~", context.temp_allocator)}
	s := strings.clone(shown)
	append(&setup.strs, s)
	append(&c.detail, s)
}

sway_dir :: proc() -> string {return strings.concatenate({config_home(), "/sway/config.d"}, context.temp_allocator)}
sway_file :: proc() -> string {return strings.concatenate({sway_dir(), "/wlperch.conf"}, context.temp_allocator)}
waybar_dir :: proc() -> string {return strings.concatenate({config_home(), "/waybar"}, context.temp_allocator)}
launcher_file :: proc() -> string {
	base := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if base == "" {base = strings.concatenate({home(), "/.local/share"}, context.temp_allocator)}
	return strings.concatenate({base, "/applications/wlperch-setup.desktop"}, context.temp_allocator)
}

// The user's waybar config file (config.jsonc or config).
waybar_config :: proc() -> string {
	for name in ([]string{"config.jsonc", "config"}) {
		p := strings.concatenate({waybar_dir(), "/", name}, context.temp_allocator)
		if os.exists(p) {return p}
	}
	return ""
}

files_equal :: proc(a, b: string) -> bool {
	da, ea := os.read_entire_file(a, context.temp_allocator)
	db, eb := os.read_entire_file(b, context.temp_allocator)
	return ea == nil && eb == nil && string(da) == string(db)
}

is_installed_binary :: proc() -> bool {
	return setup_self_path() == strings.concatenate({home(), "/.local/bin/wlperch"}, context.temp_allocator)
}

setup_self_path :: proc() -> string {
	target, err := os.read_link("/proc/self/exe", context.temp_allocator)
	if err != nil {return ""}
	return strings.trim_suffix(target, " (deleted)")
}

// ---- Status -----------------------------------------------------------------

setup_check :: proc() {
	sync.guard(&setup.mu)
	for s in setup.strs {delete(s)}
	clear(&setup.strs)
	for &c in setup.comps {clear(&c.detail)}
	setup.checked = time.tick_now()
	c := &setup.comps

	// Program
	{
		p := &c[.Program]
		detail(p, setup.bin_path)
		switch {
		case !os.exists(setup.bin_path):              p.state = .Missing
		case setup.self_path == setup.bin_path:        p.state = .Installed
		case files_equal(setup.self_path, setup.bin_path): p.state = .Installed
		case:                                          p.state = .Outdated
		}
		path_env := os.get_env("PATH", context.temp_allocator)
		if !strings.contains(path_env, strings.concatenate({home(), "/.local/bin"}, context.temp_allocator)) {
			detail(p, "~/.local/bin is not on your PATH")
		}
	}
	// Service
	{
		p := &c[.Service]
		p.state = ipc_send("ping") ? .Running : .Stopped
		detail(p, p.state == .Running ? "the background daemon is running" : "not running")
	}
	// Config
	{
		p := &c[.Config]
		path := config_path()
		detail(p, path)
		p.state = os.exists(path) ? .Installed : .Missing
	}
	// Sway
	{
		p := &c[.Sway]
		ours := sway_file()
		custom := ""
		if entries, err := os.read_all_directory_by_path(sway_dir(), context.temp_allocator); err == nil {
			for e in entries {
				full := strings.concatenate({sway_dir(), "/", e.name}, context.temp_allocator)
				if full == ours {continue}
				if text, ok := read_text(full); ok && strings.contains(text, "exec wlperch daemon") {custom = full}
			}
		}
		switch {
		case custom != "":
			p.state = .Custom
			detail(p, custom)
		case !os.exists(ours):
			p.state = .Missing
			detail(p, ours)
		case:
			text, _ := read_text(ours)
			p.state = text == SWAY_FILE ? .Installed : .Outdated
			detail(p, ours)
		}
		// The stock sway config only includes /etc/sway/config.d/*: our file
		// would never load. Install/Update adds the include line.
		if (p.state == .Installed || p.state == .Missing) && !sway_loads_config_d() {
			if p.state == .Installed {p.state = .Outdated}
			detail(p, "your sway config doesn't load ~/.config/sway/config.d/* yet (Install adds that line)")
		}
	}
	// Waybar
	{
		p := &c[.Waybar]
		dir := waybar_dir()
		if !os.exists(dir) {
			p.state = .Unavailable
			detail(p, "no ~/.config/waybar")
		} else {
			j := strings.concatenate({dir, "/wlperch.jsonc"}, context.temp_allocator)
			css := strings.concatenate({dir, "/wlperch.css"}, context.temp_allocator)
			jt, jok := read_text(j)
			ct, cok := read_text(css)
			files_ok := jok && cok
			cfg := waybar_config()
			cfg_text, _ := read_text(cfg)
			style_text, _ := read_text(strings.concatenate({dir, "/style.css"}, context.temp_allocator))
			hooked := strings.contains(cfg_text, "wlperch.jsonc") && strings.contains(cfg_text, "custom/wlperch") && strings.contains(style_text, "wlperch.css")
			switch {
			case !files_ok:                              p.state = .Missing
			case jt != WAYBAR_JSONC || ct != WAYBAR_CSS: p.state = .Outdated
			case !hooked:                                p.state = .Partial
			case:                                        p.state = .Installed
			}
			detail(p, fmt.tprintf("%s/wlperch.{{jsonc,css}}", dir))
			if cfg != "" {detail(p, hooked ? fmt.tprintf("hooked into %s", cfg) : fmt.tprintf("not yet in %s", cfg))}
		}
	}
	// RAPL udev rule
	{
		p := &c[.Rapl]
		if !os.exists("/sys/class/powercap/intel-rapl:0/energy_uj") {
			p.state = .Unavailable
			detail(p, "no RAPL energy counter on this machine")
		} else {
			readable := posix.access("/sys/class/powercap/intel-rapl:0/energy_uj", {.R_OK}) == .OK
			switch {
			case os.exists(RAPL_RULE_PATH) || os.exists(RAPL_RULE_PATH_OLD): p.state = .Installed
			case readable:                  p.state = .Custom
			case:                           p.state = .Missing
			}
			detail(p, RAPL_RULE_PATH)
			detail(p, readable ? "CPU energy counter is readable" : "CPU energy counter is root-only")
		}
	}
	// Notifications
	{
		p := &c[.Notifications]
		owner := notification_owner()
		units := other_notification_units()
		switch {
		case !notifications_enabled():
			p.state = .Unavailable
			detail(p, "off in the config: [notifications] enabled = false")
		case owner == "wlperch":
			p.state = .Running
			detail(p, "wlperch shows your notifications")
		case owner != "":
			p.state = .Missing
			detail(p, fmt.tprintf("%s shows your notifications right now", owner))
		case:
			p.state = .Stopped
			detail(p, "nothing serves notifications right now (start the background service)")
		}
		for u in units {
			out, _ := run({"systemctl", "--user", "is-enabled", u}, 2 * time.Second, context.temp_allocator)
			detail(p, fmt.tprintf("%s: %s", u, strings.trim_space(out)))
		}
	}
	// Launcher entry
	{
		p := &c[.Launcher]
		detail(p, launcher_file())
		p.state = os.exists(launcher_file()) ? .Installed : .Missing
	}
}

// ---- Actions ----------------------------------------------------------------

@(private = "file")
done :: proc(id: Comp_Id, ok: bool, msg: string) {
	sync.guard(&setup.mu)
	c := &setup.comps[id]
	c.busy = false
	c.msg_ok = ok
	delete(c.message)
	c.message = strings.clone(msg)
	log.infof("setup %v: %s", id, msg)
}

@(private = "file")
write_file :: proc(path, content: string, mode: os.Permissions = os.Permissions_Default_File) -> bool {
	dir := path[:strings.last_index_byte(path, '/')]
	os.make_directory_all(dir)
	tmp := strings.concatenate({path, ".wlperch-tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, content, mode) != nil {return false}
	return os.rename(tmp, path) == nil
}

@(private = "file")
backup :: proc(path: string) {
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		_ = os.write_entire_file(strings.concatenate({path, ".before-wlperch"}, context.temp_allocator), data)
	}
}

setup_install_program :: proc() {
	data, err := os.read_entire_file(setup.self_path, context.temp_allocator)
	if err != nil {
		done(.Program, false, "couldn't read the running binary")
		return
	}
	ok := write_file(setup.bin_path, string(data), os.Permissions_Read_All + os.Permissions_Execute_All + {.Write_User})
	done(.Program, ok, ok ? "installed to ~/.local/bin" : "couldn't write ~/.local/bin/wlperch")
}

setup_start_service :: proc(restart: bool) {
	if restart {
		ok := ipc_send("restart")
		done(.Service, ok, ok ? "restarted" : "couldn't reach the daemon")
		return
	}
	exe := os.exists(setup.bin_path) ? setup.bin_path : setup.self_path
	ok := launch_detached({exe, "daemon"})
	done(.Service, ok, ok ? "started" : "couldn't start the daemon")
}

setup_create_config :: proc() {
	path := config_path()
	if os.exists(path) {
		run_async({"xdg-open", path})
		done(.Config, true, "opened in your editor")
		return
	}
	ok := write_file(path, DEFAULT_CONFIG)
	done(.Config, ok, ok ? "default config written" : "couldn't write the config")
}

setup_install_sway :: proc() {
	if !write_file(sway_file(), SWAY_FILE) {
		done(.Sway, false, "couldn't write the sway file")
		return
	}
	if !sway_loads_config_d() {
		cfg := sway_main_config()
		text, _ := read_text(cfg)
		if text == "" {text, _ = read_text("/etc/sway/config")} // no personal config yet: start from the stock one
		if text != "" {backup(cfg)}
		line := fmt.tprintf("\n# Added by wlperch setup: load the files in config.d.\ninclude %s/*\n", sway_dir())
		if !write_file(cfg, strings.concatenate({text, line}, context.temp_allocator)) {
			done(.Sway, false, "wrote the sway file, but couldn't add the include line to your sway config")
			return
		}
	}
	done(.Sway, true, "installed; reload sway to activate")
}

@(private = "file")
sway_main_config :: proc() -> string {return strings.concatenate({config_home(), "/sway/config"}, context.temp_allocator)}

// Does the user's sway config include ~/.config/sway/config.d/* (in any spelling)?
sway_loads_config_d :: proc() -> bool {
	text, ok := read_text(sway_main_config())
	if !ok {return false}
	dir := sway_dir()
	for raw in strings.split_lines(text, context.temp_allocator) {
		line := strings.trim_space(raw)
		if !strings.has_prefix(line, "include ") {continue}
		path := strings.trim(strings.trim_space(line[len("include "):]), `"'`)
		path, _ = strings.replace_all(path, "${XDG_CONFIG_HOME:-$HOME/.config}", config_home(), context.temp_allocator)
		path, _ = strings.replace_all(path, "$XDG_CONFIG_HOME", config_home(), context.temp_allocator)
		path, _ = strings.replace_all(path, "$HOME", home(), context.temp_allocator)
		if strings.has_prefix(path, "~/") {path = strings.concatenate({home(), path[1:]}, context.temp_allocator)}
		// Relative includes are relative to the config's own directory.
		if !strings.has_prefix(path, "/") {path = strings.concatenate({config_home(), "/sway/", path}, context.temp_allocator)}
		if strings.has_prefix(path, dir) {return true}
	}
	return false
}

// [notifications] enabled, read straight from the file (setup doesn't load
// the config, so it can offer to create it).
@(private = "file")
notifications_enabled :: proc() -> bool {
	text, ok := read_text(config_path())
	if !ok {return true}
	section := ""
	for raw in strings.split_lines(text, context.temp_allocator) {
		line := strings.trim_space(raw)
		if strings.has_prefix(line, "[") {section = strings.trim(line, "[] ")}
		if section != "notifications" || !strings.has_prefix(line, "enabled") {continue}
		if eq := strings.index_byte(line, '='); eq >= 0 {
			v := strings.to_lower(strings.trim_space(line[eq + 1:]), context.temp_allocator)
			return !(v == "false" || v == "no" || v == "0" || v == "off")
		}
	}
	return true
}

setup_remove_sway :: proc() {
	ok := os.remove(sway_file()) == nil
	done(.Sway, ok, ok ? "removed; reload sway to deactivate" : "couldn't remove the sway file")
}

setup_reload_sway :: proc() {
	ok := sway_command("reload")
	done(.Sway, ok, ok ? "sway reloaded" : "sway reload failed")
}

setup_install_waybar_files :: proc() -> bool {
	dir := waybar_dir()
	ok := write_file(strings.concatenate({dir, "/wlperch.jsonc"}, context.temp_allocator), WAYBAR_JSONC) &&
	      write_file(strings.concatenate({dir, "/wlperch.css"}, context.temp_allocator), WAYBAR_CSS)
	done(.Waybar, ok, ok ? "module files installed" : "couldn't write the waybar files")
	return ok
}

// Add the include, the button and the CSS import to the user's waybar config,
// with backups. Only simple, recognisable structures are edited.
setup_hook_waybar :: proc() {
	if !setup_install_waybar_files() {return}
	cfg := waybar_config()
	if cfg == "" {
		done(.Waybar, false, "no waybar config file found")
		return
	}
	text, _ := read_text(cfg)
	if !strings.contains(text, "wlperch.jsonc") {
		if strings.contains(text, `"include"`) {
			done(.Waybar, false, `your config already has an "include": add "wlperch.jsonc" to it`)
			return
		}
		brace := strings.index_byte(text, '{')
		if brace < 0 || strings.has_prefix(strings.trim_space(text), "[") {
			done(.Waybar, false, "multi-bar configs aren't patched automatically; see the README")
			return
		}
		text = strings.concatenate({text[:brace + 1], "\n    \"include\": [\"wlperch.jsonc\"],", text[brace + 1:]}, context.temp_allocator)
	}
	if !strings.contains(text, `"custom/wlperch"`) {
		key := strings.index(text, `"modules-right"`)
		if key < 0 {
			done(.Waybar, false, `no "modules-right" in your config: add "custom/wlperch" to a modules list`)
			return
		}
		open := key + strings.index_byte(text[key:], '[')
		if open < key {
			done(.Waybar, false, `couldn't parse "modules-right": add "custom/wlperch" by hand`)
			return
		}
		close, last, ok := jsonc_array_end(text, open)
		if !ok {
			done(.Waybar, false, `couldn't parse "modules-right": add "custom/wlperch" by hand`)
			return
		}
		// Insert right after the last element (not inside a trailing comment).
		insert := last < 0 ? `"custom/wlperch"` : `, "custom/wlperch"`
		cut := last < 0 ? open + 1 : last
		_ = close
		text = strings.concatenate({text[:cut], insert, text[cut:]}, context.temp_allocator)
	}
	backup(cfg)
	if !write_file(cfg, text) {
		done(.Waybar, false, "couldn't write your waybar config")
		return
	}
	style := strings.concatenate({waybar_dir(), "/style.css"}, context.temp_allocator)
	if st, ok := read_text(style); ok && !strings.contains(st, "wlperch.css") {
		backup(style)
		write_file(style, strings.concatenate({"@import \"wlperch.css\";\n", st}, context.temp_allocator))
	}
	posix.system("pkill -SIGUSR2 -x waybar")
	done(.Waybar, true, "added to your bar (backups: *.before-wlperch)")
}

setup_reload_waybar :: proc() {
	posix.system("pkill -SIGUSR2 -x waybar")
	done(.Waybar, true, "waybar reloaded")
}

// Root-owned: pkexec shows your polkit agent's password prompt.
setup_install_rapl :: proc(install: bool) {
	{
		sync.guard(&setup.mu)
		setup.comps[.Rapl].busy = true
	}
	// Fedora & co ship rules in /usr/lib/udev/rules.d; /etc/udev/rules.d may not exist yet.
	script: string
	if install {
		script = fmt.aprintf(`mkdir -p /etc/udev/rules.d && printf '%%s\n' '%s' > %s && udevadm control --reload-rules && udevadm trigger --action=add --subsystem-match=powercap`, RAPL_RULE, RAPL_RULE_PATH)
	} else {
		script = fmt.aprintf(`rm -f %s %s && chmod 0400 /sys/class/powercap/*/energy_uj`, RAPL_RULE_PATH, RAPL_RULE_PATH_OLD)
	}
	Job :: struct {
		script:  string,
		install: bool,
	}
	job := new(Job)
	job^ = {script, install}
	thread.create_and_start_with_data(job, proc(data: rawptr) {
		job := cast(^Job)data
		// Capture the script's error output so failures can be shown.
		out, code := run_code({"pkexec", "sh", "-c", strings.concatenate({job.script, " 2>&1"}, context.temp_allocator)}, 180 * time.Second, context.temp_allocator)
		ok := job.install ? os.exists(RAPL_RULE_PATH) : !os.exists(RAPL_RULE_PATH) && !os.exists(RAPL_RULE_PATH_OLD)
		msg: string
		switch {
		case ok:          msg = job.install ? "installed; CPU power is now readable" : "removed"
		case code == 126: msg = "cancelled (password dialog dismissed)"
		case code == 127: msg = "not authorized (or no polkit agent running)"
		case:
			detail := strings.trim_space(out)
			if detail == "" {detail = fmt.tprintf("exit code %d", code)}
			msg = fmt.tprintf("failed: %s", detail)
		}
		done(.Rapl, ok, msg)
		setup_check()
		wake_main()
		delete(job.script)
		free(job)
		free_all(context.temp_allocator)
	}, self_cleanup = true)
}

setup_install_launcher :: proc(install: bool) {
	if !install {
		ok := os.remove(launcher_file()) == nil
		done(.Launcher, ok, ok ? "removed" : "couldn't remove")
		return
	}
	entry := fmt.tprintf(`[Desktop Entry]
Type=Application
Name=wlperch setup
Comment=Install and configure wlperch components
Exec=%s setup
Icon=preferences-system
Terminal=false
Categories=Settings;
`, setup.bin_path)
	ok := write_file(launcher_file(), entry)
	done(.Launcher, ok, ok ? "added to your app launcher" : "couldn't write the launcher entry")
}

// systemd user units of other notification daemons (from their D-Bus
// activation files), e.g. dunst.service.
other_notification_units :: proc() -> []string {
	units: [dynamic]string
	units.allocator = context.temp_allocator
	for dir in ([]string{"/usr/share/dbus-1/services", "/usr/local/share/dbus-1/services", strings.concatenate({home(), "/.local/share/dbus-1/services"}, context.temp_allocator)}) {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {continue}
		for e in entries {
			text, ok := read_text(strings.concatenate({dir, "/", e.name}, context.temp_allocator))
			if !ok || !strings.contains(text, "Name=org.freedesktop.Notifications") {continue}
			for line in strings.split_lines(text, context.temp_allocator) {
				if strings.has_prefix(line, "SystemdService=") {append(&units, strings.trim_space(line[len("SystemdService="):]))}
			}
		}
	}
	return units[:]
}

// Take over notifications: mask the other daemon's unit (so D-Bus can't
// start it again) and stop it; the daemon is queued for the name and takes
// over at once. take = false unmasks them again.
setup_take_notifications :: proc(take: bool) {
	units := other_notification_units()
	if len(units) == 0 && take {
		owner := notification_owner()
		if owner != "" && owner != "wlperch" {
			run({"pkill", "-x", owner}, 3 * time.Second, context.temp_allocator)
			time.sleep(400 * time.Millisecond)
			done(.Notifications, notification_owner() == "wlperch", fmt.tprintf("stopped %s (it isn't a systemd service; remove it from your autostart)", owner))
		} else {
			done(.Notifications, false, "no other notification daemon found")
		}
		return
	}
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "systemctl", "--user", take ? "mask" : "unmask")
	if take {append(&args, "--now")}
	for u in units {append(&args, u)}
	out, code := run_code(args[:], 10 * time.Second, context.temp_allocator)
	if code != 0 {
		done(.Notifications, false, fmt.tprintf("systemctl failed: %s", strings.trim_space(out)))
		return
	}
	if !take {
		done(.Notifications, true, fmt.tprintf("%s may run again; set [notifications] enabled = false and restart wlperch to hand over", strings.join(units, ", ", context.temp_allocator)))
		return
	}
	// The daemon was queued for the name: give it a moment.
	owner := ""
	for _ in 0 ..< 10 {
		owner = notification_owner()
		if owner == "wlperch" {break}
		time.sleep(200 * time.Millisecond)
	}
	ok := owner == "wlperch"
	done(.Notifications, ok, ok ? fmt.tprintf("wlperch now shows notifications (%s masked)", strings.join(units, ", ", context.temp_allocator)) : fmt.tprintf("%s masked; start the background service to take over", strings.join(units, ", ", context.temp_allocator)))
}

// Program, config, sway, waybar (files + hook), launcher, then start the daemon.
setup_install_recommended :: proc() {
	states: [Comp_Id]Comp_State
	{
		sync.guard(&setup.mu)
		for c, id in setup.comps {states[id] = c.state}
	}
	if states[.Program] != .Installed {setup_install_program()}
	if states[.Config] == .Missing {setup_create_config()}
	if states[.Sway] == .Missing || states[.Sway] == .Outdated {setup_install_sway()}
	if states[.Waybar] != .Installed && states[.Waybar] != .Unavailable {setup_hook_waybar()}
	if states[.Launcher] == .Missing {setup_install_launcher(true)}
	if states[.Service] != .Running {setup_start_service(false)}
	if states[.Notifications] == .Missing {setup_take_notifications(true)}
}

// Open the setup window as its own process (from a panel's ⚙ button).
setup_launch :: proc() {
	exe := setup_self_path()
	if exe == "" {exe = "wlperch"}
	launch_detached({exe, "setup"})
}

// ---- Main -------------------------------------------------------------------

run_setup :: proc() {
	setup.self_path = strings.clone(setup_self_path())
	setup.bin_path = strings.concatenate({home(), "/.local/bin/wlperch"})
	fds: [2]posix.FD
	posix.pipe(&fds)
	app.wake_r, app.wake_w = fds[0], fds[1]
	set_cloexec_nonblock(app.wake_r)
	set_cloexec_nonblock(app.wake_w)
	if !platform_init() {os.exit(1)}
	im_init()
	setup_check()
	if !platform_open_window("wlperch setup", "wlperch-setup", 820, 860) {
		log.error("couldn't open the setup window")
		os.exit(1)
	}
	app.show_time = time.tick_now()
	for !plat.closed {
		d := plat.display
		for wl.display_prepare_read(d) != 0 {wl.display_dispatch_pending(d)}
		wl.display_flush(d)
		timeout := plat.redraw > 0 && !plat.frame_pending ? 0 : 1000
		pfds := [2]posix.pollfd{{fd = platform_fd(), events = {.IN}}, {fd = app.wake_r, events = {.IN}}}
		n := posix.poll(&pfds[0], 2, i32(timeout))
		if n > 0 && .IN in pfds[0].revents {
			wl.display_read_events(d)
		} else {
			wl.display_cancel_read(d)
		}
		wl.display_dispatch_pending(d)
		if .IN in pfds[1].revents {
			buf: [64]u8
			for posix.read(app.wake_r, &buf[0], len(buf)) > 0 {}
			request_redraw(2)
		}
		if time.tick_since(setup.checked) > 2 * time.Second {
			setup_check()
			request_redraw(1)
		}
		if plat.redraw > 0 && platform_can_render() {
			plat.redraw -= 1
			render_setup_frame()
		}
		free_all(context.temp_allocator)
	}
	platform_hide()
}

// For the array whose '[' is at `open`: the index of its ']' and the index
// just after its last element (-1 when empty), skipping strings and // and
// /* */ comments.
jsonc_array_end :: proc(text: string, open: int) -> (close, last: int, ok: bool) {
	last = -1
	depth := 0
	i := open
	for i < len(text) {
		c := text[i]
		switch {
		case c == '"':
			i += 1
			for i < len(text) && text[i] != '"' {
				if text[i] == '\\' {i += 1}
				i += 1
			}
			i += 1
			last = i
			continue
		case c == '/' && i + 1 < len(text) && text[i + 1] == '/':
			for i < len(text) && text[i] != '\n' {i += 1}
			continue
		case c == '/' && i + 1 < len(text) && text[i + 1] == '*':
			end := strings.index(text[i + 2:], "*/")
			if end < 0 {return 0, 0, false}
			i += end + 4
			continue
		case c == '[' || c == '{':
			depth += 1
			if depth > 1 {last = -2} // nested structures: mark non-empty
		case c == ']' || c == '}':
			depth -= 1
			if depth == 0 {return i, last == -2 ? i : last, true}
			last = i + 1
		case c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ',':
		case:
			last = i + 1 // numbers, true/false/null
		}
		i += 1
	}
	return 0, 0, false
}
