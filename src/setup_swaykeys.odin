// The key bindings in wlperch.conf, editable in the Sway card before they are
// installed: each one on or off with its own key. Choices are kept in
// <data>/sway-keys ("on<TAB>key<TAB>command" for the ones that differ from
// wlperch.conf), and the installed file is wlperch.conf with them applied.
// A draft is checked with sway -C against the user's own config; keys that
// clash show in red with what they are already bound to.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import im "third_party:odin-imgui"

Sway_Key :: struct {
	cmd:     string, // "exec wlperch track go": identifies the binding
	flags:   string, // e.g. "--to-code " (with the trailing space), or ""
	desc:    string, // the comment above it in wlperch.conf
	def_key: string,
	def_on:  bool,
	key:     [64]u8, // edited key (NUL-terminated, for the text field)
	on:      bool,
}

sway_keys: struct {
	list:      [dynamic]Sway_Key,
	loaded:    bool,
	open:      bool, // the editor is expanded
	clash:     map[int]string, // index in list -> what it's already bound to
	checked:   bool, // clash is up to date with the list
	check_ran: bool, // sway -C could run
	dirty_at:  time.Tick, // last edit; checked a moment later
	dirty:     bool,
}

@(private = "file") KEYS_CHECK_DELAY :: 500 * time.Millisecond
// Draft commands are marked "WLPERCH_KEYCHECK=<index> " (one binding each,
// even where two keys run the same command).
@(private = "file") KEYCHECK_MARK :: "WLPERCH_KEYCHECK="

sway_key_text :: proc(k: ^Sway_Key) -> string {return string(cstring(&k.key[0]))}

@(private = "file")
keys_file :: proc() -> string {
	d := data_dir()
	defer delete(d)
	return fmt.tprintf("%s/sway-keys", d)
}

// The bindings in a wlperch.conf text, active or commented out, in order.
sway_keys_parse :: proc(text: string, allocator := context.allocator) -> [dynamic]Sway_Key {
	out := make([dynamic]Sway_Key, allocator)
	desc := "" // the first line of the comment block above
	in_block := false
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		on := true
		if strings.has_prefix(t, "# bindsym ") || strings.has_prefix(t, "#bindsym ") {
			t = strings.trim_space(strings.trim_prefix(t, "#"))
			on = false
		} else if strings.has_prefix(t, "#") {
			if !in_block {desc = strings.trim_space(t[1:])}
			in_block = true
			continue
		} else if t == "" {
			desc, in_block = "", false
			continue
		}
		in_block = false
		if !strings.has_prefix(t, "bindsym ") {continue}
		f := strings.fields(t, context.temp_allocator)
		i := 1
		flags := strings.builder_make(context.temp_allocator)
		for i < len(f) && strings.has_prefix(f[i], "--") {
			fmt.sbprintf(&flags, "%s ", f[i])
			i += 1
		}
		if i + 1 >= len(f) {continue}
		k := Sway_Key {
			cmd     = strings.clone(strings.join(f[i + 1:], " ", context.temp_allocator), allocator),
			flags   = strings.clone(strings.to_string(flags), allocator),
			desc    = strings.clone(key_label(strings.join(f[i + 1:], " ", context.temp_allocator), desc), allocator),
			def_key = strings.clone(f[i], allocator),
			def_on  = on,
			on      = on,
		}
		copy(k.key[:len(k.key) - 1], f[i])
		append(&out, k)
	}
	return out
}

// wlperch.conf's bindings with the saved choices applied.
sway_keys_load :: proc() {
	if sway_keys.loaded {return}
	sway_keys.loaded = true
	sway_keys.list = sway_keys_parse(SWAY_FILE)
	data, err := os.read_entire_file(keys_file(), context.temp_allocator)
	if err != nil {return}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		f := strings.split_n(line, "\t", 3, context.temp_allocator)
		if len(f) != 3 {continue}
		for &k in sway_keys.list {
			if fmt.tprintf("%s %s", k.def_key, k.cmd) != f[2] {continue}
			k.on = f[0] == "on"
			k.key = {}
			copy(k.key[:len(k.key) - 1], strings.trim_space(f[1]))
		}
	}
}

@(private = "file")
keys_save :: proc() {
	b := strings.builder_make(context.temp_allocator)
	for &k in sway_keys.list {
		if k.on == k.def_on && sway_key_text(&k) == k.def_key {continue}
		fmt.sbprintf(&b, "%s\t%s\t%s %s\n", k.on ? "on" : "off", sway_key_text(&k), k.def_key, k.cmd)
	}
	path := keys_file()
	if strings.builder_len(b) == 0 {
		os.remove(path)
		return
	}
	dir := path[:strings.last_index_byte(path, '/')]
	os.make_directory_all(dir)
	_ = os.write_entire_file(path, strings.to_string(b))
}

// The wlperch.conf to install: SWAY_FILE with each binding's on/off and key.
sway_file_text :: proc(keys: []Sway_Key) -> string {
	changed := false
	for &k in keys {if k.on != k.def_on || sway_key_text(&k) != k.def_key {changed = true}}
	if !changed {return SWAY_FILE}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# Key bindings as chosen in wlperch setup.\n")
	// The n-th binding line (as sway_keys_parse counts them) is keys[n].
	n := 0
	rest := SWAY_FILE
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(strings.trim_prefix(strings.trim_space(line), "#"))
		emitted := false
		if strings.has_prefix(t, "bindsym ") && n < len(keys) {
			f := strings.fields(t, context.temp_allocator)
			i := 1
			for i < len(f) && strings.has_prefix(f[i], "--") {i += 1}
			if i + 1 < len(f) {
				k := &keys[n]
				n += 1
				indent := line[:len(line) - len(strings.trim_left_space(line))]
				key := sway_key_text(k)
				fmt.sbprintf(&b, "%s%sbindsym %s%s %s\n", indent, k.on && key != "" ? "" : "# ", k.flags, key != "" ? key : k.def_key, k.cmd)
				emitted = true
			}
		}
		if !emitted {
			strings.write_string(&b, line)
			strings.write_byte(&b, '\n')
		}
	}
	return strings.to_string(b)
}

// Check the draft against the user's sway config with sway -C: a temporary
// config includes theirs, then the draft's bindings (marked, so they can be
// told apart from an older wlperch.conf the config already includes).
sway_keys_check :: proc() {
	clear(&sway_keys.clash)
	sway_keys.checked, sway_keys.check_ran = true, false
	cfg := sway_running_config()
	if !os.exists(cfg) {return}
	dir := fmt.tprintf("%s/wlperch-keycheck-%d", os.get_env("XDG_RUNTIME_DIR", context.temp_allocator), os.get_pid())
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	draft := strings.builder_make(context.temp_allocator)
	for &k, i in sway_keys.list {
		if !k.on || sway_key_text(&k) == "" {continue}
		cmd := k.cmd
		if strings.has_prefix(cmd, "exec ") {cmd = fmt.tprintf("exec %s%d %s", KEYCHECK_MARK, i, cmd[5:])}
		fmt.sbprintf(&draft, "bindsym %s%s %s\n", k.flags, sway_key_text(&k), cmd)
	}
	_ = os.write_entire_file(fmt.tprintf("%s/draft.conf", dir), strings.to_string(draft))
	main := fmt.tprintf("%s/config", dir)
	_ = os.write_entire_file(main, fmt.tprintf("include %s\ninclude %s/draft.conf\n", cfg, dir))
	script := `exec env -u WAYLAND_DISPLAY WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway -C -V -c "$1" 2>&1`
	out, code := run_code({"sh", "-c", script, "sh", main}, 20 * time.Second, context.temp_allocator)
	if code < 0 {return}
	sway_keys.check_ran = true
	sway_keys_clashes(out, &sway_keys.clash)
}

// From sway -C -V output: which draft bindings (marked commands) replace, or
// are replaced by, a binding that isn't wlperch's, or another draft binding.
// A key an older wlperch.conf already took from the user still counts.
sway_keys_clashes :: proc(out: string, clash: ^map[int]string) {
	// "exec WLPERCH_KEYCHECK=3 wlperch …" -> 3, "exec wlperch …"
	draft :: proc(s: string) -> (index: int, cmd: string, ok: bool) {
		k := strings.index(s, KEYCHECK_MARK)
		if k < 0 {return}
		rest := s[k + len(KEYCHECK_MARK):]
		sp := strings.index_byte(rest, ' ')
		if sp < 0 {return}
		n := 0
		for c in rest[:sp] {
			if c < '0' || c > '9' {return}
			n = n * 10 + int(c - '0')
		}
		return n, strings.concatenate({s[:k], rest[sp + 1:]}, context.temp_allocator), true
	}
	owner := make(map[string]string, context.temp_allocator) // key -> the user's command an old wlperch.conf replaced
	for line in strings.split_lines(out, context.temp_allocator) {
		k := strings.index(line, "Overwriting binding '")
		if k < 0 {continue}
		key, to, from, ok := parse_overwrite_raw(line[k:])
		if !ok {continue}
		ti, tcmd, to_draft := draft(to)
		fi, fcmd, from_draft := draft(from)
		to_wl, from_wl := strings.contains(to, "wlperch"), strings.contains(from, "wlperch")
		switch {
		case to_draft && from_draft:
			clash[ti] = strings.clone(fmt.tprintf("another wlperch key: %s", fcmd))
			clash[fi] = strings.clone(fmt.tprintf("another wlperch key: %s", tcmd))
		case to_draft && !from_wl:
			clash[ti] = strings.clone(from)
		case to_draft:
			if theirs, have := owner[key]; have {clash[ti] = strings.clone(theirs)}
		case from_draft && !to_wl:
			clash[fi] = strings.clone(to)
		case to_wl && !from_wl:
			owner[key] = from
		}
	}
}

// Debounced check after an edit; from the setup loop. ms until due, or -1.
sway_keys_tick :: proc() -> int {
	if !sway_keys.dirty {return -1}
	left := KEYS_CHECK_DELAY - time.tick_since(sway_keys.dirty_at)
	if left > 0 {return int(time.duration_milliseconds(left)) + 1}
	sway_keys.dirty = false
	sway_keys_check()
	request_redraw(1)
	return -1
}

@(private = "file")
keys_edited :: proc() {
	keys_save()
	sway_keys.checked = false
	sway_keys.dirty, sway_keys.dirty_at = true, time.tick_now()
}

// Turn off the bindings that clash (after a failed install).
sway_keys_disable_clashes :: proc() {
	for &k, i in sway_keys.list {if i in sway_keys.clash {k.on = false}}
	keys_save()
	sway_keys.checked = false
}

sway_keys_clash_count :: proc() -> int {
	n := 0
	for &k, i in sway_keys.list {if k.on && i in sway_keys.clash {n += 1}}
	return n
}

// The editor in the Sway card: a toggle line, then one row per binding.
sway_keys_ui :: proc(width: f32, accent: u32) {
	sway_keys_load()
	n_on := 0
	for &k in sway_keys.list {if k.on {n_on += 1}}
	clashes := sway_keys_clash_count()
	label := fmt.tprintf("%s Key bindings · %d of %d on%s", sway_keys.open ? ICON_CHEVRON_DOWN : ICON_CHEVRON_RIGHT, n_on, len(sway_keys.list), clashes > 0 ? fmt.tprintf(" · %d clash%s", clashes, clashes == 1 ? "" : "es") : "")
	p := im.GetCursorScreenPos()
	sz := measure(fonts.ui, SZ_SMALL + 1, label)
	if im.InvisibleButton("##swaykeys-toggle", {sz.x + 4, sz.y + 6}) {
		sway_keys.open = !sway_keys.open
		if sway_keys.open && !sway_keys.checked {sway_keys.dirty, sway_keys.dirty_at = true, {}}
	}
	if im.IsItemHovered() {im.SetMouseCursor(.Hand)}
	draw_text(fonts.ui, SZ_SMALL + 1, {p.x, p.y + 3}, col32(clashes > 0 ? C_RED : accent), label)
	if !sway_keys.open {return}

	KEY_W :: 150
	for &k, i in sway_keys.list {
		im.PushIDInt(i32(i))
		defer im.PopID()
		bad := k.on && i in sway_keys.clash
		row := im.GetCursorScreenPos()
		if toggle_switch("##on", k.on, accent) {
			k.on = !k.on
			keys_edited()
		}
		im.SameLine(0, 10)
		// The key: a text field, outlined red when it clashes.
		fp := im.GetCursorScreenPos()
		fh := im.GetFrameHeight()
		field_fill(fp, fp + {KEY_W, fh}, 6, col32(C_WELL))
		im.PushStyleColorImVec4(.FrameBg, {0, 0, 0, 0})
		im.PushStyleVar(.FrameBorderSize, 0)
		im.PushStyleColorImVec4(.Text, rgba(k.on ? C_TEXT : C_MUTED))
		im.SetNextItemWidth(KEY_W)
		if im.InputTextWithHint("##key", cstr(k.def_key), cstring(&k.key[0]), len(k.key)) {keys_edited()}
		focused := im.IsItemActive()
		im.PopStyleColor(2)
		im.PopStyleVar()
		field_outline(fp, fp + {KEY_W, fh}, 6, bad ? col32(C_RED) : focused ? col32(accent, 0.85) : col32(C_BORDER))
		im.SameLine(0, 10)
		what := k.desc != "" ? k.desc : k.cmd
		dx := im.GetCursorScreenPos().x
		draw_text(fonts.ui, SZ_SMALL, {dx, row.y + 2}, col32(k.on ? C_TEXT : C_MUTED), fit_text(fonts.ui, SZ_SMALL, what, width - (dx - row.x)))
		draw_text(fonts.mono, SZ_SMALL - 1, {dx, row.y + 16}, col32(C_FAINT), fit_text(fonts.mono, SZ_SMALL - 1, k.cmd, width - (dx - row.x)))
		im.Dummy({1, fh})
		if bad {
			wrapped(fonts.ui, SZ_SMALL, C_RED, fmt.tprintf("%s already bound in your sway config: %s", ICON_ALERT, sway_keys.clash[i]), width)
		}
	}
	status, col := "", C_FAINT
	switch {
	case sway_keys.dirty || !sway_keys.checked: status = "checking with sway…"
	case !sway_keys.check_ran:                  status, col = "couldn't run sway -C to check", C_ORANGE
	case clashes > 0:                           status, col = fmt.tprintf("%d key%s already bound in your sway config: pick another or switch it off", clashes, clashes == 1 ? " is" : "s are"), C_RED
	case:                                       status, col = "no clashes with your sway config", C_GREEN
	}
	wrapped(fonts.ui, SZ_SMALL, col, status, width)
	wrapped(fonts.ui, SZ_SMALL, C_FAINT, "Used by Install / Update. Empty: the default key.", width)
}

// A short name for a binding: known wlperch commands by name, otherwise the
// comment's first phrase.
@(private = "file")
key_label :: proc(cmd, comment: string) -> string {
	LABELS :: [?][2]string {
		{"toggle --center", "Open the panel"},
		{"toggle calc", "Calculator"},
		{"toggle launch", "App launcher"},
		{"toggle run", "Run a command"},
		{"toggle emoji", "Emoji picker"},
		{"toggle system", "System panel"},
		{"theme toggle", "Dark / light"},
		{"wlperch lock", "Lock the screen"},
		{"track go", "Go to the project's workspaces"},
		{"track move", "Move the window to the project"},
		{"track pin", "Pin the current project"},
	}
	for l in LABELS {if strings.contains(cmd, l[0]) {return l[1]}}
	s := comment
	for c, i in s {
		if c == '.' || c == ':' || c == '(' || c == ';' {
			s = s[:i]
			break
		}
	}
	return strings.trim_space(s)
}

@(private = "file")
fit_text :: proc(font: ^im.Font, size: f32, s: string, w: f32) -> string {
	if measure(font, size, s).x <= w {return s}
	for n := len(s) - 1; n > 0; n -= 1 {
		if s[n] & 0xC0 == 0x80 {continue}
		t := fmt.tprintf("%s…", s[:n])
		if measure(font, size, t).x <= w {return t}
	}
	return ""
}
