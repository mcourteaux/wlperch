// The setup window's Settings tab: the config.ini keys people commonly change
// (SETTINGS in config_edit.odin), grouped into cards, each with the right
// control, its help line and a reset. Edits are written with config_set_value
// (comments and layout kept), debounced, and applied: the daemon restarts
// (re-executes, keeping its state), the bar re-reads the file by itself, the
// lock screen reads it when it locks.
package main

import "core:encoding/ini"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"

import im "third_party:odin-imgui"

SETTINGS_MIN_COL :: 360 // narrowest settings column
@(private = "file") TEXT_DELAY :: 800 * time.Millisecond   // typing
@(private = "file") NUM_DELAY :: 450 * time.Millisecond    // steppers, sliders, the colour picker
@(private = "file") RESTART_DELAY :: 600 * time.Millisecond // after the last write
@(private = "file") THEME_DELAY :: 1500 * time.Millisecond // re-apply the mode once the daemon is back

@(private = "file")
Row :: struct {
	value:      string, // effective value, normalised (heap)
	def:        string, // the template's (heap)
	set:        bool,   // in the user's file
	legacy:     bool,   // set through a renamed old key
	buf:        [400]u8,
	frac:       f32,    // slider position
	color:      [3]f32,
	pending:    bool,
	pend_value: string, // heap
	changed_at: time.Tick,
	delay:      time.Duration,
	note:       string, // static text
	note_ok:    bool,   // applied (green) rather than just saved
	err:        string, // static text
}

@(private = "file")
ss: struct {
	rows:          [len(SETTINGS)]Row,
	row_h:         [len(SETTINGS)]f32, // drawn height of each row, last frame
	loaded:        bool,
	stamp:         [2]i64, // mtime, size of config.ini when last read
	search:        [128]u8,
	dragging:      int,    // row whose slider is held (-1)
	restart_due:   time.Tick,
	restart:       bool,
	restart_rows:  [dynamic]int,
	theme_due:     time.Tick,
	theme:         bool,
} = {dragging = -1}

Setup_Tab :: enum {Components, Settings}
setup_tab: Setup_Tab

@(private = "file")
set_str :: proc(dst: ^string, s: string) {
	if dst^ == s {return}
	delete(dst^)
	dst^ = strings.clone(s)
}

@(private = "file")
buf_set :: proc(buf: []u8, s: string) {
	n := min(len(s), len(buf) - 1)
	copy(buf[:n], s[:n])
	buf[n] = 0
}

@(private = "file")
buf_str :: proc(buf: []u8) -> string {return string(cstring(raw_data(buf)))}

@(private = "file")
config_stamp :: proc() -> [2]i64 {
	path := config_path()
	defer delete(path)
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {return {}}
	return {time.to_unix_nanoseconds(fi.modification_time), fi.size}
}

// What the row shows for a raw ini value: parsed and clamped as config_load does.
@(private = "file")
shown_value :: proc(s: Setting, raw, def_raw: string) -> string {
	switch s.kind {
	case .Bool:
		v, ok := parse_bool_value(raw)
		if !ok {v, _ = parse_bool_value(def_raw)}
		return v ? "true" : "false"
	case .Int:
		return fmt.tprintf("%d", parse_int_lim(raw, s.ilim))
	case .Float:
		return format_float(parse_float_lim(raw, s.flim))
	case .Color:
		c, ok := parse_hex_color(raw)
		if !ok {c, _ = parse_hex_color(def_raw)}
		return fmt.tprintf("#%06x", c)
	case .Choice:
		for c in s.choices {if strings.equal_fold(c.value, strings.trim_space(raw)) {return c.value}}
		if s.key == "background_mode" {
			// The lock's own aliases (screenshot, colour, picture…).
			switch lock_bg_mode_parse(raw, "x") {
			case .Blur:  return "blur"
			case .Color: return strings.trim_space(raw) == "" ? "" : "color"
			case .Image: return "image"
			}
		}
		return raw
	case .Text, .Path:
		return raw
	}
	return raw
}

// Re-read config.ini (also picks up hand edits). Rows with an edit waiting keep it.
@(private = "file")
settings_load :: proc() {
	ss.loaded = true
	ss.stamp = config_stamp()
	path := config_path()
	defer delete(path)
	defaults, _ := ini.load_map_from_string(DEFAULT_CONFIG, context.temp_allocator)
	m, _, ok := ini.load_map_from_path(path, context.temp_allocator)
	if !ok {m = defaults}
	for s, i in SETTINGS {
		r := &ss.rows[i]
		if r.pending {continue}
		raw, set, legacy := setting_raw(s, m, defaults)
		def_raw := setting_default(s, defaults)
		set_str(&r.value, shown_value(s, raw, def_raw))
		set_str(&r.def, shown_value(s, def_raw, def_raw))
		r.set, r.legacy = set, legacy
		if ss.dragging != i {
			buf_set(r.buf[:], r.value)
			switch s.kind {
			case .Int:   r.frac = f32(parse_int_lim(r.value, s.ilim) - s.ilim.lo) / f32(max(s.ilim.hi - s.ilim.lo, 1))
			case .Float: r.frac = f32((parse_float_lim(r.value, s.flim) - s.flim.lo) / max(s.flim.hi - s.flim.lo, 1e-9))
			case .Color:
				c, _ := parse_hex_color(r.value)
				r.color = {f32((c >> 16) & 0xff) / 255, f32((c >> 8) & 0xff) / 255, f32(c & 0xff) / 255}
			case .Bool, .Choice, .Text, .Path:
			}
		}
	}
}

// From setup's 2 s check: re-read when the file changed. True when it did.
settings_poll :: proc() -> bool {
	if !ss.loaded || ss.dragging >= 0 {return false}
	for r in ss.rows {if r.pending {return false}}
	if config_stamp() == ss.stamp {return false}
	settings_load()
	return true
}

@(private = "file")
edit :: proc(i: int, value: string, delay: time.Duration) {
	r := &ss.rows[i]
	set_str(&r.pend_value, value)
	r.pending = true
	r.changed_at = time.tick_now()
	r.delay = delay
	r.err = ""
	if delay == 0 {flush(i)}
}

@(private = "file")
flush :: proc(i: int) {
	s := SETTINGS[i]
	r := &ss.rows[i]
	r.pending = false
	v, ok, why := setting_normalize(s, r.pend_value)
	if !ok {
		r.err = why
		settings_load()
		return
	}
	if r.set && !r.legacy && v == r.value {return} // nothing changed
	if !config_set_value(s.section, s.key, v) {
		r.err = "couldn't write the config file"
		return
	}
	log.infof("setup settings: [%s] %s = %s", s.section, s.key, v)
	settings_load()
	applied(i)
}

@(private = "file")
reset :: proc(i: int) {
	s := SETTINGS[i]
	r := &ss.rows[i]
	r.pending = false
	r.err = ""
	ok := config_remove_value(s.section, s.key)
	if ok && s.old_key != "" {ok = config_remove_value(s.old_section, s.old_key)}
	if !ok {
		r.err = "couldn't write the config file"
		return
	}
	log.infof("setup settings: [%s] %s reset to the default", s.section, s.key)
	settings_load()
	applied(i)
}

// The mode a [theme.*] section belongs to.
@(private = "file")
theme_section_current :: proc(section: string) -> bool {
	return section == (theme_light ? "theme.light" : "theme.dark")
}

@(private = "file")
applied :: proc(i: int) {
	s := SETTINGS[i]
	r := &ss.rows[i]
	r.note_ok = false
	switch s.apply {
	case .Daemon, .Daemon_Bar, .Theme:
		r.note = "applying…"
		ss.restart = true
		ss.restart_due = time.tick_now()
		for j in ss.restart_rows {if j == i {return}}
		append(&ss.restart_rows, i)
	case .Bar:
		if len(session_pids("wlperch-bar")) > 0 {
			r.note, r.note_ok = "applied to the bar", true
		} else {
			r.note = "saved; used when the wlperch bar starts"
		}
	case .Lock:
		r.note = "saved; used the next time the screen locks"
	case .Setup:
		setup_dim_load_config()
		r.note, r.note_ok = "applied", true
	}
}

@(private = "file")
do_restart :: proc() {
	ss.restart = false
	ok := ipc_send("restart")
	log.infof("setup settings: daemon restart %s", ok ? "requested" : "skipped (not running)")
	for i in ss.restart_rows {
		s := SETTINGS[i]
		r := &ss.rows[i]
		r.note_ok = true
		switch {
		case !ok:
			r.note, r.note_ok = "saved; applies when the daemon starts", false
		case s.apply == .Theme && theme_section_current(s.section):
			r.note = "applied (the current mode was switched again)"
			ss.theme = true
			ss.theme_due = time.tick_now()
		case s.apply == .Theme:
			r.note, r.note_ok = theme_light ? "saved; used at the next switch to dark" : "saved; used at the next switch to light", false
		case s.apply == .Daemon_Bar:
			r.note = "applied (daemon and bar)"
		case:
			r.note = "applied"
		}
	}
	clear(&ss.restart_rows)
}

// From the setup loop: writes edits that have rested, then restarts the
// daemon once the writes stop. Returns ms until something is due (-1: nothing).
settings_tick :: proc() -> int {
	wait := -1
	due :: proc(wait: ^int, at: time.Tick, delay: time.Duration) -> bool {
		left := delay - time.tick_since(at)
		if left <= 0 {return true}
		ms := int(time.duration_milliseconds(left)) + 1
		if wait^ < 0 || ms < wait^ {wait^ = ms}
		return false
	}
	for &r, i in ss.rows {
		if !r.pending {continue}
		if ss.dragging == i {
			if wait < 0 || wait > 100 {wait = 100}
			continue
		}
		if due(&wait, r.changed_at, r.delay) {
			flush(i)
			request_redraw(1)
		}
	}
	if ss.restart {
		// Not while something is still being typed or dragged: one restart per burst.
		busy := ss.dragging >= 0
		for r in ss.rows {if r.pending {busy = true}}
		if busy {
			ss.restart_due = time.tick_now()
		}
		if !busy && due(&wait, ss.restart_due, RESTART_DELAY) {
			do_restart()
			request_redraw(1)
		} else if busy && (wait < 0 || wait > 200) {
			wait = 200
		}
	}
	if ss.theme && due(&wait, ss.theme_due, THEME_DELAY) {
		ss.theme = false
		ipc_send(theme_light ? "theme light" : "theme dark")
	}
	return wait
}

// ---- Drawing ---------------------------------------------------------------------

@(private = "file")
Group_Look :: struct {icon: string, accent: u32}

@(private = "file")
group_look :: proc(g: string) -> Group_Look {
	switch g {
	case "Panel":             return {ICON_APPS, C_BLUE}
	case "Clock and weather": return {ICON_CLOCK, C_CYAN}
	case "Bar":               return {ICON_MONITORS, C_TEAL}
	case "Memory":            return {ICON_MEMORY, C_ORANGE}
	case "Notifications":     return {ICON_BELL, C_YELLOW}
	case "Lock screen":       return {ICON_LOCK, C_BLUE}
	case "Lock screen info":  return {ICON_LOCK, C_TEAL}
	case "Idle lock":         return {ICON_PROGRESS_CLOCK, C_ORANGE}
	case "Time tracking":     return {ICON_PROGRESS_CLOCK, C_GREEN}
	case "GitHub":            return {ICON_GITHUB, C_PURPLE}
	case "Launcher":          return {ICON_MAGNIFY, C_GREEN}
	case "Dark theme":        return {ICON_MOON, C_PURPLE}
	case "Light theme":       return {ICON_SUNNY, C_YELLOW}
	}
	return {ICON_TUNE, C_BLUE}
}

// When a group's changes take effect, for the card title.
@(private = "file")
group_when :: proc(g: string) -> string {
	switch g {
	case "Lock screen", "Lock screen info": return "next time the screen locks"
	case "Dark theme":  return theme_light ? "next switch to dark" : "applies right away"
	case "Light theme": return theme_light ? "applies right away" : "next switch to light"
	}
	return "applies right away"
}

@(private = "file")
matches :: proc(s: Setting, filter: string) -> bool {
	if filter == "" {return true}
	for f in ([]string{s.label, s.key, s.section, s.group, setting_help(s)}) {
		if strings.contains(strings.to_lower(f, context.temp_allocator), filter) {return true}
	}
	return false
}

@(private = "file")
hint_text :: proc(text: string, width: f32, col: u32 = C_FAINT) {
	im.PushFontFloat(fonts.ui, SZ_SMALL)
	im.PushStyleColorImVec4(.Text, rgba(col & 0xffffff))
	im.PushTextWrapPos(im.GetCursorPosX() + width)
	b, e := str_range(text)
	im.TextUnformatted(b, e)
	im.PopTextWrapPos()
	im.PopStyleColor()
	im.PopFont()
}

@(private = "file")
field_style_push :: proc() {
	im.PushFontFloat(fonts.ui, SZ_BODY)
	im.PushStyleVarImVec2(.FramePadding, {9, 5})
	im.PushStyleVar(.FrameRounding, 7)
	im.PushStyleVar(.FrameBorderSize, 1)
	im.PushStyleColorImVec4(.FrameBg, rgba(C_WELL))
	im.PushStyleColorImVec4(.FrameBgHovered, rgba(C_WELL))
	im.PushStyleColorImVec4(.FrameBgActive, rgba(C_WELL))
	im.PushStyleColorImVec4(.Border, rgba(C_BORDER))
	im.PushStyleColorImVec4(.TextDisabled, rgba(C_FAINT)) // the hint in an empty field
}

@(private = "file")
field_style_pop :: proc() {
	im.PopStyleColor(5)
	im.PopStyleVar(3)
	im.PopFont()
}

// A text field bound to the row's buffer; edits are written after `delay`
// of rest, or right away when the field is left (Enter, Tab, a click elsewhere).
@(private = "file")
text_field :: proc(i: int, width: f32, hint: string, delay: time.Duration, flags: im.InputTextFlags = {}) {
	r := &ss.rows[i]
	s := SETTINGS[i]
	field_style_push()
	im.SetNextItemWidth(width)
	id := cstr(fmt.tprintf("##f:%s.%s", s.section, s.key))
	if im.InputTextWithHint(id, cstr(hint), cstring(&r.buf[0]), len(r.buf), flags) {
		edit(i, buf_str(r.buf[:]), delay)
	}
	if im.IsItemDeactivatedAfterEdit() && r.pending {flush(i)}
	field_style_pop()
}

@(private = "file")
small_button :: proc(id, text: string, accent: u32) -> bool {
	w, h: f32 = 26, 26
	p := im.GetCursorScreenPos()
	clicked := im.InvisibleButton(cstr(id), {w, h})
	hovered := im.IsItemHovered()
	if hovered {im.SetMouseCursor(.Hand)}
	im.DrawList_AddRectFilled(dl(), p, {p.x + w, p.y + h}, col32(accent, hovered ? 0.24 : 0.13), 7)
	sz := measure(fonts.bold, SZ_BODY + 2, text)
	draw_text(fonts.bold, SZ_BODY + 2, {p.x + (w - sz.x) / 2, p.y + (h - sz.y) / 2}, col32(accent), text)
	return clicked
}

@(private = "file")
segmented_width :: proc(items: []string) -> f32 {
	w: f32 = 4
	for it in items {w += measure(fonts.ui, SZ_SMALL + 1, it).x + 24}
	return w
}

// The value as currently shown, including an edit that isn't written yet.
@(private = "file")
current :: proc(i: int) -> string {
	r := &ss.rows[i]
	return r.pending ? r.pend_value : r.value
}

@(private = "file")
draw_row :: proc(i: int, inner: f32, accent: u32) {
	s := SETTINGS[i]
	r := &ss.rows[i]
	ROW_H :: 28
	p := im.GetCursorScreenPos()
	right := p.x + inner

	// Label, then "default" or a reset link.
	draw_text(fonts.bold, SZ_BODY, {p.x, p.y + 5}, col32(C_TEXT), s.label)
	tx := p.x + measure(fonts.bold, SZ_BODY, s.label).x + 10
	// Set to something else than the default (a key that just repeats the
	// template's value counts as default).
	if r.set && (r.legacy || r.value != r.def) {
		lbl := r.legacy ? "↺ reset (old key)" : "↺ reset"
		lsz := measure(fonts.ui, SZ_SMALL, lbl)
		im.SetCursorScreenPos({tx, p.y + 6})
		if im.InvisibleButton(cstr(fmt.tprintf("##reset:%s.%s", s.section, s.key)), lsz + {0, 4}) {reset(i)}
		hov := im.IsItemHovered()
		if hov {
			im.SetMouseCursor(.Hand)
			def := r.def == "" ? "empty" : r.def
			tip(fmt.tprintf("Remove [%s] %s from config.ini: back to the default (%s)", s.section, s.key, def))
		}
		draw_text(fonts.ui, SZ_SMALL, {tx, p.y + 7}, col32(accent, hov ? 1 : 0.8), lbl)
	} else {
		draw_text(fonts.ui, SZ_SMALL, {tx, p.y + 7}, col32(C_FAINT), "default")
	}

	below := false // the control takes a line of its own under the label
	switch s.kind {
	case .Bool:
		on := current(i) == "true"
		im.SetCursorScreenPos({right - 38, p.y + 3})
		if toggle_switch(fmt.tprintf("##b:%s.%s", s.section, s.key), on, accent) {
			edit(i, on ? "false" : "true", 0)
		}
	case .Choice:
		labels := make([]string, len(s.choices), context.temp_allocator)
		active := -1
		cur := current(i)
		for c, k in s.choices {
			labels[k] = c.label
			if c.value == cur {active = k}
		}
		sw := segmented_width(labels)
		label_end := tx + 60
		if len(s.choices) <= 4 && right - sw >= label_end {
			im.SetCursorScreenPos({right - sw, p.y})
			if k := segmented(fmt.tprintf("##c:%s.%s", s.section, s.key), labels, active, accent); k >= 0 && k != active {
				edit(i, s.choices[k].value, 0)
			}
		} else {
			cw: f32 = 170
			im.SetCursorScreenPos({right - cw, p.y})
			preview := active >= 0 ? labels[active] : fmt.tprintf("custom: %s", cur)
			im.PushStyleVarImVec2(.FramePadding, {10, 5})
			im.PushStyleVarImVec2(.WindowPadding, {6, 6})
			im.PushStyleVar(.FrameRounding, 7)
			im.SetNextItemWidth(cw)
			if im.BeginCombo(cstr(fmt.tprintf("##c:%s.%s", s.section, s.key)), cstr(preview), {}) {
				for c, k in s.choices {
					if im.Selectable(cstr(fmt.tprintf("%s##%d", c.label, k)), k == active) && k != active {
						edit(i, c.value, 0)
					}
				}
				im.EndCombo()
			}
			im.PopStyleVar(3)
		}
	case .Int, .Float:
		if s.kind == .Int && !s.slider {
			// Stepper: − [value] + unit
			unit_w := s.unit != "" ? measure(fonts.ui, SZ_SMALL, s.unit).x + 6 : 0
			fw: f32 = 70
			x := right - unit_w - 26 - 4 - fw - 4 - 26
			n := parse_int_lim(current(i), s.ilim)
			im.SetCursorScreenPos({x, p.y + 1})
			if small_button(fmt.tprintf("##dec:%s.%s", s.section, s.key), "−", accent) {
				v := fmt.tprintf("%d", clamp(n - max(s.step, 1), s.ilim.lo, s.ilim.hi))
				buf_set(r.buf[:], v)
				edit(i, v, NUM_DELAY)
			}
			im.SetCursorScreenPos({x + 30, p.y + 1})
			text_field(i, fw, "", TEXT_DELAY, {.CharsDecimal, .AutoSelectAll})
			im.SetCursorScreenPos({x + 34 + fw, p.y + 1})
			if small_button(fmt.tprintf("##inc:%s.%s", s.section, s.key), "+", accent) {
				v := fmt.tprintf("%d", clamp(n + max(s.step, 1), s.ilim.lo, s.ilim.hi))
				buf_set(r.buf[:], v)
				edit(i, v, NUM_DELAY)
			}
			if s.unit != "" {draw_text(fonts.ui, SZ_SMALL, {right - unit_w + 6, p.y + 7}, col32(C_MUTED), s.unit)}
		} else {
			// Slider under the label; the value on the right of the label line.
			val := current(i)
			shown := s.unit != "" ? fmt.tprintf("%s %s", val, s.unit) : val
			vw := measure(fonts.bold, SZ_BODY, shown).x
			draw_text(fonts.bold, SZ_BODY, {right - vw, p.y + 5}, col32(accent), shown)
			im.SetCursorScreenPos({p.x, p.y + ROW_H})
			if slider(fmt.tprintf("##s:%s.%s", s.section, s.key), &r.frac, 1, accent, inner) {
				v: string
				if s.kind == .Int {
					n := s.ilim.lo + int(r.frac * f32(s.ilim.hi - s.ilim.lo) + 0.5)
					r.frac = f32(n - s.ilim.lo) / f32(max(s.ilim.hi - s.ilim.lo, 1))
					v = fmt.tprintf("%d", n)
				} else {
					f := s.flim.lo + f64(r.frac) * (s.flim.hi - s.flim.lo)
					v = format_float(f64(int(f * 100 + 0.5)) / 100)
				}
				edit(i, v, NUM_DELAY)
			}
			if im.IsItemActive() {ss.dragging = i} else if ss.dragging == i {ss.dragging = -1}
			im.Dummy({inner, 0})
			below = true
		}
	case .Color:
		fw: f32 = 92
		im.SetCursorScreenPos({right - fw, p.y + 1})
		text_field(i, fw, "#rrggbb", TEXT_DELAY, {.CharsNoBlank})
		im.SetCursorScreenPos({right - fw - 34, p.y + 1})
		im.PushStyleVar(.FrameRounding, 7)
		im.PushStyleVarImVec2(.FramePadding, {6, 6})
		if im.ColorEdit3(cstr(fmt.tprintf("##col:%s.%s", s.section, s.key)), &r.color, {.NoInputs, .NoLabel, .NoAlpha, .NoOptions, .NoDragDrop}) {
			c := u32(clamp(r.color[0], 0, 1) * 255 + 0.5) << 16 | u32(clamp(r.color[1], 0, 1) * 255 + 0.5) << 8 | u32(clamp(r.color[2], 0, 1) * 255 + 0.5)
			v := fmt.tprintf("#%06x", c)
			buf_set(r.buf[:], v)
			edit(i, v, NUM_DELAY)
		}
		im.PopStyleVar(2)
	case .Text, .Path:
		im.SetCursorScreenPos({p.x, p.y + ROW_H + 2})
		text_field(i, inner, s.hint != "" ? s.hint : "empty", TEXT_DELAY)
		below = true
	}
	if !below {
		im.SetCursorScreenPos({p.x, p.y + ROW_H})
		im.Dummy({inner, 0})
	}

	help := setting_help(s)
	if help != "" {hint_text(help, inner)}
	switch {
	case r.err != "":
		hint_text(fmt.tprintf("%s %s", ICON_ALERT, r.err), inner, C_RED)
	case s.kind == .Path && current(i) != "" && !os.exists(expand_home_tmp(current(i))):
		hint_text(fmt.tprintf("%s no such file", ICON_ALERT), inner, C_ORANGE)
	case r.pending:
		hint_text("…", inner, C_MUTED)
	case r.note != "":
		hint_text(fmt.tprintf("%s %s", r.note_ok ? ICON_CHECK : ICON_INFO, r.note), inner, r.note_ok ? C_GREEN : C_MUTED)
	}
}

@(private = "file")
expand_home_tmp :: proc(path: string) -> string {
	if strings.has_prefix(path, "~/") {
		return strings.concatenate({os.get_env("HOME", context.temp_allocator), path[1:]}, context.temp_allocator)
	}
	return path
}

// The Settings tab, from (x, y) over `width`.
draw_settings :: proc(x, y, width: f32) {
	if !ss.loaded {settings_load()}

	// ---- Filter box and where it goes -------------------------------------------
	SEARCH_W :: 380
	im.SetCursorScreenPos({x, y})
	im.PushFontFloat(fonts.ui, SZ_BODY + 1)
	im.PushStyleVarImVec2(.FramePadding, {36, 8})
	im.PushStyleVar(.FrameRounding, 10)
	im.PushStyleVar(.FrameBorderSize, 1)
	im.PushStyleColorImVec4(.FrameBg, rgba(C_CARD))
	im.PushStyleColorImVec4(.FrameBgHovered, rgba(C_CARD))
	im.PushStyleColorImVec4(.FrameBgActive, rgba(C_CARD))
	im.PushStyleColorImVec4(.Border, rgba(C_BORDER))
	im.SetNextItemWidth(SEARCH_W)
	im.InputTextWithHint("##settings-filter", "Filter settings…", cstring(&ss.search[0]), len(ss.search))
	im.PopStyleColor(4)
	im.PopStyleVar(3)
	im.PopFont()
	draw_text(fonts.ui, 17, {x + 12, y + 7}, col32(C_MUTED), ICON_MAGNIFY)
	filter := strings.to_lower(strings.trim_space(buf_str(ss.search[:])), context.temp_allocator)
	note := "Saved to ~/.config/wlperch/config.ini as you change them (your comments stay). Reset removes the key, so the default applies."
	top := y + 50
	if x + SEARCH_W + 18 + measure(fonts.ui, SZ_SMALL, note).x <= x + width {
		draw_text(fonts.ui, SZ_SMALL, {x + SEARCH_W + 18, y + 11}, col32(C_MUTED), note)
	} else {
		// Narrow window: the note goes under the filter box, wrapped.
		im.SetCursorScreenPos({x + 2, y + 46})
		im.PushFontFloat(fonts.ui, SZ_SMALL)
		im.PushStyleColorImVec4(.Text, rgba(C_MUTED))
		im.PushTextWrapPos(im.GetCursorPosX() + width - 4)
		b, e := str_range(note)
		im.TextUnformatted(b, e)
		im.PopTextWrapPos()
		im.PopStyleColor()
		im.PopFont()
		top = im.GetItemRectMax().y + 12
	}

	// ---- Group cards, each into the shortest column ------------------------------
	// As many columns as fit: a wide window shows everything without scrolling.
	GAP :: 14
	ncols := min(fit_columns(width, SETTINGS_MIN_COL, GAP), len(SETTINGS_GROUPS))
	cw := (width - GAP * f32(ncols - 1)) / f32(ncols)
	bottoms := make([]f32, ncols, context.temp_allocator)
	for &b in bottoms {b = top}
	// A group that would run past the window's bottom continues in another
	// column with room, so a wide window needs no scrolling even for the tall
	// groups. Row heights come from the previous frame.
	limit := im.GetWindowPos().y + im.GetWindowSize().y - im.GetStyle().WindowPadding.y - 8 - 12 - im.GetScrollY()
	CARD_TAIL :: 20 // below the last row: padding, spacing
	CARD_HEAD :: 60 // above the first row: padding, title
	// Groups go in their usual order, unless that leaves a column too tall:
	// then the tallest first, which balances the columns best.
	order: [len(SETTINGS_GROUPS)]int
	est: [len(SETTINGS_GROUPS)]f32
	for g, gi in SETTINGS_GROUPS {
		order[gi] = gi
		n := 0
		for s, i in SETTINGS {
			if s.group == g && matches(s, filter) {
				est[gi] += ss.row_h[i] + 4
				n += 1
			}
		}
		if n > 0 {est[gi] += CARD_HEAD + CARD_TAIL + GAP}
	}
	simulate :: proc(order: []int, est: []f32, ncols: int) -> f32 {
		cols: [MAX_COLS]f32
		for gi in order {
			c := 0
			for k in 0 ..< ncols {if cols[k] < cols[c] - 1 {c = k}}
			cols[c] += est[gi]
		}
		m: f32
		for c in cols[:ncols] {m = max(m, c)}
		return m
	}
	if top + simulate(order[:], est[:], ncols) > limit {
		// Stable insertion sort, tallest first.
		for i in 1 ..< len(order) {
			for j := i; j > 0 && est[order[j]] > est[order[j - 1]]; j -= 1 {
				order[j], order[j - 1] = order[j - 1], order[j]
			}
		}
	}
	any := false
	for gi in order {
		g := SETTINGS_GROUPS[gi]
		rows := make([dynamic]int, context.temp_allocator)
		for s, i in SETTINGS {
			if s.group == g && matches(s, filter) {append(&rows, i)}
		}
		if len(rows) == 0 {continue}
		any = true
		col := 0
		for b, k in bottoms {if b < bottoms[col] - 1 {col = k}}
		im.SetCursorScreenPos({x + f32(col) * (cw + GAP), bottoms[col]})
		look := group_look(g)
		part := 0
		card_begin(fmt.tprintf("settings:%s:0", g), cw)
		inner := im.GetContentRegionAvail().x
		card_title(look.icon, g, look.accent, group_when(g))
		for i, k in rows {
			if k > 0 && im.GetCursorScreenPos().y + 4 + ss.row_h[i] + CARD_TAIL > limit {
				to := -1
				for b, c in bottoms {
					if c == col || b + CARD_HEAD + ss.row_h[i] + CARD_TAIL > limit {continue}
					if to < 0 || b < bottoms[to] {to = c}
				}
				if to >= 0 {
					im.Dummy({inner, 2})
					card_end()
					bottoms[col] = im.GetItemRectMax().y + GAP
					col = to
					part += 1
					im.SetCursorScreenPos({x + f32(col) * (cw + GAP), bottoms[col]})
					card_begin(fmt.tprintf("settings:%s:%d", g, part), cw)
					card_title(look.icon, g, look.accent, "continued")
					y0 := im.GetCursorScreenPos().y
					draw_row(i, inner, look.accent)
					ss.row_h[i] = im.GetCursorScreenPos().y - y0
					continue
				}
			}
			if k > 0 {
				lp := im.GetCursorScreenPos()
				im.DrawList_AddLine(dl(), {lp.x, lp.y + 1}, {lp.x + inner, lp.y + 1}, col32(C_BORDER), 1)
				im.Dummy({inner, 4})
			}
			y0 := im.GetCursorScreenPos().y
			draw_row(i, inner, look.accent)
			ss.row_h[i] = im.GetCursorScreenPos().y - y0
		}
		im.Dummy({inner, 2})
		card_end()
		bottoms[col] = im.GetItemRectMax().y + GAP
	}
	bottom := top
	for b in bottoms {bottom = max(bottom, b)}
	if !any {
		draw_text(fonts.ui, SZ_BODY, {x + 4, top + 4}, col32(C_MUTED), "No setting matches. The rest of config.ini (panels, sensors, display presets, projects) is edited by hand: Open on the Settings file card.")
		bottom = top + 30 + GAP
	}
	im.SetCursorScreenPos({x, bottom - GAP}) // no gap after the last card
	im.Dummy({width, 0})
}
