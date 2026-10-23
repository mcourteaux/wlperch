package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

import im "third_party:odin-imgui"
import imgl "third_party:odin-imgui/imgui_impl_opengl3"
import gl "vendor:OpenGL"

import "wl"

USAGE :: `wlwidgets — quick-settings popup for wlroots compositors

usage: wlwidgets [command]

commands:
  toggle   show the popup, or hide it when shown (default)
  show     show the popup
  hide     hide the popup
  daemon   start the background daemon without showing the popup
  quit     stop the running daemon
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

// Visibility mirror readable from worker threads without locking.
plat_visible_flag: bool

show_popup :: proc() {
	if platform_visible() {return}
	w, h := popup_size()
	if platform_show(popup_placement(), w, h) {
		plat_visible_flag = true
		app.show_time = time.tick_now()
		on_show()
	}
}

hide_popup :: proc() {
	if !platform_visible() && plat.surface == nil {return}
	platform_hide()
	plat_visible_flag = false
	hidden_since = time.tick_now()
	on_hide()
}

handle_command :: proc(cmd: string) -> string {
	switch cmd {
	case "toggle":
		if platform_visible() {hide_popup()} else {show_popup()}
	case "show":
		show_popup()
	case "hide":
		hide_popup()
	case "quit":
		app.running = false
	case "daemon", "ping":
	case:
		return "unknown command\n"
	}
	return "ok\n"
}

main :: proc() {
	level := os.get_env("WLWIDGETS_DEBUG", context.temp_allocator) != "" ? log.Level.Debug : log.Level.Info
	context.logger = log.create_console_logger(level, {.Level, .Terminal_Color, .Time})

	cmd := len(os.args) > 1 ? os.args[1] : "toggle"
	switch cmd {
	case "-h", "--help", "help":
		fmt.print(USAGE)
		return
	case "toggle", "show", "hide", "quit", "daemon":
	case:
		fmt.eprint(USAGE)
		os.exit(2)
	}

	if fd, ok := resume_from_args(); ok {
		app.ipc_fd = fd
	} else {
		if ipc_send(cmd) {return}
		if cmd == "quit" || cmd == "hide" {return} // nothing running

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

	config_load()
	log.debugf("rss after config: %d kB", rss_kb())

	t0 := time.tick_now()
	restrict_egl_vendor() // touches the environment: before any thread exists
	if !platform_init() {os.exit(1)}
	log.debugf("platform_init took %v, rss %d kB", time.tick_since(t0), rss_kb())

	im.CHECKVERSION()
	im.CreateContext()
	io := im.GetIO()
	io.IniFilename = nil
	io.ConfigFlags += {.NavEnableKeyboard}
	io.BackendFlags += {.HasMouseCursors}
	theme_init()

	t0 = time.tick_now()
	services_start()
	log.debugf("services_start took %v, rss %d kB", time.tick_since(t0), rss_kb())

	if cmd != "daemon" {show_popup()}

	app.running = true
	for app.running {
		loop_iteration()
	}

	hide_popup()
	if plat.gl_ready {imgl.Shutdown()}
}

imgl_ready: bool

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

rss_kb :: proc() -> int {
	data, err := os.read_entire_file("/proc/self/statm", context.temp_allocator)
	if err != nil {return 0}
	f := strings.fields(string(data), context.temp_allocator)
	if len(f) < 2 {return 0}
	pages, _ := strconv.parse_int(f[1])
	return pages * 4
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
	} else if plat.egl_context != nil && config.release_gpu_after > 0 {
		// Wake up to release GPU resources once we've been hidden long enough.
		left := config.release_gpu_after - time.tick_since(hidden_since)
		timeout = max(int(time.duration_milliseconds(left)), 0) + 1
	}

	pfds := [3]posix.pollfd {
		{fd = platform_fd(), events = {.IN}},
		{fd = app.wake_r, events = {.IN}},
		{fd = app.ipc_fd, events = {.IN}},
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
		request_redraw(1)
	}
	if .IN in pfds[2].revents {
		if cmd, client, ok := ipc_accept(app.ipc_fd); ok {
			ipc_reply(client, handle_command(cmd))
		}
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
		if (plat.focus_lost || plat.outside_click) && config.close_on_click_outside {
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
	} else if plat.egl_context != nil && config.release_gpu_after > 0 && time.tick_since(hidden_since) >= config.release_gpu_after {
		// The GPU driver keeps its memory after eglTerminate; a fresh process image doesn't.
		reexec_self()
		// exec failed: at least release what we can and carry on.
		gl_down(proc() {
			fade_reset()
			if imgl_ready {
				imgl.Shutdown()
				imgl_ready = false
			}
		})
	}
	free_all(context.temp_allocator)
}
