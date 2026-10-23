// Top processes by CPU and by memory. Processes are grouped by executable
// name (all of Firefox's content processes count as "firefox"). Sampling only
// runs while a panel showing the processes module is open.
package main

import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

PROC_TOP :: 8
PROC_INTERVAL :: 2 * time.Second

Proc_Group :: struct {
	name:  [32]u8,
	nlen:  int,
	count: int,
	cpu:   f32, // % of one core, summed over the group (like top)
	rss:   u64, // bytes
}

proc_group_name :: proc(g: ^Proc_Group) -> string {return string(g.name[:g.nlen])}

Procs :: struct {
	mu:      sync.Mutex,
	ok:      bool,
	by_cpu:  [PROC_TOP]Proc_Group,
	n_cpu:   int,
	by_mem:  [PROC_TOP]Proc_Group,
	n_mem:   int,
	total:   int, // processes seen
	active:  bool, // set by the UI while the module is on screen
}
procs: Procs

@(private = "file")
prev_ticks: map[i32]u64 // pid -> utime+stime at the previous sample
@(private = "file")
prev_time: time.Tick
@(private = "file")
clk_tck: f64 = 100
@(private = "file")
page_size: u64 = 4096

@(private = "file")
wake: sync.Sema

// Called each frame by the module; starts sampling right away when it appears.
procs_mark_active :: proc() {
	if !procs.active {
		procs.active = true
		sync.sema_post(&wake)
	}
}

@(private = "file")
exe_name :: proc(pid: string, comm: string) -> string {
	link := strings.concatenate({"/proc/", pid, "/exe"}, context.temp_allocator)
	if target, err := os.read_link(link, context.temp_allocator); err == nil && len(target) > 0 {
		target = strings.trim_suffix(target, " (deleted)")
		// Versioned installs (".../claude/versions/2.1.308"): name them after
		// the first path component that isn't a version or a "versions"/"bin" dir.
		parts := strings.split(target, "/", context.temp_allocator)
		for i := len(parts) - 1; i >= 0; i -= 1 {
			c := parts[i]
			if c == "" || c == "versions" || c == "bin" || (c[0] >= '0' && c[0] <= '9') {continue}
			return c
		}
	}
	return comm
}

@(private = "file")
sample :: proc() {
	now := time.tick_now()
	elapsed := time.duration_seconds(time.tick_diff(prev_time, now))
	first := prev_time == {}
	prev_time = now

	Acc :: struct {
		cpu: f64,
		rss: u64,
		n:   int,
	}
	groups := make(map[string]Acc, 256, context.temp_allocator)
	seen := make(map[i32]u64, 512, context.temp_allocator)

	dir, err := os.open("/proc")
	if err != nil {return}
	entries, _ := os.read_all_directory(dir, context.temp_allocator)
	os.close(dir)
	total := 0
	for e in entries {
		pid_n, ok := strconv.parse_int(e.name)
		if !ok {continue}
		pid := i32(pid_n)
		stat, serr := os.read_entire_file(strings.concatenate({"/proc/", e.name, "/stat"}, context.temp_allocator), context.temp_allocator)
		if serr != nil {continue}
		s := string(stat)
		// "pid (comm) state ..." — comm may contain spaces and parens.
		open := strings.index_byte(s, '(')
		close := strings.last_index_byte(s, ')')
		if open < 0 || close < open {continue}
		comm := s[open + 1:close]
		fields := strings.fields(s[close + 1:], context.temp_allocator)
		if len(fields) < 13 {continue}
		utime, _ := strconv.parse_u64(fields[11])
		stime, _ := strconv.parse_u64(fields[12])
		ticks := utime + stime
		seen[pid] = ticks

		rss: u64
		if sm, merr := os.read_entire_file(strings.concatenate({"/proc/", e.name, "/statm"}, context.temp_allocator), context.temp_allocator); merr == nil {
			if f := strings.fields(string(sm), context.temp_allocator); len(f) >= 2 {
				pages, _ := strconv.parse_u64(f[1])
				rss = pages * page_size
			}
		}
		// Kernel threads have no memory and aren't interesting here.
		if rss == 0 {continue}
		total += 1

		cpu: f64
		if prev, had := prev_ticks[pid]; had && !first && elapsed > 0 && ticks >= prev {
			cpu = f64(ticks - prev) / clk_tck / elapsed * 100
		}
		name := exe_name(e.name, comm)
		a := groups[name]
		a.cpu += cpu
		a.rss += rss
		a.n += 1
		groups[name] = a
	}
	clear(&prev_ticks)
	for pid, t in seen {prev_ticks[pid] = t}

	list := make([dynamic]Proc_Group, 0, len(groups), context.temp_allocator)
	for name, a in groups {
		g := Proc_Group{count = a.n, cpu = f32(a.cpu), rss = a.rss}
		g.nlen = copy(g.name[:], name)
		append(&list, g)
	}

	sync.guard(&procs.mu)
	slice.sort_by(list[:], proc(a, b: Proc_Group) -> bool {return a.cpu > b.cpu})
	procs.n_cpu = min(len(list), PROC_TOP)
	copy(procs.by_cpu[:], list[:procs.n_cpu])
	slice.sort_by(list[:], proc(a, b: Proc_Group) -> bool {return a.rss > b.rss})
	procs.n_mem = min(len(list), PROC_TOP)
	copy(procs.by_mem[:], list[:procs.n_mem])
	procs.total = total
	procs.ok = !first
}

procs_start :: proc() {
	if v := posix.sysconf(._CLK_TCK); v > 0 {clk_tck = f64(v)}
	if v := posix.sysconf(._PAGESIZE); v > 0 {page_size = u64(v)}
	thread.create_and_start(proc() {
		for {
			if !(procs.active && plat_visible_flag) {
				procs.active = false
				prev_time = {}
				sync.sema_wait(&wake)
				continue
			}
			sample()
			wake_ui()
			free_all(context.temp_allocator)
			// Drop "active" so sampling stops once the module is no longer drawn.
			procs.active = false
			// First sample only establishes the baseline: take the next one quickly.
			wait := procs.ok ? PROC_INTERVAL : 500 * time.Millisecond
			time.sleep(wait)
		}
	})
}
