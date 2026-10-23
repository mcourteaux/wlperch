// Placeholder windows: keep empty project workspaces alive. Sway removes a
// workspace as soon as it is empty and not focused; with "keep workspaces" on,
// every empty project workspace gets a content-less regular window (titled
// "<workspace> · placeholder"). It closes as soon as a real window arrives.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

import "wl"

@(private = "file")
Placeholder :: struct {
	ws:         string,
	title:      string,
	surface:    ^wl.Surface,
	xdg:        ^wl.Xdg_Surface,
	toplevel:   ^wl.Xdg_Toplevel,
	viewport:   ^wl.Wp_Viewport,
	w, h:       i32,
	configured: bool,
	mapped_at:  time.Tick,
	moved:      bool,
	closed:     bool, // the user closed it
}

Placeholders :: struct {
	keep:      bool,
	keep_path: string,
	list:      [dynamic]^Placeholder,
	ruled:     map[string]bool, // for_window rules installed this session
	dismissed: map[string]bool, // workspaces whose placeholder the user closed
	buffer:    ^wl.Buffer,
}
placeholders: Placeholders

placeholders_init :: proc() {
	placeholders.keep_path = strings.concatenate({data_dir(), "/timetracker.keep"})
	placeholders.keep = os.exists(placeholders.keep_path)
}

placeholders_set_keep :: proc(on: bool) {
	placeholders.keep = on
	if on {
		_ = os.write_entire_file(placeholders.keep_path, "on\n")
	} else {
		os.remove(placeholders.keep_path)
	}
	request_redraw()
	wake_main()
}

@(private = "file")
regex_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in s {
		if strings.contains_rune(`\.^$*+?()[]{}|"`, c) {strings.write_byte(&b, '\\')}
		strings.write_rune(&b, c)
	}
	return strings.to_string(b)
}

@(private = "file")
criteria :: proc(title: string) -> string {
	return fmt.tprintf(`[app_id="%s" title="^%s$"]`, PLACEHOLDER_APP_ID, regex_escape(title))
}

@(private = "file")
toplevel_listener := wl.Xdg_Toplevel_Listener {
	configure = proc "c" (data: rawptr, self: ^wl.Xdg_Toplevel, width, height: i32, states: ^wl.Array) {
		p := cast(^Placeholder)data
		if width > 0 && height > 0 {p.w, p.h = width, height}
	},
	close = proc "c" (data: rawptr, self: ^wl.Xdg_Toplevel) {
		(cast(^Placeholder)data).closed = true
	},
	configure_bounds = proc "c" (data: rawptr, self: ^wl.Xdg_Toplevel, width, height: i32) {},
	wm_capabilities = proc "c" (data: rawptr, self: ^wl.Xdg_Toplevel, capabilities: ^wl.Array) {},
}

@(private = "file")
xdg_surface_listener := wl.Xdg_Surface_Listener {
	configure = proc "c" (data: rawptr, self: ^wl.Xdg_Surface, serial: u32) {
		p := cast(^Placeholder)data
		wl.xdg_surface_ack_configure(self, serial)
		if p.w <= 0 || p.h <= 0 {p.w, p.h = 640, 400}
		wl.wp_viewport_set_destination(p.viewport, p.w, p.h)
		if !p.configured {
			wl.surface_attach(p.surface, placeholders.buffer, 0, 0)
			wl.surface_damage_buffer(p.surface, 0, 0, 1, 1)
			p.configured = true
			p.mapped_at = time.tick_now()
		}
		wl.surface_commit(p.surface)
	},
}

@(private = "file")
spawn :: proc(ws: string) {
	if plat.xdg_wm_base == nil || plat.single_pixel == nil || plat.viewporter == nil {return}
	if placeholders.buffer == nil {
		// #111318, the panel background.
		c :: proc(v: u32) -> u32 {return u32(u64(v) * 0xffffffff / 255)}
		placeholders.buffer = wl.wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(plat.single_pixel, c(0x11), c(0x13), c(0x18), 0xffffffff)
	}
	p := new(Placeholder)
	p.ws = strings.clone(ws)
	p.title = fmt.aprintf("%s · placeholder", ws)
	// Send it straight to its workspace when it maps (no flash elsewhere).
	if !placeholders.ruled[ws] {
		sway_command(fmt.tprintf(`for_window %s move container to workspace "%s"`, criteria(p.title), ws))
		placeholders.ruled[strings.clone(ws)] = true
	}
	p.surface = wl.compositor_create_surface(plat.compositor)
	p.viewport = wl.wp_viewporter_get_viewport(plat.viewporter, p.surface)
	p.xdg = wl.xdg_wm_base_get_xdg_surface(plat.xdg_wm_base, p.surface)
	wl.xdg_surface_add_listener(p.xdg, &xdg_surface_listener, p)
	p.toplevel = wl.xdg_surface_get_toplevel(p.xdg)
	wl.xdg_toplevel_add_listener(p.toplevel, &toplevel_listener, p)
	wl.xdg_toplevel_set_app_id(p.toplevel, PLACEHOLDER_APP_ID)
	wl.xdg_toplevel_set_title(p.toplevel, strings.clone_to_cstring(p.title, context.temp_allocator))
	wl.surface_commit(p.surface)
	append(&placeholders.list, p)
	log.debugf("placeholder for %q", ws)
}

@(private = "file")
destroy :: proc(i: int) {
	p := placeholders.list[i]
	wl.xdg_toplevel_destroy(p.toplevel)
	wl.xdg_surface_destroy(p.xdg)
	wl.wp_viewport_destroy(p.viewport)
	wl.surface_destroy(p.surface)
	delete(p.ws)
	delete(p.title)
	free(p)
	ordered_remove(&placeholders.list, i)
}

placeholders_destroy_all :: proc() {
	for len(placeholders.list) > 0 {destroy(len(placeholders.list) - 1)}
}

// Called every main-loop iteration.
placeholders_tick :: proc() {
	if !placeholders.keep {
		placeholders_destroy_all()
		return
	}
	counts := make(map[string]int, 32, context.temp_allocator)
	{
		sync.guard(&sway.mu)
		for k, v in sway.ws_windows {counts[strings.clone(k, context.temp_allocator)] = v}
	}

	// Closed by the user, or a real window arrived: the placeholder goes.
	for i := len(placeholders.list) - 1; i >= 0; i -= 1 {
		p := placeholders.list[i]
		if p.closed {
			placeholders.dismissed[strings.clone(p.ws)] = true
			destroy(i)
		} else if counts[p.ws] > 0 {
			destroy(i)
		}
	}
	// Fallback for when the for_window rule is gone (e.g. after a sway reload).
	for p in placeholders.list {
		if p.configured && !p.moved && time.tick_since(p.mapped_at) > 300 * time.Millisecond {
			sway_command(fmt.tprintf(`%s move container to workspace "%s"`, criteria(p.title), p.ws))
			p.moved = true
		}
	}
	// Every existing, empty project workspace gets one.
	for ws, n in counts {
		if n > 0 || project_for_workspace(ws) < 0 || placeholders.dismissed[ws] {continue}
		has := false
		for p in placeholders.list {if p.ws == ws {has = true}}
		if !has {spawn(ws)}
	}
	// Forget dismissals once the workspace is gone.
	for ws in placeholders.dismissed {
		if ws not_in counts {
			delete_key(&placeholders.dismissed, ws)
			delete(ws)
			break // map changed; continue next tick
		}
	}
}
