// Setup component "Desktop portal": apps that follow the system dark / light
// setting (Discord and other Electron apps, Chrome, Firefox, Flatpaks) read
// it from xdg-desktop-portal (org.freedesktop.appearance color-scheme) and
// update live on its SettingChanged signal. wlperch theme already sets the
// gsettings color-scheme the gtk backend serves; this makes sure the portal
// can run at all.
//
// The portal service is Requisite=graphical-session.target, which only a
// session target bound to it starts. Sway started from a TTY with its own
// config (not /etc/sway/config.d/*) never starts one, so the portal fails
// with "dependency". "Start session" writes config.d/wlperch-session.conf
// running sway-systemd's session.sh (or, without sway-systemd, importing the
// environment and starting wlperch-session.target of our own), and runs it
// now. "Switch back" removes the files (the running session stays until
// logout). A missing Settings backend (xdg-desktop-portal-gtk) is installed
// with pkexec.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

PORTAL_CONF_NAME :: "wlperch-session.conf"
PORTAL_TARGET :: "wlperch-session.target"
PORTAL_BACKEND_PKG :: "xdg-desktop-portal-gtk"

@(private = "file")
SWAY_SYSTEMD_SESSION := []string {
	"/usr/libexec/sway-systemd/session.sh", // Fedora
	"/usr/lib/sway-systemd/session.sh", // Arch, Debian
	"/usr/share/sway-systemd/session.sh",
}

PORTAL_TARGET_UNIT :: `# Written by wlperch setup ("Switch back" in the Desktop portal card removes it).
[Unit]
Description=Sway session (wlperch)
BindsTo=graphical-session.target
Wants=graphical-session-pre.target
After=graphical-session-pre.target
`

@(private = "file")
PORTAL_ENV_CMD :: "dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP=sway XDG_SESSION_TYPE=wayland && systemctl --user start " + PORTAL_TARGET

// What the last check found (read by the dark / light card and the actions).
Portal_Status :: struct {
	session:  bool, // graphical-session.target active
	backend:  bool, // some installed portal backend provides Settings
	ready:    bool, // the portal answers color-scheme
	scheme:   string, // dark | light | no preference
	elsewhere: bool, // the user's sway files already start a session
	installed: bool, // our config.d file (from Start session)
}

portal_status: Portal_Status

@(private = "file")
sway_systemd_session :: proc() -> string {
	for p in SWAY_SYSTEMD_SESSION {if os.exists(p) {return p}}
	return ""
}

// The exec command that starts the session.
@(private = "file")
portal_session_cmd :: proc() -> string {
	if s := sway_systemd_session(); s != "" {return s}
	return PORTAL_ENV_CMD
}

@(private = "file")
portal_conf_text :: proc() -> string {
	return fmt.tprintf(`# Start the systemd graphical session (written by wlperch setup; "Switch back" removes it).
# xdg-desktop-portal needs it: apps that follow the system dark / light
# setting (Discord, browsers, Flatpaks) read it from the portal.
exec %s
`, portal_session_cmd())
}

@(private = "file")
portal_no_files :: proc() -> []string {return nil}

@(private = "file")
portal_no_rewrite :: proc(text: string, allocator := context.temp_allocator) -> (out: string, changes: int) {
	return strings.clone(text, allocator), 0
}

@(private = "file")
portal_switch_spec :: proc() -> Config_Switch {
	return Config_Switch {
		backup = "portal-backup",
		files = portal_no_files,
		rewrite = portal_no_rewrite,
		new_path = fmt.tprintf("%s/sway/config.d/%s", sway_config_home(), PORTAL_CONF_NAME),
		new_text = portal_conf_text(),
	}
}

@(private = "file")
portal_unit_path :: proc() -> string {
	return fmt.tprintf("%s/systemd/user/%s", sway_config_home(), PORTAL_TARGET)
}

// Does a portal backend (any .portal file) provide the Settings interface?
portal_has_settings_backend :: proc() -> bool {
	dirs := []string{"/usr/share/xdg-desktop-portal/portals", "/usr/local/share/xdg-desktop-portal/portals"}
	for dir in dirs {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {continue}
		for e in entries {
			if !strings.has_suffix(e.name, ".portal") {continue}
			data, rerr := os.read_entire_file(fmt.tprintf("%s/%s", dir, e.name), context.temp_allocator)
			if rerr == nil && strings.contains(string(data), "org.freedesktop.impl.portal.Settings") {return true}
		}
	}
	return false
}

// "v u 1" -> dark; "" when the portal doesn't answer.
portal_parse_scheme :: proc(reply: string) -> string {
	f := strings.fields(strings.trim_space(reply), context.temp_allocator)
	if len(f) < 3 || f[0] != "v" {return ""}
	switch f[len(f) - 1] {
	case "1": return "dark"
	case "2": return "light"
	case "0": return "no preference"
	}
	return ""
}

// An active line in the user's sway files that already starts a session.
@(private = "file")
portal_session_elsewhere :: proc(ours: string) -> string {
	for f in sway_candidate_files(scripts = false) {
		if f == ours {continue}
		data, err := os.read_entire_file(f, context.temp_allocator)
		if err != nil {continue}
		for line in strings.split_lines(string(data), context.temp_allocator) {
			t := strings.trim_space(line)
			if strings.has_prefix(t, "#") {continue}
			if strings.contains(t, "sway-systemd/session.sh") || strings.contains(t, "sway-session.target") || strings.contains(t, "include /etc/sway/config.d") {
				return f
			}
		}
	}
	return ""
}

portal_setup_check :: proc(p: ^Component, add_detail: proc(c: ^Component, line: string)) {
	spec := portal_switch_spec()
	_, installed := switch_manifest(spec)
	st: Portal_Status
	out, _ := run({"systemctl", "--user", "is-active", "graphical-session.target"}, 2 * time.Second, context.temp_allocator)
	st.session = strings.trim_space(out) == "active"
	st.backend = portal_has_settings_backend()
	// Only ask the portal when it can start: otherwise each check would log
	// a failed activation job.
	if st.session {
		reply, ok := run({"busctl", "--user", "--timeout=3", "call", "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "ReadOne", "ss", "org.freedesktop.appearance", "color-scheme"}, 5 * time.Second, context.temp_allocator)
		if ok {st.scheme = portal_parse_scheme(reply)}
		st.ready = st.scheme != ""
	}
	starter := portal_session_elsewhere(spec.new_path)
	st.elsewhere = starter != ""
	st.installed = installed
	portal_status = st

	switch {
	case st.ready:
		p.state = installed ? .Installed : .Running
		add_detail(p, fmt.tprintf("the portal reports %s; apps set to follow the system switch with wlperch theme", st.scheme))
	case !st.session && installed:
		p.state = .Stopped
		add_detail(p, "the graphical session isn't running yet (Start now, or log in again)")
	case !st.session && st.elsewhere:
		p.state = .Stopped
		add_detail(p, fmt.tprintf("%s starts the session, but it isn't running (log in again)", starter))
	case !st.session:
		p.state = .Missing
		add_detail(p, "graphical-session.target isn't running, so xdg-desktop-portal can't start: apps can't see dark / light")
	case !st.backend:
		p.state = .Missing
	case:
		p.state = .Stopped
		add_detail(p, "the session runs but the portal doesn't answer (systemctl --user status xdg-desktop-portal)")
	}
	if !st.backend {
		add_detail(p, fmt.tprintf("no portal backend serves the dark / light setting: install %s", PORTAL_BACKEND_PKG))
	}
	if installed {
		add_detail(p, fmt.tprintf("added %s", spec.new_path))
		if os.exists(portal_unit_path()) {add_detail(p, fmt.tprintf("added %s", portal_unit_path()))}
	} else if !st.session && !st.elsewhere {
		add_detail(p, fmt.tprintf("Start session adds %s: exec %s", spec.new_path, portal_session_cmd()))
	}
	if !st.ready {add_detail(p, "Discord: Settings > Appearance > Sync with computer, once the portal answers")}
}

@(private = "file")
portal_done :: proc(ok: bool, msg: string) {
	sync.guard(&setup.mu)
	c := &setup.comps[.Portal]
	c.busy = false
	c.msg_ok = ok
	delete(c.message)
	c.message = strings.clone(msg)
	log.infof("setup portal: %s", msg)
}

// Run the session command inside sway (as at login: it stays until sway exits).
@(private = "file")
portal_start_now :: proc() -> bool {
	return sway_command(fmt.tprintf("exec %s", portal_session_cmd()))
}

// Wait (briefly) for graphical-session.target, so the next check sees it.
@(private = "file")
portal_wait_session :: proc() -> bool {
	for _ in 0 ..< 20 {
		out, _ := run({"systemctl", "--user", "is-active", "graphical-session.target"}, 2 * time.Second, context.temp_allocator)
		if strings.trim_space(out) == "active" {return true}
		time.sleep(150 * time.Millisecond)
	}
	return false
}

setup_install_portal :: proc() {
	spec := portal_switch_spec()
	if sway_systemd_session() == "" {
		path := portal_unit_path()
		os.make_directory_all(path[:strings.last_index_byte(path, '/')])
		if os.write_entire_file(path, PORTAL_TARGET_UNIT) != nil {
			portal_done(false, fmt.tprintf("couldn't write %s", path))
			return
		}
		run({"systemctl", "--user", "daemon-reload"}, 10 * time.Second, context.temp_allocator)
	}
	_, err := switch_apply(spec, allow_new = true)
	if err != "" {
		portal_done(false, err)
		return
	}
	started := portal_start_now() && portal_wait_session()
	portal_done(started, started ? "session started; apps following the system now see dark / light" : fmt.tprintf("added %s; log in again to start it", spec.new_path))
}

setup_start_portal_session :: proc() {
	ok := portal_start_now() && portal_wait_session()
	portal_done(ok, ok ? "session started" : "couldn't start the session (see journalctl --user)")
}

// Removes the files; the running session (and portal) stays until logout.
setup_remove_portal :: proc() {
	spec := portal_switch_spec()
	_, err := switch_back(spec)
	if err != "" {
		portal_done(false, err)
		return
	}
	path := portal_unit_path()
	if data, rerr := os.read_entire_file(path, context.temp_allocator); rerr == nil && strings.has_prefix(string(data), "# Written by wlperch setup") {
		os.remove(path)
		run({"systemctl", "--user", "daemon-reload"}, 10 * time.Second, context.temp_allocator)
	}
	portal_done(true, "removed; the running session stays until you log out")
}

// The package manager command that installs the gtk backend ("" = unknown).
@(private = "file")
portal_install_script :: proc() -> string {
	bins := []string{"/usr/bin", "/bin", "/usr/sbin"}
	for d in bins {
		if os.exists(fmt.tprintf("%s/dnf", d)) {return "dnf install -y " + PORTAL_BACKEND_PKG}
		if os.exists(fmt.tprintf("%s/apt-get", d)) {return "apt-get install -y " + PORTAL_BACKEND_PKG}
		if os.exists(fmt.tprintf("%s/pacman", d)) {return "pacman -S --noconfirm --needed " + PORTAL_BACKEND_PKG}
		if os.exists(fmt.tprintf("%s/zypper", d)) {return "zypper --non-interactive install " + PORTAL_BACKEND_PKG}
	}
	return ""
}

portal_can_install_backend :: proc() -> bool {return portal_install_script() != ""}

// Root-owned: pkexec shows your polkit agent's password prompt. The portal
// reads its backends at start, so a running one is restarted.
setup_install_portal_backend :: proc() {
	{
		sync.guard(&setup.mu)
		setup.comps[.Portal].busy = true
	}
	thread.create_and_start(proc() {
		script := portal_install_script()
		out, code := run_code({"pkexec", "sh", "-c", strings.concatenate({script, " 2>&1"}, context.temp_allocator)}, 600 * time.Second, context.temp_allocator)
		ok := portal_has_settings_backend()
		msg: string
		switch {
		case ok:
			run({"systemctl", "--user", "try-restart", "xdg-desktop-portal.service"}, 10 * time.Second, context.temp_allocator)
			msg = fmt.tprintf("%s installed", PORTAL_BACKEND_PKG)
		case code == 126: msg = "cancelled (password dialog dismissed)"
		case code == 127: msg = "not authorized (or no polkit agent running)"
		case:
			d := strings.trim_space(out)
			if i := strings.last_index_byte(d, '\n'); i >= 0 {d = d[i + 1:]}
			if d == "" {d = fmt.tprintf("exit code %d", code)}
			msg = fmt.tprintf("failed: %s", d)
		}
		portal_done(ok, msg)
		setup_check()
		wake_main()
	}, self_cleanup = true)
}
