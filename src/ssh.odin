// SSH keys in OpenSSH's own ssh-agent: which private keys in ~/.ssh are
// loaded ("unlocked"), with how long they have left, and unlocking,
// forgetting and locking through ssh-add.
//
// Passphrases never pass through here: ssh-add runs with
// SSH_ASKPASS = this binary (askpass.odin) and SSH_ASKPASS_REQUIRE=force,
// no stdin, so only that child sees what is typed, and hands it to ssh-add
// over the pipe ssh-add reads. Private key files are never read: keys are
// found by their .pub (parsed here) or, without one, by `ssh-keygen -l`.
//
// ssh-add -l doesn't tell how long a key has left, so wlperch keeps what
// it added itself (fingerprint, when, until when; never key material) in
// ~/.local/share/wlperch/ssh-agent. The daemon, the bar and the lock screen
// (separate processes) all read it; whoever changes the agent rewrites it,
// and the bar's data-dir watch picks that up.
//
// Shared by the daemon (panel card, quick tile, IPC "ssh …", idle forget),
// the bar (the ssh module) and the lock screen ([ssh] forget_on_lock).
package main

import "core:crypto/sha2"
import "core:encoding/base64"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

import "wl"

// ---- Keys ---------------------------------------------------------------------

Ssh_Key :: struct {
	path:        string, // the private key file
	name:        string, // its file name
	kind:        string, // RSA, ED25519, ECDSA… (as ssh-add -l prints it)
	bits:        int,
	fingerprint: string, // SHA256:…
	comment:     string,
	loaded:      bool,
	added:       i64, // unix seconds wlperch added it (0: not by wlperch)
	expires:     i64, // unix seconds it leaves the agent (0: unknown / never)
}

// One identity of `ssh-add -l`.
Ssh_Loaded :: struct {
	bits:        int,
	fingerprint: string,
	comment:     string,
	kind:        string,
}

ssh_key_free :: proc(k: ^Ssh_Key) {
	delete(k.path); delete(k.name); delete(k.kind); delete(k.fingerprint); delete(k.comment)
	k^ = {}
}

ssh_home :: proc() -> string {
	return strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.ssh"}, context.temp_allocator)
}

// "ssh-ed25519" -> ED25519, as ssh-add -l names key types.
ssh_kind_name :: proc(t: string) -> string {
	switch t {
	case "ssh-rsa":                             return "RSA"
	case "ssh-ed25519":                         return "ED25519"
	case "ssh-dss":                             return "DSA"
	case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521": return "ECDSA"
	case "sk-ssh-ed25519@openssh.com":          return "ED25519-SK"
	case "sk-ecdsa-sha2-nistp256@openssh.com":  return "ECDSA-SK"
	}
	return strings.to_upper(t, context.temp_allocator)
}

// A .pub line: type, bits, SHA256 fingerprint (as ssh-keygen -l prints it)
// and the comment. Strings are temp-allocated.
ssh_pub_parse :: proc(text: string) -> (kind: string, bits: int, fingerprint, comment: string, ok: bool) {
	line := strings.trim_space(text)
	if nl := strings.index_byte(line, '\n'); nl >= 0 {line = strings.trim_space(line[:nl])}
	f := strings.fields(line, context.temp_allocator)
	if len(f) < 2 {return}
	blob, err := base64.decode(f[1], allocator = context.temp_allocator)
	if err != nil || len(blob) < 8 {return}
	// The blob starts with the type again: a guard against a stray file.
	tlen := int(blob[0]) << 24 | int(blob[1]) << 16 | int(blob[2]) << 8 | int(blob[3])
	if tlen <= 0 || 4 + tlen > len(blob) || string(blob[4:4 + tlen]) != f[0] {return}
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, blob)
	sum: [32]u8
	sha2.final(&ctx, sum[:])
	b64 := base64.encode(sum[:], allocator = context.temp_allocator, options = {.No_Padding})
	fingerprint = strings.concatenate({"SHA256:", b64}, context.temp_allocator)
	kind = ssh_kind_name(f[0])
	switch {
	case f[0] == "ssh-rsa":
		// string type, mpint e, mpint n: bits of n.
		at := 4 + tlen
		for i in 0 ..< 2 {
			if at + 4 > len(blob) {break}
			n := int(blob[at]) << 24 | int(blob[at + 1]) << 16 | int(blob[at + 2]) << 8 | int(blob[at + 3])
			at += 4
			if at + n > len(blob) {break}
			if i == 1 {
				m := blob[at:at + n]
				for len(m) > 0 && m[0] == 0 {m = m[1:]}
				if len(m) > 0 {
					top := 8
					for b := m[0]; b & 0x80 == 0 && top > 0; b <<= 1 {top -= 1}
					bits = (len(m) - 1) * 8 + top
				}
			}
			at += n
		}
	case strings.contains(f[0], "ed25519"):  bits = 256
	case strings.has_suffix(f[0], "nistp256") || strings.contains(f[0], "nistp256@"): bits = 256
	case strings.has_suffix(f[0], "nistp384"): bits = 384
	case strings.has_suffix(f[0], "nistp521"): bits = 521
	case f[0] == "ssh-dss": bits = 1024
	}
	if len(f) > 2 {comment = strings.join(f[2:], " ", context.temp_allocator)}
	return kind, bits, fingerprint, comment, true
}

// `ssh-add -l` / `ssh-keygen -l` lines: "3072 SHA256:… comment (RSA)".
ssh_parse_list :: proc(out: string, allocator := context.temp_allocator) -> []Ssh_Loaded {
	list: [dynamic]Ssh_Loaded
	list.allocator = allocator
	for raw in strings.split_lines(out, context.temp_allocator) {
		line := strings.trim_space(raw)
		sp := strings.index_byte(line, ' ')
		if sp <= 0 {continue}
		bits, bok := strconv.parse_int(line[:sp])
		if !bok {continue}
		rest := strings.trim_left_space(line[sp + 1:])
		sp2 := strings.index_byte(rest, ' ')
		fp := sp2 < 0 ? rest : rest[:sp2]
		if !strings.has_prefix(fp, "SHA256:") && !strings.has_prefix(fp, "MD5:") {continue}
		comment := sp2 < 0 ? "" : strings.trim_space(rest[sp2 + 1:])
		kind := ""
		if strings.has_suffix(comment, ")") {
			if open := strings.last_index_byte(comment, '('); open >= 0 {
				kind = comment[open + 1:len(comment) - 1]
				comment = strings.trim_space(comment[:open])
			}
		}
		append(&list, Ssh_Loaded{bits, strings.clone(fp, allocator), strings.clone(comment, allocator), strings.clone(kind, allocator)})
	}
	return list[:]
}

// Files in ~/.ssh that are never keys.
@(private = "file")
not_a_key :: proc(name: string) -> bool {
	if strings.has_prefix(name, ".") || strings.has_suffix(name, ".pub") || strings.has_suffix(name, "~") {return true}
	for p in ([]string{"known_hosts", "authorized_keys", "config", "environment", "rc"}) {
		if name == p || strings.has_prefix(name, strings.concatenate({p, "."}, context.temp_allocator)) {return true}
	}
	for s in ([]string{".old", ".bak", ".orig", ".swp", ".before-wlperch", ".tmp"}) {
		if strings.has_suffix(name, s) {return true}
	}
	return strings.contains(name, ".before-wlperch") || strings.contains(name, ".wlperch-")
}

// `ssh-keygen -l` results for key files without a .pub, by path and mtime:
// it runs once per file, not on every refresh.
@(private = "file") keygen_mu: sync.Mutex
@(private = "file") keygen_cache: map[string]struct {mtime: i64, line: string}

@(private = "file")
keygen_info :: proc(path: string) -> (Ssh_Loaded, bool) {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {return {}, false}
	mtime := time.to_unix_nanoseconds(fi.modification_time)
	line: string
	{
		sync.guard(&keygen_mu)
		if c, ok := keygen_cache[path]; ok && c.mtime == mtime {line = strings.clone(c.line, context.temp_allocator)}
	}
	if line == "" {
		out, code := run_code({"ssh-keygen", "-l", "-E", "sha256", "-f", path}, 3 * time.Second, context.temp_allocator)
		line = code == 0 ? strings.trim_space(out) : "-"
		sync.guard(&keygen_mu)
		if c, ok := keygen_cache[path]; ok {
			delete(c.line)
			keygen_cache[path] = {mtime, strings.clone(line)}
		} else {
			keygen_cache[strings.clone(path)] = {mtime, strings.clone(line)}
		}
	}
	l := ssh_parse_list(line)
	if len(l) == 0 {return {}, false}
	return l[0], true
}

// Does `only` ([ssh] keys: names or paths; empty = all) take this key?
ssh_key_wanted :: proc(only: []string, path, name: string) -> bool {
	if len(only) == 0 {return true}
	for o in only {
		w := o
		if strings.has_prefix(w, "~/") {w = strings.concatenate({os.get_env("HOME", context.temp_allocator), w[1:]}, context.temp_allocator)}
		if w == name || w == path {return true}
	}
	return false
}

// The private keys in dir: files with a matching .pub, or that ssh-keygen
// recognises. Sorted by name. Owned by the caller (ssh_key_free).
ssh_scan_keys :: proc(dir: string, only: []string) -> [dynamic]Ssh_Key {
	keys: [dynamic]Ssh_Key
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return keys}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for e in entries {
		if e.type != .Regular || not_a_key(e.name) {continue}
		if e.size == 0 || e.size > 64 << 10 {continue}
		path := strings.concatenate({dir, "/", e.name}, context.temp_allocator)
		if !ssh_key_wanted(only, path, e.name) {continue}
		k := Ssh_Key{path = strings.clone(path), name = strings.clone(e.name)}
		if pub, perr := os.read_entire_file(strings.concatenate({path, ".pub"}, context.temp_allocator), context.temp_allocator); perr == nil {
			kind, bits, fp, comment, ok := ssh_pub_parse(string(pub))
			if !ok {
				ssh_key_free(&k)
				continue
			}
			k.kind, k.bits, k.fingerprint, k.comment = strings.clone(kind), bits, strings.clone(fp), strings.clone(comment)
		} else if l, ok := keygen_info(path); ok {
			k.kind, k.bits, k.fingerprint, k.comment = strings.clone(l.kind), l.bits, strings.clone(l.fingerprint), strings.clone(l.comment)
		} else {
			ssh_key_free(&k)
			continue
		}
		append(&keys, k)
	}
	return keys
}

// ---- The agent ------------------------------------------------------------------

// The systemd user socket of OpenSSH's agent (Fedora's ssh-agent.socket:
// ListenStream=%t/ssh-agent.socket).
ssh_systemd_socket :: proc() -> string {
	rt := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if rt == "" {return ""}
	return strings.concatenate({rt, "/ssh-agent.socket"}, context.temp_allocator)
}

// Something accepts connections on this unix socket.
ssh_socket_alive :: proc(path: string) -> bool {
	if path == "" {return false}
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {return false}
	defer posix.close(fd)
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	if len(path) >= len(addr.sun_path) {return false}
	for i in 0 ..< len(path) {addr.sun_path[i] = type_of(addr.sun_path[0])(path[i])}
	return posix.connect(fd, cast(^posix.sockaddr)&addr, size_of(addr)) == .OK
}

// The agent wlperch talks to: $SSH_AUTH_SOCK when it answers, else
// OpenSSH's systemd socket (set up, but not in this session's environment
// yet: before the next login). "" = none.
ssh_agent_socket :: proc() -> string {
	if s := os.get_env("SSH_AUTH_SOCK", context.temp_allocator); s != "" && ssh_socket_alive(s) {return s}
	if s := ssh_systemd_socket(); s != "" && os.exists(s) && ssh_socket_alive(s) {return s}
	return ""
}

// Which program serves an agent socket, from its path.
ssh_agent_kind :: proc(sock: string) -> string {
	switch {
	case sock == "":                                return ""
	case sock == ssh_systemd_socket():              return "OpenSSH ssh-agent"
	case strings.contains(sock, "/keyring"):        return "GNOME Keyring"
	case strings.contains(sock, "gpg-agent") || strings.contains(sock, "/gnupg/"): return "gpg-agent"
	case strings.contains(sock, "/.ssh/agent/") || strings.contains(sock, "/ssh-") && strings.contains(sock, "agent."): return "ssh-agent (started by hand)"
	case strings.contains(sock, "kwallet") || strings.contains(sock, "ksshaskpass"): return "KWallet"
	case strings.contains(sock, "1password") || strings.contains(sock, "1Password"): return "1Password"
	case strings.contains(sock, "keepassxc") || strings.contains(sock, "KeePass"): return "KeePassXC"
	}
	return "an SSH agent"
}

// Startup (the daemon, before any thread): with no agent in the
// environment but OpenSSH's socket set up, use it, so apps started from
// wlperch (the launcher) find it before the next login.
ssh_session_env_init :: proc() {
	cur := os.get_env("SSH_AUTH_SOCK", context.temp_allocator)
	if cur != "" && ssh_socket_alive(cur) {return}
	s := ssh_systemd_socket()
	if s == "" || !os.exists(s) {return}
	posix.setenv("SSH_AUTH_SOCK", strings.clone_to_cstring(s, context.temp_allocator), true)
	log.infof("ssh: SSH_AUTH_SOCK=%s for apps started from wlperch", s)
}

// The environment ssh-add runs with: this agent, and with askpass this
// binary as SSH_ASKPASS (forced, so a terminal is never asked).
ssh_env :: proc(sock: string, askpass: bool) -> [^]cstring {
	set := make([dynamic]string, context.temp_allocator)
	append(&set, strings.concatenate({"SSH_AUTH_SOCK=", sock}, context.temp_allocator))
	if askpass {
		exe := setup_self_path()
		if exe == "" {exe = "wlperch"}
		append(&set, strings.concatenate({"SSH_ASKPASS=", exe}, context.temp_allocator))
		append(&set, "SSH_ASKPASS_REQUIRE=force")
		append(&set, "WLPERCH_ASKPASS=1") // main() dispatches on it
	}
	return env_with(set[:], {"SSH_AGENT_PID"})
}

// ssh-add with these arguments: output and error output, exit code.
ssh_add :: proc(sock: string, args: []string, askpass := false, timeout := 15 * time.Second) -> (out: string, code: int) {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "ssh-add")
	append(&argv, ..args)
	return run_code_env(argv[:], ssh_env(sock, askpass), true, timeout, context.temp_allocator)
}

// What's loaded. ok = false: the agent doesn't answer.
ssh_list_loaded :: proc(sock: string) -> (loaded: []Ssh_Loaded, ok: bool) {
	if sock == "" {return nil, false}
	out, code := ssh_add(sock, {"-l", "-E", "sha256"}, timeout = 5 * time.Second)
	switch code {
	case 0: return ssh_parse_list(out), true
	case 1: return nil, true // "The agent has no identities." (or it is locked)
	}
	return nil, false
}

// ---- What wlperch added ---------------------------------------------------------

Ssh_Record :: struct {
	fingerprint:    string,
	added, expires: i64, // unix seconds; expires 0 = until forgotten
}

Ssh_Records :: struct {
	keys:      [dynamic]Ssh_Record,
	locked_at: i64, // wlperch locked the agent (ssh-add -x); 0 = not
}

ssh_records_path :: proc() -> string {
	dir := data_dir()
	defer delete(dir)
	return strings.concatenate({dir, "/", SSH_RECORDS_NAME}, context.temp_allocator)
}

SSH_RECORDS_NAME :: "ssh-agent"

// Temp-allocated.
ssh_records_parse :: proc(text: string) -> (r: Ssh_Records) {
	r.keys.allocator = context.temp_allocator
	for line in strings.split_lines(text, context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 || strings.has_prefix(f[0], "#") {continue}
		switch f[0] {
		case "key":
			if len(f) < 4 {continue}
			a, aok := strconv.parse_i64(f[2])
			e, eok := strconv.parse_i64(f[3])
			if aok && eok {append(&r.keys, Ssh_Record{f[1], a, e})}
		case "locked":
			if len(f) > 1 {r.locked_at = strconv.parse_i64(f[1]) or_else 0}
		}
	}
	return
}

ssh_records_format :: proc(r: Ssh_Records) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# wlperch: SSH keys it added to the agent (fingerprint, added, expires: unix seconds; 0 = never). No key material.\n")
	for k in r.keys {fmt.sbprintf(&b, "key %s %d %d\n", k.fingerprint, k.added, k.expires)}
	if r.locked_at != 0 {fmt.sbprintf(&b, "locked %d\n", r.locked_at)}
	return strings.to_string(b)
}

ssh_records_load :: proc() -> Ssh_Records {
	data, err := os.read_entire_file(ssh_records_path(), context.temp_allocator)
	if err != nil {return {}}
	return ssh_records_parse(string(data))
}

// Written only when it changes (the bar watches the file), or with
// `touch` anyway: after any action, so the bar looks at the agent again.
ssh_records_save :: proc(r: Ssh_Records, touch := false) {
	path := ssh_records_path()
	text := ssh_records_format(r)
	if cur, err := os.read_entire_file(path, context.temp_allocator); err == nil && string(cur) == text && !touch {return}
	if len(r.keys) == 0 && r.locked_at == 0 && !os.exists(path) {return}
	os.make_directory_all(path[:strings.last_index_byte(path, '/')])
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, text, {.Read_User, .Write_User}) == nil {os.rename(tmp, path)}
}

// Drops records of keys no longer loaded (expired, forgotten elsewhere, a
// new agent), unless the agent is locked (it then lists nothing). Returns
// whether anything changed.
ssh_records_reconcile :: proc(r: ^Ssh_Records, loaded: []Ssh_Loaded, now: i64) -> bool {
	changed := false
	if r.locked_at != 0 && len(loaded) > 0 {
		r.locked_at = 0 // it answers with keys: unlocked elsewhere (or a new agent)
		changed = true
	}
	if r.locked_at != 0 {return changed}
	for i := len(r.keys) - 1; i >= 0; i -= 1 {
		k := r.keys[i]
		found := false
		for l in loaded {if l.fingerprint == k.fingerprint {found = true}}
		if !found || (k.expires != 0 && k.expires <= now) {
			ordered_remove(&r.keys, i)
			changed = true
		}
	}
	return changed
}

ssh_record_set :: proc(r: ^Ssh_Records, fp: string, added, expires: i64) {
	for &k in r.keys {
		if k.fingerprint == fp {
			k.added, k.expires = added, expires
			return
		}
	}
	append(&r.keys, Ssh_Record{strings.clone(fp, context.temp_allocator), added, expires})
}

ssh_record_drop :: proc(r: ^Ssh_Records, fp: string) {
	for i := len(r.keys) - 1; i >= 0; i -= 1 {
		if r.keys[i].fingerprint == fp {ordered_remove(&r.keys, i)}
	}
}

// "42 min", "1 h 05 min", "< 1 min".
ssh_left_text :: proc(secs: i64) -> string {
	switch {
	case secs < 60:   return "< 1 min"
	case secs < 3600: return fmt.tprintf("%d min", (secs + 59) / 60)
	}
	m := (secs + 59) / 60
	return fmt.tprintf("%d h %02d min", m / 60, m % 60)
}

// ---- Actions (any process) --------------------------------------------------------

Ssh_Action :: enum {Unlock, Forget, Forget_All, Lock, Unlock_Agent}

// What ssh-add said, as one line for the UI ("" = nothing useful).
@(private = "file")
ssh_error_text :: proc(out: string) -> string {
	for raw in strings.split_lines(out, context.temp_allocator) {
		l := strings.trim_space(raw)
		if l == "" {continue}
		switch {
		case strings.contains(l, "Could not open a connection") || strings.contains(l, "Error connecting to agent"): return "no SSH agent running"
		case strings.contains(l, "Failed to unlock"):                                                                return "wrong password, the agent stays locked"
		case strings.contains(l, "Failed to lock"):                                                                  return "not locked (an empty password isn't allowed)"
		case strings.contains(l, "agent refused operation") || strings.contains(l, "Failed to remove"):            return "the agent refused (is it locked?)"
		case strings.contains(l, "Passwords do not match"):                                                         return "the two passwords didn't match"
		case strings.contains(l, "incorrect passphrase") || strings.contains(l, "Bad passphrase"):                  return "wrong passphrase"
		}
		return l
	}
	return ""
}

// Runs one action against the agent (blocking: the askpass popup may wait
// for the user) and updates the records. key: the private key path
// (Unlock, Forget); fp its fingerprint. lifetime in seconds, 0 = none.
ssh_run_action :: proc(act: Ssh_Action, key, fp: string, lifetime: int) -> (ok: bool, msg: string) {
	sock := ssh_agent_socket()
	if sock == "" {return false, "no SSH agent running"}
	now := time.to_unix_seconds(time.now())
	name := strings.has_prefix(key, "SHA256:") ? "the key" : key[strings.last_index_byte(key, '/') + 1:]
	out: string
	code: int
	switch act {
	case .Unlock:
		args := make([dynamic]string, context.temp_allocator)
		if lifetime > 0 {append(&args, "-t", fmt.tprintf("%d", lifetime))}
		append(&args, key)
		// The user types in the popup: no short timeout.
		out, code = ssh_add(sock, args[:], askpass = true, timeout = 15 * time.Minute)
		if code == 0 {
			r := ssh_records_load()
			ssh_record_set(&r, fp, now, lifetime > 0 ? now + i64(lifetime) : 0)
			ssh_records_save(r)
			return true, lifetime > 0 ? fmt.tprintf("%s unlocked for %s", name, ssh_left_text(i64(lifetime))) : fmt.tprintf("%s unlocked", name)
		}
		if e := ssh_error_text(out); e != "" && !strings.has_prefix(e, "Identity added") {return false, e}
		return false, "cancelled"
	case .Forget:
		// The .pub is enough for ssh-add -d (and spares it the private key).
		target := key
		tmp := ""
		if pub := strings.concatenate({key, ".pub"}, context.temp_allocator); os.exists(pub) {
			target = pub
		} else if strings.has_prefix(key, "SHA256:") || strings.has_prefix(key, "MD5:") {
			// A key without a file here: its public half from the agent.
			listing, lcode := ssh_add(sock, {"-L"}, timeout = 5 * time.Second)
			if lcode != 0 {return false, "couldn't list the agent's keys"}
			for l in strings.split_lines(listing, context.temp_allocator) {
				if _, _, lfp, _, lok := ssh_pub_parse(l); lok && lfp == fp {
					tmp = fmt.tprintf("%s/wlperch-ssh-forget-%d.pub", os.get_env("XDG_RUNTIME_DIR", context.temp_allocator), posix.getpid())
					if os.write_entire_file(tmp, strings.concatenate({l, "\n"}, context.temp_allocator)) != nil {return false, "couldn't write a temporary file"}
				}
			}
			if tmp == "" {return false, "that key isn't in the agent any more"}
			target = tmp
		}
		out, code = ssh_add(sock, {"-d", target})
		if tmp != "" {os.remove(tmp)}
		if code == 0 {
			r := ssh_records_load()
			ssh_record_drop(&r, fp)
			ssh_records_save(r)
			return true, fmt.tprintf("%s forgotten", name)
		}
	case .Forget_All:
		out, code = ssh_add(sock, {"-D"})
		if code == 0 {
			r := ssh_records_load()
			clear(&r.keys)
			ssh_records_save(r)
			return true, "all keys forgotten"
		}
	case .Lock:
		out, code = ssh_add(sock, {"-x"}, askpass = true, timeout = 15 * time.Minute)
		if code == 0 {
			r := ssh_records_load()
			r.locked_at = now
			ssh_records_save(r)
			return true, "agent locked"
		}
		if e := ssh_error_text(out); e != "" {return false, e}
		return false, "cancelled"
	case .Unlock_Agent:
		out, code = ssh_add(sock, {"-X"}, askpass = true, timeout = 15 * time.Minute)
		if code == 0 {
			r := ssh_records_load()
			r.locked_at = 0
			ssh_records_save(r)
			return true, "agent unlocked"
		}
		if e := ssh_error_text(out); e != "" {return false, e}
		return false, "cancelled"
	}
	if e := ssh_error_text(out); e != "" {return false, e}
	return false, fmt.tprintf("ssh-add failed (exit %d)", code)
}

// ssh_run_action, then a nudge for the bar (whatever changed in the agent).
ssh_do :: proc(act: Ssh_Action, key, fp: string, lifetime: int) -> (ok: bool, msg: string) {
	ok, msg = ssh_run_action(act, key, fp, lifetime)
	if os.exists(ssh_records_path()) || ok {ssh_records_save(ssh_records_load(), touch = true)}
	return
}

// ssh-add -D from wherever (the lock screen at lock time, the daemon after
// idle); quiet when there is no agent or nothing is loaded.
ssh_forget_all_now :: proc(reason: string) {
	sock := ssh_agent_socket()
	if sock == "" {return}
	loaded, ok := ssh_list_loaded(sock)
	if !ok || len(loaded) == 0 {return}
	if okk, msg := ssh_do(.Forget_All, "", "", 0); okk {
		log.infof("ssh: %d key(s) forgotten (%s)", len(loaded), reason)
	} else {
		log.warnf("ssh: couldn't forget the keys (%s): %s", reason, msg)
	}
}

// The same on a short-lived thread.
ssh_forget_all_async :: proc(reason: string) {
	r := new_clone(reason) // a static string: the pointer is what's cloned
	thread.create_and_start_with_data(r, proc(data: rawptr) {
		reason := (^string)(data)
		ssh_forget_all_now(reason^)
		free(reason)
		free_all(context.temp_allocator)
	}, init_context = context, self_cleanup = true)
}

// ---- The daemon's view (panel card, quick tile) -------------------------------------

Ssh_Agent_State :: enum {None, Running, Locked}

Ssh_State :: struct {
	mu:        sync.Mutex,
	started:   bool,
	checked:   bool, // refreshed at least once
	available: bool, // ssh-add is installed
	sock:      string,
	agent:     Ssh_Agent_State,
	keys:      [dynamic]Ssh_Key,
	others:    [dynamic]Ssh_Key, // loaded, but no key file of ours
	busy:      string, // key path being worked on, "*" = the whole agent, "" = idle
	msg:       string,
	msg_key:   string, // the key the message is about ("" = the card)
	msg_ok:    bool,
	refreshed: time.Tick,
	wake:      sync.Sema,
	want:      bool, // a refresh is wanted
}
ssh: Ssh_State

ssh_start :: proc() {
	if ssh.started {return}
	ssh.started = true
	thread.create_and_start(proc() {
		for {
			sync.sema_wait(&ssh.wake)
			{
				sync.guard(&ssh.mu)
				if !ssh.want {continue}
				ssh.want = false
			}
			ssh_refresh_now()
			free_all(context.temp_allocator)
		}
	})
	ssh_watch_idle()
}

ssh_request_refresh :: proc() {
	if !ssh.started {return}
	sync.guard(&ssh.mu)
	ssh.want = true
	sync.sema_post(&ssh.wake)
}

// Look at ~/.ssh and the agent (worker thread, or the CLI).
ssh_refresh_now :: proc() {
	_, available := find_program("ssh-add")
	sock := available ? ssh_agent_socket() : ""
	keys := ssh_scan_keys(ssh_home(), config.ssh_keys[:])
	loaded, answers := ssh_list_loaded(sock)
	now := time.to_unix_seconds(time.now())
	r := ssh_records_load()
	if answers && ssh_records_reconcile(&r, loaded, now) {ssh_records_save(r)}
	others: [dynamic]Ssh_Key
	for l in loaded {
		mine := false
		for &k in keys {
			if k.fingerprint != l.fingerprint {continue}
			mine = true
			k.loaded = true
			for rec in r.keys {
				if rec.fingerprint == k.fingerprint {k.added, k.expires = rec.added, rec.expires}
			}
		}
		if !mine {
			o := Ssh_Key{name = strings.clone(l.comment != "" ? l.comment : l.fingerprint), kind = strings.clone(l.kind), bits = l.bits, fingerprint = strings.clone(l.fingerprint), comment = strings.clone(l.comment), loaded = true}
			for rec in r.keys {
				if rec.fingerprint == o.fingerprint {o.added, o.expires = rec.added, rec.expires}
			}
			append(&others, o)
		}
	}
	state := Ssh_Agent_State.None
	if answers {state = r.locked_at != 0 && len(loaded) == 0 ? .Locked : .Running}
	sync.guard(&ssh.mu)
	for &k in ssh.keys {ssh_key_free(&k)}
	delete(ssh.keys)
	for &k in ssh.others {ssh_key_free(&k)}
	delete(ssh.others)
	ssh.keys, ssh.others = keys, others
	delete(ssh.sock)
	ssh.sock = strings.clone(sock)
	ssh.agent = state
	ssh.available = available
	ssh.checked = true
	ssh.refreshed = time.tick_now()
	wake_ui()
}

@(private = "file")
ssh_set_msg :: proc(key: string, ok: bool, msg: string) {
	delete(ssh.msg)
	delete(ssh.msg_key)
	ssh.msg = strings.clone(msg)
	ssh.msg_key = strings.clone(key)
	ssh.msg_ok = ok
}

@(private = "file")
Ssh_Job :: struct {
	act:      Ssh_Action,
	key, fp:  string,
	lifetime: int,
}

// Start an action on its own thread; false when another one is running.
ssh_start_action :: proc(act: Ssh_Action, key := "", fp := "") -> bool {
	{
		sync.guard(&ssh.mu)
		if ssh.busy != "" {return false}
		ssh.busy = strings.clone(act == .Unlock || act == .Forget ? key : "*")
		ssh_set_msg("", true, "")
	}
	job := new(Ssh_Job)
	job^ = {act, strings.clone(key), strings.clone(fp), config.ssh_lifetime * 60}
	thread.create_and_start_with_data(job, proc(data: rawptr) {
		job := (^Ssh_Job)(data)
		ok, msg := ssh_do(job.act, job.key, job.fp, job.lifetime)
		log.infof("ssh: %v %s: %s", job.act, job.key, msg)
		{
			sync.guard(&ssh.mu)
			delete(ssh.busy)
			ssh.busy = ""
			ssh_set_msg(job.act == .Unlock || job.act == .Forget ? job.key : "", ok, msg)
		}
		ssh_refresh_now()
		wake_main() // a re-exec held back for this may go ahead
		delete(job.key)
		delete(job.fp)
		free(job)
		free_all(context.temp_allocator)
	}, init_context = context, self_cleanup = true)
	return true
}

// An action runs (ssh-add, maybe waiting for the passphrase popup): the
// daemon must not re-execute now, which would kill ssh-add.
ssh_busy :: proc() -> bool {
	sync.guard(&ssh.mu)
	return ssh.busy != ""
}

ssh_on_show :: proc() {
	if time.tick_since(ssh.refreshed) > 3 * time.Second || !ssh.checked {ssh_request_refresh()}
}

// While a panel with the card or tile is open: refresh every 30 s, and right
// after the next key leaves the agent.
ssh_timeout :: proc() -> time.Duration {
	if !platform_visible() || !ssh.started || !(panel_shows("ssh") || panel_shows("quick")) {return -1}
	sync.guard(&ssh.mu)
	due := 30 * time.Second - time.tick_since(ssh.refreshed)
	now := time.to_unix_seconds(time.now())
	for k in ssh.keys {
		if k.loaded && k.expires > 0 {due = min(due, time.Duration(k.expires - now) * time.Second + time.Second)}
	}
	return max(due, 0)
}

ssh_tick :: proc() {
	if ssh_idled {
		ssh_idled = false
		log.infof("ssh: idle for %d min", config.ssh_forget_on_idle)
		ssh_forget_all_async("idle")
		if ssh.started {ssh_request_refresh()}
	}
	if !ssh.started || !platform_visible() || !(panel_shows("ssh") || panel_shows("quick")) {return}
	if ssh_timeout() == 0 {
		ssh.refreshed = time.tick_now() // once per due time
		ssh_request_refresh()
	}
}

// ---- Forget after idle ----------------------------------------------------------

@(private = "file") ssh_idle_note: ^wl.Ext_Idle_Notification_V1
@(private = "file") ssh_idled: bool

@(private = "file")
ssh_idle_listener := wl.Ext_Idle_Notification_V1_Listener {
	idled = proc "c" (data: rawptr, self: ^wl.Ext_Idle_Notification_V1) {
		ssh_idled = true
		wake_main()
	},
	resumed = proc "c" (data: rawptr, self: ^wl.Ext_Idle_Notification_V1) {},
}

// [ssh] forget_on_idle: the compositor tells us after that much idle time.
ssh_watch_idle :: proc() {
	if ssh_idle_note != nil {
		wl.ext_idle_notification_v1_destroy(ssh_idle_note)
		ssh_idle_note = nil
	}
	if config.ssh_forget_on_idle <= 0 || plat.idle_notifier == nil || plat.seat == nil {return}
	ms := u32(config.ssh_forget_on_idle) * 60_000
	ssh_idle_note = wl.ext_idle_notifier_v1_get_idle_notification(plat.idle_notifier, ms, plat.seat)
	wl.ext_idle_notification_v1_add_listener(ssh_idle_note, &ssh_idle_listener, nil)
}

// ---- IPC and command line --------------------------------------------------------

// The key named by a user (file name, path or fingerprint).
@(private = "file")
find_key :: proc(keys: []Ssh_Key, name: string) -> (Ssh_Key, bool) {
	for k in keys {
		if k.name == name || k.path == name || k.fingerprint == name {return k, true}
	}
	return {}, false
}

// Plain text: the agent, then one line per key.
ssh_status_text :: proc() -> string {
	sync.guard(&ssh.mu)
	b := strings.builder_make(context.temp_allocator)
	now := time.to_unix_seconds(time.now())
	switch ssh.agent {
	case .None:    strings.write_string(&b, "agent: none\n")
	case .Running: fmt.sbprintf(&b, "agent: %s (%s)\n", ssh_agent_kind(ssh.sock), ssh.sock)
	case .Locked:  fmt.sbprintf(&b, "agent: %s (%s), locked\n", ssh_agent_kind(ssh.sock), ssh.sock)
	}
	line :: proc(b: ^strings.Builder, k: Ssh_Key, now: i64) {
		state := "locked"
		if k.loaded {state = k.expires > 0 ? fmt.tprintf("unlocked, %s left", ssh_left_text(k.expires - now)) : "unlocked"}
		fmt.sbprintf(b, "%s\t%s %d\t%s\t%s\n", k.name, k.kind, k.bits, k.fingerprint, state)
	}
	for k in ssh.keys {line(&b, k, now)}
	for k in ssh.others {line(&b, k, now)}
	return strings.to_string(b)
}

// "ssh status|refresh|unlock <key>|forget <key>|forget-all|lock|unlock-agent"
// (the daemon). Actions start and reply at once.
ssh_command :: proc(args: []string) -> string {
	ssh_start()
	sub := len(args) > 0 ? args[0] : "status"
	switch sub {
	case "status":
		if !ssh.checked {ssh_refresh_now()}
		return ssh_status_text()
	case "refresh":
		ssh_request_refresh()
		return "ok\n"
	case "unlock", "forget":
		if len(args) < 2 {return fmt.tprintf("usage: ssh %s <key>\n", sub)}
		ssh_refresh_now()
		k: Ssh_Key
		found: bool
		{
			sync.guard(&ssh.mu)
			k, found = find_key(ssh.keys[:], args[1])
			if !found {k, found = find_key(ssh.others[:], args[1])}
			if found {k = {path = strings.clone(k.path, context.temp_allocator), fingerprint = strings.clone(k.fingerprint, context.temp_allocator)}}
		}
		if !found {return "no such key\n"}
		if sub == "forget" && k.path == "" {k.path = k.fingerprint}
		if !ssh_start_action(sub == "unlock" ? .Unlock : .Forget, k.path, k.fingerprint) {return "busy\n"}
		if sub == "unlock" && platform_visible() {hide_popup()} // the passphrase popup takes the keyboard
	case "forget-all":
		if !ssh_start_action(.Forget_All) {return "busy\n"}
	case "lock":
		if !ssh_start_action(.Lock) {return "busy\n"}
		if platform_visible() {hide_popup()}
	case "unlock-agent":
		if !ssh_start_action(.Unlock_Agent) {return "busy\n"}
		if platform_visible() {hide_popup()}
	case:
		return "usage: ssh [status|refresh|unlock <key>|forget <key>|forget-all|lock|unlock-agent]\n"
	}
	return "ok\n"
}

// `wlperch ssh …`: through the daemon, or here when none runs.
ssh_cli :: proc(args: []string) -> int {
	cmd := strings.join(args, " ", context.temp_allocator)
	if reply, ok := ipc_query(strings.concatenate({"ssh ", cmd}, context.temp_allocator)); ok {
		fmt.print(reply)
		r := strings.trim_space(reply)
		return strings.has_prefix(r, "usage") || r == "busy" || r == "no such key" ? 1 : 0
	}
	config_load()
	sub := len(args) > 0 ? args[0] : "status"
	if sub == "status" || sub == "refresh" {
		ssh_refresh_now()
		fmt.print(ssh_status_text())
		return 0
	}
	act: Ssh_Action
	key, fp: string
	switch sub {
	case "forget-all":   act = .Forget_All
	case "lock":         act = .Lock
	case "unlock-agent": act = .Unlock_Agent
	case "unlock", "forget":
		if len(args) < 2 {
			fmt.eprintfln("usage: wlperch ssh %s <key>", sub)
			return 2
		}
		ssh_refresh_now()
		k, found := find_key(ssh.keys[:], args[1])
		if !found {k, found = find_key(ssh.others[:], args[1])}
		if !found {
			fmt.eprintln("no such key")
			return 1
		}
		act = sub == "unlock" ? .Unlock : .Forget
		key, fp = k.path != "" ? k.path : k.fingerprint, k.fingerprint
	case:
		fmt.eprintln("usage: wlperch ssh [status|unlock <key>|forget <key>|forget-all|lock|unlock-agent]")
		return 2
	}
	ok, msg := ssh_do(act, key, fp, config.ssh_lifetime * 60)
	fmt.println(msg)
	return ok ? 0 : 1
}

// ---- The bar --------------------------------------------------------------------

// For the bar's ssh module: how many keys the agent holds, a tooltip (names,
// time left) and when the next one leaves it (0 = none known).
ssh_bar_sample :: proc() -> (n: int, tip: string, next: i64) {
	sock := ssh_agent_socket()
	loaded, ok := ssh_list_loaded(sock)
	if !ok || len(loaded) == 0 {return 0, "", 0}
	keys := ssh_scan_keys(ssh_home(), nil)
	defer {
		for &k in keys {ssh_key_free(&k)}
		delete(keys)
	}
	r := ssh_records_load()
	now := time.to_unix_seconds(time.now())
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "SSH: %d key%s unlocked", len(loaded), len(loaded) == 1 ? "" : "s")
	for l in loaded {
		name := l.comment != "" ? l.comment : l.fingerprint
		for k in keys {if k.fingerprint == l.fingerprint {name = k.name}}
		left := ""
		for rec in r.keys {
			if rec.fingerprint != l.fingerprint || rec.expires <= 0 {continue}
			left = fmt.tprintf(" · %s left", ssh_left_text(max(rec.expires - now, 0)))
			if next == 0 || rec.expires < next {next = rec.expires}
		}
		fmt.sbprintf(&b, "\n%s%s", name, left)
	}
	strings.write_string(&b, "\nClick: SSH keys · right click: forget all, lock")
	return len(loaded), strings.to_string(b), next
}
