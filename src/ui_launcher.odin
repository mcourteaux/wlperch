// Launcher module: a search field over apps (desktop entries), wlperch's
// panels and the calculator; "> command" runs a command (the "run" panel
// starts with it), ":name" searches emoji (the "emoji" panel does without the
// colon). Keyboard first: type, arrows (or Ctrl+N/P, Ctrl+J/K), Enter; Tab
// completes a command or takes a sum to the calculator.
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import im "third_party:odin-imgui"

@(private = "file")
Row_Kind :: enum {
	App,
	Calc,  // the query as a sum
	Panel, // one of wlperch's panels
	Bin,   // a program on $PATH (run mode)
	Shell, // the typed command line
	Emoji, // emoji_table[index]
}

@(private = "file")
Row :: struct {
	kind:  Row_Kind,
	index: int, // into launcher.apps / panels / launcher.bins
	score: f32,
	text:  string, // Shell: the command; Calc: the expression
}

@(private = "file")
Launch_UI :: struct {
	buf:      [512]u8,
	pending:  bool, // buf was replaced: the active field takes it over
	refocus:  bool,
	typed:    bool,
	move:     int, // selection moves requested by the field's callback
	complete: bool, // Tab
	query:    string, // the query `rows` were built for (heap)
	rows:     [dynamic]Row,
	sel, top: int,
	wheel:    f32, // unspent wheel motion (smooth scrolling sends fractions)
	calc_ok:  bool,
	calc_v:   Calc_Value,
	calc_lit: bool, // the calc row is a lone number (a conversion), not a sum
	math:     bool, // the query is a sum: the result as in the calculator, no other rows
	copied:   string, // format label just copied from the calc row
	restored: bool, // the kept sum was put back and is selected: typing replaces it
	sel_all:  bool, // select the whole text when the field takes `buf` over
}

// A sum left in the launcher comes back, selected, the next time it opens,
// also after a restart: ~/.local/share/wlperch/launcher-sum. Other queries
// (and an emptied field) start empty, as usual.
@(private = "file")
Kept_Sum :: struct {
	text:   string, // heap
	loaded: bool,
	dirty:  bool, // differs from the file
}

@(private = "file")
kept: Kept_Sum

@(private = "file")
kept_path :: proc() -> string {
	d := data_dir()
	defer delete(d)
	return strings.concatenate({d, "/launcher-sum"}, context.temp_allocator)
}

@(private = "file")
kept_load :: proc() {
	if kept.loaded {return}
	kept.loaded = true
	if data, err := os.read_entire_file(kept_path(), context.temp_allocator); err == nil {
		kept.text = strings.clone(strings.trim_space(string(data)))
	}
}

@(private = "file")
kept_set :: proc(s: string) {
	kept_load()
	if s == kept.text {return}
	delete(kept.text)
	kept.text = strings.clone(s)
	kept.dirty = true
}

// Write the kept sum out if it changed (the popup hid, or we re-exec).
launcher_save_sum :: proc() {
	if !kept.dirty {return}
	kept.dirty = false
	path := kept_path()
	if kept.text == "" {
		os.remove(path)
		return
	}
	d := data_dir()
	defer delete(d)
	os.make_directory_all(d)
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, strings.concatenate({kept.text, "\n"}, context.temp_allocator)) == nil {os.rename(tmp, path)}
}

@(private = "file")
lui: Launch_UI

@(private = "file")
ROWS :: 7
@(private = "file")
ROW_H :: f32(62)
@(private = "file")
FIELD_H :: f32(58)
@(private = "file")
FIELD_SZ :: f32(22) // query font size
@(private = "file")
TITLE_SZ :: SZ_BODY + 3
@(private = "file")
SUB_SZ :: SZ_SMALL + 1.5
@(private = "file")
ICON_SZ :: f32(40)
@(private = "file")
ICON_LOADS_PER_FRAME :: 4
@(private = "file")
EMOJI_SZ :: f32(46)
// Emoji also listed in a plain search ("heart"), after the apps.
@(private = "file")
EMOJI_IN_SEARCH :: 3

@(private = "file")
ui_text :: proc() -> string {return string(cstring(&lui.buf[0]))}

@(private = "file")
set_text :: proc(s: string) {
	n := min(len(s), len(lui.buf) - 1)
	copy(lui.buf[:], s[:n])
	lui.buf[n] = 0
	lui.pending = true
}

@(private = "file")
input_cb :: proc "c" (data: ^im.InputTextCallbackData) -> i32 {
	context = (^runtime.Context)(data.UserData)^
	if .CallbackHistory in data.EventFlag {
		lui.move += data.EventKey == .UpArrow ? -1 : 1
	} else if .CallbackCompletion in data.EventFlag {
		lui.complete = true
	} else if lui.pending {
		im.InputTextCallbackData_DeleteChars(data, 0, data.BufTextLen)
		im.InputTextCallbackData_InsertChars(data, 0, cstr(ui_text()))
		data.CursorPos = data.BufTextLen
		data.SelectionStart, data.SelectionEnd = lui.sel_all ? 0 : data.BufTextLen, data.BufTextLen
		lui.pending, lui.sel_all, lui.restored = false, false, false
	}
	return 0
}

// The run panel, or a query starting with ">": commands instead of apps.
@(private = "file")
run_mode :: proc(q: string) -> (cmd: string, ok: bool) {
	t := strings.trim_left_space(q)
	if strings.has_prefix(t, ">") {return strings.trim_space(t[1:]), true}
	return "", false
}

// The emoji panel, or a query starting with ":": emoji instead of apps.
@(private = "file")
emoji_mode :: proc(q: string) -> (query: string, ok: bool) {
	t := strings.trim_left_space(q)
	if strings.has_prefix(t, ":") {return strings.trim_space(t[1:]), true}
	if len(panels) > 0 && cur_panel().name == "emoji" {return strings.trim_space(t), true}
	return "", false
}

// A sum worth showing: an operator, a digit next to letters (2pi) or "=".
@(private = "file")
looks_like_math :: proc(q: string) -> (expr: string, ok, literal: bool) {
	t := strings.trim_space(q)
	if strings.has_prefix(t, "=") {return strings.trim_space(t[1:]), true, false}
	has_digit, has_op := false, false
	for c in transmute([]u8)t {
		if c >= '0' && c <= '9' {has_digit = true}
		if strings.index_byte("+-*/^%()!&|<>~,", c) >= 0 {has_op = true}
	}
	if !has_digit && !has_op {return "", false, false}
	// A lone number ("2048", "0xff") is a conversion, not a search: show it after the apps.
	return t, true, !has_op
}

@(private = "file")
build_rows :: proc(q: string) {
	clear(&lui.rows)
	lui.calc_ok, lui.calc_lit, lui.math = false, false, false
	now := time.to_unix_seconds(time.now())

	if eq, ok := emoji_mode(q); ok {
		emoji_load()
		words := strings.fields(strings.to_lower(eq, context.temp_allocator), context.temp_allocator)
		tone := emoji_tone_asked(words)
		for &e, i in emoji_table {
			s: f32
			if len(words) == 0 {
				if e.tone {continue}
			} else {
				s = emoji_score(&e, words, tone)
				if s < 0 {continue}
			}
			append(&lui.rows, Row{kind = .Emoji, index = i, score = s + launcher_frecency(emoji_use_id(&e), now)})
		}
		// Stable: ties keep Unicode's order (smileys first, then people, …).
		slice.stable_sort_by(lui.rows[:], proc(a, b: Row) -> bool {return a.score > b.score})
		if len(words) > 0 && len(lui.rows) > 300 {resize(&lui.rows, 300)}
		return
	}

	if cmd, ok := run_mode(q); ok {
		bins := launcher_bins()
		f := strings.fields(cmd, context.temp_allocator)
		word := len(f) > 0 ? f[0] : ""
		exact := false
		for b, i in bins {
			s: f32 = 0
			if word != "" {
				if b == word {
					exact = true
					continue // that's the command row
				}
				// Commands by name only: scattered letters match too much of $PATH.
				s = fuzzy_score(strings.to_lower(word, context.temp_allocator), strings.to_lower(b, context.temp_allocator), false)
				if s < 0 {continue}
			}
			s += launcher_frecency(strings.concatenate({"run:", b}, context.temp_allocator), now)
			append(&lui.rows, Row{kind = .Bin, index = i, score = s})
		}
		slice.stable_sort_by(lui.rows[:], proc(a, b: Row) -> bool {return a.score > b.score})
		if len(lui.rows) > 200 {resize(&lui.rows, 200)}
		// The typed line first when it names a program or has arguments
		// (a pipeline, a builtin); a bare "fire" picks "firefox" first.
		if cmd != "" {inject_at(&lui.rows, exact || len(f) > 1 || len(lui.rows) == 0 ? 0 : 1, Row{kind = .Shell, text = cmd})}
		return
	}

	words := strings.fields(strings.to_lower(q, context.temp_allocator), context.temp_allocator)
	calc_row := -1
	calc_literal := false
	if expr, ok, literal := looks_like_math(q); ok && expr != "" {
		if v, err := calc_eval(expr, {is_int = true}, calc_degrees()); err == "" {
			lui.calc_ok, lui.calc_v, lui.calc_lit = true, v, literal
			calc_row, calc_literal = len(lui.rows), literal
			append(&lui.rows, Row{kind = .Calc, text = expr})
		}
	}
	start := len(lui.rows)
	for &app, i in launcher.apps {
		if len(words) == 0 {
			if app.action {continue}
			append(&lui.rows, Row{kind = .App, index = i, score = launcher_frecency(app.id, now)})
			continue
		}
		s := launcher_score(&app, words)
		if s < 0 {continue}
		append(&lui.rows, Row{kind = .App, index = i, score = s + launcher_frecency(app.id, now)})
	}
	if len(words) > 0 {
		for p, i in panels {
			if p.name == "launch" || p.name == "run" {continue}
			title := strings.to_lower(panel_label(p), context.temp_allocator)
			s: f32 = 0
			for w in words {
				ws := max(fuzzy_score(w, title), fuzzy_score(w, p.name))
				if ws < 0 {
					s = -1
					break
				}
				s += ws
			}
			if s >= 0 {append(&lui.rows, Row{kind = .Panel, index = i, score = s * 0.9})}
		}
	}
	emoji_rows := emoji_in_search(words, q)
	rest := lui.rows[start:]
	if len(words) == 0 {
		// Most used first, then by name.
		slice.stable_sort_by(rest, proc(a, b: Row) -> bool {
			if a.score != b.score {return a.score > b.score}
			return strings.compare(launcher.apps[a.index].name_lc, launcher.apps[b.index].name_lc) < 0
		})
	} else {
		slice.stable_sort_by(rest, proc(a, b: Row) -> bool {return a.score > b.score})
	}
	if calc_row >= 0 && calc_literal && len(lui.rows) > 1 {
		// "2048": the game first, its conversions second.
		r := lui.rows[calc_row]
		ordered_remove(&lui.rows, calc_row)
		inject_at(&lui.rows, 1, r)
	}
	// A few emoji whose name has the word, after everything else.
	append(&lui.rows, ..emoji_rows)
	if len(words) > 0 && len(lui.rows) == 0 {
		append(&lui.rows, Row{kind = .Shell, text = strings.trim_space(q)})
	}
}

// Emoji for a plain search: only names with the words at a word start
// ("heart", "thumbs up"), at most EMOJI_IN_SEARCH, so apps stay on top.
@(private = "file")
emoji_in_search :: proc(words: []string, q: string) -> []Row {
	out: [dynamic]Row
	out.allocator = context.temp_allocator
	if len(words) == 0 || len(strings.trim_space(q)) < 3 {return nil}
	emoji_load()
	now := time.to_unix_seconds(time.now())
	for &e, i in emoji_table {
		if e.tone {continue}
		s: f32 = 0
		for w in words {
			ws := fuzzy_score(w, e.name, false)
			if ws < 85 { // the start of the name or of one of its words
				s = -1
				break
			}
			s += ws
		}
		if s < 0 {continue}
		append(&out, Row{kind = .Emoji, index = i, score = s + launcher_frecency(emoji_use_id(&e), now)})
	}
	slice.stable_sort_by(out[:], proc(a, b: Row) -> bool {return a.score > b.score})
	return out[:min(len(out), EMOJI_IN_SEARCH)]
}

panel_label :: proc(p: Panel) -> string {
	if p.title != "" {return p.title}
	if p.name == "" {return ""}
	return strings.concatenate({strings.to_upper(p.name[:1], context.temp_allocator), p.name[1:]}, context.temp_allocator)
}

// Run the row; false keeps the popup open.
@(private = "file")
activate :: proc(r: Row, terminal, alt: bool) {
	switch r.kind {
	case .App:
		app := &launcher.apps[r.index]
		hide_requested = true
		if !launcher_start(app) {toast(fmt.tprintf("couldn't start %s", app.name))}
	case .Calc:
		if alt {
			if calc_open_with(r.text) {return}
		}
		f := calc_formats(lui.calc_v)
		run_async({"wl-copy", "--", f[0].copy})
		hide_requested = true
	case .Panel:
		switch_panel(r.index)
	case .Bin:
		cmd, _ := run_mode(ui_text())
		args := ""
		if f := strings.fields(cmd, context.temp_allocator); len(f) > 1 {args = strings.join(f[1:], " ", context.temp_allocator)}
		line := args == "" ? launcher.bins[r.index] : strings.concatenate({launcher.bins[r.index], " ", args}, context.temp_allocator)
		hide_requested = true
		launcher_run(line, terminal)
	case .Shell:
		hide_requested = true
		launcher_run(r.text, terminal)
	case .Emoji:
		emoji_insert(&emoji_table[r.index], copy_only = terminal)
	}
}

draw_launcher :: proc(w: f32) {
	p := cur_panel()
	emoji_pictures_trim()
	if ui.shown_frames <= 1 {
		launcher_refresh()
		start := ""
		if p.name == "run" {
			start = "> "
		} else if p.name != "emoji" {
			kept_load()
			start = kept.text
		}
		set_text(start)
		lui.restored = start != "" && p.name != "run"
		lui.sel_all = lui.restored
		lui.typed = false
		lui.sel, lui.top = 0, 0
		delete(lui.query)
		lui.query = strings.clone("\x00") // rebuild
	}

	// Typing before the field has focus goes into it.
	if !im.IsAnyItemActive() {
		io := im.GetIO()
		if q := &io.InputQueueCharacters; q.Size > 0 {
			b := strings.builder_make(context.temp_allocator)
			if !lui.restored {strings.write_string(&b, ui_text())} // a kept sum is selected: replace it
			for k in 0 ..< q.Size {strings.write_rune(&b, ([^]rune)(q.Data)[k])}
			q.Size = 0
			set_text(strings.to_string(b))
			lui.restored, lui.sel_all = false, false
			lui.refocus = true
		}
	}
	if ui.shown_frames <= 2 || lui.refocus {
		im.SetKeyboardFocusHere()
		lui.refocus = false
	}

	// Search field, with a magnifier (or prompt) inside on the left.
	_, running := run_mode(ui_text())
	_, emojis := emoji_mode(ui_text())
	top := im.GetCursorScreenPos()
	im.PushFontFloat(fonts.ui, FIELD_SZ)
	im.PushStyleVarImVec2(.FramePadding, {52, (FIELD_H - FIELD_SZ * 1.2) / 2})
	im.PushStyleVar(.FrameRounding, 12)
	im.PushStyleColorImVec4(.FrameBg, rgba(C_CARD))
	im.PushStyleColorImVec4(.FrameBgHovered, rgba(C_CARD))
	im.PushStyleColorImVec4(.FrameBgActive, rgba(C_CARD))
	im.PushStyleVar(.FrameBorderSize, 1)
	ctx := context
	im.SetNextItemWidth(w)
	hint: cstring = p.name == "run" ? "Command to run…" : p.name == "emoji" ? "Search emoji…" : "Search apps, = calculate, > run a command, : emoji"
	entered := im.InputTextWithHint("##launch", hint, cstring(&lui.buf[0]), uint(len(lui.buf)), {.EnterReturnsTrue, .CallbackAlways, .CallbackHistory, .CallbackCompletion}, input_cb, &ctx)
	active := im.IsItemActive()
	if active {im.SetNavCursorVisible(false)}
	im.PopStyleVar(3)
	im.PopStyleColor(3)
	im.PopFont()

	io := im.GetIO()
	text := ui_text()
	if text != lui.query {
		delete(lui.query)
		lui.query = strings.clone(text)
		build_rows(text)
		lui.sel, lui.top = 0, 0
		// A sum: the calculator's view of it, and it's kept for next time.
		lui.math = lui.calc_ok && !lui.calc_lit && len(lui.rows) > 0 && lui.rows[0].kind == .Calc
		if lui.math {resize(&lui.rows, 1)}
		// (Not while closing: Escape makes the field revert to the text it had
		// when it took focus.)
		if p.name != "run" && p.name != "emoji" && !hide_requested {kept_set(lui.math ? strings.trim_space(text) : "")}
	}

	_, running = run_mode(text)
	_, emojis = emoji_mode(text)
	accent: u32 = running ? C_GREEN : emojis ? C_YELLOW : lui.math ? C_ORANGE : C_BLUE
	if active {im.DrawList_AddRect(dl(), top, {top.x + w, top.y + FIELD_H}, col32(accent, 0.7), 12, 1.5)}
	icon := running ? ICON_CONSOLE : emojis ? ICON_EMOTICON : lui.math ? ICON_CALC : ICON_MAGNIFY
	isz := measure(fonts.ui, 23, icon)
	draw_text(fonts.ui, 23, {top.x + 18, top.y + (FIELD_H - isz.y) / 2}, col32(active ? accent : C_MUTED), icon)

	// Keys.
	n := len(lui.rows)
	if io.KeyCtrl {
		if im.IsKeyPressed(.N) || im.IsKeyPressed(.J) {lui.move += 1}
		if im.IsKeyPressed(.P) || im.IsKeyPressed(.K) {lui.move -= 1}
		// Ctrl+C on an emoji: copy it (the field's own copy has nothing to copy).
		if im.IsKeyPressed(.C) && lui.sel < n && lui.rows[lui.sel].kind == .Emoji {
			emoji_insert(&emoji_table[lui.rows[lui.sel].index], copy_only = true)
		}
	}
	if im.IsKeyPressed(.PageDown) {lui.move += ROWS}
	if im.IsKeyPressed(.PageUp) {lui.move -= ROWS}
	if lui.complete {
		lui.complete = false
		if lui.sel < n {
			r := lui.rows[lui.sel]
			#partial switch r.kind {
			case .Bin:
				set_text(strings.concatenate({"> ", launcher.bins[r.index], " "}, context.temp_allocator))
				lui.refocus = true
			case .Shell:
				// Complete to the best matching command.
				for o in lui.rows {
					if o.kind != .Bin {continue}
					set_text(strings.concatenate({"> ", launcher.bins[o.index], " "}, context.temp_allocator))
					lui.refocus = true
					break
				}
			case .Calc:
				activate(r, false, true)
			case:
				lui.move += 1
			}
		}
	}
	if lui.move != 0 && n > 0 {
		step := lui.move
		if abs(step) == 1 {
			lui.sel = (lui.sel + step + n) % n // arrows wrap around
		} else {
			lui.sel = clamp(lui.sel + step, 0, n - 1)
		}
	}
	lui.move = 0
	lui.sel = clamp(lui.sel, 0, max(n - 1, 0))
	if lui.sel < lui.top {lui.top = lui.sel}
	if lui.sel >= lui.top + ROWS {lui.top = lui.sel - ROWS + 1}
	if entered {
		if lui.sel < n {activate(lui.rows[lui.sel], io.KeyShift, io.KeyCtrl)}
		lui.refocus = true
	}

	// The list: always ROWS tall, so the centred popup doesn't jump.
	im.Dummy({1, 6})
	list := im.GetCursorScreenPos()
	list_h := ROWS * ROW_H
	// The wheel moves the selection (a row per notch); the view follows it.
	// Scrolling only the view got undone by the follow-the-selection above.
	if im.IsMouseHoveringRect(list, {list.x + w, list.y + list_h}) && io.MouseWheel != 0 && n > 0 {
		lui.wheel += io.MouseWheel
		steps := int(lui.wheel)
		lui.wheel -= f32(steps)
		lui.sel = clamp(lui.sel - steps, 0, n - 1)
		if lui.sel < lui.top {lui.top = lui.sel}
		if lui.sel >= lui.top + ROWS {lui.top = lui.sel - ROWS + 1}
	}
	lui.top = clamp(lui.top, 0, max(n - ROWS, 0))
	d := dl()
	loads := 0
	if n == 0 {
		msg := running ? "Type a command; Enter runs it, Shift+Enter in a terminal." : emojis ? "No emoji matches." : len(launcher.apps) == 0 ? "No applications found." : "Nothing matches."
		msz := measure(fonts.ui, SZ_BODY, msg)
		draw_text(fonts.ui, SZ_BODY, {list.x + (w - msz.x) / 2, list.y + 40}, col32(C_FAINT), msg)
	}
	if lui.math && n > 0 {
		// The result as the calculator shows it: big, then the format tiles.
		im.PushClipRect(list, {list.x + w, list.y + list_h}, true)
		im.PushStyleVarImVec2(.ItemSpacing, {8, 6}) // the calculator card's tile spacing
		im.SetCursorScreenPos({list.x, list.y + 6})
		formats := calc_formats(lui.calc_v)
		clicked := calc_result_big(formats[0], "= ", w, 1, &lui.copied)
		if calc_tiles(formats[1:], w, 1, &lui.copied) {clicked = true}
		if clicked {lui.refocus = true}
		im.PopStyleVar()
		im.PopClipRect()
	}
	for i in lui.top ..< min(lui.top + ROWS, n) {
		if lui.math {break}
		r := lui.rows[i]
		y := list.y + f32(i - lui.top) * ROW_H
		im.SetCursorScreenPos({list.x, y})
		clicked := im.InvisibleButton(cstr(fmt.tprintf("##row%d", i)), {w, ROW_H - 2})
		hovered := im.IsItemHovered()
		if hovered {im.SetMouseCursor(.Hand)}
		selected := i == lui.sel
		if selected {
			im.DrawList_AddRectFilled(d, {list.x, y}, {list.x + w, y + ROW_H - 2}, col32(accent, 0.16), 10)
		} else if hovered {
			im.DrawList_AddRectFilled(d, {list.x, y}, {list.x + w, y + ROW_H - 2}, col32(C_OVERLAY, 0.05), 10)
		}
		if draw_row(r, {list.x + 10, y}, w - 20, selected, &loads) {
			lui.refocus = true // a format chip was clicked
		} else if clicked {
			lui.sel = i
			activate(r, io.KeyShift, io.KeyCtrl)
			lui.refocus = true
		}
	}
	if loads >= ICON_LOADS_PER_FRAME {request_redraw()}
	im.SetCursorScreenPos({list.x, list.y + list_h})

	// Footer: what the keys do for the selected row, and a count.
	im.Dummy({1, 2})
	fp := im.GetCursorScreenPos()
	keys := "↵ open   Tab next   > run a command   = calculate   : emoji"
	if lui.sel < n {
		#partial switch lui.rows[lui.sel].kind {
		case .Calc:          keys = "↵ copy   Tab or Ctrl+↵ open in the calculator"
		case .Bin:           keys = "↵ run   ⇧↵ in a terminal   Tab complete"
		case .Shell:         keys = "↵ run   ⇧↵ in a terminal"
		case .Panel:         keys = "↵ open the panel"
		case .Emoji:
			e := &emoji_table[lui.rows[lui.sel].index]
			keys = emoji_can_type() ? "↵ type it   ⇧↵ or Ctrl+C copy" : "↵ copy (install wtype to type it)"
			if e.tones {keys = strings.concatenate({keys, "   + “dark”, “light”… skin tones"}, context.temp_allocator)}
		}
	}
	draw_text(fonts.ui, SZ_SMALL + 1, {fp.x + 2, fp.y}, col32(C_FAINT), keys)
	if n > 0 && !lui.math {
		cnt := fmt.tprintf("%d / %d", lui.sel + 1, n)
		csz := measure(fonts.ui, SZ_SMALL + 1, cnt)
		draw_text(fonts.ui, SZ_SMALL + 1, {fp.x + w - csz.x - 2, fp.y}, col32(C_FAINT), cnt)
	}
	im.Dummy({w, 16})
}

// One row's content; true when a calc format chip took the click.
@(private = "file")
draw_row :: proc(r: Row, pos: Vec2, w: f32, selected: bool, loads: ^int) -> bool {
	d := dl()
	ip := Vec2{pos.x, pos.y + (ROW_H - 2 - ICON_SZ) / 2}
	tx := pos.x + ICON_SZ + 16
	title, sub: string
	glyph_badge :: proc(ip: Vec2, glyph: string, col: u32) {
		d := dl()
		im.DrawList_AddRectFilled(d, ip, {ip.x + ICON_SZ, ip.y + ICON_SZ}, col32(col, 0.18), 9)
		gsz := measure(fonts.ui, 22, glyph)
		draw_text(fonts.ui, 22, {ip.x + (ICON_SZ - gsz.x) / 2, ip.y + (ICON_SZ - gsz.y) / 2}, col32(col), glyph)
	}
	chip_clicked := false
	switch r.kind {
	case .App:
		app := &launcher.apps[r.index]
		if !app.tried && loads^ < ICON_LOADS_PER_FRAME {
			app.tried = true
			loads^ += 1
			if app.icon != "" {app.tex = icon_resolve(app.icon)}
		} else if !app.tried {
			loads^ += 1
		}
		if app.tex != nil {
			im.DrawList_AddImage(d, im.TextureRef{_TexID = icon_texture(app.tex)}, ip, {ip.x + ICON_SZ, ip.y + ICON_SZ})
		} else {
			col := app_color(app.name)
			im.DrawList_AddRectFilled(d, ip, {ip.x + ICON_SZ, ip.y + ICON_SZ}, col32(col, 0.2), 9)
			ini := app_initial(app.name)
			isz := measure(fonts.bold, 19, ini)
			draw_text(fonts.bold, 19, {ip.x + (ICON_SZ - isz.x) / 2, ip.y + (ICON_SZ - isz.y) / 2}, col32(col), ini)
		}
		title = app.name
		sub = app.generic != "" && app.comment != "" && app.generic != app.comment ? strings.concatenate({app.generic, " · ", app.comment}, context.temp_allocator) : app.generic != "" ? app.generic : app.comment
		if app.terminal {sub = sub != "" ? strings.concatenate({sub, " · terminal"}, context.temp_allocator) : "runs in a terminal"}
	case .Panel:
		p := panels[r.index]
		glyph_badge(ip, panel_icon(p), C_PURPLE)
		title = panel_label(p)
		sub = "wlperch panel"
	case .Bin:
		glyph_badge(ip, ICON_CONSOLE, C_GREEN)
		title = launcher.bins[r.index]
		sub = "command"
	case .Shell:
		glyph_badge(ip, ICON_CONSOLE, C_GREEN)
		title = r.text
		sub = "run in a shell"
	case .Emoji:
		e := &emoji_table[r.index]
		pic, cached := emoji_cached(e)
		if !cached && loads^ < ICON_LOADS_PER_FRAME {
			loads^ += 1
			pic = emoji_picture(e)
			cached = true
		} else if !cached {
			loads^ += 1
		}
		ep := Vec2{pos.x + (ICON_SZ - EMOJI_SZ) / 2, pos.y + (ROW_H - 2 - EMOJI_SZ) / 2}
		if pic != nil {
			im.DrawList_AddImage(d, im.TextureRef{_TexID = icon_texture(pic)}, ep, {ep.x + EMOJI_SZ, ep.y + EMOJI_SZ})
		} else if cached {
			// No colour emoji font (or no Pango): the UI font's attempt.
			gsz := measure(fonts.ui, 30, e.ch)
			draw_text(fonts.ui, 30, {ip.x + (ICON_SZ - gsz.x) / 2, ip.y + (ICON_SZ - gsz.y) / 2}, col32(C_TEXT), e.ch)
		}
		title = strings.concatenate({strings.to_upper(e.name[:1], context.temp_allocator), e.name[1:]}, context.temp_allocator)
		sub = e.keywords != "" ? strings.concatenate({e.group, " · ", e.keywords}, context.temp_allocator) : e.group
	case .Calc:
		glyph_badge(ip, ICON_CALC, C_ORANGE)
		formats := calc_formats(lui.calc_v)
		res := strings.concatenate({"= ", formats[0].text}, context.temp_allocator)
		draw_text(fonts.mono, 19, {tx, pos.y + 8}, col32(C_TEXT), fit(fonts.mono, 19, res, w - (tx - pos.x)))
		// Other formats as chips: click copies.
		x := tx
		y := pos.y + 36
		for f in formats[1:] {
			if strings.has_prefix(f.label, "oct") || strings.has_prefix(f.label, "f32") {continue}
			lab := lui.copied == f.label ? "copied" : f.label
			val := fit(fonts.mono, SZ_SMALL, f.text, 220)
			cw := measure(fonts.ui, SZ_SMALL - 1, lab).x + measure(fonts.mono, SZ_SMALL, val).x + 18
			if x + cw > pos.x + w {break}
			im.SetCursorScreenPos({x, y - 1})
			if im.InvisibleButton(cstr(fmt.tprintf("##chip%s", f.label)), {cw, 18}) {
				run_async({"wl-copy", "--", f.copy})
				delete(lui.copied)
				lui.copied = strings.clone(f.label)
				chip_clicked = true
			}
			hov := im.IsItemHovered()
			if hov {
				im.SetMouseCursor(.Hand)
				tip("Copy")
			} else if lui.copied == f.label {
				delete(lui.copied)
				lui.copied = ""
			}
			im.DrawList_AddRectFilled(d, {x, y - 1}, {x + cw, y + 17}, col32(hov ? C_BORDER : C_CARD_HI), 6)
			lw := measure(fonts.ui, SZ_SMALL - 1, lab).x
			draw_text(fonts.ui, SZ_SMALL - 1, {x + 6, y + 1}, col32(lab == "copied" ? C_GREEN : C_MUTED), lab)
			draw_text(fonts.mono, SZ_SMALL, {x + 12 + lw, y}, col32(C_TEXT, 0.85), val)
			x += cw + 6
		}
		return chip_clicked
	}
	right: f32 = selected ? 30 : 0
	draw_text(fonts.bold, TITLE_SZ, {tx, pos.y + (sub != "" ? 10 : 19)}, col32(C_TEXT), fit(fonts.bold, TITLE_SZ, title, w - (tx - pos.x) - right))
	if sub != "" {
		draw_text(fonts.ui, SUB_SZ, {tx, pos.y + 33}, col32(C_MUTED), fit(fonts.ui, SUB_SZ, sub, w - (tx - pos.x) - right))
	}
	if selected {
		rsz := measure(fonts.ui, 18, ICON_RETURN)
		draw_text(fonts.ui, 18, {pos.x + w - rsz.x, pos.y + (ROW_H - 2 - rsz.y) / 2}, col32(C_MUTED), ICON_RETURN)
	}
	return false
}

// Cut `s` with an ellipsis to fit `w`.
@(private = "file")
fit :: proc(font: ^im.Font, size: f32, s: string, w: f32) -> string {
	if measure(font, size, s).x <= w {return s}
	cut := len(s)
	for cut > 0 && measure(font, size, s[:cut]).x + measure(font, size, "…").x > w {
		cut -= 1
		for cut > 0 && s[cut] & 0xc0 == 0x80 {cut -= 1} // whole UTF-8 sequences
	}
	return strings.concatenate({s[:cut], "…"}, context.temp_allocator)
}
