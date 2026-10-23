// Storage card: used space per mounted volume; external drives can be
// mounted, opened and ejected.
package main

import "core:fmt"
import "core:strings"
import "core:sync"

import im "third_party:odin-imgui"

@(private = "file")
Storage_Action :: struct {
	kind: enum {None, Open, Mount, Eject},
	path: string,
}

@(private = "file")
volume_name :: proc(v: Volume) -> string {
	for m in v.mountpoints {if m == "/" {return "System"}}
	if v.label != "" {return v.label}
	if len(v.mountpoints) > 0 {
		m := v.mountpoints[0]
		if i := strings.last_index_byte(m, '/'); i >= 0 && i + 1 < len(m) {return m[i + 1:]}
		return m
	}
	return fmt.tprintf("%s volume", fmt_disk(v.size))
}

// Bar color by how full a volume is.
@(private = "file")
fill_color :: proc(frac: f32) -> u32 {
	switch {
	case frac >= 0.95: return C_RED
	case frac >= 0.85: return C_ORANGE
	}
	return C_YELLOW
}

draw_storage :: proc(w: f32) {
	// Actions take the lock themselves, so they run after drawing.
	act := draw_storage_locked(w)
	switch act.kind {
	case .Open:
		run_async({"xdg-open", act.path})
		hide_requested = true
	case .Mount: storage_mount(act.path)
	case .Eject: storage_eject(act.path)
	case .None:
	}
}

@(private = "file")
draw_storage_locked :: proc(w: f32) -> (act: Storage_Action) {
	sync.guard(&storage.mu)
	if !storage.ok || len(storage.drives) == 0 {return}
	card_begin("storage", w)
	defer card_end()
	n_ext := 0
	for d in storage.drives {if d.external {n_ext += 1}}
	card_title(ICON_HARDDISK, "Storage", C_YELLOW, n_ext > 0 ? fmt.tprintf("%d external", n_ext) : "")

	inner := im.GetContentRegionAvail().x
	for d, di in storage.drives {
		if di > 0 {im.Dummy({1, 4})}
		// Drive header: icon, model, bus and size; eject for external drives.
		p := im.GetCursorScreenPos()
		dd := dl()
		draw_text(fonts.ui, 17, {p.x, p.y + 1}, col32(d.external ? C_YELLOW : C_MUTED), d.external ? ICON_USB_DRIVE : ICON_HARDDISK)
		model := d.model != "" ? d.model : d.path
		draw_text(fonts.bold, SZ_BODY, {p.x + 26, p.y + 2}, col32(C_TEXT), model)
		meta := fmt.tprintf("%s%s%s", strings.to_upper(d.tran, context.temp_allocator), d.tran != "" ? " · " : "", fmt_disk(d.size))
		msz := measure(fonts.ui, SZ_SMALL, meta)
		right := p.x + inner
		if d.external {
			if storage.busy == d.path {
				s := "ejecting…"
				ssz := measure(fonts.ui, SZ_SMALL, s)
				draw_text(fonts.ui, SZ_SMALL, {right - ssz.x, p.y + 4}, col32(C_ORANGE), s)
				right -= ssz.x + 10
				request_redraw(2)
			} else {
				im.SetCursorScreenPos({right - 26, p.y - 3})
				if icon_button(fmt.tprintf("##eject:%s", d.path), ICON_EJECT, C_YELLOW, 26, tooltip = fmt.tprintf("Eject %s: unmount and power off, then unplug", model)) {
					act = {.Eject, strings.clone(d.path, context.temp_allocator)}
				}
				right -= 34
			}
		}
		draw_text(fonts.ui, SZ_SMALL, {right - msz.x, p.y + 4}, col32(C_MUTED), meta)
		im.SetCursorScreenPos(p)
		im.Dummy({inner, 22})

		if d.external && len(d.volumes) == 0 {
			im.SetCursorPosX(im.GetCursorPosX() + 26)
			label(fonts.ui, SZ_SMALL, col32(C_FAINT), "no readable volumes")
		}
		for v in d.volumes {
			vp := im.GetCursorScreenPos()
			mounted := len(v.mountpoints) > 0
			busy := storage.busy == v.path
			x0 := vp.x + 26
			vw := inner - 26
			name := volume_name(v)
			if mounted {
				h: f32 = 40
				clicked := im.InvisibleButton(cstr(fmt.tprintf("vol:%s", v.path)), {inner, h})
				hovered := im.IsItemHovered()
				if hovered {
					im.SetMouseCursor(.Hand)
					im.DrawList_AddRectFilled(dd, {vp.x - 6, vp.y - 2}, {vp.x + inner + 6, vp.y + h}, col32(0xffffff, 0.05), 7)
					tip(fmt.tprintf("Open %s in the file manager\n%s · %s", v.mountpoints[0], v.path, v.fstype))
				}
				if clicked {act = {.Open, strings.clone(v.mountpoints[0], context.temp_allocator)}}
				frac := v.total > 0 ? f32(f64(v.used) / f64(v.total)) : 0
				col := fill_color(frac)
				draw_text(fonts.ui, SZ_BODY, {x0, vp.y + 2}, col32(C_TEXT, 0.9), name)
				nsz := measure(fonts.ui, SZ_BODY, name)
				// "/" first: btrfs subvolumes list e.g. /home before /.
				mps := make([]string, len(v.mountpoints), context.temp_allocator)
				copy(mps, v.mountpoints)
				for m, i in mps {if m == "/" {mps[0], mps[i] = mps[i], mps[0]}}
				where_ := strings.join(mps, " · ", context.temp_allocator)
				if where_ != name && where_ != fmt.tprintf("/%s", name) {
					draw_text(fonts.ui, SZ_SMALL, {x0 + nsz.x + 8, vp.y + 4}, col32(C_FAINT), where_)
				}
				free_s := fmt.tprintf("%s free", fmt_disk(v.total - min(v.used, v.total)))
				pct := fmt.tprintf("%d%%", int(frac * 100 + 0.5))
				psz := measure(fonts.mono, SZ_SMALL, pct)
				fsz := measure(fonts.ui, SZ_SMALL, free_s)
				draw_text(fonts.mono, SZ_SMALL, {x0 + vw - psz.x, vp.y + 3}, col32(frac >= 0.85 ? col : C_TEXT), pct)
				draw_text(fonts.ui, SZ_SMALL, {x0 + vw - psz.x - fsz.x - 10, vp.y + 4}, col32(C_MUTED), free_s)
				im.SetCursorScreenPos({x0, vp.y + 24})
				usage_bar(frac, col32(col, 0.85), {vw, 5})
				im.SetCursorScreenPos(vp)
				im.Dummy({inner, h})
			} else {
				h: f32 = 30
				draw_text(fonts.ui, SZ_BODY, {x0, vp.y + 5}, col32(C_TEXT, 0.6), name)
				nsz := measure(fonts.ui, SZ_BODY, name)
				draw_text(fonts.ui, SZ_SMALL, {x0 + nsz.x + 8, vp.y + 7}, col32(C_FAINT), fmt.tprintf("%s · %s · not mounted", v.fstype, fmt_disk(v.size)))
				if busy {
					s := "mounting…"
					ssz := measure(fonts.ui, SZ_SMALL, s)
					draw_text(fonts.ui, SZ_SMALL, {vp.x + inner - ssz.x, vp.y + 7}, col32(C_ORANGE), s)
					request_redraw(2)
				} else if storage.busy == "" {
					lbl := "Mount"
					im.SetCursorScreenPos({vp.x + inner - measure(fonts.bold, SZ_SMALL + 1, lbl).x - 24, vp.y + 1})
					if pill_button(fmt.tprintf("##mount:%s", v.path), lbl, C_YELLOW) {act = {.Mount, strings.clone(v.path, context.temp_allocator)}}
				}
				im.SetCursorScreenPos(vp)
				im.Dummy({inner, h})
			}
		}
	}
	if storage.message != "" {
		label(fonts.ui, SZ_SMALL, col32(storage.msg_ok ? C_GREEN : C_RED), fmt.tprintf("%s %s", storage.msg_ok ? ICON_CHECK : ICON_ALERT, storage.message))
	}
	return
}
