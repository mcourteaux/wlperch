// The daemon's idle inhibitor, shared by everything that keeps the session
// awake: a fullscreen game (game_hold.odin) and `wlperch idle hold`
// (idle_hold.odin). While any of them wants it, the daemon holds one
// zwp_idle_inhibitor_v1; swayidle, the idle countdown and wlperch's own
// idle lock and monitors-off (ext-idle-notify) all honour it.
//
// Where it sits matters. Sway counts an application inhibitor only when its
// surface is on screen: a view that's visible, or (sway 1.12) a layer
// surface mapped on an enabled output; a surface without a role counts as
// invisible there (older sway assumed it visible). So the inhibitor sits on
// a mapped 1×1 layer surface in the background layer: fully transparent,
// no input region, no keyboard, no exclusive zone. When its output goes
// away (`closed`), it's made again on another output, as soon as there is
// one.
package main

import "wl"

Awake_Owner :: enum {
	Game,  // a fullscreen game
	Holds, // `wlperch idle hold`
}

@(private = "file")
aw: struct {
	want:      bit_set[Awake_Owner],
	surface:   ^wl.Surface,
	layer:     ^wl.Zwlr_Layer_Surface_V1,
	buffer:    ^wl.Buffer,
	inhibitor: ^wl.Zwp_Idle_Inhibitor_V1,
	closed:    bool, // its output went away: make it again
}

// An owner wants the session kept awake, or no longer does.
awake_want :: proc(owner: Awake_Owner, on: bool) {
	if on {aw.want += {owner}} else {aw.want -= {owner}}
	awake_tick()
}

// Whether the inhibitor is in place (for tests and status).
awake_held :: proc() -> bool {return aw.inhibitor != nil}

// Main loop: (re)make or drop the inhibitor to match what's wanted.
awake_tick :: proc() {
	if aw.closed {
		destroy()
		aw.closed = false
	}
	if aw.want == {} {
		destroy()
		return
	}
	if aw.surface != nil || plat.compositor == nil || plat.inhibit_mgr == nil {return}
	if plat.layer_shell == nil || plat.single_pixel == nil {
		// No layer shell or single-pixel buffers: a surface without a role,
		// which older sway counted as visible.
		aw.surface = wl.compositor_create_surface(plat.compositor)
		aw.inhibitor = wl.zwp_idle_inhibit_manager_v1_create_inhibitor(plat.inhibit_mgr, aw.surface)
		return
	}
	if len(plat.outputs) == 0 {return} // again when an output appears
	aw.surface = wl.compositor_create_surface(plat.compositor)
	r := wl.compositor_create_region(plat.compositor)
	wl.surface_set_input_region(aw.surface, r)
	wl.region_destroy(r)
	aw.buffer = wl.wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(plat.single_pixel, 0, 0, 0, 0)
	aw.layer = wl.zwlr_layer_shell_v1_get_layer_surface(plat.layer_shell, aw.surface, plat.outputs[0].output, wl.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "wlperch-awake")
	wl.zwlr_layer_surface_v1_add_listener(aw.layer, &layer_listener, nil)
	wl.zwlr_layer_surface_v1_set_anchor(aw.layer, wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT)
	wl.zwlr_layer_surface_v1_set_size(aw.layer, 1, 1)
	wl.zwlr_layer_surface_v1_set_exclusive_zone(aw.layer, 0)
	wl.zwlr_layer_surface_v1_set_keyboard_interactivity(aw.layer, wl.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE)
	wl.surface_commit(aw.surface)
}

@(private = "file")
destroy :: proc() {
	if aw.inhibitor != nil {wl.zwp_idle_inhibitor_v1_destroy(aw.inhibitor)}
	if aw.layer != nil {wl.zwlr_layer_surface_v1_destroy(aw.layer)}
	if aw.surface != nil {wl.surface_destroy(aw.surface)}
	if aw.buffer != nil {wl.buffer_destroy(aw.buffer)}
	aw.inhibitor, aw.layer, aw.surface, aw.buffer = nil, nil, nil, nil
}

@(private = "file")
layer_listener := wl.Zwlr_Layer_Surface_V1_Listener {
	configure = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1, serial, width, height: u32) {
		wl.zwlr_layer_surface_v1_ack_configure(self, serial)
		if aw.inhibitor != nil {return}
		wl.surface_attach(aw.surface, aw.buffer, 0, 0)
		wl.surface_damage_buffer(aw.surface, 0, 0, 1, 1)
		wl.surface_commit(aw.surface)
		// After the commit that maps it: sway looks at the surface when the
		// inhibitor arrives.
		aw.inhibitor = wl.zwp_idle_inhibit_manager_v1_create_inhibitor(plat.inhibit_mgr, aw.surface)
	},
	closed = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1) {
		aw.closed = true
	},
}
