// Ask sway to validate its config (sway -C) before setup reloads it, and
// find what wlperch's changes break: a key wlperch binds that the user's
// config already binds ("Overwriting binding", which sway only reports as a
// swaynag warning after the reload), or a line sway rejects in a file
// wlperch wrote. A sway that is running is asked nothing: -C reads the files
// with a throwaway headless backend.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"

Sway_Conflict :: struct {
	key:  string, // as sway reports it, e.g. "Mod4+p"
	ours: string, // wlperch's command
	theirs: string, // the user's command it would replace (or that replaces it)
}

Sway_Check :: struct {
	ran:       bool, // sway -C could be run at all
	conflicts: [dynamic]Sway_Conflict,
	errors:    [dynamic]string, // "Error on line …" messages
}

// The config the running sway was started with (its -c), else the default.
sway_running_config :: proc() -> string {
	sock := os.get_env("SWAYSOCK", context.temp_allocator)
	// sway-ipc.<uid>.<pid>.sock
	if i := strings.last_index(sock, ".sock"); i > 0 {
		head := sock[:i]
		if j := strings.last_index_byte(head, '.'); j >= 0 {
			raw, err := os.read_entire_file(fmt.tprintf("/proc/%s/cmdline", head[j + 1:]), context.temp_allocator)
			if err == nil {
				args := strings.split(strings.trim_right(string(raw), "\x00"), "\x00", context.temp_allocator)
				for a, k in args {
					if (a == "-c" || a == "--config") && k + 1 < len(args) {return args[k + 1]}
					if strings.has_prefix(a, "--config=") {return a[len("--config="):]}
				}
			}
		}
	}
	return strings.concatenate({sway_config_home(), "/sway/config"}, context.temp_allocator)
}

// Run sway -C -V on the config and collect the conflicts and errors that
// involve wlperch. Errors elsewhere are the user's own and only counted.
sway_config_check :: proc(allocator := context.temp_allocator) -> (c: Sway_Check) {
	c.conflicts.allocator = allocator
	c.errors.allocator = allocator
	cfg := sway_running_config()
	if !os.exists(cfg) {return}
	// -V: "Overwriting binding" is logged at info level. Headless + pixman:
	// no GPU, no outputs, no windows.
	script := `exec env -u WAYLAND_DISPLAY WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway -C -V -c "$1" 2>&1`
	out, code := run_code({"sh", "-c", script, "sh", cfg}, 20 * time.Second, context.temp_allocator)
	if code < 0 {return}
	c = sway_check_parse(out, allocator)
	log.debugf("setup: sway -C %s: %d conflicts, %d errors", cfg, len(c.conflicts), len(c.errors))
	return
}

// The conflicts and errors involving wlperch in sway -C -V's output.
sway_check_parse :: proc(out: string, allocator := context.temp_allocator) -> (c: Sway_Check) {
	c.ran = true
	c.conflicts.allocator = allocator
	c.errors.allocator = allocator
	for line in strings.split_lines(out, context.temp_allocator) {
		if k := strings.index(line, "Overwriting binding '"); k >= 0 {
			if conflict, ok := parse_overwrite(line[k:], allocator); ok {append(&c.conflicts, conflict)}
		} else if k := strings.index(line, "Error on line"); k >= 0 {
			msg := line[k:]
			if strings.contains(msg, "wlperch") {append(&c.errors, strings.clone(msg, allocator))}
		}
	}
	return
}

// "Overwriting binding 'KEY' [for device 'D'] to `NEW` from `OLD`": a conflict
// when either command is wlperch's.
@(private = "file")
parse_overwrite :: proc(s: string, allocator := context.temp_allocator) -> (c: Sway_Conflict, ok: bool) {
	key, newer, older, parsed := parse_overwrite_raw(s)
	if !parsed {return}
	switch {
	case strings.contains(newer, "wlperch") && !strings.contains(older, "wlperch"): c.ours, c.theirs = newer, older
	case strings.contains(older, "wlperch") && !strings.contains(newer, "wlperch"): c.ours, c.theirs = older, newer
	case: return // neither (the user's own duplicate) or both
	}
	c.key = strings.clone(key, allocator)
	c.ours = strings.clone(c.ours, allocator)
	c.theirs = strings.clone(c.theirs, allocator)
	return c, true
}

// "Overwriting binding 'KEY' [for device 'D'] to `NEW` from `OLD`" -> its parts.
parse_overwrite_raw :: proc(s: string) -> (key, newer, older: string, ok: bool) {
	rest := s[len("Overwriting binding '"):]
	q := strings.index_byte(rest, '\'')
	if q < 0 {return}
	key = rest[:q]
	rest = rest[q:]
	to := strings.index(rest, "to `")
	if to < 0 {return}
	rest = rest[to + 4:]
	e := strings.index_byte(rest, '`')
	if e < 0 {return}
	newer = rest[:e]
	rest = rest[e + 1:]
	from := strings.index(rest, "from `")
	if from < 0 {return}
	rest = rest[from + 6:]
	e = strings.index_byte(rest, '`')
	if e < 0 {return}
	older = rest[:e]
	return key, newer, older, true
}

// One line per problem, for a card message.
sway_check_text :: proc(c: Sway_Check) -> string {
	b := strings.builder_make(context.temp_allocator)
	for x in c.conflicts {fmt.sbprintf(&b, "\n%s is already bound in your sway config (%s)", x.key, x.theirs)}
	for e in c.errors {fmt.sbprintf(&b, "\nsway: %s", e)}
	return strings.to_string(b)
}

// Reload sway unless sway -C finds a conflict or error involving wlperch.
// problem says why it didn't (empty when it reloaded or sway isn't there).
sway_reload_checked :: proc() -> (reloaded: bool, problem: string) {
	c := sway_config_check()
	if len(c.conflicts) > 0 || len(c.errors) > 0 {
		return false, fmt.tprintf("not reloaded, sway reports:%s", sway_check_text(c))
	}
	return sway_command("reload"), ""
}

// For the components that switch your own sway lines and reload: false (and
// a log line) when sway reports a conflict or error involving wlperch.
sway_reload_if_valid :: proc() -> bool {
	ok, problem := sway_reload_checked()
	if problem != "" {log.warnf("setup: %s", problem)}
	return ok
}
