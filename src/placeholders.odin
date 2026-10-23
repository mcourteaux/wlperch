// Placeholder windows: keep empty project workspaces alive. Sway removes a
// workspace as soon as it is empty and not focused; with "keep workspaces" on,
// every empty project workspace gets a content-less regular window (titled
// "<workspace> · placeholder"). It closes as soon as a real window arrives.
package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"
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
	label_surf: ^wl.Surface,    // centered label, a subsurface
	label_sub:  ^wl.Subsurface,
	label_buf:  ^wl.Buffer,
	lw, lh:     i32,
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
	styled:    bool,            // global "no border" rule installed
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
		if p.label_sub != nil {
			wl.subsurface_set_position(p.label_sub, (p.w - p.lw) / 2, (p.h - p.lh) / 2)
		}
		if !p.configured {
			wl.surface_attach(p.surface, placeholders.buffer, 0, 0)
			wl.surface_damage_buffer(p.surface, 0, 0, 1, 1)
			if p.label_surf != nil {
				wl.surface_attach(p.label_surf, p.label_buf, 0, 0)
				wl.surface_damage_buffer(p.label_surf, 0, 0, p.lw, p.lh)
				wl.surface_commit(p.label_surf)
			}
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
		// #111318 (the panel background) at 55 %, premultiplied: the wallpaper shows through.
		c :: proc(v: f64) -> u32 {return u32(v * 0.55 / 255 * f64(max(u32)))}
		placeholders.buffer = wl.wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(plat.single_pixel, c(0x11), c(0x13), c(0x18), c(255))
	}
	if !placeholders.styled {
		sway_command(fmt.tprintf(`for_window [app_id="%s"] border none`, PLACEHOLDER_APP_ID))
		placeholders.styled = true
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
	make_label(p)
	wl.surface_commit(p.surface)
	append(&placeholders.list, p)
	log.debugf("placeholder for %q", ws)
}

@(private = "file")
destroy :: proc(i: int) {
	p := placeholders.list[i]
	if p.label_sub != nil {
		wl.subsurface_destroy(p.label_sub)
		wl.surface_destroy(p.label_surf)
		wl.buffer_destroy(p.label_buf)
	}
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
			sway_command(fmt.tprintf(`%s move container to workspace "%s", border none`, criteria(p.title), p.ws))
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

// Render the centered label ("ACME" / "workspace 2 · placeholder" / hint) into
// a shared-memory buffer on a subsurface. Software-rendered: placeholders must
// not need the GPU (the popup's GL state may be released).
@(private = "file")
make_label :: proc(p: ^Placeholder) {
	if plat.shm == nil || plat.subcompositor == nil {return}
	soft_fonts_init()
	name := p.ws
	color: u32 = C_TEXT
	number := ""
	if pi := project_for_workspace(p.ws); pi >= 0 {
		pr := tracker.projects[pi]
		name = pr.name
		color = pr.color
		number = strings.trim_space(p.ws[len(pr.name):])
	}
	line2 := number != "" ? fmt.tprintf("workspace %s  ·  placeholder", number) : "placeholder"
	line3 := "Move a window here to start working"
	PX1 :: 34
	PX2 :: 15
	PX3 :: 13
	w1 := soft_text_width(&soft_bold, PX1, name)
	w2 := soft_text_width(&soft_regular, PX2, line2)
	w3 := soft_text_width(&soft_regular, PX3, line3)
	pad: f32 = 26
	lw := i32(max(w1, w2, w3) + pad * 2)
	b1 := pad + soft_ascent(&soft_bold, PX1)
	b2 := b1 + 28
	b3 := b2 + 24
	lh := i32(b3 + pad * 0.8)

	size := int(lw * lh * 4)
	fd, err := linux.memfd_create("wlwidgets-label", {.CLOEXEC})
	if err != .NONE {return}
	defer linux.close(fd)
	if linux.ftruncate(fd, i64(size)) != .NONE {return}
	mem := posix.mmap(nil, uint(size), {.READ, .WRITE}, {.SHARED}, posix.FD(fd), 0)
	if mem == posix.MAP_FAILED {return}
	pixels := ([^]u32)(mem)[:lw * lh]

	// Soft dark rounded card behind the text, for contrast over any wallpaper.
	radius: f32 = 16
	for y in 0 ..< int(lh) {
		for x in 0 ..< int(lw) {
			// Signed distance to the rounded rectangle edge (for antialiasing).
			fx, fy := f32(x) + 0.5, f32(y) + 0.5
			cx := clamp(fx, radius, f32(lw) - radius)
			cy := clamp(fy, radius, f32(lh) - radius)
			dx, dy := fx - cx, fy - cy
			d := radius - math.sqrt(dx * dx + dy * dy)
			cov := clamp(d + 0.5, 0, 1) * 0.72
			a := u32(cov * 255 + 0.5)
			pixels[y * int(lw) + x] = a << 24 | u32(0x11 * cov) << 16 | u32(0x13 * cov) << 8 | u32(0x18 * cov)
		}
	}
	soft_draw_text(pixels, int(lw), int(lh), &soft_bold, PX1, (f32(lw) - w1) / 2, b1, name, color)
	soft_draw_text(pixels, int(lw), int(lh), &soft_regular, PX2, (f32(lw) - w2) / 2, b2, line2, C_TEXT, 0.85)
	soft_draw_text(pixels, int(lw), int(lh), &soft_regular, PX3, (f32(lw) - w3) / 2, b3, line3, C_MUTED)
	posix.munmap(mem, uint(size))

	pool := wl.shm_create_pool(plat.shm, i32(fd), i32(size))
	p.label_buf = wl.shm_pool_create_buffer(pool, 0, lw, lh, lw * 4, wl.SHM_FORMAT_ARGB8888)
	wl.shm_pool_destroy(pool)
	p.lw, p.lh = lw, lh
	p.label_surf = wl.compositor_create_surface(plat.compositor)
	p.label_sub = wl.subcompositor_get_subsurface(plat.subcompositor, p.label_surf, p.surface)
	// Clicks go to the placeholder window itself.
	region := wl.compositor_create_region(plat.compositor)
	wl.surface_set_input_region(p.label_surf, region)
	wl.region_destroy(region)
}
