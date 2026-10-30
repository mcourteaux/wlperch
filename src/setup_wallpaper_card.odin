// Setup component "Wallpaper": wlperch's wallpaper process
// (wallpaper_proc.odin) instead of sway's swaybg. "Use wlperch wallpaper"
// writes config.d/wlperch-wallpaper.conf (swaybg_command -, and
// exec_always wlperch wallpaper), starts the process, which stops sway's
// running swaybg once it has drawn, and reloads sway so the file holds from
// then on. "Switch back" removes the file and reloads sway (swaybg returns
// with your `output * bg`), shows the current picture through swaybg and
// stops ours.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

wallpaper_setup_check :: proc(p: ^Component, add_detail: proc(c: ^Component, line: string)) {
	installed := wallpaper_conf_installed()
	pid := wallpaper_running()
	switch {
	case installed && pid > 0:
		p.state = .Running
		add_detail(p, fmt.tprintf("running (pid %d); sway's swaybg is off", pid))
	case installed:
		p.state = .Stopped
		add_detail(p, "set up, but not running (sway starts it on login and reload)")
	case pid > 0:
		p.state = .Missing
		add_detail(p, fmt.tprintf("running (pid %d), but sway still has swaybg: switch over to keep it off", pid))
	case:
		p.state = .Missing
		add_detail(p, fmt.tprintf("adds %s", wallpaper_conf_path()))
	}
	if installed {add_detail(p, wallpaper_conf_path())}
	if cur := wallpaper_current(); cur != "" {add_detail(p, fmt.tprintf("showing %s", cur))}
	if n := config.wallpapers_rotate_minutes; n > 0 {
		add_detail(p, fmt.tprintf("next picture every %d min ([wallpapers] rotate_minutes)", n))
	}
	if installed && len(sway_swaybg_pids()) > 0 {add_detail(p, "sway's swaybg still runs (reload sway)")}
}

@(private = "file")
wallpaper_done :: proc(ok: bool, msg: string) {
	sync.guard(&setup.mu)
	c := &setup.comps[.Wallpaper]
	c.busy = false
	c.msg_ok = ok
	delete(c.message)
	c.message = strings.clone(msg)
	log.infof("setup wallpaper: %s", msg)
}

// Until the process runs (it takes the lock once it's up).
@(private = "file")
wait_running :: proc(timeout: time.Duration) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		if wallpaper_running() > 0 {return true}
		time.sleep(100 * time.Millisecond)
	}
	return false
}

setup_install_wallpaper :: proc() {
	path := wallpaper_conf_path()
	dir := path[:strings.last_index_byte(path, '/')]
	os.make_directory_all(dir)
	if !write_file_atomic(path, WALLPAPER_CONF) {
		wallpaper_done(false, fmt.tprintf("couldn't write %s", path))
		return
	}
	// The picture swaybg shows now, unless wlperch already picked one.
	if wallpaper_current() == "" {
		if t := config.theme_targets[theme_mode_load()].wallpaper; t != "" {wallpaper_state_save(t)}
	}
	if wallpaper_running() == 0 {launch_detached({wallpaper_exe(), "wallpaper"})}
	running := wait_running(5 * time.Second)
	// Ours is on screen: sway's swaybg goes for good (and not again on reload).
	time.sleep(500 * time.Millisecond)
	reloaded := sway_reload_if_valid()
	switch {
	case !running:
		wallpaper_done(false, "set up, but it didn't start; see $XDG_RUNTIME_DIR/wlperch-wallpaper-*.log")
	case reloaded:
		wallpaper_done(true, "wlperch shows the wallpaper now (sway reloaded)")
	case:
		wallpaper_done(true, "wlperch shows the wallpaper now; reload sway to keep swaybg off")
	}
}

setup_start_wallpaper :: proc() {
	launch_detached({wallpaper_exe(), "wallpaper"})
	ok := wait_running(5 * time.Second)
	wallpaper_done(ok, ok ? "started" : "didn't start; see $XDG_RUNTIME_DIR/wlperch-wallpaper-*.log")
}

setup_restart_wallpaper :: proc() {
	old := wallpaper_running()
	launch_detached({wallpaper_exe(), "wallpaper", "--replace"})
	// The new one takes over once it has drawn.
	start := time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		if pid := wallpaper_running(); pid > 0 && pid != old {
			wallpaper_done(true, "restarted")
			return
		}
		time.sleep(100 * time.Millisecond)
	}
	wallpaper_done(false, "the new one didn't take over")
}

setup_remove_wallpaper :: proc() {
	path := wallpaper_conf_path()
	if os.exists(path) && os.remove(path) != nil {
		wallpaper_done(false, fmt.tprintf("couldn't remove %s", path))
		return
	}
	// swaybg comes back with the config's `output * bg` …
	reloaded := sway_reload_if_valid()
	// … showing what wlperch showed, then ours goes.
	if cur := wallpaper_current(); cur != "" && reloaded {wallpaper_apply_sway(cur)}
	// (Without the reload, sway still has no swaybg: ours stays until then.)
	if pid := wallpaper_running(); pid > 0 && reloaded {
		time.sleep(500 * time.Millisecond)
		posix.kill(posix.pid_t(pid), .SIGTERM)
	}
	wallpaper_done(true, reloaded ? "back to swaybg (sway reloaded)" : "removed; reload sway to get swaybg back")
}
