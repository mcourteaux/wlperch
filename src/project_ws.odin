// More than one workspace of a project on a monitor: "<name> N" is the
// project's workspace on the N-th monitor (left to right), "<name> Nb",
// "<name> Nc", … are more of them on that monitor. All count as the project.
// The daemon remembers, per project and monitor, which of them was shown
// last: `track go`, Mod+P and the group lock bring each monitor back there.
// `track new` adds the next free letter on the focused monitor and
// `track next|prev` steps through the project's workspaces on it;
// `track move-new|move-next|move-prev` take the focused window along.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"

// The part after "<name> ": "2" (sub 0) or "2b" (sub 1), "2c" (sub 2), …
ws_suffix_parse :: proc(s: string) -> (n, sub: int, ok: bool) {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {i += 1}
	if i == 0 || i > 6 {return}
	v, _ := strconv.parse_int(s[:i])
	switch len(s) - i {
	case 0:
		return v, 0, true
	case 1:
		if c := s[i]; c >= 'a' && c <= 'z' {return v, int(c - 'a'), true}
	}
	return
}

// "NeonRAW 2b" -> (index of NeonRAW, 2, 1); p = -1 if it's no project's workspace.
project_ws_parse :: proc(ws: string) -> (p, n, sub: int) {
	p = -1
	for pr, i in tracker.projects {
		if !strings.has_prefix(ws, pr.name) {continue}
		rest := ws[len(pr.name):]
		if len(rest) < 2 || rest[0] != ' ' {continue}
		if nn, ss, ok := ws_suffix_parse(rest[1:]); ok {return i, nn, ss}
	}
	return
}

// The project's workspace `sub` on monitor n: "<name> n", "<name> nb", …
project_workspace_sub :: proc(p: Project, n, sub: int) -> string {
	if sub <= 0 || sub > 25 {return project_workspace(p, n)}
	return fmt.tprintf("%s %d%c", p.name, n, rune('a' + sub))
}

// Where monitor n goes for project p: the one it showed last, if it still
// exists (`existing` nil: don't check), else "<name> n".
project_target :: proc(p: Project, n: int, existing: []string) -> string {
	main := project_workspace(p, n)
	if last, ok := tracker.last_ws[main]; ok && last != main {
		if existing == nil || slice.contains(existing, last) {return strings.clone(last, context.temp_allocator)}
	}
	return main
}

// The project's workspaces on monitor n that exist, in letter order; "<name> n" always.
project_ws_on :: proc(index, n: int, existing: []string) -> []string {
	Ws :: struct {
		name: string,
		sub:  int,
	}
	found := make([dynamic]Ws, context.temp_allocator)
	append(&found, Ws{project_workspace(tracker.projects[index], n), 0})
	for w in existing {
		p, nn, sub := project_ws_parse(w)
		if p == index && nn == n && sub > 0 {append(&found, Ws{w, sub})}
	}
	slice.sort_by(found[:], proc(a, b: Ws) -> bool {return a.sub < b.sub})
	out := make([]string, len(found), context.temp_allocator)
	for w, i in found {out[i] = w.name}
	return out
}

// The first letter (b, c, …) not in use for project `index` on monitor n.
project_ws_free :: proc(index, n: int, existing: []string) -> string {
	pr := tracker.projects[index]
	for sub in 1 ..= 25 {
		ws := project_workspace_sub(pr, n, sub)
		if !slice.contains(existing, ws) {return ws}
	}
	return ""
}

// Workspace names as sway has them now, and the focused one and its output
// (asked, not from our event-fed state, which can lag a burst of switches).
sway_workspace_list :: proc() -> (names: []string, focused, output: string) {
	out: [dynamic]string
	out.allocator = context.temp_allocator
	reply, ok := sway_request(IPC_GET_WORKSPACES, "")
	if !ok {return}
	v, _ := jparse(reply)
	for ws in jarr(v) {
		name := strings.clone(jstr(jobj(ws, "name")), context.temp_allocator)
		append(&out, name)
		if jbool(jobj(ws, "focused")) {focused, output = name, strings.clone(jstr(jobj(ws, "output")), context.temp_allocator)}
	}
	return out[:], focused, output
}

ws_names :: proc() -> []string {
	names, _, _ := sway_workspace_list()
	return names
}

// The number (1 = leftmost) of monitor `output`.
@(private = "file")
monitor_number :: proc(output: string) -> int {
	outs, _ := project_outputs()
	for o, i in outs {if o == output {return i + 1}}
	return 1
}

// `track new`: another workspace of the project on this monitor.
tracker_new_workspace :: proc(index: int) -> string {
	if index < 0 || index >= len(tracker.projects) {return ""}
	tracker.last = index
	existing, _, output := sway_workspace_list()
	ws := project_ws_free(index, monitor_number(output), existing)
	if ws == "" {return ""}
	sway_command(fmt.tprintf(`workspace "%s" output %s; workspace "%s"`, ws, output, ws))
	return ws
}

// `track next|prev`: the project's next / previous workspace on this
// monitor (from elsewhere: the one it showed last).
tracker_step_workspace :: proc(index, dir: int) -> string {
	if index < 0 || index >= len(tracker.projects) {return ""}
	tracker.last = index
	existing, cur, output := sway_workspace_list()
	n := monitor_number(output)
	ws := project_ws_step(project_ws_on(index, n, existing), cur, dir) or_else project_target(tracker.projects[index], n, existing)
	sway_command(fmt.tprintf(`workspace "%s" output %s; workspace "%s"`, ws, output, ws))
	return ws
}

// The workspace after (dir 1) or before (-1) `cur` in `list`, wrapping;
// false when `cur` isn't one of them.
project_ws_step :: proc(list: []string, cur: string, dir: int) -> (string, bool) {
	i, found := slice.linear_search(list, cur)
	if !found {return "", false}
	return list[(i + dir + len(list)) % len(list)], true
}

// `track move-next|move-prev` (dir 1 / -1) and `track move-new` (dir 0):
// the focused window to the project's next / previous / a new workspace on
// this monitor, and the view follows it. From another workspace, next and
// prev take it to the one this monitor showed last. "" when there's nowhere
// to go: a single workspace (nothing is created) or no free letter.
tracker_move_window_step :: proc(index, dir: int) -> string {
	if index < 0 || index >= len(tracker.projects) {return ""}
	tracker.last = index
	existing, cur, output := sway_workspace_list()
	n := monitor_number(output)
	ws: string
	if dir == 0 {
		ws = project_ws_free(index, n, existing)
	} else {
		list := project_ws_on(index, n, existing)
		ok: bool
		if ws, ok = project_ws_step(list, cur, dir); !ok {
			ws = project_target(tracker.projects[index], n, existing)
		}
		if ws == cur {return ""}
	}
	if ws == "" {return ""}
	sway_command(fmt.tprintf(`workspace "%s" output %s; move container to workspace "%s"; workspace "%s"`, ws, output, ws, ws))
	return ws
}

// Every tick: remember which of its workspaces each monitor shows.
last_ws_note :: proc() {
	changed := false
	{
		sync.guard(&sway.mu)
		for v in sway.visible {
			p, n, _ := project_ws_parse(v.ws)
			if p < 0 {continue}
			changed |= last_ws_set(project_workspace(tracker.projects[p], n), v.ws)
		}
	}
	if changed {last_ws_save()}
}

// Remember `ws` as monitor `main`'s last; true if that changed.
last_ws_set :: proc(main, ws: string) -> bool {
	if old, had := tracker.last_ws[main]; had {
		if old == ws {return false}
		delete(old)
		tracker.last_ws[main] = strings.clone(ws)
		return true
	}
	tracker.last_ws[strings.clone(main)] = strings.clone(ws)
	return true
}

// Rename: the remembered workspaces follow ("old 1b" -> "new 1b").
last_ws_rename :: proc(old, new: string) {
	moves: [dynamic][2]string
	moves.allocator = context.temp_allocator
	for k, v in tracker.last_ws {
		if strings.has_prefix(k, old) && len(k) > len(old) && k[len(old)] == ' ' {append(&moves, [2]string{k, v})}
	}
	for m in moves {
		key, _ := delete_key(&tracker.last_ws, m[0])
		delete(key)
		delete(m[1])
		last_ws_set(fmt.tprintf("%s%s", new, m[0][len(old):]), fmt.tprintf("%s%s", new, m[1][len(old):]))
	}
	if len(moves) > 0 {last_ws_save()}
}

// "<name> N\t<workspace>" per line, so a restart keeps it.
last_ws_save :: proc() {
	if tracker.last_ws_path == "" {return}
	b := strings.builder_make(context.temp_allocator)
	for k, v in tracker.last_ws {fmt.sbprintf(&b, "%s\t%s\n", k, v)}
	_ = os.write_entire_file(tracker.last_ws_path, strings.to_string(b))
}

last_ws_load :: proc() {
	data, err := os.read_entire_file(tracker.last_ws_path, context.temp_allocator)
	if err != nil {return}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) == 2 && f[0] != "" && f[1] != "" {last_ws_set(f[0], f[1])}
	}
}
