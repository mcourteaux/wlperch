// Fullscreen games keep the screen awake ([lock] games_keep_awake): while a
// fullscreen view is a game (game_classify: wine / Proton or another .exe,
// Steam, gamescope, Lutris), the daemon holds an idle inhibitor
// (zwp_idle_inhibit_v1). Everything that waits for inactivity honours it:
// swayidle's lock and `output * power off` timeouts, the idle countdown and
// wlperch's own idle lock and monitors-off (ext-idle-notify), so a game
// played with a controller only isn't locked or blanked. One mechanism for
// all of them. Locking before sleep isn't idle-based and still happens.
//
// The inhibitor sits on a wl_surface without a role: sway counts an
// inhibitor whose surface isn't a view as always active (a view's only while
// it's visible). It goes away with the daemon (or a re-exec, after which the
// new image takes it again), so nothing can stay held by accident.
//
// The setup window (another process) reads $XDG_RUNTIME_DIR/wlperch-game-hold:
// "<daemon pid>\t<app>\t<why>" while held.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"

import "wl"

@(private = "file")
gh: struct {
	surface:   ^wl.Surface,
	inhibitor: ^wl.Zwp_Idle_Inhibitor_V1,
	seq:       int, // fullscreen_seq() last looked at (-1: never)
	enabled:   bool,
	app:       string,
} = {seq = -1}

// Which fullscreen game, if any, holds the screen awake.
game_hold_pick :: proc(covers: []Fs_Cover, enabled: bool) -> (hold: bool, app, why: string) {
	if !enabled {return}
	for c in covers {if c.game {return true, c.app, c.why}}
	return
}

@(private = "file")
hold_path :: proc() -> string {
	dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if dir == "" {dir = "/tmp"}
	return fmt.tprintf("%s/wlperch-game-hold", dir)
}

// Main loop: take or release the inhibitor when the fullscreen views change.
game_hold_tick :: proc() {
	seq := fullscreen_seq()
	if seq == gh.seq && config.lock_games_awake == gh.enabled {return}
	gh.seq, gh.enabled = seq, config.lock_games_awake
	hold: bool
	app, why: string
	{
		sync.guard(&sway.mu)
		hold, app, why = game_hold_pick(sway.fs[:], gh.enabled)
		app, why = strings.clone(app, context.temp_allocator), strings.clone(why, context.temp_allocator)
	}
	if hold && gh.inhibitor == nil {
		if plat.inhibit_mgr == nil || plat.compositor == nil {return}
		gh.surface = wl.compositor_create_surface(plat.compositor)
		gh.inhibitor = wl.zwp_idle_inhibit_manager_v1_create_inhibitor(plat.inhibit_mgr, gh.surface)
		log.infof("idle: held by fullscreen game %s (%s): no idle lock or monitors-off", app, why)
	} else if !hold && gh.inhibitor != nil {
		game_hold_release()
		log.info("idle: no fullscreen game any more, released")
		return
	} else if !hold {
		_ = os.remove(hold_path()) // left by the image before a re-exec
		return
	} else if app == gh.app {
		return
	}
	delete(gh.app)
	gh.app = strings.clone(app)
	_ = os.write_entire_file(hold_path(), transmute([]u8)fmt.tprintf("%d\t%s\t%s\n", posix.getpid(), app, why))
}

game_hold_release :: proc() {
	if gh.inhibitor != nil {wl.zwp_idle_inhibitor_v1_destroy(gh.inhibitor)}
	if gh.surface != nil {wl.surface_destroy(gh.surface)}
	gh.inhibitor, gh.surface = nil, nil
	delete(gh.app)
	gh.app = ""
	_ = os.remove(hold_path())
}

// For the setup window: the game holding the screen awake now ("" if none,
// or if the daemon that wrote it is gone).
game_hold_current :: proc() -> (app, why: string) {
	data, err := os.read_entire_file(hold_path(), context.temp_allocator)
	if err != nil {return}
	f := strings.split(strings.trim_space(string(data)), "\t", context.temp_allocator)
	if len(f) < 3 {return}
	pid, ok := strconv.parse_int(f[0])
	if !ok || pid <= 0 || posix.kill(posix.pid_t(pid), posix.Signal(0)) != .OK {return}
	return f[1], f[2]
}
