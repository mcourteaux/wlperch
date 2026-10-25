package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:path/filepath"
import "core:sys/posix"
import "core:time"

import im "third_party:odin-imgui"
import imgl "third_party:odin-imgui/imgui_impl_opengl3"
import gl "vendor:OpenGL"

import "wl"

USAGE :: `wlperch — quick-settings popup for wlroots compositors

usage: wlperch [command]

commands:
  toggle [panel]  show the popup (default panel or the named one), or hide it
  show [panel]    show the popup / switch to a panel
                  add --center to either for a centred popup instead of the
                  configured corner (meant for key bindings)
  hide     hide the popup
  daemon   start the background daemon without showing the popup
  quit     stop the running daemon
  setup    install / configure components (program, sway, waybar, udev rule…)
  setup settings   the setup window on its Settings tab (common config.ini keys);
                   the default once every component is set up
  setup components the setup window on its Components tab
  restart  restart the daemon (new binary, re-read config); keeps graph history
  audio refresh    fix stuck audio: switch the output's card profile and back
  audio restart    restart PipeWire, WirePlumber and pipewire-pulse
  track <project>  create/focus the project's workspaces (one per monitor) to track time
  track go [project]    go to the current (or last used) project's workspaces
  track move [project]  move the focused window to that project's workspace on this monitor
  track pin [project|off]  for a minute, go/move target this project wherever you are
                           (to gather misplaced windows); each move extends it
  track lock [on|off]  group-lock monitors: they follow each other into/out of projects
  track keep [on|off]  keep empty project workspaces alive with placeholder windows
  track rename [--dry-run] [--merge] [--workspaces] <old> <new>
                   rename a project in the time log and config.ini (backups
                   kept as *.before-rename-*); --workspaces also renames its
                   sway workspaces ("old 1" -> "new 1"), --merge allows
                   renaming onto an existing project (overlaps count once)
  media play-pause|play|pause|next|previous [player]
                   control the playing media player (MPRIS)
  notify dnd [on|off]  do not disturb (popups held; they wait in the Notifications panel)
  notify clear     empty the notification history
  notify dismiss   close the notification popups on screen
  display [list]   display presets from the config ("*" = current layout)
  display <name>|next|prev  switch the monitors to a preset
  display save <name> [label]  add the current layout to the config as a preset
  theme [dark|light|toggle|status]  switch wlperch and the desktop (GTK
                   color-scheme, waybar, kitty, nvim, wallpaper… see [theme])
  calc <expression>  evaluate and print it as decimal, hex, octal, binary and
                   IEEE-754 (hex float, f64/f32 bits); "toggle calc" opens the popup
  bar              the status bar (instead of waybar); run it from sway:
                   bar { swaybar_command wlperch-bar }
  bar restart      start a fresh bar; it takes over from the running one
  ssh [status|unlock <key>|forget <key>|forget-all|lock|unlock-agent]
                   SSH keys in the agent (unlock asks in wlperch's popup and
                   adds the key for [ssh] lifetime minutes)
  askpass <prompt> SSH_ASKPASS program: a passphrase popup (also as wlperch-askpass)
  lock [-f]        lock the screen (clock, notification count, media, battery);
                   -f forks once locked, for swayidle before-sleep
  sensors scan [seconds]  list the Tuya devices announcing themselves on the LAN
  sensors read <name|id>  query one configured Tuya device once (read-only)
  status media [prev|next]  waybar JSON: the playing track (click: play/pause),
                   or a previous / next button
  status [sensors|timer|notifications]  print waybar JSON every few seconds for a
                   custom module: the panel button (memory warning), a room
                   temperature + CO2, the running project timer, or a bell
                   with the unread notification count
`

App :: struct {
	running:     bool,
	wake_r:      posix.FD, // worker threads write here to wake the UI loop
	wake_w:      posix.FD,
	ipc_fd:      posix.FD,
	show_time:   time.Tick,
	frame_count: int,
}
app: App

// Wake the main loop from any thread (e.g. new data arrived).
wake_ui :: proc "contextless" () {
	if !plat_visible_flag {return}
	b := u8(1)
	posix.write(app.wake_w, &b, 1)
}

// For samplers that refresh about once a second: no wake of its own. The
// main loop's once-per-second tick draws the new values, so the samples
// don't each cost a frame of their own out of phase with the tick.
wake_ui_lazy :: proc "contextless" () {}

// Wake the main loop regardless of visibility (e.g. the time tracker).
wake_main :: proc "contextless" () {
	b := u8(1)
	posix.write(app.wake_w, &b, 1)
}

// Visibility mirror readable from worker threads without locking.
plat_visible_flag: bool

// Opened by "toggle --center": no anchor, so the compositor centres it.
popup_centered: bool

// Opened by "toggle --at OUTPUT:X:WIDTH" (the bar): under that spot of the
// output, kept inside its edges.
Popup_At :: struct {
	set:    bool,
	output: string,
	x, w:   i32, // logical x of the clicked item's centre, the output's width
}
popup_at: Popup_At

parse_popup_at :: proc(s: string) -> (at: Popup_At, ok: bool) {
	f := strings.split(s, ":", context.temp_allocator)
	if len(f) != 3 {return}
	x, xok := strconv.parse_int(f[1])
	w, wok := strconv.parse_int(f[2])
	if !xok || !wok || w <= 0 {return}
	return {true, f[0], i32(x), i32(w)}, true
}

show_popup :: proc() {
	if platform_visible() {return}
	w, h := popup_size()
	placement := popup_placement()
	if popup_centered {
		placement.anchor = 0
		placement.margin = {}
	} else if popup_at.set {
		vertical := config.anchor & (wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM)
		if vertical == 0 {vertical = wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP}
		placement.anchor = vertical | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT
		placement.output = popup_at.output
		edge := config.margin[1] - (SHADOW - SHADOW_BASE)
		right := popup_at.w - popup_at.x - w / 2
		placement.margin[1] = clamp(right, edge, max(popup_at.w - w - edge, edge))
	}
	if platform_show(placement, w, h) {
		plat_visible_flag = true
		app.show_time = time.tick_now()
		countdown_on_popup_shown()
		on_show()
	}
}

hide_popup :: proc() {
	if !platform_visible() && plat.surface == nil {return}
	platform_hide()
	plat_visible_flag = false
	hidden_since = time.tick_now()
	countdown_on_popup_hidden()
	on_hide()
}

// Commands: toggle|show [panel], hide, quit, restart, daemon, ping.
handle_command :: proc(line: string) -> string {
	if strings.has_prefix(line, "track rename") {return track_rename_ipc(line)}
	f := strings.fields(line, context.temp_allocator)
	center := false
	at: Popup_At
	if len(f) > 0 && (f[0] == "toggle" || f[0] == "show") {
		kept := make([dynamic]string, 0, len(f), context.temp_allocator)
		for i := 0; i < len(f); i += 1 {
			w := f[i]
			switch {
			case w == "--center" || w == "--centre":
				center = true
			case w == "--at" && i + 1 < len(f):
				i += 1
				at, _ = parse_popup_at(f[i])
			case:
				append(&kept, w)
			}
		}
		f = kept[:]
	}
	if len(f) == 0 {return "unknown command\n"}
	cmd := f[0]
	target := -1
	if len(f) > 1 && (cmd == "toggle" || cmd == "show") {
		target = panel_find(f[1])
		if target < 0 {return "unknown panel\n"}
	}
	switch cmd {
	case "toggle":
		// From the bar, another module's panel opens under that module.
		moved := at.set && (!popup_at.set || at.output != popup_at.output || abs(at.x - popup_at.x) > 2)
		if platform_visible() && moved && target >= 0 && target != current_panel {hide_popup()}
		if platform_visible() {
			if target < 0 || target == current_panel {hide_popup()} else {switch_panel(target)}
		} else {
			current_panel = target >= 0 ? target : 0
			popup_centered = center
			set_popup_at(at)
			show_popup()
		}
	case "show":
		if platform_visible() {
			if target >= 0 && target != current_panel {switch_panel(target)}
		} else {
			current_panel = target >= 0 ? target : 0
			popup_centered = center
			set_popup_at(at)
			show_popup()
		}
	case "hide":
		hide_popup()
	case "quit":
		app.running = false
	case "restart":
		restart_requested = true
	case "audio":
		if len(f) < 2 {return "usage: audio refresh|restart\n"}
		msg: string
		ok: bool
		switch f[1] {
		case "refresh": msg, ok = audio_bounce_profile()
		case "restart": msg, ok = audio_restart()
		case:           return "usage: audio refresh|restart\n"
		}
		if platform_visible() {toast(msg)}
		return ok ? "ok\n" : strings.concatenate({msg, "\n"}, context.temp_allocator)
	case "track":
		if len(f) < 2 {return "usage: track <project> | track lock [on|off]\n"}
		if f[1] == "keep" {
			mode := len(f) > 2 ? f[2] : "toggle"
			switch mode {
			case "on":     placeholders_set_keep(true)
			case "off":    placeholders_set_keep(false)
			case "toggle": placeholders_set_keep(!placeholders.keep)
			case:          return "usage: track keep [on|off]\n"
			}
			return placeholders.keep ? "keep on\n" : "keep off\n"
		}
		if f[1] == "lock" {
			mode := len(f) > 2 ? f[2] : "toggle"
			switch mode {
			case "on":     tracker_set_lock(true)
			case "off":    tracker_set_lock(false)
			case "toggle": tracker_set_lock(!tracker.lock)
			case:          return "usage: track lock [on|off]\n"
			}
			return tracker.lock ? "lock on\n" : "lock off\n"
		}
		// track pin [project|off]: gather windows into one project for a minute.
		if f[1] == "pin" {
			if len(f) > 2 && f[2] == "off" {
				tracker_unpin()
				return "ok\n"
			}
			i := tracker_current_project()
			if len(f) > 2 {i = project_find(strings.join(f[2:], " ", context.temp_allocator))}
			if i < 0 {return "no project (name one, or work in one first)\n"}
			tracker_pin(i)
			return "ok\n"
		}
		// track go|move [project]: the current/last project by default.
		if f[1] == "go" || f[1] == "move" {
			i := tracker_current_project()
			if len(f) > 2 {i = project_find(strings.join(f[2:], " ", context.temp_allocator))}
			if i < 0 {return "no project (name one, or work in one first)\n"}
			if f[1] == "go" {
				tracker_start(i)
			} else if !tracker_move_window(i) {
				return "move failed\n"
			}
			return "ok\n"
		}
		i := project_find(strings.join(f[1:], " ", context.temp_allocator))
		if i < 0 {return "unknown project\n"}
		tracker_start(i)
		return "ok\n"
	case "notify":
		sub := len(f) > 1 ? f[1] : "status"
		switch sub {
		case "status":
			// unread dnd owner held cover outputs: cover is game / fullscreen / -,
			// outputs the covered connectors popups keep off (comma-separated).
			outs, game := fullscreen_blocked()
			cover := len(outs) == 0 ? "-" : game ? "game" : "fullscreen"
			list := len(outs) == 0 ? "-" : strings.join(outs, ",", context.temp_allocator)
			return fmt.tprintf("%d %d %d %d %s %s\n", notif_unread(), int(notifs.dnd), int(notifs.owner), notif_held_count(), cover, list)
		case "dnd":
			mode := len(f) > 2 ? f[2] : "toggle"
			switch mode {
			case "on":     notif_set_dnd(true)
			case "off":    notif_set_dnd(false)
			case "toggle": notif_set_dnd(!notifs.dnd)
			case:          return "usage: notify dnd [on|off]\n"
			}
			return notifs.dnd ? "dnd on\n" : "dnd off\n"
		case "clear":
			notif_clear_all()
		case "dismiss":
			for n in notifs.list {if n.popup {n.popup = false; n.read = true; notif_close(n.id, .Dismissed)}}
		case:
			return "usage: notify [status|dnd [on|off]|clear|dismiss]\n"
		}
	case "lockinfo":
		countdown_on_locked()
		return lock_info_reply()
	case "countdown-preview":
		return countdown_preview(len(f) > 1 ? strconv.parse_int(f[1]) or_else 0 : 0)
	case "theme":
		return theme_command(f[1:])
	case "ssh":
		return ssh_command(f[1:])
	case "daemon", "ping":
	case:
		return "unknown command\n"
	}
	return "ok\n"
}

set_popup_at :: proc(at: Popup_At) {
	delete(popup_at.output)
	popup_at = at
	popup_at.output = strings.clone(at.output)
}

// Swap the content of the open popup for another panel.
switch_panel :: proc(index: int) {
	current_panel = index
	w, h := popup_size()
	platform_request_size(w, h)
	app.show_time = time.tick_now() // replay the fade so the swap feels intentional
	on_show()
	request_redraw()
}

main :: proc() {
	level := os.get_env("WLPERCH_DEBUG", context.temp_allocator) != "" ? log.Level.Debug : log.Level.Info
	context.logger = log.create_console_logger(level, {.Level, .Terminal_Color, .Time})

	// ssh-add runs SSH_ASKPASS as one program name with the prompt as its
	// argument: wlperch-askpass, or this binary marked by the environment.
	if filepath.base(os.args[0]) == "wlperch-askpass" || os.get_env("WLPERCH_ASKPASS", context.temp_allocator) == "1" {
		posix.unsetenv("WLPERCH_ASKPASS")
		os.exit(askpass_main(os.args[1:]))
	}
	migrate_old_name()
	// sway runs swaybar_command as one program name: "wlperch-bar" is the bar.
	if filepath.base(os.args[0]) == "wlperch-bar" {
		config_load()
		os.exit(bar_main(os.args[1:]))
	}
	cmd := len(os.args) > 1 ? os.args[1] : "toggle"
	// Full command line for the daemon, e.g. "toggle perf".
	full := len(os.args) > 1 ? strings.join(os.args[1:], " ") : "toggle"
	switch cmd {
	case "-h", "--help", "help":
		fmt.print(USAGE)
		return
	case "setup":
		run_setup()
		return
	case "toggle", "show", "hide", "quit", "daemon", "restart", "audio", "notify":
	case "track":
		if len(os.args) > 2 && os.args[2] == "rename" {os.exit(track_rename_cli(os.args[3:]))}
	case "media":
		os.exit(media_cli(os.args[2:]))
	case "calc":
		os.exit(calc_cli(os.args[2:]))
	case "bar":
		if len(os.args) > 2 && os.args[2] == "restart" {
			ok, msg := bar_restart()
			fmt.println(msg)
			os.exit(ok ? 0 : 1)
		}
		// Its own process too: see bar.odin.
		config_load()
		os.exit(bar_main(os.args[2:]))
	case "lock":
		// Its own process, never the daemon's: see lock.odin.
		config_load()
		os.exit(lock_main(os.args[2:]))
	case "display", "displays":
		os.exit(displays_cli(os.args[2:]))
	case "theme":
		os.exit(theme_cli(os.args[2:]))
	case "ssh":
		os.exit(ssh_cli(os.args[2:]))
	case "askpass":
		os.exit(askpass_main(os.args[2:]))
	case "sensors":
		config_load()
		os.exit(sensors_cli(os.args[2:]))
	case "status":
		config_load()
		if len(os.args) > 2 && os.args[2] == "sensors" {
			status_sensors_loop()
		} else if len(os.args) > 2 && os.args[2] == "media" {
			status_media_loop(len(os.args) > 3 ? os.args[3] : "")
		} else if len(os.args) > 2 && os.args[2] == "notifications" {
			status_notifications_loop()
		} else if len(os.args) > 2 && os.args[2] == "timer" {
			clocks_init()
			status_timer_loop()
		} else {
			status_loop()
		}
		return
	case:
		fmt.eprint(USAGE)
		os.exit(2)
	}

	resume_show := false
	if fd, ok, show := resume_from_args(); ok {
		app.ipc_fd = fd
		resume_show = show
	} else {
		if cmd == "notify" {
			if reply, ok := ipc_query(full); ok {fmt.print(reply)} else {fmt.eprintln("wlperch is not running")}
			return
		}
		if ipc_send(full) {return}
		if cmd == "quit" || cmd == "hide" || cmd == "restart" {return} // nothing running
		// Started from a download (not the installed copy, nothing running):
		// the first thing to show is setup.
		if len(os.args) == 1 && !is_installed_binary() {
			run_setup()
			return
		}

		// We are the daemon.
		app.ipc_fd = ipc_listen()
		if app.ipc_fd < 0 {
			log.error("cannot create control socket", ipc_socket_path())
			os.exit(1)
		}
	}
	defer {
		posix.close(app.ipc_fd)
		posix.unlink(cstring(raw_data(ipc_socket_path())))
	}
	fds: [2]posix.FD
	posix.pipe(&fds)
	app.wake_r, app.wake_w = fds[0], fds[1]
	set_cloexec_nonblock(app.wake_r)
	set_cloexec_nonblock(app.wake_w)
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	posix.signal(.SIGCHLD, auto_cast posix.SIG_DFL)
	// Logout / shutdown: leave the main loop normally so state gets saved.
	for sig in ([]posix.Signal{.SIGTERM, .SIGINT, .SIGHUP}) {posix.signal(sig, on_term_signal)}

	config_load()
	log.debugf("rss after config: %d kB", rss_kb())

	t0 := time.tick_now()
	restrict_egl_vendor() // touches the environment: before any thread exists
	ssh_session_env_init() // idem
	if !platform_init() {os.exit(1)}
	log.debugf("platform_init took %v, rss %d kB", time.tick_since(t0), rss_kb())

	im_init()

	t0 = time.tick_now()
	if !perf_resumed {perf_load()}
	perf_start_saver()
	services_start()
	tracker_init()
	placeholders_init()
	notifications_start()
	countdown_init()
	log.debugf("services_start took %v, rss %d kB", time.tick_since(t0), rss_kb())

	if resume_show {
		if i := panel_find(resume_panel); i >= 0 {current_panel = i}
		show_popup()
	} else if cmd == "toggle" || cmd == "show" {
		if r := handle_command(full); r != "ok\n" {log.errorf("%s: %s", full, strings.trim_space(r))}
	}

	app.running = true
	for app.running && !term_requested {
		loop_iteration()
	}
	if term_requested {log.info("terminating on signal")}

	perf_save()
	tracker_shutdown()
	notifications_shutdown()
	placeholders_destroy_all()
	hide_popup()
	if plat.gl_ready {imgl.Shutdown()}
}

imgl_ready: bool

term_requested: bool

on_term_signal :: proc "c" (sig: posix.Signal) {
	term_requested = true
	b := u8(1)
	posix.write(app.wake_w, &b, 1) // interrupt poll()
}

OPEN_ANIM :: 140 * time.Millisecond

// 0 -> 1 ease-out progress of the open animation.
open_progress :: proc() -> f32 {
	t := f32(time.duration_seconds(time.tick_since(app.show_time)) / time.duration_seconds(OPEN_ANIM))
	if t >= 1 {return 1}
	u := 1 - t
	return 1 - u * u * u
}

hidden_since: time.Tick
last_render_second: i64
restart_requested: bool

rss_kb :: proc() -> int {
	data, err := os.read_entire_file("/proc/self/statm", context.temp_allocator)
	if err != nil {return 0}
	f := strings.fields(string(data), context.temp_allocator)
	if len(f) < 2 {return 0}
	pages, _ := strconv.parse_int(f[1])
	return pages * 4
}

im_init :: proc() {
	im.CHECKVERSION()
	im.CreateContext()
	io := im.GetIO()
	io.IniFilename = nil
	io.ConfigFlags += {.NavEnableKeyboard}
	io.BackendFlags += {.HasMouseCursors}
	theme_init_mode()
	theme_init()
}

// The setup window: same pipeline, its own UI, no auto-sizing.
render_setup_frame :: proc() {
	if !imgl_ready {
		imgl.Init("#version 330 core")
		imgl_ready = true
	}
	platform_begin_frame()
	imgl.NewFrame()
	im.NewFrame()
	draw_setup()
	im.Render()
	platform_set_cursor(im.GetMouseCursor())
	bw, bh := platform_buffer_size()
	gl.Viewport(0, 0, bw, bh)
	gl.ClearColor(0, 0, 0, 0)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	imgl.RenderDrawData(im.GetDrawData())
	platform_end_frame()
}

render_frame :: proc() {
	if !imgl_ready {
		imgl.Init("#version 330 core")
		imgl_ready = true
	}
	platform_begin_frame()
	imgl.NewFrame()
	im.NewFrame()

	content_h := draw_ui()

	im.Render()
	platform_set_cursor(im.GetMouseCursor())

	bw, bh := platform_buffer_size()
	gl.Viewport(0, 0, bw, bh)
	gl.ClearColor(0, 0, 0, 0)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	imgl.RenderDrawData(im.GetDrawData())
	if e := open_progress(); e < 1 {
		fade_apply(e)
		request_redraw(1)
	}
	platform_end_frame()
	app.frame_count += 1
	if ui.shown_frames == 1 {log.debugf("first frame %v after show", time.tick_since(app.show_time))}
	log.debugf("frame %d %dx%d@%.2f content_h=%.1f", app.frame_count, plat.width, plat.height, platform_scale(), content_h)

	if content_h > 0 {
		h := i32(content_h + 0.5)
		if h != plat.height {platform_request_height(h)}
	}
}

// New data from worker threads is drawn once this long after the first wake.
DATA_COALESCE :: 60 * time.Millisecond
@(private = "file") data_due: time.Tick

loop_iteration :: proc() {
	d := plat.display
	for wl.display_prepare_read(d) != 0 {wl.display_dispatch_pending(d)}
	wl.display_flush(d)

	// Work out how long we may sleep.
	timeout := -1
	if platform_visible() {
		if plat.redraw > 0 && !plat.frame_pending {
			timeout = 0
		} else {
			// Tick once per second for clocks/graphs (aligned to the wall clock).
			now := time.now()
			ns := time.duration_nanoseconds(time.Duration(time.to_unix_nanoseconds(now) % i64(time.Second)))
			timeout = int((i64(time.Second) - ns) / i64(time.Millisecond)) + 1
		}
		if r := platform_key_repeat(); r >= 0 {
			timeout = min(timeout < 0 ? max(int) : timeout, int(time.duration_milliseconds(r)) + 1)
		}
	} else if plat.egl_context != nil && config.release_gpu_after > 0 && !countdown_holds_reexec() && !ssh_busy() {
		// Wake up to release GPU resources once we've been hidden long enough.
		// (Not while the idle countdown holds it: its events wake us.)
		left := config.release_gpu_after - time.tick_since(hidden_since)
		timeout = max(int(time.duration_milliseconds(left)), 0) + 1
	}
	if data_due != {} && platform_visible() {
		ms := max(int(time.duration_milliseconds(time.tick_diff(time.tick_now(), data_due))), 0) + 1
		timeout = timeout < 0 ? ms : min(timeout, ms)
	}
	if hb := tracker_timeout(); hb >= 0 {
		ms := int(time.duration_milliseconds(hb)) + 1
		timeout = timeout < 0 ? ms : min(timeout, ms)
	}
	if pc := placeholders_timeout(); pc >= 0 {
		ms := int(time.duration_milliseconds(pc)) + 1
		timeout = timeout < 0 ? ms : min(timeout, ms)
	}
	if nt := notifications_timeout(); nt >= 0 {
		ms := int(time.duration_milliseconds(nt)) + 1
		timeout = timeout < 0 ? ms : min(timeout, ms)
	}
	if mt := memwarn_timeout(); mt >= 0 {
		ms := int(time.duration_milliseconds(mt)) + 1
		timeout = timeout < 0 ? ms : min(timeout, ms)
	}
	if ct := countdown_timeout(); ct >= 0 {
		ms := int(time.duration_milliseconds(ct)) + 1
		timeout = timeout < 0 ? ms : min(timeout, ms)
	}
	if st := ssh_timeout(); st >= 0 {
		ms := int(time.duration_milliseconds(st)) + 1
		timeout = timeout < 0 ? ms : min(timeout, ms)
	}

	bus_fd, bus_events := notifications_fd()
	pfds := [4]posix.pollfd {
		{fd = platform_fd(), events = {.IN}},
		{fd = app.wake_r, events = {.IN}},
		{fd = app.ipc_fd, events = {.IN}},
		{fd = posix.FD(bus_fd), events = transmute(posix.Poll_Event)bus_events},
	}
	n := posix.poll(&pfds[0], len(pfds), i32(timeout))
	if n < 0 {
		wl.display_cancel_read(d)
		return
	}
	if .IN in pfds[0].revents {
		wl.display_read_events(d)
	} else {
		wl.display_cancel_read(d)
	}
	if .HUP in pfds[0].revents || .ERR in pfds[0].revents {
		log.error("wayland connection lost")
		app.running = false
		return
	}
	wl.display_dispatch_pending(d)

	if .IN in pfds[1].revents {
		buf: [64]u8
		for posix.read(app.wake_r, &buf[0], len(buf)) > 0 {}
		// The samplers (cpu, procs, network, audio…) each wake us about once a
		// second, a few ms apart: one frame for the whole burst, not one each.
		if data_due == {} {data_due = time.tick_add(time.tick_now(), DATA_COALESCE)}
	}
	if data_due != {} && time.tick_diff(data_due, time.tick_now()) >= 0 {
		data_due = {}
		request_redraw(1)
	}
	if .IN in pfds[2].revents {
		if cmd, client, ok := ipc_accept(app.ipc_fd); ok {
			ipc_reply(client, handle_command(cmd))
		}
	}

	tracker_tick()
	placeholders_tick()
	notifications_tick()
	memwarn_tick()
	countdown_tick()
	ssh_tick()

	// (Not while ssh-add waits for a passphrase: a re-exec would kill it.)
	if restart_requested && !ssh_busy() {
		restart_requested = false
		was_visible := platform_visible()
		hide_popup()
		notifications_save()
		wl.display_flush(d)
		reexec_self(was_visible)
		log.error("restart failed")
		if was_visible {show_popup()}
		return
	}

	if platform_visible() {
		if plat.closed {
			hide_popup()
			return
		}
		if hide_requested {
			hide_requested = false
			hide_popup()
			return
		}
		// Losing keyboard focus is NOT a reason to close: overlays such as
		// slurp (screenshot region selection) grab it temporarily.
		if plat.outside_click && config.close_on_click_outside {
			hide_popup()
			return
		}
		// Once-per-second tick for the clocks, unless something else already
		// redrew during this second (the CPU sampler usually does).
		sec := time.to_unix_seconds(time.now())
		if n == 0 && plat.redraw == 0 && sec != last_render_second {request_redraw(1)}
		if plat.redraw > 0 && platform_can_render() {
			plat.redraw -= 1
			last_render_second = sec
			render_frame()
		}
	} else if plat.egl_context != nil && config.release_gpu_after > 0 && time.tick_since(hidden_since) >= config.release_gpu_after && !notifications_busy() && !memwarn_busy() && !countdown_holds_reexec() && !ssh_busy() {
		// The GPU driver keeps its memory after eglTerminate; a fresh process image doesn't.
		// (Not while notification popups are up: they'd vanish.)
		notifications_save()
		reexec_self()
		// exec failed: at least release what we can and carry on.
		gl_down(proc() {
			fade_reset()
			notif_textures_reset()
			emoji_textures_reset()
			if imgl_ready {
				imgl.Shutdown()
				imgl_ready = false
			}
		})
	}
	free_all(context.temp_allocator)
}
