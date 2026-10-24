// Calculator card: an expression field with the result as you type, shown as
// decimal / hex / octal / binary and its IEEE-754 encodings (click to copy),
// plus the session's history. As the first module of a panel ([panel.calc])
// it takes the keyboard when the popup opens: bind `wlperch toggle calc`.
package main

import "base:runtime"
import "core:fmt"
import "core:strings"

import im "third_party:odin-imgui"

@(private = "file")
Calc_Entry :: struct {
	expr, result: string,
}

@(private = "file")
Calc_State :: struct {
	buf:      [256]u8,
	ans:      Calc_Value, // last result committed with Enter
	has_ans:  bool,
	degrees:  bool,
	last:     Calc_Value, // last valid result while typing
	has_last: bool,
	history:  [dynamic]Calc_Entry, // oldest first
	recall:   int, // history index while browsing with Up/Down; len = not browsing
	pending:  bool, // buf was replaced: the active field takes it over
	refocus:  bool,
	typed:    bool, // characters were caught before the field had focus
	help:     bool, // syntax list shown
	copied:   string, // label of the tile just copied (until the pointer leaves it)
}

@(private = "file")
calc: Calc_State

CALC_HISTORY_MAX :: 30

@(private = "file")
calc_text :: proc() -> string {return string(cstring(&calc.buf[0]))}

@(private = "file")
calc_set_text :: proc(s: string) {
	n := min(len(s), len(calc.buf) - 1)
	copy(calc.buf[:], s[:n])
	calc.buf[n] = 0
	calc.pending = true
}

// Starting with an operator continues from the last result: "* 2" = "ans * 2".
@(private = "file")
calc_effective :: proc(text: string) -> string {
	t := strings.trim_space(text)
	if !calc.has_ans || t == "" {return t}
	for op in ([]string{"+", "*", "/", "^", "%", "&", "|", "<<", ">>", "×", "÷", "mod ", "xor "}) {
		if strings.has_prefix(t, op) {return strings.concatenate({"ans ", t}, context.temp_allocator)}
	}
	return t
}

@(private = "file")
calc_input_cb :: proc "c" (data: ^im.InputTextCallbackData) -> i32 {
	context = (^runtime.Context)(data.UserData)^
	replace :: proc(data: ^im.InputTextCallbackData, s: string) {
		im.InputTextCallbackData_DeleteChars(data, 0, data.BufTextLen)
		im.InputTextCallbackData_InsertChars(data, 0, cstr(s))
	}
	if .CallbackHistory in data.EventFlag && len(calc.history) > 0 {
		if data.EventKey == .UpArrow {
			calc.recall = max(calc.recall - 1, 0)
		} else if data.EventKey == .DownArrow {
			calc.recall = min(calc.recall + 1, len(calc.history))
		}
		replace(data, calc.recall < len(calc.history) ? calc.history[calc.recall].expr : "")
		calc.pending = false
	} else if calc.pending {
		replace(data, calc_text())
		data.CursorPos = data.BufTextLen
		data.SelectionStart, data.SelectionEnd = data.BufTextLen, data.BufTextLen
		calc.pending = false
	}
	return 0
}

// Open the calculator panel with `expr` in its field (from the launcher).
calc_open_with :: proc(expr: string) -> bool {
	i := panel_find("calc")
	if i < 0 {return false}
	calc_set_text(expr)
	switch_panel(i)
	return true
}

// The calculator's angle unit, for the launcher's results.
calc_degrees :: proc() -> bool {return calc.degrees}

@(private = "file")
calc_commit :: proc(expr, result: string, v: Calc_Value) {
	calc.ans, calc.has_ans = v, true
	if n := len(calc.history); n == 0 || calc.history[n - 1].expr != expr {
		if n >= CALC_HISTORY_MAX {
			delete(calc.history[0].expr)
			delete(calc.history[0].result)
			ordered_remove(&calc.history, 0)
		}
		append(&calc.history, Calc_Entry{strings.clone(expr), strings.clone(result)})
	}
	calc.recall = len(calc.history)
}

@(private = "file")
CALC_HELP := [?][2]string {
	{"Operators", "+ - * / ^ (or **)   % or mod (floored)   n!   2pi, 3(4+1)"},
	{"Bitwise", "& | xor ~ << >>  on integers (exact up to 128 bits)"},
	{"Numbers", "0x1f  0b1010  0o17  1_000  1.5e3  0x1.8p+1 (hex float)"},
	{"Rounding", "floor ceil round trunc frac abs sign min max gcd lcm"},
	{"Powers, logs", "sqrt cbrt exp ln log(x[, base]) log2 log10 pow hypot gamma"},
	{"Trigonometry", "sin cos tan asin acos atan atan2(y, x) deg rad; sinh cosh tanh asinh acosh atanh"},
	{"Constants", "pi e tau phi inf nan ans"},
	{"Keys", "Enter keeps the result as ans (start with an operator to continue from it), Up/Down recall history. Click a result to copy it."},
}

draw_calculator :: proc(w: f32) {
	card_begin("calculator", w)
	defer card_end()
	inner := im.GetContentRegionAvail().x
	// As a panel's first module (the calculator popup) the panel title names
	// it already, and the field grabs the keyboard when the popup opens
	// (keeping the previous expression, selected).
	p := cur_panel()
	leading := len(p.columns) > 0 && len(p.columns[0]) > 0 && p.columns[0][0] == "calculator"

	// Angle unit and help: on the title row, or beside the field.
	units := []string{"RAD", "DEG"}
	ctl_w: f32 = 4 + 6 + 28
	for u in units {ctl_w += measure(fonts.ui, SZ_SMALL + 1, u).x + 24}
	FIELD_H :: 17 + 2 * 10 + 2
	top := im.GetCursorScreenPos()
	field_w := inner
	ctl_y := top.y - 4
	if leading {
		field_w = inner - ctl_w - 10
		ctl_y = top.y + (FIELD_H - 30) / 2
	} else {
		card_title(ICON_CALC, "Calculator", C_ORANGE)
	}
	field_top := im.GetCursorScreenPos()
	im.SetCursorScreenPos({top.x + inner - ctl_w, ctl_y})
	if j := segmented("##angle", units, calc.degrees ? 1 : 0, C_ORANGE); j >= 0 {calc.degrees = j == 1}
	im.SetCursorScreenPos({top.x + inner - 28, ctl_y + 1})
	if icon_button("##calchelp", ICON_HELP, calc.help ? C_ORANGE : C_MUTED, 28, calc.help, calc.help ? "" : "Syntax and functions") {calc.help = !calc.help}
	im.SetCursorScreenPos(field_top)

	// Typing while the field isn't focused goes into it: right after the
	// popup opened it replaces the previous expression, later it appends.
	if ui.shown_frames <= 1 {calc.typed = false}
	if leading && !im.IsAnyItemActive() {
		io := im.GetIO()
		if q := &io.InputQueueCharacters; q.Size > 0 {
			b := strings.builder_make(context.temp_allocator)
			if calc.typed || ui.shown_frames > 3 {strings.write_string(&b, calc_text())}
			for k in 0 ..< q.Size {strings.write_rune(&b, ([^]rune)(q.Data)[k])}
			q.Size = 0
			calc_set_text(strings.to_string(b))
			calc.typed = true
			calc.refocus = true
		}
	}
	if (leading && ui.shown_frames <= 2) || calc.refocus {
		im.SetKeyboardFocusHere()
		calc.refocus = false
	}
	if len(calc.history) == 0 {calc.recall = 0}
	im.PushFontFloat(fonts.mono, 17)
	im.PushStyleVarImVec2(.FramePadding, {12, 10})
	im.PushStyleVar(.FrameRounding, 10)
	im.PushStyleColorImVec4(.FrameBg, rgba(C_BG))
	im.PushStyleColorImVec4(.FrameBgHovered, rgba(C_BG))
	im.PushStyleColorImVec4(.FrameBgActive, rgba(C_BG))
	im.PushStyleVar(.FrameBorderSize, 1)
	field_pos := im.GetCursorScreenPos()
	ctx := context // for the callback
	im.SetNextItemWidth(field_w)
	entered := im.InputTextWithHint("##calcinput", "sqrt(2) * 0x10, floor(7/2), sin(pi/6)…", cstring(&calc.buf[0]), uint(len(calc.buf)), {.EnterReturnsTrue, .CallbackAlways, .CallbackHistory}, calc_input_cb, &ctx)
	active := im.IsItemActive()
	if active {im.SetNavCursorVisible(false)} // the orange outline marks focus
	im.PopStyleVar(3)
	im.PopStyleColor(3)
	im.PopFont()
	if active {
		fsz := im.GetItemRectSize()
		im.DrawList_AddRect(dl(), field_pos, {field_pos.x + fsz.x, field_pos.y + fsz.y}, col32(C_ORANGE, 0.7), 10, 1.5)
	}

	text := calc_effective(calc_text())
	v: Calc_Value
	err := ""
	showing_ans := false
	if text == "" {
		v, showing_ans = calc.ans, calc.has_ans
	} else {
		v, err = calc_eval(text, calc.ans, calc.degrees)
		if err == "" {calc.last, calc.has_last = v, true}
	}
	if entered {
		if text != "" && err == "" {
			calc_commit(text, calc_decimal(v), v)
			calc_set_text("")
		}
		calc.refocus = true
	}

	if calc.help {calc_help(inner)}

	// Big result line.
	im.Dummy({1, 4})
	if text != "" && err != "" {
		label(fonts.ui, SZ_SMALL + 1, col32(err == "incomplete" || err == "missing )" ? C_MUTED : C_RED, 0.9), err)
		if calc.has_last {v = calc.last} else {return}
	} else if text == "" && !showing_ans {
		label(fonts.ui, SZ_SMALL + 1, col32(C_FAINT), "Results show here as you type; ? lists the syntax.")
		return
	}
	dim: f32 = (text != "" && err != "") ? 0.45 : 1
	formats := calc_formats(v)
	clicked := calc_result_big(formats[0], showing_ans ? "ans = " : "= ", inner, dim, &calc.copied)
	if calc_tiles(formats[1:], inner, dim, &calc.copied) {clicked = true}
	if clicked {
		// Back to the field, cursor at the end, to keep typing.
		calc_set_text(calc_text())
		calc.refocus = true
	}

	// History, newest first; a click puts the expression back.
	if len(calc.history) > 0 {
		sub_heading("History")
		shown := 0
		for i := len(calc.history) - 1; i >= 0 && shown < 6; i -= 1 {
			e := calc.history[i]
			shown += 1
			rp := im.GetCursorScreenPos()
			row_h: f32 = 24
			if im.InvisibleButton(cstr(fmt.tprintf("##calchist%d", i)), {inner, row_h}) {
				calc_set_text(e.expr)
				calc.refocus = true
			}
			hovered := im.IsItemHovered()
			if hovered {
				im.SetMouseCursor(.Hand)
				im.DrawList_AddRectFilled(dl(), {rp.x - 6, rp.y}, {rp.x + inner + 6, rp.y + row_h}, col32(C_OVERLAY, 0.05), 6)
			}
			res := strings.concatenate({"= ", e.result}, context.temp_allocator)
			rw := min(measure(fonts.mono, SZ_BODY, res).x, inner * 0.55)
			draw_text(fonts.mono, SZ_BODY, {rp.x, rp.y + 4}, col32(hovered ? C_TEXT : C_MUTED), fit_text(fonts.mono, SZ_BODY, e.expr, inner - rw - 16))
			draw_text(fonts.mono, SZ_BODY, {rp.x + inner - rw, rp.y + 4}, col32(C_TEXT, 0.9), fit_text(fonts.mono, SZ_BODY, res, rw))
		}
	}
}

@(private = "file")
calc_help :: proc(inner: f32) {
	LABEL_W :: 100
	im.Dummy({1, 4})
	top := im.GetCursorScreenPos()
	d := dl()
	im.DrawList_ChannelsSplit(d, 2)
	im.DrawList_ChannelsSetCurrent(d, 1)
	im.Indent(10)
	im.Dummy({1, 4})
	for row in CALC_HELP {
		p := im.GetCursorScreenPos()
		draw_text(fonts.bold, SZ_SMALL, {p.x, p.y + 1}, col32(C_MUTED), row[0])
		im.SetCursorScreenPos({p.x + LABEL_W, p.y})
		im.PushFontFloat(fonts.ui, SZ_SMALL + 1)
		im.PushStyleColorImVec4(.Text, rgba(C_TEXT, 0.85))
		im.PushTextWrapPos(im.GetCursorPosX() + inner - LABEL_W - 20)
		b, e := str_range(row[1])
		im.TextUnformatted(b, e)
		im.PopTextWrapPos()
		im.PopStyleColor()
		im.PopFont()
		im.Dummy({1, 1})
	}
	im.Unindent(10)
	bottom := im.GetCursorScreenPos().y
	im.DrawList_ChannelsSetCurrent(d, 0)
	im.DrawList_AddRectFilled(d, top, {top.x + inner, bottom + 2}, col32(C_CARD_HI), 10)
	im.DrawList_ChannelsMerge(d)
	im.Dummy({1, 2})
}

// Put a format on the clipboard; `copied` names it (until the pointer leaves).
@(private = "file")
copy_format :: proc(f: Calc_Format, copied: ^string) {
	run_async({"wl-copy", "--", f.copy})
	delete(copied^)
	copied^ = strings.clone(f.label)
}

@(private = "file")
forget_copied :: proc(copied: ^string) {
	delete(copied^)
	copied^ = ""
}

// The big "= result" line (click copies the decimal); true when clicked.
// Shared with the launcher's math mode.
calc_result_big :: proc(dec: Calc_Format, prefix: string, inner, dim: f32, copied: ^string) -> (clicked: bool) {
	size: f32 = SZ_BIG
	for size > 14 && measure(fonts.mono, size, strings.concatenate({prefix, dec.text}, context.temp_allocator)).x > inner - 24 {size -= 1}
	rp := im.GetCursorScreenPos()
	pw := measure(fonts.mono, size, prefix).x
	dw := measure(fonts.mono, size, dec.text).x
	im.SetCursorScreenPos({rp.x + pw, rp.y})
	if im.InvisibleButton("##calcresult", {max(dw, 1), size + 4}) {
		copy_format(dec, copied)
		clicked = true
	}
	hovered := im.IsItemHovered()
	if hovered {im.SetMouseCursor(.Hand)}
	draw_text(fonts.mono, size, rp, col32(C_MUTED, dim), prefix)
	draw_text(fonts.mono, size, {rp.x + pw, rp.y}, col32(C_TEXT, dim), dec.text)
	if copied^ == dec.label {
		draw_text(fonts.ui, SZ_SMALL, {rp.x + pw + dw + 10, rp.y + size - 14}, col32(C_GREEN), "copied")
	} else if hovered {
		draw_text(fonts.ui, 14, {rp.x + pw + dw + 8, rp.y + size - 16}, col32(C_MUTED), ICON_COPY)
	}
	if !hovered && copied^ == dec.label {forget_copied(copied)}
	im.SetCursorScreenPos({rp.x, rp.y + size + 8})
	return
}

// Cut `s` with an ellipsis to fit `w`.
@(private = "file")
fit_text :: proc(font: ^im.Font, size: f32, s: string, w: f32) -> string {
	if measure(font, size, s).x <= w {return s}
	cut := len(s)
	for cut > 0 && measure(font, size, s[:cut]).x + measure(font, size, "…").x > w {cut -= 1}
	return strings.concatenate({s[:cut], "…"}, context.temp_allocator)
}

// Break space-separated digit groups into lines no wider than `w`.
@(private = "file")
wrap_groups :: proc(font: ^im.Font, size: f32, s: string, w: f32) -> []string {
	lines: [dynamic]string
	lines.allocator = context.temp_allocator
	start, last_space := 0, -1
	for i := 0; i <= len(s); i += 1 {
		if i < len(s) && s[i] != ' ' {continue}
		if measure(font, size, s[start:i]).x > w && last_space > start {
			append(&lines, s[start:last_space])
			start = last_space + 1
		}
		last_space = i
	}
	if start < len(s) {append(&lines, s[start:])}
	return lines[:]
}

// The formats as tiles: two per row when they fit, full width otherwise;
// a click copies one (true). Shared with the launcher's math mode.
calc_tiles :: proc(formats: []Calc_Format, inner, dim: f32, copied: ^string) -> (any_clicked: bool) {
	GAP :: 8
	PAD :: 10
	half := (inner - GAP) / 2
	VSZ :: SZ_BODY
	fits_half :: proc(f: Calc_Format, half: f32) -> bool {
		return measure(fonts.mono, VSZ, f.text).x + 2 * PAD <= half
	}
	im.Dummy({1, 2})
	i := 0
	for i < len(formats) {
		row := []Calc_Format{formats[i]}
		if i + 1 < len(formats) && fits_half(formats[i], half) && fits_half(formats[i + 1], half) {
			row = formats[i:i + 2]
		}
		tile_w := len(row) == 2 ? half : inner
		// Wrap long values (64-bit binary) at digit groups.
		row_lines := 1
		wrapped := make([][]string, len(row), context.temp_allocator)
		for f, j in row {
			wrapped[j] = wrap_groups(fonts.mono, VSZ, f.text, tile_w - 2 * PAD)
			row_lines = max(row_lines, len(wrapped[j]))
		}
		tile_h := f32(PAD + 15 + 2 + row_lines * (int(VSZ) + 4) + PAD - 2)
		y := im.GetCursorScreenPos().y
		x0 := im.GetCursorScreenPos().x
		for f, j in row {
			x := x0 + f32(j) * (half + GAP)
			im.SetCursorScreenPos({x, y})
			clicked := im.InvisibleButton(cstr(fmt.tprintf("##calctile%s", f.label)), {tile_w, tile_h})
			hovered := im.IsItemHovered()
			if clicked {
				copy_format(f, copied)
				any_clicked = true
			}
			if !hovered && copied^ == f.label {forget_copied(copied)}
			d := dl()
			im.DrawList_AddRectFilled(d, {x, y}, {x + tile_w, y + tile_h}, col32(hovered ? C_BORDER : C_CARD_HI, 1), 10)
			lab := f.label
			lab_col := col32(C_MUTED, dim)
			if copied^ == f.label {
				lab, lab_col = "copied", col32(C_GREEN)
			} else if hovered {
				im.SetMouseCursor(.Hand)
			}
			draw_text(fonts.bold, SZ_SMALL, {x + PAD, y + PAD - 1}, lab_col, strings.to_upper(lab, context.temp_allocator))
			if hovered && copied^ != f.label {
				isz := measure(fonts.ui, 14, ICON_COPY)
				draw_text(fonts.ui, 14, {x + tile_w - PAD - isz.x, y + PAD - 2}, col32(C_MUTED), ICON_COPY)
			}
			for line, k in wrapped[j] {
				draw_text(fonts.mono, VSZ, {x + PAD, y + PAD + 17 + f32(k) * (VSZ + 4)}, col32(C_TEXT, 0.92 * dim), line)
			}
		}
		im.SetCursorScreenPos({x0, y + tile_h + GAP})
		im.Dummy({inner, 0})
		i += len(row)
	}
	return
}
