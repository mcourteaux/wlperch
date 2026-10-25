// Tests for the SSH keys support (ssh.odin, setup_ssh.odin, askpass.odin).
// No agent and no real keys: public halves of throwaway keys only.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(private = "file") PUB_ED :: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFSKvVTlA7W58/GrnfEE9SAa6ucz3z+YbL+CdCsG1DlE test@ed\n"
@(private = "file") PUB_RSA :: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCVBf8Bpt7S1HOVxdnLbdZ7wvmq3WUF3ZqTDCSJm7wIY6JCVJBY6TMQ9oA2PikMVhF6y/pq63uX3Ym5kL5Rfoh8rHqxet8Av6Yg3vC9Di/Qp1mZTzKWxZz0HLnTeuLU5xtqZo+kpPSVLhZKKy9Tp8SRCzohkF2vlz14g/jijqXAIGqVIxIWoPICK/sX7vTWk/ScEwP6lNikDdHxx+ED3wGvZpAld/JVVbNi2W5PvkKnHw785pxDFPxE7WR1R0pUZW+Rrq8N/np+z2wq11X0H/IAqGYQ0gXoBQoGWN128LH5F2HitPo+nigghu69Zplf4ik4B0GXGLReIW/mSlbrVKyn+BaacURZhmNPytbpuXzI3O5Y91q60FnTXl5qtb4Lze6ORpfgj+80wRelWpAGxLxDDmlPXUMeqdfYWl+3+NMv5LaUHQo9qV4eIyylhpKvOH/gPEl0J4pKKbMW+ipS4t6jWMwY91KgJovav34PAYoPT2zuOpsIH42/LoVZpWgdwV0= test rsa key\n"
@(private = "file") PUB_EC :: "ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBE7BUkVbsST4rRgTdTth7nz8/TpLuCH1I5TWa84BGtOHx8TghbM81R5nLhp2z/tJzb3zAUw2kTWf09W/FfKDucYo8Fwbuuz3OUR3DCoZow7hHlmL3UlxGmbB0F7EkiLvFg== \n"

@(test)
test_ssh_pub_fingerprints :: proc(t: ^testing.T) {
	// Expected values from ssh-keygen -lf.
	kind, bits, fp, comment, ok := ssh_pub_parse(PUB_ED)
	testing.expect(t, ok)
	testing.expect_value(t, kind, "ED25519")
	testing.expect_value(t, bits, 256)
	testing.expect_value(t, fp, "SHA256:4qNa2refthCBW6ZXK+0ujecbj5B1sedKRcH1UATtdSY")
	testing.expect_value(t, comment, "test@ed")
	kind, bits, fp, comment, ok = ssh_pub_parse(PUB_RSA)
	testing.expect(t, ok)
	testing.expect_value(t, kind, "RSA")
	testing.expect_value(t, bits, 3072)
	testing.expect_value(t, fp, "SHA256:eN/pF+Xm68UOCTd8+dsSMZ/YZYGCvoMBMuVw0FrIdu8")
	testing.expect_value(t, comment, "test rsa key")
	kind, bits, fp, comment, ok = ssh_pub_parse(PUB_EC)
	testing.expect(t, ok)
	testing.expect_value(t, kind, "ECDSA")
	testing.expect_value(t, bits, 384)
	testing.expect_value(t, fp, "SHA256:RvmWm5fU2QawXVbxK34feaFaI0C++0Dov+LI5LzadKA")
	testing.expect_value(t, comment, "")
	// Not public keys.
	for bad in ([]string{"", "ssh-rsa", "ssh-rsa !!!", "ssh-ed25519 AAAAB3NzaC1yc2EAAAADAQABAAABgQCVBf8B x", "Host *\n  User me\n"}) {
		_, _, _, _, ok = ssh_pub_parse(bad)
		testing.expectf(t, !ok, "%q parsed as a key", bad)
	}
}

@(test)
test_ssh_parse_list :: proc(t: ^testing.T) {
	out := "3072 SHA256:eN/pF+Xm68UOCTd8+dsSMZ/YZYGCvoMBMuVw0FrIdu8 /home/u/.ssh/id_rsa (RSA)\n256 SHA256:4qNa2refthCBW6ZXK+0ujecbj5B1sedKRcH1UATtdSY my key (with parens) (ED25519)\nThe agent has no identities.\n"
	l := ssh_parse_list(out)
	testing.expect_value(t, len(l), 2)
	if len(l) == 2 {
		testing.expect_value(t, l[0].bits, 3072)
		testing.expect_value(t, l[0].comment, "/home/u/.ssh/id_rsa")
		testing.expect_value(t, l[0].kind, "RSA")
		testing.expect_value(t, l[1].fingerprint, "SHA256:4qNa2refthCBW6ZXK+0ujecbj5B1sedKRcH1UATtdSY")
		testing.expect_value(t, l[1].comment, "my key (with parens)")
		testing.expect_value(t, l[1].kind, "ED25519")
	}
	testing.expect_value(t, len(ssh_parse_list("The agent has no identities.\n")), 0)
}

@(test)
test_ssh_records :: proc(t: ^testing.T) {
	r: Ssh_Records
	r.keys.allocator = context.temp_allocator
	ssh_record_set(&r, "SHA256:a", 100, 3700)
	ssh_record_set(&r, "SHA256:b", 200, 0)
	ssh_record_set(&r, "SHA256:a", 150, 3750) // replaces
	text := ssh_records_format(r)
	testing.expect(t, !strings.contains(text, "PRIVATE"))
	back := ssh_records_parse(text)
	testing.expect_value(t, len(back.keys), 2)
	testing.expect_value(t, back.keys[0].added, 150)
	testing.expect_value(t, back.keys[0].expires, 3750)
	testing.expect_value(t, back.keys[1].expires, 0)
	testing.expect_value(t, back.locked_at, 0)

	// Only what's still loaded and not past its time stays.
	loaded := []Ssh_Loaded{{fingerprint = "SHA256:b"}}
	testing.expect(t, ssh_records_reconcile(&back, loaded, 1000))
	testing.expect_value(t, len(back.keys), 1)
	testing.expect(t, !ssh_records_reconcile(&back, loaded, 1000))
	ssh_record_set(&back, "SHA256:c", 900, 950)
	testing.expect(t, ssh_records_reconcile(&back, []Ssh_Loaded{{fingerprint = "SHA256:b"}, {fingerprint = "SHA256:c"}}, 1000))
	testing.expect_value(t, len(back.keys), 1)

	// A locked agent lists nothing: the records wait.
	back.locked_at = 500
	testing.expect(t, !ssh_records_reconcile(&back, nil, 1000))
	testing.expect_value(t, len(back.keys), 1)
	// It lists keys again: unlocked (elsewhere).
	testing.expect(t, ssh_records_reconcile(&back, loaded, 1000))
	testing.expect_value(t, back.locked_at, 0)
	testing.expect(t, strings.contains(ssh_records_format({locked_at = 7}), "locked 7"))

	testing.expect_value(t, ssh_left_text(10), "< 1 min")
	testing.expect_value(t, ssh_left_text(60), "1 min")
	testing.expect_value(t, ssh_left_text(61), "2 min")
	testing.expect_value(t, ssh_left_text(3600), "1 h 00 min")
	testing.expect_value(t, ssh_left_text(3600 * 2 + 5 * 60), "2 h 05 min")
}

@(test)
test_ssh_scan_keys :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/wlperch-test-ssh-%d", posix.getpid())
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	w :: proc(dir, name, text: string) {_ = os.write_entire_file(fmt.tprintf("%s/%s", dir, name), text)}
	// Private files hold a placeholder: the scan never reads them.
	w(dir, "id_ed", "placeholder")
	w(dir, "id_ed.pub", PUB_ED)
	w(dir, "work_rsa", "placeholder")
	w(dir, "work_rsa.pub", PUB_RSA)
	w(dir, "orphan.pub", PUB_EC) // no private half
	w(dir, "known_hosts", "host ssh-ed25519 AAAA\n")
	w(dir, "authorized_keys", PUB_ED)
	w(dir, "config", "Host *\n")
	w(dir, "broken", "x")
	w(dir, "broken.pub", "not a key\n")
	keys := ssh_scan_keys(dir, nil)
	defer {
		for &k in keys {ssh_key_free(&k)}
		delete(keys)
	}
	names := make([dynamic]string, context.temp_allocator)
	for k in keys {append(&names, k.name)}
	testing.expect_value(t, strings.join(names[:], " ", context.temp_allocator), "id_ed work_rsa")
	if len(keys) == 2 {
		testing.expect_value(t, keys[1].kind, "RSA")
		testing.expect_value(t, keys[1].bits, 3072)
		testing.expect_value(t, keys[0].path, fmt.tprintf("%s/id_ed", dir))
	}
	only := ssh_scan_keys(dir, {"work_rsa"})
	testing.expect_value(t, len(only), 1)
	for &k in only {ssh_key_free(&k)}
	delete(only)
	testing.expect(t, ssh_key_wanted({"~/.ssh/x"}, fmt.tprintf("%s/.ssh/x", os.get_env("HOME", context.temp_allocator)), "x"))
	testing.expect(t, !ssh_key_wanted({"y"}, "/a/x", "x"))
	testing.expect_value(t, ssh_agent_kind("/run/user/1000/keyring/ssh"), "GNOME Keyring")
	testing.expect_value(t, ssh_agent_kind("/run/user/1000/gnupg/S.gpg-agent.ssh"), "gpg-agent")
}

@(test)
test_askpass_prompts :: proc(t: ^testing.T) {
	title, sub, body, err := askpass_parse_prompt("Enter passphrase for /home/u/.ssh/id_rsa: ", "/home/u", "")
	testing.expect_value(t, title, "Unlock SSH key")
	testing.expect_value(t, sub, "~/.ssh/id_rsa")
	testing.expect_value(t, err, "")
	_ = body
	title, sub, body, err = askpass_parse_prompt("Bad passphrase, try again for /home/u/.ssh/id_rsa (will confirm each use): ", "/home/u", "")
	testing.expect_value(t, sub, "~/.ssh/id_rsa")
	testing.expect(t, err != "")
	title, sub, body, err = askpass_parse_prompt("Enter lock password: ", "/home/u", "")
	testing.expect_value(t, title, "SSH agent password")
	title, sub, body, err = askpass_parse_prompt("Allow use of key /home/u/.ssh/id_rsa?\nKey fingerprint SHA256:x.", "/home/u", "confirm")
	testing.expect_value(t, title, "Allow use of an SSH key?")
	testing.expect(t, strings.contains(body, "fingerprint"))
	// A home that is only a prefix of the path stays as it is.
	_, sub, _, _ = askpass_parse_prompt("Enter passphrase for /home/user2/k:", "/home/user", "")
	testing.expect_value(t, sub, "/home/user2/k")
}

@(test)
test_ssh_config_rewrite :: proc(t: ^testing.T) {
	ssh_config_lifetime = "60m"
	defer ssh_config_lifetime = "60m"
	block := ssh_config_block()
	cases := [][2]string {
		{"", block},
		{"Host gump\n    HostName 10.0.0.2\n", strings.concatenate({block, "\nHost gump\n    HostName 10.0.0.2\n"}, context.temp_allocator)},
		{"# my config\n\nHost *\n    User me\n", strings.concatenate({"# my config\n\n", block, "\nHost *\n    User me\n"}, context.temp_allocator)},
		{"# only a comment", strings.concatenate({"# only a comment\n\n", block}, context.temp_allocator)},
	}
	for c in cases {
		got, n := ssh_config_rewrite(c[0])
		testing.expect_value(t, n, 1)
		testing.expect_value(t, got, c[1])
		// Once is enough.
		again, n2 := ssh_config_rewrite(got)
		testing.expect_value(t, n2, 0)
		testing.expect_value(t, again, got)
	}
	// The user's own AddKeysToAgent wins.
	mine := "Host *\n  addkeystoagent confirm\n"
	got, n := ssh_config_rewrite(mine)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, got, mine)
	testing.expect_value(t, ssh_config_add_keys_line(mine), 2)
	testing.expect_value(t, ssh_config_add_keys_line("# AddKeysToAgent yes\n"), 0)

	p, pn := ssh_profile_rewrite("export A=1")
	testing.expect_value(t, pn, 1)
	testing.expect_value(t, p, strings.concatenate({"export A=1\n\n", SSH_PROFILE_BLOCK}, context.temp_allocator))
	_, pn = ssh_profile_rewrite(p)
	testing.expect_value(t, pn, 0)
}

// Install / Remove against a fake home: every file back byte for byte.
@(test)
test_ssh_setup_round_trip :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/wlperch-test-sshsetup-%d", posix.getpid())
	defer os.remove_all(root)
	saved: [6]string
	names := [6]string{"HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "SHELL", "ZDOTDIR", "XDG_RUNTIME_DIR"}
	for n, i in names {saved[i] = strings.clone(os.get_env(n, context.temp_allocator), context.temp_allocator)}
	defer for n, i in names {os.set_env(n, saved[i])}
	h := fmt.tprintf("%s/home", root)
	os.set_env("HOME", h)
	os.set_env("XDG_CONFIG_HOME", fmt.tprintf("%s/.config", h))
	os.set_env("XDG_DATA_HOME", fmt.tprintf("%s/.local/share", h))
	os.set_env("ZDOTDIR", "")
	os.set_env("XDG_RUNTIME_DIR", fmt.tprintf("%s/run", root))
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/.ssh/agent", h)) == nil)
	read :: proc(p: string) -> (string, bool) {
		data, err := os.read_entire_file(p, context.temp_allocator)
		return string(data), err == nil
	}

	// zsh with no ~/.zprofile yet, a ~/.ssh/config: both come and go exactly.
	os.set_env("SHELL", "/usr/bin/zsh")
	CFG :: "# mine\nHost gump\n    HostName 10.0.0.2\n    User pi\n"
	cfg := fmt.tprintf("%s/.ssh/config", h)
	testing.expect(t, os.write_entire_file(cfg, CFG) == nil)
	zprofile := fmt.tprintf("%s/.zprofile", h)
	ok, msg := ssh_setup_install(apply = false)
	testing.expectf(t, ok, "install: %s", msg)
	text, have := read(zprofile)
	testing.expect(t, have && text == SSH_PROFILE_BLOCK)
	envd, _ := read(ssh_envd_path())
	testing.expect_value(t, envd, SSH_ENVD_TEXT)
	ok, msg = ssh_setup_add_keys(true)
	testing.expectf(t, ok, "add keys: %s", msg)
	text, _ = read(cfg)
	testing.expect(t, strings.has_prefix(text, "# mine\n\n# Added by wlperch setup"))
	testing.expect(t, strings.has_suffix(text, "\nHost gump\n    HostName 10.0.0.2\n    User pi\n"))
	ours, theirs := ssh_config_state()
	testing.expect(t, ours && !theirs)

	ok, msg = ssh_setup_remove(apply = false)
	testing.expectf(t, ok, "remove: %s", msg)
	testing.expect(t, !os.exists(zprofile))
	testing.expect(t, !os.exists(ssh_envd_path()))
	text, _ = read(cfg)
	testing.expect_value(t, text, CFG)

	// bash with ~/.bash_profile (no trailing newline): edited, then restored.
	os.set_env("SHELL", "/bin/bash")
	BP :: "# .bash_profile\n[ -f ~/.bashrc ] && . ~/.bashrc"
	bp := fmt.tprintf("%s/.bash_profile", h)
	testing.expect(t, os.write_entire_file(bp, BP) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/.profile", h), "x=1\n") == nil)
	testing.expect_value(t, ssh_profile_path(), bp)
	ok, msg = ssh_setup_install(apply = false)
	testing.expectf(t, ok, "install: %s", msg)
	text, _ = read(bp)
	testing.expect(t, strings.has_prefix(text, BP) && strings.contains(text, "export SSH_AUTH_SOCK="))
	// Installing again changes nothing.
	ok, _ = ssh_setup_install(apply = false)
	again, _ := read(bp)
	testing.expect_value(t, again, text)
	ok, msg = ssh_setup_remove(apply = false)
	testing.expectf(t, ok, "remove: %s", msg)
	text, _ = read(bp)
	testing.expect_value(t, text, BP)
	text, _ = read(fmt.tprintf("%s/.profile", h))
	testing.expect_value(t, text, "x=1\n")
	// No ~/.ssh/config: Add keys creates it (0600), Stop removes it.
	os.remove(cfg)
	ok, _ = ssh_setup_add_keys(true)
	text, have = read(cfg)
	testing.expect(t, ok && have && strings.contains(text, "AddKeysToAgent "))
	st: posix.stat_t
	posix.stat(strings.clone_to_cstring(cfg, context.temp_allocator), &st)
	testing.expect_value(t, u32(transmute(u32)st.st_mode) & 0o777, 0o600)
	ok, _ = ssh_setup_add_keys(false)
	testing.expect(t, ok && !os.exists(cfg))
	delete(setup.comps[.Ssh].message)
	setup.comps[.Ssh].message = ""
}
