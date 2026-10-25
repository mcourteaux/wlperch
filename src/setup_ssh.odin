// Setup component "SSH agent": OpenSSH's own ssh-agent for the SSH keys
// panel, instead of none (or GNOME Keyring's / gpg-agent's).
//
// Install:
//   - systemctl --user enable --now ssh-agent.socket (the openssh unit:
//     ListenStream=%t/ssh-agent.socket; the agent starts on first use);
//   - ~/.config/environment.d/50-wlperch-ssh-agent.conf with
//     SSH_AUTH_SOCK=${XDG_RUNTIME_DIR}/ssh-agent.socket, for systemd's user
//     manager (its services, D-Bus activated apps) and display managers;
//   - a marked block in the login shell's profile (~/.zprofile for zsh,
//     ~/.bash_profile or ~/.profile for bash), which a sway started from a
//     TTY login inherits, and with it every terminal and app. sway has no
//     command to change its own environment, so that takes a new login;
//     until then the daemon passes the socket to what it launches
//     (ssh_session_env_init) and wlperch's own ssh-add calls find it.
//     The block is skipped in SSH logins (they bring a forwarded agent).
//   - stale sockets of an earlier hand-started agent in ~/.ssh/agent/ are
//     removed when nothing listens on them.
// The profile goes through config_switch.odin (backup, byte-identical
// restore); the environment.d file is ours and simply removed again.
//
// "Add keys on first use" puts AddKeysToAgent <[ssh] lifetime> at the top
// of ~/.ssh/config (its own backup), so keys ssh loads go into the agent
// for that long.
package main

import "core:encoding/ini"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

SSH_ENVD_NAME :: "50-wlperch-ssh-agent.conf"
SSH_SETUP_MARK :: "# Added by wlperch setup (SSH agent)"

SSH_ENVD_TEXT :: SSH_SETUP_MARK + `: OpenSSH's ssh-agent, started by systemd
# on first use. For systemd's user services and display-manager logins.
SSH_AUTH_SOCK=${XDG_RUNTIME_DIR}/ssh-agent.socket
`

SSH_PROFILE_BLOCK :: SSH_SETUP_MARK + `: OpenSSH's ssh-agent for this
# login (sway and everything started from it); not in SSH logins.
if [ -z "$SSH_CONNECTION" ] && [ -n "$XDG_RUNTIME_DIR" ]; then
    export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.socket"
fi
`

SSH_CONFIG_MARK :: "# Added by wlperch setup: keys ssh loads go into the agent"

@(private = "file") SSH_UNIT :: "ssh-agent.socket"

@(private = "file")
home :: proc() -> string {return os.get_env("HOME", context.temp_allocator)}

// The login shell's profile that the session's environment comes from
// ("" = a shell we don't write for, like fish).
ssh_profile_path :: proc() -> string {
	shell := os.get_env("SHELL", context.temp_allocator)
	base := shell[strings.last_index_byte(shell, '/') + 1:]
	switch base {
	case "zsh":
		dir := os.get_env("ZDOTDIR", context.temp_allocator)
		if dir == "" {dir = home()}
		return strings.concatenate({dir, "/.zprofile"}, context.temp_allocator)
	case "bash":
		// bash reads the first of these that exists; a new one would hide ~/.profile.
		for n in ([]string{".bash_profile", ".bash_login", ".profile"}) {
			p := strings.concatenate({home(), "/", n}, context.temp_allocator)
			if os.exists(p) {return p}
		}
		return strings.concatenate({home(), "/.profile"}, context.temp_allocator)
	case "sh", "dash", "ksh", "mksh", "":
		return strings.concatenate({home(), "/.profile"}, context.temp_allocator)
	}
	return ""
}

ssh_envd_path :: proc() -> string {
	return strings.concatenate({sway_config_home(), "/environment.d/", SSH_ENVD_NAME}, context.temp_allocator)
}

@(private = "file")
enabled_link :: proc() -> string {
	return strings.concatenate({sway_config_home(), "/systemd/user/sockets.target.wants/", SSH_UNIT}, context.temp_allocator)
}

@(private = "file")
lexists :: proc(path: string) -> bool {
	st: posix.stat_t
	return posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .OK
}

// The socket unit is enabled: systemctl's symlink is there (no systemctl
// call every two seconds).
@(private = "file")
socket_enabled :: proc() -> bool {return lexists(enabled_link())}

@(private = "file")
unit_available :: proc() -> bool {
	for d in ([]string{"/usr/lib/systemd/user", "/lib/systemd/user", "/etc/systemd/user", "/usr/local/lib/systemd/user"}) {
		if os.exists(strings.concatenate({d, "/", SSH_UNIT}, context.temp_allocator)) {return true}
	}
	return os.exists(strings.concatenate({sway_config_home(), "/systemd/user/", SSH_UNIT}, context.temp_allocator))
}

// Where Install notes that it enabled the socket (Remove disables it only then).
@(private = "file")
enabled_marker :: proc() -> string {
	return strings.concatenate({switch_backup_dir(SSH_PROFILE_SWITCH), "/enabled-socket"}, context.temp_allocator)
}

// ---- The profile and ~/.ssh/config (config_switch.odin) ----------------------------

SSH_PROFILE_SWITCH :: Config_Switch {
	backup  = "ssh-agent-backup",
	files   = ssh_profile_files,
	rewrite = ssh_profile_rewrite,
}

@(private = "file")
ssh_profile_files :: proc() -> []string {
	p := ssh_profile_path()
	if p == "" {return nil}
	out := make([]string, 1, context.temp_allocator)
	out[0] = p
	return out
}

// Our block at the end of the profile, once.
ssh_profile_rewrite :: proc(text: string, allocator := context.temp_allocator) -> (out: string, changes: int) {
	if strings.contains(text, SSH_SETUP_MARK) {return strings.clone(text, allocator), 0}
	sep := len(text) == 0 || strings.has_suffix(text, "\n") ? "\n" : "\n\n"
	if len(text) == 0 {sep = ""}
	return strings.concatenate({text, sep, SSH_PROFILE_BLOCK}, allocator), 1
}

@(private = "file")
profile_spec :: proc() -> Config_Switch {
	s := SSH_PROFILE_SWITCH
	s.new_path = ssh_profile_path()
	s.new_text = SSH_PROFILE_BLOCK
	return s
}

SSH_CONFIG_SWITCH :: Config_Switch {
	backup  = "ssh-config-backup",
	files   = ssh_config_files,
	rewrite = ssh_config_rewrite,
}

ssh_config_path :: proc() -> string {return strings.concatenate({home(), "/.ssh/config"}, context.temp_allocator)}

@(private = "file")
ssh_config_files :: proc() -> []string {
	out := make([]string, 1, context.temp_allocator)
	out[0] = ssh_config_path()
	return out
}

// The value written: [ssh] lifetime as ssh's time format ("60m"), "yes"
// for 0. Set before the switch runs (a rewrite proc takes no arguments).
ssh_config_lifetime := "60m"

// The lines Install adds.
ssh_config_block :: proc() -> string {
	return fmt.tprintf("%s, for %s ([ssh] lifetime).\nAddKeysToAgent %s\n", SSH_CONFIG_MARK, ssh_config_lifetime == "yes" ? "good" : ssh_config_lifetime, ssh_config_lifetime)
}

// The user's own AddKeysToAgent line (1-based; 0 = none). Comments don't count.
ssh_config_add_keys_line :: proc(text: string) -> int {
	for raw, i in strings.split_lines(text, context.temp_allocator) {
		l := strings.to_lower(strings.trim_space(raw), context.temp_allocator)
		if strings.has_prefix(l, "addkeystoagent") {return i + 1}
	}
	return 0
}

// AddKeysToAgent at the top, as a global option (ssh takes the first value
// it reads, and options before any Host / Match apply to every host). After
// the file's leading comment lines, so a header stays first; nothing else
// is touched.
ssh_config_rewrite :: proc(text: string, allocator := context.temp_allocator) -> (out: string, changes: int) {
	if strings.contains(text, SSH_CONFIG_MARK) || ssh_config_add_keys_line(text) > 0 {return strings.clone(text, allocator), 0}
	lines := strings.split_after(text, "\n", context.temp_allocator)
	at := 0 // leading comment lines
	for line in lines {
		if !strings.has_prefix(strings.trim_space(line), "#") {break}
		at += 1
	}
	head := strings.join(lines[:at], "", context.temp_allocator)
	rest := strings.join(lines[at:], "", context.temp_allocator)
	b := strings.builder_make(allocator)
	if head != "" {
		strings.write_string(&b, head)
		if !strings.has_suffix(head, "\n") {strings.write_byte(&b, '\n')}
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, ssh_config_block())
	if strings.trim_space(rest) != "" && !strings.has_prefix(rest, "\n") {strings.write_byte(&b, '\n')}
	strings.write_string(&b, rest)
	return strings.to_string(b), 1
}

@(private = "file")
config_spec :: proc() -> Config_Switch {
	s := SSH_CONFIG_SWITCH
	s.new_path = ssh_config_path()
	s.new_text = ssh_config_block()
	return s
}

// [ssh] lifetime from config.ini (setup doesn't load the config).
@(private = "file")
lifetime_from_config :: proc() -> string {
	defaults, _ := ini.load_map_from_string(DEFAULT_CONFIG, context.temp_allocator)
	path := config_path()
	defer delete(path)
	m, _, ok := ini.load_map_from_path(path, context.temp_allocator)
	if !ok {m = defaults}
	mins := parse_int_lim(config_value(m, defaults, "ssh", "lifetime"), LIM_SSH_LIFETIME)
	return mins == 0 ? "yes" : fmt.tprintf("%dm", mins)
}

// ---- The session ------------------------------------------------------------------

// SSH_AUTH_SOCK in sway's own environment (the session everything starts
// from): sway's pid is in $SWAYSOCK's name. found = false: sway's
// environment couldn't be read; then ours.
ssh_session_sock :: proc() -> (sock: string, found: bool) {
	swaysock := os.get_env("SWAYSOCK", context.temp_allocator)
	name := swaysock[strings.last_index_byte(swaysock, '/') + 1:]
	f := strings.split(name, ".", context.temp_allocator)
	if len(f) >= 4 && f[0] == "sway-ipc" {
		if _, ok := strconv.parse_int(f[2]); ok {
			if data, err := os.read_entire_file(fmt.tprintf("/proc/%s/environ", f[2]), context.temp_allocator); err == nil {
				for kv in strings.split(string(data), "\x00", context.temp_allocator) {
					if strings.has_prefix(kv, "SSH_AUTH_SOCK=") {return kv[len("SSH_AUTH_SOCK="):], true}
				}
				return "", true
			}
		}
	}
	return os.get_env("SSH_AUTH_SOCK", context.temp_allocator), false
}

// Some process listens on this unix socket path (/proc/net/unix lists
// every bound socket with its path).
unix_socket_bound :: proc(path: string) -> bool {
	data, err := os.read_entire_file("/proc/net/unix", context.temp_allocator)
	if err != nil {return true} // can't tell: assume it is
	for line in strings.split_lines(string(data), context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) >= 8 && f[len(f) - 1] == path {return true}
	}
	return false
}

// Sockets in ~/.ssh/agent/ (OpenSSH's default for a hand-started agent)
// that nothing listens on any more.
ssh_stale_sockets :: proc() -> []string {
	dir := strings.concatenate({home(), "/.ssh/agent"}, context.temp_allocator)
	out: [dynamic]string
	out.allocator = context.temp_allocator
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return nil}
	for e in entries {
		p := strings.concatenate({dir, "/", e.name}, context.temp_allocator)
		st: posix.stat_t
		if posix.lstat(strings.clone_to_cstring(p, context.temp_allocator), &st) != .OK || !posix.S_ISSOCK(st.st_mode) {continue}
		if !strings.has_prefix(e.name, "s.") {continue}
		if unix_socket_bound(p) || ssh_socket_alive(p) {continue}
		append(&out, p)
	}
	return out[:]
}

// ---- The card ---------------------------------------------------------------------

ssh_setup_check :: proc(p: ^Component, add_detail: proc(c: ^Component, line: string)) {
	ours := ssh_systemd_socket()
	sess, from_sway := ssh_session_sock()
	enabled := socket_enabled()
	profile := ssh_profile_path()
	envd := ssh_envd_path()
	envd_text, envd_err := os.read_entire_file(envd, context.temp_allocator)
	envd_ours := envd_err == nil && strings.has_prefix(string(envd_text), SSH_SETUP_MARK)
	prof_text, _ := os.read_entire_file(profile, context.temp_allocator)
	prof_ours := profile == "" || strings.contains(string(prof_text), SSH_SETUP_MARK)
	files_ok := envd_ours && prof_ours
	other_alive := sess != "" && sess != ours && ssh_socket_alive(sess)
	_, have_agent := find_program("ssh-agent")
	where_ := from_sway ? "sway's environment" : "this session"
	switch {
	case !have_agent:
		p.state = .Unavailable
		add_detail(p, "OpenSSH's ssh-agent isn't installed (openssh-clients)")
		return
	case !unit_available():
		p.state = .Unavailable
		add_detail(p, "no ssh-agent.socket systemd user unit on this system")
		return
	case other_alive && !(enabled && files_ok):
		p.state = .Custom
		add_detail(p, fmt.tprintf("%s is the agent in %s (SSH_AUTH_SOCK=%s)", ssh_agent_kind(sess), where_, sess))
		add_detail(p, "the SSH keys panel uses it; Install switches the next login to OpenSSH's own agent")
	case enabled && files_ok && sess == ours:
		p.state = .Installed
		add_detail(p, fmt.tprintf("SSH_AUTH_SOCK=%s in %s", ours, where_))
	case enabled && files_ok:
		p.state = .Partial
		add_detail(p, other_alive ? fmt.tprintf("set up; %s still serves this login (SSH_AUTH_SOCK=%s)", ssh_agent_kind(sess), sess) : fmt.tprintf("set up; %s gets SSH_AUTH_SOCK at the next login", where_))
		add_detail(p, "log out and back in (apps started from wlperch already find the agent)")
	case enabled || envd_ours || (profile != "" && strings.contains(string(prof_text), SSH_SETUP_MARK)):
		p.state = .Outdated
		add_detail(p, "partly set up; Install finishes it")
	case:
		p.state = .Missing
		if sess != "" && !ssh_socket_alive(sess) {add_detail(p, fmt.tprintf("SSH_AUTH_SOCK=%s doesn't answer", sess))} else {add_detail(p, fmt.tprintf("no SSH agent in %s", where_))}
	}
	add_detail(p, fmt.tprintf("socket: %s (%s)", ours, enabled ? "enabled" : "not enabled"))
	add_detail(p, envd)
	if profile != "" {
		add_detail(p, prof_ours ? fmt.tprintf("%s: exports SSH_AUTH_SOCK", profile) : fmt.tprintf("%s: Install adds SSH_AUTH_SOCK (with a backup)", profile))
	} else {
		add_detail(p, fmt.tprintf("%s isn't a shell setup writes for: set SSH_AUTH_SOCK=$XDG_RUNTIME_DIR/ssh-agent.socket in its login config", os.get_env("SHELL", context.temp_allocator)))
	}
	cfg_text, cfg_err := os.read_entire_file(ssh_config_path(), context.temp_allocator)
	switch {
	case cfg_err == nil && strings.contains(string(cfg_text), SSH_CONFIG_MARK):
		add_detail(p, "~/.ssh/config: keys ssh loads go into the agent (AddKeysToAgent)")
	case cfg_err == nil && ssh_config_add_keys_line(string(cfg_text)) > 0:
		add_detail(p, fmt.tprintf("~/.ssh/config:%d sets AddKeysToAgent itself", ssh_config_add_keys_line(string(cfg_text))))
	}
	if stale := ssh_stale_sockets(); len(stale) > 0 {
		add_detail(p, fmt.tprintf("%d stale socket%s in ~/.ssh/agent (Install removes %s)", len(stale), len(stale) == 1 ? "" : "s", len(stale) == 1 ? "it" : "them"))
	}
}

// AddKeysToAgent is ours (Switch back offered) / the user's own (nothing offered).
ssh_config_state :: proc() -> (ours, theirs: bool) {
	text, err := os.read_entire_file(ssh_config_path(), context.temp_allocator)
	if err != nil {return}
	ours = strings.contains(string(text), SSH_CONFIG_MARK)
	theirs = !ours && ssh_config_add_keys_line(string(text)) > 0
	return
}

@(private = "file")
ssh_done :: proc(ok: bool, msg: string) {
	sync.guard(&setup.mu)
	c := &setup.comps[.Ssh]
	c.busy = false
	c.msg_ok = ok
	delete(c.message)
	c.message = strings.clone(msg)
	log.infof("setup ssh: %s", msg)
}

@(private = "file")
systemctl :: proc(args: ..string) -> (ok: bool, out: string) {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "systemctl", "--user")
	append(&argv, ..args)
	o, code := run_code_env(argv[:], nil, true, 15 * time.Second, context.temp_allocator)
	return code == 0, strings.trim_space(o)
}

// Install; apply = also systemctl and the daemon (false in unit tests).
ssh_setup_install :: proc(apply: bool) -> (ok: bool, msg: string) {
	notes := make([dynamic]string, context.temp_allocator)
	if apply {
		was := socket_enabled()
		if sok, out := systemctl("enable", "--now", SSH_UNIT); !sok {
			return false, fmt.tprintf("systemctl --user enable --now %s failed: %s", SSH_UNIT, out)
		}
		if !was {
			os.make_directory_all(switch_backup_dir(SSH_PROFILE_SWITCH))
			_ = os.write_entire_file(enabled_marker(), "enabled by wlperch setup\n")
		}
		// environment.d is read when the user manager starts: tell it now too.
		systemctl("set-environment", strings.concatenate({"SSH_AUTH_SOCK=", ssh_systemd_socket()}, context.temp_allocator))
	}
	envd := ssh_envd_path()
	if cur, err := os.read_entire_file(envd, context.temp_allocator); err == nil && !strings.has_prefix(string(cur), SSH_SETUP_MARK) {
		append(&notes, fmt.tprintf("%s isn't wlperch's; left alone", envd))
	} else {
		os.make_directory_all(envd[:strings.last_index_byte(envd, '/')])
		if !write_through(envd, SSH_ENVD_TEXT) {return false, fmt.tprintf("couldn't write %s", envd)}
	}
	if ssh_profile_path() != "" {
		if _, err := switch_apply(profile_spec(), allow_new = true); err != "" {return false, err}
	} else {
		append(&notes, "set SSH_AUTH_SOCK in your shell's login config yourself")
	}
	removed := 0
	for s in ssh_stale_sockets() {
		if os.remove(s) == nil {removed += 1}
	}
	if removed > 0 {append(&notes, fmt.tprintf("removed %d stale socket%s from ~/.ssh/agent", removed, removed == 1 ? "" : "s"))}
	// The daemon picks the socket up when it starts (for what it launches).
	if apply {ipc_send("restart")}
	msg = "OpenSSH's agent is set up; log out and back in so sway and your terminals get SSH_AUTH_SOCK"
	if len(notes) > 0 {msg = fmt.tprintf("%s (%s)", msg, strings.join(notes[:], "; ", context.temp_allocator))}
	return true, msg
}

// Remove: everything Install (and "Add keys on first use") changed.
ssh_setup_remove :: proc(apply: bool) -> (ok: bool, msg: string) {
	notes := make([dynamic]string, context.temp_allocator)
	if _, had := switch_manifest(SSH_PROFILE_SWITCH); had {
		kept, err := switch_back(profile_spec())
		if err != "" {return false, err}
		if kept > 0 {append(&notes, fmt.tprintf("your later edits are in %s/*.edited", switch_backup_dir(SSH_PROFILE_SWITCH)))}
	}
	envd := ssh_envd_path()
	if cur, err := os.read_entire_file(envd, context.temp_allocator); err == nil && strings.has_prefix(string(cur), SSH_SETUP_MARK) {
		os.remove(envd)
	}
	if _, had := switch_manifest(SSH_CONFIG_SWITCH); had {
		ssh_config_lifetime = lifetime_from_config()
		kept, err := switch_back(config_spec())
		if err != "" {return false, err}
		if kept > 0 {append(&notes, fmt.tprintf("your later ~/.ssh/config edits are in %s/*.edited", switch_backup_dir(SSH_CONFIG_SWITCH)))}
	}
	if os.exists(enabled_marker()) {
		if apply {
			if sok, out := systemctl("disable", "--now", SSH_UNIT); !sok {append(&notes, fmt.tprintf("systemctl disable failed: %s", out))}
		}
		os.remove(enabled_marker())
	} else if socket_enabled() {
		append(&notes, "the socket was enabled before; left enabled")
	}
	if apply {
		if _, out := systemctl("show-environment"); strings.contains(out, strings.concatenate({"SSH_AUTH_SOCK=", ssh_systemd_socket()}, context.temp_allocator)) {
			systemctl("unset-environment", "SSH_AUTH_SOCK")
		}
	}
	// Our directories, when empty by now.
	os.remove(switch_backup_dir(SSH_PROFILE_SWITCH))
	os.remove(switch_backup_dir(SSH_CONFIG_SWITCH))
	os.remove(envd[:strings.last_index_byte(envd, '/')])
	msg = "removed; the next login has no SSH_AUTH_SOCK from wlperch"
	if len(notes) > 0 {msg = fmt.tprintf("%s (%s)", msg, strings.join(notes[:], "; ", context.temp_allocator))}
	return true, msg
}

ssh_setup_add_keys :: proc(add: bool) -> (ok: bool, msg: string) {
	ssh_config_lifetime = lifetime_from_config()
	if !add {
		kept, err := switch_back(config_spec())
		if err != "" {return false, err}
		os.remove(switch_backup_dir(SSH_CONFIG_SWITCH)) // when empty
		return true, kept > 0 ? fmt.tprintf("~/.ssh/config restored; your later edits are in %s/*.edited", switch_backup_dir(SSH_CONFIG_SWITCH)) : "~/.ssh/config restored"
	}
	dir := strings.concatenate({home(), "/.ssh"}, context.temp_allocator)
	if !os.exists(dir) {
		os.make_directory_all(dir)
		posix.chmod(strings.clone_to_cstring(dir, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	}
	fresh := !os.exists(ssh_config_path())
	changed, err := switch_apply(config_spec(), allow_new = true)
	if err != "" {return false, err}
	if fresh && changed > 0 {posix.chmod(strings.clone_to_cstring(ssh_config_path(), context.temp_allocator), {.IRUSR, .IWUSR})}
	if changed == 0 {return true, "nothing to change"}
	return true, fmt.tprintf("keys ssh loads now go into the agent for %s (AddKeysToAgent in ~/.ssh/config, with a backup)", ssh_config_lifetime == "yes" ? "good" : ssh_config_lifetime)
}

setup_install_ssh :: proc() {ssh_done(ssh_setup_install(apply = true))}
setup_remove_ssh :: proc() {ssh_done(ssh_setup_remove(apply = true))}
setup_ssh_add_keys :: proc() {ssh_done(ssh_setup_add_keys(true))}
setup_ssh_stop_add_keys :: proc() {ssh_done(ssh_setup_add_keys(false))}
setup_ssh_show_keys :: proc() {
	ok := ipc_send("show ssh --center")
	ssh_done(ok, ok ? "the SSH keys panel is open" : "the daemon isn't running")
}
