// Updates from GitHub releases: a check once a day ([update] check_daily) and
// on request (the update button in the main panel's header, "wlperch update
// check"), and an install that downloads the release tarball for this CPU,
// checks it against the release's SHA256SUMS, swaps ~/.local/bin/wlperch and
// restarts the daemon and the bar.
//
// The check is one request to the GitHub API (curl); nothing is sent beyond
// what any download sends. Installing never runs code from the download
// other than the new wlperch itself (its --version, then the restart).
package main

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

UPDATE_REPO :: "mcourteaux/wlperch"
UPDATE_EVERY :: 24 * time.Hour

when ODIN_ARCH == .amd64 {
	UPDATE_ARCH :: "x86_64"
} else when ODIN_ARCH == .arm64 {
	UPDATE_ARCH :: "aarch64"
} else {
	UPDATE_ARCH :: ""
}

Update_State :: enum {Idle, Checking, Up_To_Date, Available, Installing, Installed, Failed}

update: struct {
	mu:          sync.Mutex,
	state:       Update_State,
	latest:      string, // "0.1.2" (Available / Installed)
	tarball_url: string,
	sums_url:    string,
	message:     string, // Failed: why; Installed: what happened
	checked_at:  i64, // unix seconds of the last finished check
	notified:    string, // the version a history entry was written for
	new_found:   bool, // for the main thread: log it in the notification history
	wake:        sync.Sema,
}

@(private = "file")
state_path :: proc() -> string {return strings.concatenate({data_dir(), "/update-check"}, context.temp_allocator)}

// "checked <unix>\nnotified <version>\n"
@(private = "file")
state_load :: proc() {
	data, err := os.read_entire_file(state_path(), context.temp_allocator)
	if err != nil {return}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		k, _, v := strings.partition(line, " ")
		switch k {
		case "checked":  update.checked_at = i64(strconv.parse_i64(v) or_else 0)
		case "notified": update.notified = strings.clone(v)
		}
	}
}

@(private = "file")
state_save :: proc() {
	os.make_directory_all(data_dir())
	_ = os.write_entire_file(state_path(), fmt.tprintf("checked %d\nnotified %s\n", update.checked_at, update.notified))
}

// "0.1.10" > "0.1.9": numeric parts, missing ones count as 0. A leading "v"
// is ignored; anything after "-" (0.2.0-rc1) sorts before the plain version.
version_newer :: proc(a, b: string) -> bool {
	parse :: proc(s: string) -> (parts: [4]int, pre: bool) {
		s := strings.trim_prefix(strings.trim_space(s), "v")
		core, _, suffix := strings.partition(s, "-")
		pre = suffix != ""
		i := 0
		for p in strings.split_iterator(&core, ".") {
			if i >= len(parts) {break}
			parts[i] = strconv.parse_int(p) or_else 0
			i += 1
		}
		return
	}
	pa, prea := parse(a)
	pb, preb := parse(b)
	for i in 0 ..< len(pa) {
		if pa[i] != pb[i] {return pa[i] > pb[i]}
	}
	return !prea && preb
}

// Pick the newest release newer than `current` from the GitHub API's release
// list, with its tarball for this CPU and SHA256SUMS. Drafts are skipped.
update_pick :: proc(releases_json, current, arch: string) -> (version, tarball, sums: string, ok: bool) {
	v, pok := jparse(releases_json)
	if !pok {return}
	best := ""
	for r in jarr(v) {
		if jbool(jobj(r, "draft")) {continue}
		tag := strings.trim_prefix(jstr(jobj(r, "tag_name")), "v")
		if tag == "" || !version_newer(tag, current) || (best != "" && !version_newer(tag, best)) {continue}
		want := fmt.tprintf("wlperch-%s-%s-linux.tar.gz", tag, arch)
		t, s := "", ""
		for a in jarr(jobj(r, "assets")) {
			switch jstr(jobj(a, "name")) {
			case want:         t = jstr(jobj(a, "browser_download_url"))
			case "SHA256SUMS": s = jstr(jobj(a, "browser_download_url"))
			}
		}
		if t == "" || s == "" {continue} // no build for this CPU in that release
		best, tarball, sums = tag, t, s
	}
	if best == "" {return}
	return best, tarball, sums, true
}

// One check, blocking (a worker thread or the CLI).
update_check_now :: proc() -> (msg: string, ok: bool) {
	{
		sync.guard(&update.mu)
		if update.state == .Installing {return "an update is being installed", false}
		update.state = .Checking
	}
	request_redraw(1)
	out, rok := run({"curl", "-sfL", "--max-time", "15", "-H", "Accept: application/vnd.github+json", fmt.tprintf("https://api.github.com/repos/%s/releases?per_page=20", UPDATE_REPO)}, 20 * time.Second, context.temp_allocator)
	sync.guard(&update.mu)
	update.checked_at = time.to_unix_seconds(time.now())
	defer state_save()
	if !rok {
		update.state = .Failed
		set_message("couldn't reach GitHub")
		return update.message, false
	}
	version, tarball, sums, found := update_pick(out, VERSION, UPDATE_ARCH)
	if !found {
		update.state = .Up_To_Date
		return fmt.tprintf("wlperch %s is up to date", VERSION), true
	}
	delete(update.latest); delete(update.tarball_url); delete(update.sums_url)
	update.latest, update.tarball_url, update.sums_url = strings.clone(version), strings.clone(tarball), strings.clone(sums)
	update.state = .Available
	if update.notified != version {update.new_found = true}
	return fmt.tprintf("wlperch %s is available (this is %s)", version, VERSION), true
}

@(private = "file")
set_message :: proc(m: string) {
	delete(update.message)
	update.message = strings.clone(m)
}

// The installed program (setup's Program component puts it there).
update_target :: proc() -> string {
	return strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.local/bin/wlperch"}, context.temp_allocator)
}

// Download, verify and install the available release. Blocking.
update_install_now :: proc() -> (msg: string, ok: bool) {
	version, tarball, sums: string
	{
		sync.guard(&update.mu)
		if update.state != .Available {return "no update to install (check first)", false}
		update.state = .Installing
		version = strings.clone(update.latest, context.temp_allocator)
		tarball = strings.clone(update.tarball_url, context.temp_allocator)
		sums = strings.clone(update.sums_url, context.temp_allocator)
	}
	request_redraw(1)
	msg, ok = install(version, tarball, sums)
	sync.guard(&update.mu)
	if ok {
		update.state = .Installed
	} else {
		update.state = .Available // still there to retry
	}
	set_message(msg)
	log.infof("update: %s", msg)
	return
}

@(private = "file")
install :: proc(version, tarball_url, sums_url: string) -> (string, bool) {
	tmp := fmt.tprintf("%s/wlperch-update", os.get_env("XDG_RUNTIME_DIR", context.temp_allocator))
	if !strings.has_prefix(tmp, "/") {tmp = fmt.tprintf("/tmp/wlperch-update-%d", posix.getuid())}
	os.remove_all(tmp)
	if os.make_directory_all(tmp) != nil {return "couldn't create a download folder", false}
	defer os.remove_all(tmp)
	name := tarball_url[strings.last_index_byte(tarball_url, '/') + 1:]
	tar_path := fmt.tprintf("%s/%s", tmp, name)
	sums_path := fmt.tprintf("%s/SHA256SUMS", tmp)
	if _, dok := run({"curl", "-sfL", "--max-time", "120", "-o", tar_path, tarball_url}, 130 * time.Second, context.temp_allocator); !dok {
		return "download failed", false
	}
	if _, dok := run({"curl", "-sfL", "--max-time", "30", "-o", sums_path, sums_url}, 40 * time.Second, context.temp_allocator); !dok {
		return "couldn't download SHA256SUMS", false
	}

	// The tarball's checksum must match its line in SHA256SUMS.
	data, rerr := os.read_entire_file(tar_path, context.temp_allocator)
	if rerr != nil {return "couldn't read the download", false}
	got := string(hex.encode(hash.hash_bytes(.SHA256, data, context.temp_allocator), context.temp_allocator))
	sums_data, serr := os.read_entire_file(sums_path, context.temp_allocator)
	if serr != nil {return "couldn't read SHA256SUMS", false}
	want := ""
	sums_text := string(sums_data)
	for line in strings.split_lines_iterator(&sums_text) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 2 && strings.trim_prefix(f[1], "*") == name {want = strings.to_lower(f[0], context.temp_allocator)}
	}
	if want == "" {return "the download isn't listed in SHA256SUMS", false}
	if got != want {return "checksum mismatch: the download is not what the release lists", false}

	if _, tok := run({"tar", "-xzf", tar_path, "-C", tmp}, 30 * time.Second, context.temp_allocator); !tok {
		return "couldn't unpack the download", false
	}
	new_bin := fmt.tprintf("%s/wlperch-%s-%s-linux/wlperch", tmp, version, UPDATE_ARCH)
	vout, vok := run({new_bin, "--version"}, 10 * time.Second, context.temp_allocator)
	if !vok || strings.trim_space(vout) != fmt.tprintf("wlperch %s", version) {
		return fmt.tprintf("the new binary doesn't run here (%s)", strings.trim_space(vout)), false
	}

	// Swap in place (a running daemon keeps its old image until it restarts).
	target := update_target()
	bin, berr := os.read_entire_file(new_bin, context.temp_allocator)
	if berr != nil {return "couldn't read the new binary", false}
	os.make_directory_all(target[:strings.last_index_byte(target, '/')])
	staged := strings.concatenate({target, ".update-new"}, context.temp_allocator)
	if os.write_entire_file(staged, bin, os.Permissions_Read_All + os.Permissions_Execute_All + {.Write_User}) != nil {
		return fmt.tprintf("couldn't write %s", staged), false
	}
	if os.rename(staged, target) != nil {
		os.remove(staged)
		return fmt.tprintf("couldn't replace %s", target), false
	}
	return fmt.tprintf("installed wlperch %s; restarting", version), true
}

// ---- Daemon side ------------------------------------------------------------------------

// A worker that checks once a day (and when asked), sleeping in between.
update_start :: proc() {
	state_load()
	thread.create_and_start(proc() {
		for {
			due := config.update_check && time.to_unix_seconds(time.now()) - update.checked_at >= i64(UPDATE_EVERY / time.Second)
			manual := false
			if !due {
				// Woken by update_check_async, or recheck the time hourly.
				manual = sync.sema_wait_with_timeout(&update.wake, time.Hour)
			}
			if due || manual {
				update_check_now()
				wake_main()
			}
			free_all(context.temp_allocator)
		}
	}, self_cleanup = true)
}

update_check_async :: proc() {sync.sema_post(&update.wake)}

update_install_async :: proc() {
	thread.create_and_start(proc() {
		_, ok := update_install_now()
		free_all(context.temp_allocator)
		if ok {
			// The bar runs from the same binary: hand over to the new one.
			if len(session_pids("wlperch-bar")) > 0 {bar_restart()}
			restart_requested = true
		}
		wake_main()
	}, self_cleanup = true)
}

// Main thread: a newly found release goes into the notification history once.
update_tick :: proc() {
	sync.guard(&update.mu)
	if !update.new_found {return}
	update.new_found = false
	update.notified = strings.clone(update.latest)
	state_save()
	notif_log_local("wlperch", fmt.tprintf("wlperch %s is available", update.latest), fmt.tprintf("You have %s. Click the update button in the main panel's header to install it.", VERSION), 1)
	request_redraw()
}

// For the header button: icon colour, tooltip, and whether it's highlighted.
update_button_info :: proc() -> (col: u32, tip: string, highlight: bool) {
	sync.guard(&update.mu)
	ago := ""
	if update.checked_at > 0 {
		mins := (time.to_unix_seconds(time.now()) - update.checked_at) / 60
		switch {
		case mins < 1:    ago = "just now"
		case mins < 60:   ago = fmt.tprintf("%d min ago", mins)
		case mins < 1440: ago = fmt.tprintf("%d h ago", mins / 60)
		case:             ago = fmt.tprintf("%d days ago", mins / 1440)
		}
	}
	switch update.state {
	case .Checking:   return C_MUTED, "Checking for updates…", false
	case .Installing: return C_BLUE, fmt.tprintf("Installing wlperch %s…", update.latest), true
	case .Available:
		extra := update.message != "" ? fmt.tprintf("\nlast attempt: %s", update.message) : ""
		return C_GREEN, fmt.tprintf("wlperch %s is available (you have %s)\nclick to download, verify and install it%s", update.latest, VERSION, extra), true
	case .Installed:  return C_GREEN, update.message, true
	case .Failed:     return C_ORANGE, fmt.tprintf("Update check failed: %s\nclick to try again", update.message), false
	case .Up_To_Date, .Idle:
	}
	if ago == "" {return C_MUTED, fmt.tprintf("wlperch %s · check for updates", VERSION), false}
	return C_MUTED, fmt.tprintf("wlperch %s is up to date (checked %s)\nclick to check again", VERSION, ago), false
}

update_available :: proc() -> bool {
	sync.guard(&update.mu)
	return update.state == .Available
}

// ---- CLI ---------------------------------------------------------------------------------

// wlperch update [check|install]
update_cli :: proc(args: []string) -> int {
	sub := len(args) > 0 ? args[0] : "install"
	state_load()
	switch sub {
	case "check":
		msg, ok := update_check_now()
		fmt.println(msg)
		return ok ? 0 : 1
	case "install":
		msg, ok := update_check_now()
		if !ok || !update_available() {
			fmt.println(msg)
			return ok ? 0 : 1
		}
		fmt.println(msg)
		imsg, iok := update_install_now()
		fmt.println(imsg)
		if !iok {return 1}
		// A running daemon and bar: hand over to the new binary.
		if ipc_send("restart") {fmt.println("restarted the daemon")}
		if len(session_pids("wlperch-bar")) > 0 {
			_, bmsg := bar_restart()
			fmt.println(bmsg)
		}
		return 0
	}
	fmt.eprintln("usage: wlperch update [check|install]")
	return 2
}
