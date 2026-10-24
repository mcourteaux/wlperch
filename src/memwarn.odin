// Low-memory warning: once available memory (MemAvailable / MemTotal) drops
// below [memory] warn_free_percent, a card pops up at the top of the screen
// with the biggest memory users and a SIGTERM / SIGKILL button for each.
//
// Why its own shm layer surface and not the GL panel: it has to work when
// memory is tight, and the daemon drops its GPU context (re-executes itself)
// whenever the panel is hidden, so this is software-rendered into shared
// memory like the notification popups. It is not a notification either: it
// needs a row of buttons per process, must show under do not disturb and
// must not time out.
//
// Threads: the sysmon sampler (1 Hz) runs the threshold state machine and,
// while the card is up, gathers the offenders; the main loop owns the
// surface (memwarn_tick) and the pointer.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

import "wl"

MEMWARN_HYST :: 5.0 // re-arm once available memory is this many % above the threshold
MEMWARN_TOP :: 5 // killable groups shown
MEMWARN_ROWS :: 8 // plus protected ones ranked in between
MEMWARN_MAX_PIDS :: 1024

// ---- Threshold ----------------------------------------------------------------------

// Hysteresis: low once free < warn; stays low until free >= warn + MEMWARN_HYST.
memwarn_step :: proc(low: bool, free_pct, warn_pct: f64) -> bool {
	if warn_pct <= 0 {return false}
	if !low {return free_pct < warn_pct}
	return free_pct < warn_pct + MEMWARN_HYST
}

// Test hook: with WLPERCH_TEST_MEM_AVAILABLE=<file>, MemAvailable is taken
// as the percentage of MemTotal written in that file (e.g. "8"), re-read on
// every sample, so the warning and the bar's states can be tried without
// actually running out of memory. Ignored when unset or unreadable.
mem_test_override :: proc(total: u64, avail: ^u64) {
	path := os.get_env("WLPERCH_TEST_MEM_AVAILABLE", context.temp_allocator)
	if path == "" || total == 0 {return}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return}
	pct, ok := strconv.parse_f64(strings.trim_space(string(data)))
	if !ok {return}
	avail^ = u64(f64(total) * clamp(pct, 0, 100) / 100)
}

// ---- Offenders ----------------------------------------------------------------------

Mw_Proc :: struct {
	pid:  i32,
	uid:  u32,
	rss:  u64,
	name: string, // executable (grouping key, like the processes module)
	comm: string,
}

Mw_Group :: struct {
	name:      [32]u8,
	nlen:      int,
	count:     int,
	rss:       u64,
	protected: bool, // shown, never offered for killing
	pids:      [MEMWARN_MAX_PIDS]i32,
	npids:     int,
}

mw_group_name :: proc(g: ^Mw_Group) -> string {return string(g.name[:g.nlen])}

// PID 1, the compositor, the user's service manager and wlperch itself.
memwarn_protected :: proc(p: Mw_Proc, my_pid: i32) -> bool {
	if p.pid <= 1 || p.pid == my_pid {return true}
	for n in ([]string{p.name, p.comm}) {
		switch n {
		case "sway", "systemd", "Xwayland", "init": return true
		}
		if strings.has_prefix(n, "wlperch") {return true}
	}
	return false
}

// Groups by executable; other users' processes are left out. Sorted by
// resident memory; MEMWARN_TOP killable groups, plus protected groups that
// rank above the last of those. Returns the number of rows filled.
memwarn_group :: proc(ps: []Mw_Proc, my_uid: u32, my_pid: i32, out: []Mw_Group) -> int {
	Acc :: struct {
		name:      string,
		protected: bool,
		rss:       u64,
		pids:      [dynamic]i32,
	}
	accs := make([dynamic]Acc, 0, 64, context.temp_allocator)
	index := make(map[string]int, 64, context.temp_allocator)
	for p in ps {
		if p.uid != my_uid || p.rss == 0 {continue}
		prot := memwarn_protected(p, my_pid)
		key := strings.concatenate({prot ? "!" : "", p.name}, context.temp_allocator)
		i, ok := index[key]
		if !ok {
			i = len(accs)
			index[key] = i
			append(&accs, Acc{name = p.name, protected = prot, pids = make([dynamic]i32, context.temp_allocator)})
		}
		a := &accs[i]
		a.rss += p.rss
		append(&a.pids, p.pid)
	}
	slice.sort_by(accs[:], proc(a, b: Acc) -> bool {return a.rss > b.rss})
	n, killable := 0, 0
	for &a in accs {
		if n == len(out) || killable == MEMWARN_TOP {break}
		g := &out[n]
		g^ = {}
		g.nlen = copy(g.name[:], a.name)
		g.count = len(a.pids)
		g.rss = a.rss
		g.protected = a.protected
		slice.sort(a.pids[:])
		g.npids = copy(g.pids[:], a.pids[:])
		n += 1
		if !a.protected {killable += 1}
	}
	// Protected groups below the last killable one add nothing.
	for n > 0 && out[n - 1].protected && killable > 0 {n -= 1}
	return n
}

@(private = "file")
proc_uid :: proc(pid: string) -> (uid: u32, ok: bool) {
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(strings.concatenate({"/proc/", pid}, context.temp_allocator), context.temp_allocator), &st) != .OK {return}
	return u32(st.st_uid), true
}

@(private = "file")
proc_comm :: proc(pid: string) -> string {
	data, err := os.read_entire_file(strings.concatenate({"/proc/", pid, "/comm"}, context.temp_allocator), context.temp_allocator)
	if err != nil {return ""}
	return strings.trim_space(string(data))
}

@(private = "file")
page_bytes: u64

// This user's processes with their resident memory (statm, like procs.odin).
@(private = "file")
scan_procs :: proc() -> []Mw_Proc {
	if page_bytes == 0 {
		v := posix.sysconf(._PAGESIZE)
		page_bytes = v > 0 ? u64(v) : 4096
	}
	me := u32(posix.getuid())
	out := make([dynamic]Mw_Proc, 0, 512, context.temp_allocator)
	entries, err := os.read_all_directory_by_path("/proc", context.temp_allocator)
	if err != nil {return nil}
	for e in entries {
		pid, ok := strconv.parse_int(e.name)
		if !ok {continue}
		uid, uok := proc_uid(e.name)
		if !uok || uid != me {continue}
		sm, merr := os.read_entire_file(strings.concatenate({"/proc/", e.name, "/statm"}, context.temp_allocator), context.temp_allocator)
		if merr != nil {continue}
		f := strings.fields(string(sm), context.temp_allocator)
		if len(f) < 2 {continue}
		pages, _ := strconv.parse_u64(f[1])
		if pages == 0 {continue}
		comm := proc_comm(e.name)
		append(&out, Mw_Proc{pid = i32(pid), uid = uid, rss = pages * page_bytes, name = exe_name(e.name, comm), comm = comm})
	}
	return out[:]
}

// ---- Shared state (sampler thread <-> main loop) --------------------------------------

Memwarn :: struct {
	mu:         sync.Mutex,
	low:        bool,
	episode:    int, // bumped every time memory goes low
	dismissed:  int, // the episode the user closed the card for
	avail:      u64,
	total:      u64,
	groups:     [MEMWARN_ROWS]Mw_Group,
	n:          int,
	sampled:    int, // episode the groups belong to (0: none yet)
	version:    int, // bumped with every new sample
}
memwarn: Memwarn

// Called by the sysmon thread after each memory sample.
memwarn_sample :: proc(used, total: u64) {
	if total == 0 {return}
	avail := total - min(used, total)
	free_pct := f64(avail) / f64(total) * 100
	sync.mutex_lock(&memwarn.mu)
	was := memwarn.low
	memwarn.low = memwarn_step(was, free_pct, f64(config.memory_free_warn_pct))
	if memwarn.low && !was {memwarn.episode += 1}
	memwarn.avail, memwarn.total = avail, total
	show := memwarn.low && memwarn.dismissed != memwarn.episode
	episode := memwarn.episode
	sync.mutex_unlock(&memwarn.mu)
	if show {
		ps := scan_procs()
		groups: [MEMWARN_ROWS]Mw_Group
		n := memwarn_group(ps, u32(posix.getuid()), i32(posix.getpid()), groups[:])
		sync.guard(&memwarn.mu)
		memwarn.groups = groups
		memwarn.n = n
		memwarn.sampled = episode
		memwarn.version += 1
	}
	if show || memwarn.low != was {wake_main()}
}

// Kept across re-executions, so a dismissed card stays dismissed.
memwarn_saved :: proc() -> (low, dismissed: bool) {
	sync.guard(&memwarn.mu)
	return memwarn.low, memwarn.low && memwarn.dismissed == memwarn.episode
}

memwarn_restore :: proc(low, dismissed: bool) {
	sync.guard(&memwarn.mu)
	memwarn.low = low
	if low {memwarn.episode = 1}
	if dismissed {memwarn.dismissed = 1}
	mw.logged = memwarn.episode // already in the history
}

// Card on screen: the GPU-release re-exec waits, like for notifications.
memwarn_busy :: proc() -> bool {return mw.surface != nil}

// ---- The card -----------------------------------------------------------------------

@(private = "file") CARD_W :: 452
@(private = "file") SHADOW_M :: 14
@(private = "file") PAD :: 16
@(private = "file") RADIUS :: 14
@(private = "file") ROW_H :: 34
@(private = "file") BTN_H :: 26
@(private = "file") TERM_W :: 74
@(private = "file") KILL_W :: 100
@(private = "file") CONFIRM :: 4 * time.Second
@(private = "file") NOTE_FOR :: 5 * time.Second

@(private = "file")
Mw_Card :: struct {
	surface:    ^wl.Surface,
	layer:      ^wl.Zwlr_Layer_Surface_V1,
	configured: bool,
	dirty:      bool,
	w, h:       i32,
	scale:      i32,
	light:      bool, // theme it was drawn in
	version:    int,
	logged:     int, // episode written to the notification history
	// What's shown (a copy of the sampler's).
	groups:     [MEMWARN_ROWS]Mw_Group,
	n:          int,
	avail:      u64,
	total:      u64,
	// Pointer.
	hovered:    bool,
	mx, my:     f32,
	part:       int, // -1 none, 0 close, 1 + 2*row (SIGTERM), 2 + 2*row (SIGKILL)
	close_r:    Bar_Rect,
	term_r:     [MEMWARN_ROWS]Bar_Rect,
	kill_r:     [MEMWARN_ROWS]Bar_Rect,
	// SIGKILL confirmation: the group armed by the first click.
	armed:      [32]u8,
	armed_len:  int,
	armed_at:   time.Tick,
	// One line of feedback after a button.
	note:       [96]u8,
	note_len:   int,
	note_bad:   bool,
	note_at:    time.Tick,
}
@(private = "file") mw: Mw_Card

memwarn_owns :: proc(surface: ^wl.Surface) -> bool {return surface != nil && surface == mw.surface}

@(private = "file")
fmt_gib :: proc(b: u64) -> string {
	GiB :: f64(1 << 30)
	if b < 1 << 30 {return fmt.tprintf("%.0f MiB", f64(b) / (1 << 20))}
	return fmt.tprintf("%.1f GiB", f64(b) / GiB)
}

@(private = "file")
card_height :: proc() -> i32 {
	h := PAD + 24 + 22 + 14 + 22 // title, figures, meter, heading
	h += max(mw.n, 1) * ROW_H
	h += 8 + 18 // note / hint line
	return i32(h + PAD)
}

@(private = "file")
output_scale :: proc() -> i32 {
	s: i32 = 1
	for o in plat.outputs {s = max(s, o.scale)}
	return s
}

@(private = "file")
layer_listener := wl.Zwlr_Layer_Surface_V1_Listener {
	configure = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1, serial, width, height: u32) {
		wl.zwlr_layer_surface_v1_ack_configure(self, serial)
		mw.configured = true
		mw.dirty = true
	},
	closed = proc "c" (data: rawptr, self: ^wl.Zwlr_Layer_Surface_V1) {
		mw.configured = false
	},
}

@(private = "file")
create :: proc() {
	if plat.layer_shell == nil || plat.compositor == nil || plat.shm == nil {return}
	mw.part = -1
	mw.scale = output_scale()
	mw.w = CARD_W + 2 * SHADOW_M
	mw.h = card_height() + 2 * SHADOW_M
	mw.surface = wl.compositor_create_surface(plat.compositor)
	mw.layer = wl.zwlr_layer_shell_v1_get_layer_surface(plat.layer_shell, mw.surface, nil, wl.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "wlperch-memory-warning")
	wl.zwlr_layer_surface_v1_add_listener(mw.layer, &layer_listener, nil)
	// Top centre: clear of the notification stack in the top-right corner.
	wl.zwlr_layer_surface_v1_set_anchor(mw.layer, wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP)
	wl.zwlr_layer_surface_v1_set_size(mw.layer, u32(mw.w), u32(mw.h))
	wl.zwlr_layer_surface_v1_set_margin(mw.layer, 8 - SHADOW_M, 0, 0, 0)
	wl.surface_commit(mw.surface)
}

@(private = "file")
destroy :: proc() {
	if mw.surface == nil {return}
	if plat.pointer_surface == mw.surface {plat.pointer_surface = nil}
	wl.zwlr_layer_surface_v1_destroy(mw.layer)
	wl.surface_destroy(mw.surface)
	mw.surface, mw.layer = nil, nil
	mw.configured = false
	mw.hovered = false
	mw.armed_len = 0
	mw.note_len = 0
}

@(private = "file")
set_note :: proc(s: string, bad := false) {
	mw.note_len = copy(mw.note[:], s)
	mw.note_bad = bad
	mw.note_at = time.tick_now()
	mw.dirty = true
}

@(private = "file")
armed_row :: proc() -> int {
	if mw.armed_len == 0 {return -1}
	for i in 0 ..< mw.n {
		g := &mw.groups[i]
		if !g.protected && mw_group_name(g) == string(mw.armed[:mw.armed_len]) {return i}
	}
	return -1
}

@(private = "file")
center_text :: proc(cv: ^Bar_Canvas, r: Bar_Rect, f: Bar_Font, px: f32, s: string, rgb: u32) {
	w := bar_text_width(f, px, s)
	bar_text(cv, f, px, r.x + (r.w - w) / 2, r.y + r.h / 2 + 0.33 * px, s, rgb)
}

@(private = "file")
ellipsize :: proc(f: Bar_Font, px, w: f32, s: string) -> string {
	if bar_text_width(f, px, s) <= w {return s}
	cut := len(s)
	for cut > 0 && bar_text_width(f, px, s[:cut]) + bar_text_width(f, px, "…") > w {cut -= 1}
	for cut > 0 && (s[cut] & 0xc0) == 0x80 {cut -= 1} // whole UTF-8 sequences
	return strings.concatenate({s[:cut], "…"}, context.temp_allocator)
}

@(private = "file")
render :: proc() {
	h := card_height() + 2 * SHADOW_M
	if h != mw.h {
		// New height: wait for the configure before drawing at it.
		mw.h = h
		wl.zwlr_layer_surface_v1_set_size(mw.layer, u32(mw.w), u32(mw.h))
		wl.surface_commit(mw.surface)
		mw.configured = false
		return
	}
	s := max(mw.scale, 1)
	b, ok := bar_buffer_new(int(mw.w * s), int(mw.h * s), f32(s))
	if !ok {return}
	cv := &b.cv
	mw.light = theme_light

	card := Bar_Rect{SHADOW_M, SHADOW_M, CARD_W, f32(mw.h - 2 * SHADOW_M)}
	bar_shadow(cv, card, RADIUS, SHADOW_M - 2)
	bar_fill_round(cv, card, RADIUS, C_CARD, 0.98)
	bar_stroke(cv, card, {RADIUS, RADIUS, RADIUS, RADIUS}, C_RED, 0.9)

	x0, x1 := card.x + PAD, card.x + card.w - PAD
	y := card.y + PAD
	// Title row and the close button.
	bar_text(cv, .Regular, 18, x0, y + 17, ICON_ALERT, C_RED)
	bar_text(cv, .Bold, 15, x0 + 26, y + 16, "Low memory", C_RED)
	mw.close_r = {x1 - 24, y - 2, 26, 26}
	{
		hot := mw.part == 0
		bar_fill_round(cv, mw.close_r, 13, hot ? C_RED : C_OVERLAY, hot ? 0.22 : 0.07)
		center_text(cv, mw.close_r, .Regular, 14, ICON_CLOSE, hot ? C_RED : C_MUTED)
	}
	y += 24

	// Figures and a meter of what's used.
	used := mw.total - min(mw.avail, mw.total)
	free_pct := mw.total > 0 ? f64(mw.avail) / f64(mw.total) * 100 : 0
	line := fmt.tprintf("%s available of %s (%.0f%% free)", fmt_gib(mw.avail), fmt_gib(mw.total), free_pct)
	bar_text(cv, .Regular, 13, x0, y + 14, line, C_TEXT)
	lim := fmt.tprintf("warns below %d%%", config.memory_free_warn_pct)
	bar_text(cv, .Regular, 11.5, x1 - bar_text_width(.Regular, 11.5, lim), y + 14, lim, C_FAINT)
	y += 22
	{
		r := Bar_Rect{x0, y, x1 - x0, 6}
		bar_fill_round(cv, r, 3, C_TRACK, 1)
		f := mw.total > 0 ? f32(f64(used) / f64(mw.total)) : 0
		if f > 0 {bar_fill_round(cv, {r.x, r.y, max(r.w * f, 6), r.h}, 3, C_RED, 0.9)}
	}
	y += 14
	bar_text(cv, .Regular, 11.5, x0, y + 13, "Biggest memory users (resident)", C_MUTED)
	y += 22

	if mw.n == 0 {
		bar_text(cv, .Regular, 13, x0, y + 21, "Looking…", C_FAINT)
	}
	armed := armed_row()
	any_group := false
	for i in 0 ..< mw.n {
		g := &mw.groups[i]
		ry := y + f32(i) * ROW_H
		by := ry + (ROW_H - BTN_H) / 2
		kill_r := Bar_Rect{x1 - KILL_W, by, KILL_W, BTN_H}
		term_r := Bar_Rect{kill_r.x - 6 - TERM_W, by, TERM_W, BTN_H}
		size := fmt_gib(g.rss)
		size_w := bar_text_width(.Regular, 13, size)
		size_x := term_r.x - 12 - size_w
		name := mw_group_name(g)
		label := g.count > 1 ? fmt.tprintf("%s ×%d", name, g.count) : name
		label = ellipsize(.Bold, 13.5, size_x - 10 - x0, label)
		base := ry + ROW_H / 2 + 4.5
		if i > 0 {bar_fill_round(cv, {x0, ry, x1 - x0, 1}, 0, C_BORDER, 0.7)}
		if g.protected {
			bar_text(cv, .Bold, 13.5, x0, base, label, C_FAINT)
			bar_text(cv, .Regular, 13, size_x, base, size, C_FAINT)
			center_text(cv, {term_r.x, by, x1 - term_r.x, BTN_H}, .Regular, 12, "protected", C_FAINT)
			mw.term_r[i], mw.kill_r[i] = {}, {}
			continue
		}
		if g.count > 1 {any_group = true}
		bar_text(cv, .Bold, 13.5, x0, base, label, C_TEXT)
		bar_text(cv, .Regular, 13, size_x, base, size, C_MUTED)
		mw.term_r[i], mw.kill_r[i] = term_r, kill_r
		{
			hot := mw.part == 1 + 2 * i
			bar_fill_round(cv, term_r, 7, C_ORANGE, hot ? 0.32 : 0.15)
			center_text(cv, term_r, .Bold, 12, "SIGTERM", C_ORANGE)
		}
		{
			hot := mw.part == 2 + 2 * i
			if i == armed {
				bar_fill_round(cv, kill_r, 7, C_RED, 1)
				center_text(cv, kill_r, .Bold, 12, "Really kill?", theme_light ? 0xffffff : C_BG)
			} else {
				bar_fill_round(cv, kill_r, 7, C_RED, hot ? 0.32 : 0.15)
				center_text(cv, kill_r, .Bold, 12, "SIGKILL", C_RED)
			}
		}
	}
	y += f32(max(mw.n, 1)) * ROW_H + 8
	if mw.note_len > 0 {
		bar_text(cv, .Regular, 12, x0, y + 13, string(mw.note[:mw.note_len]), mw.note_bad ? C_RED : C_GREEN)
	} else if any_group {
		bar_text(cv, .Regular, 11.5, x0, y + 13, "A ×N row signals every process in that group.", C_FAINT)
	}

	bar_buffer_attach(&b, plat.shm, mw.surface, s)
	region := wl.compositor_create_region(plat.compositor)
	wl.region_add(region, i32(card.x), i32(card.y), i32(card.w), i32(card.h))
	wl.surface_set_input_region(mw.surface, region)
	wl.region_destroy(region)
	wl.surface_commit(mw.surface)
	mw.dirty = false
}

// One entry in the notification history per low-memory episode.
@(private = "file")
log_history :: proc() {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s available of %s.", fmt_gib(mw.avail), fmt_gib(mw.total))
	for i in 0 ..< min(mw.n, 3) {
		g := &mw.groups[i]
		fmt.sbprintf(&b, i == 0 ? " Biggest: %s" : ", %s", mw_group_name(g))
		if g.count > 1 {fmt.sbprintf(&b, " ×%d", g.count)}
		fmt.sbprintf(&b, " %s", fmt_gib(g.rss))
	}
	notif_log_local("Memory", fmt.tprintf("Low memory: %.0f%% free", f64(mw.avail) / f64(max(mw.total, 1)) * 100), strings.to_string(b), 2)
}

// Main loop: show / update / hide the card; expire the confirm and the note.
memwarn_tick :: proc() {
	sync.mutex_lock(&memwarn.mu)
	want := memwarn.low && memwarn.dismissed != memwarn.episode
	episode := memwarn.episode
	fresh := memwarn.version != mw.version && memwarn.sampled == episode
	if fresh {
		mw.version = memwarn.version
		mw.groups = memwarn.groups
		mw.n = memwarn.n
		mw.avail, mw.total = memwarn.avail, memwarn.total
	}
	sampled := memwarn.sampled
	sync.mutex_unlock(&memwarn.mu)

	if !want {
		destroy()
		return
	}
	if mw.surface == nil {
		// Wait for the first offender list so the card opens complete.
		if sampled != episode {return}
		create()
		if mw.surface == nil {return}
	}
	if fresh {mw.dirty = true}
	if mw.logged != episode && mw.n > 0 {
		mw.logged = episode
		log_history()
	}
	now := time.tick_now()
	if mw.armed_len > 0 && time.tick_diff(mw.armed_at, now) >= CONFIRM {
		mw.armed_len = 0
		mw.dirty = true
	}
	if mw.note_len > 0 && time.tick_diff(mw.note_at, now) >= NOTE_FOR {
		mw.note_len = 0
		mw.dirty = true
	}
	if mw.light != theme_light {mw.dirty = true}
	if mw.dirty && mw.configured {render()}
}

// How long the main loop may sleep for the confirm / note to expire (-1: no limit).
memwarn_timeout :: proc() -> time.Duration {
	if mw.surface == nil {return -1}
	best := time.Duration(-1)
	now := time.tick_now()
	if mw.armed_len > 0 {best = max(CONFIRM - time.tick_diff(mw.armed_at, now), 0)}
	if mw.note_len > 0 {
		d := max(NOTE_FOR - time.tick_diff(mw.note_at, now), 0)
		if best < 0 || d < best {best = d}
	}
	return best
}

// ---- Signals --------------------------------------------------------------------------

// Every PID of the group that is still this user's and still the same program.
@(private = "file")
signal_group :: proc(g: ^Mw_Group, sig: posix.Signal) -> (sent, failed: int) {
	me := u32(posix.getuid())
	my_pid := i32(posix.getpid())
	name := mw_group_name(g)
	for pid in g.pids[:g.npids] {
		ps := fmt.tprint(pid)
		uid, ok := proc_uid(ps)
		if !ok {continue} // already gone
		comm := proc_comm(ps)
		p := Mw_Proc{pid = pid, uid = uid, name = exe_name(ps, comm), comm = comm}
		if uid != me || p.name != name || memwarn_protected(p, my_pid) {continue}
		if posix.kill(posix.pid_t(pid), sig) == .OK {sent += 1} else {failed += 1}
	}
	return
}

@(private = "file")
send :: proc(row: int, sig: posix.Signal) {
	g := &mw.groups[row]
	if g.protected {return}
	sent, failed := signal_group(g, sig)
	sig_name := sig == .SIGKILL ? "SIGKILL" : "SIGTERM"
	name := mw_group_name(g)
	switch {
	case failed > 0:
		set_note(fmt.tprintf("%s: %d sent, %d failed (%s)", sig_name, sent, failed, name), true)
	case sent == 0:
		set_note(fmt.tprintf("%s has already exited", name), true)
	case sent == 1:
		set_note(fmt.tprintf("Sent %s to %s", sig_name, name))
	case:
		set_note(fmt.tprintf("Sent %s to %d processes (%s)", sig_name, sent, name))
	}
}

// ---- Pointer --------------------------------------------------------------------------

@(private = "file")
hit :: proc() -> int {
	if bar_in_rect(mw.close_r, mw.mx, mw.my) {return 0}
	for i in 0 ..< mw.n {
		if bar_in_rect(mw.term_r[i], mw.mx, mw.my) {return 1 + 2 * i}
		if bar_in_rect(mw.kill_r[i], mw.mx, mw.my) {return 2 + 2 * i}
	}
	return -1
}

memwarn_on_enter :: proc(surface: ^wl.Surface, x, y: f32) -> bool {
	if !memwarn_owns(surface) {return false}
	mw.hovered = true
	mw.mx, mw.my = x, y
	mw.part = hit()
	mw.dirty = true
	if plat.cursor_device != nil {
		wl.wp_cursor_shape_device_v1_set_shape(plat.cursor_device, plat.pointer_serial, wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT)
	}
	return true
}

memwarn_on_leave :: proc(surface: ^wl.Surface) -> bool {
	if !memwarn_owns(surface) {return false}
	mw.hovered = false
	if mw.part != -1 {mw.dirty = true}
	mw.part = -1
	return true
}

memwarn_on_motion :: proc(surface: ^wl.Surface, x, y: f32) -> bool {
	if !memwarn_owns(surface) {return false}
	mw.mx, mw.my = x, y
	if part := hit(); part != mw.part {
		mw.part = part
		mw.dirty = true
		if plat.cursor_device != nil {
			shape := u32(part >= 0 ? wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER : wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT)
			wl.wp_cursor_shape_device_v1_set_shape(plat.cursor_device, plat.pointer_serial, shape)
		}
	}
	return true
}

memwarn_on_button :: proc(surface: ^wl.Surface, button, state: u32) -> bool {
	if !memwarn_owns(surface) {return false}
	if state != wl.POINTER_BUTTON_STATE_RELEASED || button != 0x110 {return true}
	part := hit()
	switch {
	case part == 0:
		sync.guard(&memwarn.mu)
		memwarn.dismissed = memwarn.episode
		destroy()
	case part > 0 && part % 2 == 1:
		send((part - 1) / 2, .SIGTERM)
	case part > 0:
		row := (part - 2) / 2
		if armed_row() == row {
			mw.armed_len = 0
			send(row, .SIGKILL)
		} else {
			mw.armed_len = copy(mw.armed[:], mw_group_name(&mw.groups[row]))
			mw.armed_at = time.tick_now()
		}
		mw.dirty = true
	}
	return true
}
