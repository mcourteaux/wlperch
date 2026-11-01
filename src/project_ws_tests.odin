#+feature dynamic-literals
package main

import "core:testing"

@(private = "file")
with_projects :: proc() -> Tracker {
	saved := tracker
	tracker = Tracker{running = -1}
	append(&tracker.projects, Project{key = "pallas", name = "Pallas"})
	append(&tracker.projects, Project{key = "home", name = "Home Lab"})
	return saved
}

@(test)
test_project_ws_parse :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	saved := with_projects()
	defer tracker = saved

	p, n, sub := project_ws_parse("Pallas 1")
	testing.expect(t, p == 0 && n == 1 && sub == 0)
	p, n, sub = project_ws_parse("Pallas 1b")
	testing.expect(t, p == 0 && n == 1 && sub == 1)
	p, n, sub = project_ws_parse("Home Lab 12c")
	testing.expect(t, p == 1 && n == 12 && sub == 2)
	for bad in ([]string{"Pallas", "Pallas b", "Pallas 1B", "Pallas 1bc", "Pallas 1-", "Pallasx 1", "1b"}) {
		p, _, _ = project_ws_parse(bad)
		testing.expectf(t, p == -1, "%q is no project workspace", bad)
	}
	testing.expect_value(t, project_for_workspace("Pallas 2d"), 0)
	testing.expect_value(t, project_workspace_sub(tracker.projects[0], 2, 0), "Pallas 2")
	testing.expect_value(t, project_workspace_sub(tracker.projects[0], 2, 2), "Pallas 2c")
}

@(test)
test_project_ws_free_and_order :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	saved := with_projects()
	defer tracker = saved

	existing := []string{"1", "Pallas 1", "Pallas 1c", "Pallas 2", "Pallas 2b", "Home Lab 1b"}
	testing.expect_value(t, project_ws_free(0, 1, existing), "Pallas 1b") // b is free, c taken
	testing.expect_value(t, project_ws_free(0, 2, existing), "Pallas 2c")
	on := project_ws_on(0, 1, existing)
	testing.expect_value(t, len(on), 2)
	if len(on) == 2 {
		testing.expect_value(t, on[0], "Pallas 1")
		testing.expect_value(t, on[1], "Pallas 1c")
	}
	// "<name> N" is always in the list, even when it doesn't exist right now.
	on = project_ws_on(1, 1, existing)
	testing.expect_value(t, len(on), 2)
	if len(on) == 2 {testing.expect_value(t, on[0], "Home Lab 1")}
}

@(test)
test_project_ws_last_used :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	saved := with_projects()
	defer tracker = saved

	pr := tracker.projects[0]
	testing.expect_value(t, project_target(pr, 1, nil), "Pallas 1")
	last_ws_set("Pallas 1", "Pallas 1b")
	testing.expect_value(t, project_target(pr, 1, nil), "Pallas 1b")
	testing.expect_value(t, project_target(pr, 1, []string{"Pallas 1", "Pallas 1b"}), "Pallas 1b")
	// Gone (sway removed it once empty): back to "<name> N".
	testing.expect_value(t, project_target(pr, 1, []string{"Pallas 1"}), "Pallas 1")
	testing.expect_value(t, project_target(pr, 2, nil), "Pallas 2")

	// The group lock brings the other monitor to its last one.
	last_ws_set("Pallas 2", "Pallas 2c")
	outs := []string{"DP-3", "DP-1"}
	ret := make(map[string]string)
	vis := map[string]string{"DP-3" = "Pallas 1b", "DP-1" = "7"}
	moves := plan_sync("1", "Pallas 1b", "DP-3", outs, vis, &ret)
	testing.expect_value(t, len(moves), 1)
	if len(moves) == 1 {
		testing.expect_value(t, moves[0].output, "DP-1")
		testing.expect_value(t, moves[0].workspace, "Pallas 2c")
	}
	// Between the project's own workspaces: nobody moves.
	vis = map[string]string{"DP-3" = "Pallas 1", "DP-1" = "Pallas 2c"}
	testing.expect_value(t, len(plan_sync("Pallas 1b", "Pallas 1", "DP-3", outs, vis, &ret)), 0)

	// A rename takes the memory along.
	last_ws_rename("Pallas", "Athena")
	testing.expect_value(t, tracker.last_ws["Athena 1"], "Athena 1b")
	testing.expect_value(t, tracker.last_ws["Athena 2"], "Athena 2c")
	_, had := tracker.last_ws["Pallas 1"]
	testing.expect(t, !had)

	// Extras are renamed with the rest.
	mv, _ := workspace_rename_plan([]string{"Pallas 1", "Pallas 1b", "Pallas 2c", "Pallas"}, "Pallas", "Athena")
	testing.expect_value(t, len(mv), 3)
}

@(test)
test_project_ws_step :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	saved := with_projects()
	defer tracker = saved

	existing := []string{"Pallas 1", "Pallas 1c", "Pallas 1b", "Pallas 2", "Home Lab 1"}
	on := project_ws_on(0, 1, existing)
	ws, ok := project_ws_step(on, "Pallas 1", 1)
	testing.expect(t, ok && ws == "Pallas 1b")
	ws, ok = project_ws_step(on, "Pallas 1c", 1)
	testing.expect(t, ok && ws == "Pallas 1", "next wraps to the first")
	ws, ok = project_ws_step(on, "Pallas 1", -1)
	testing.expect(t, ok && ws == "Pallas 1c", "previous wraps to the last")
	_, ok = project_ws_step(on, "Home Lab 1", 1)
	testing.expect(t, !ok, "from elsewhere: no step")
	// A single workspace steps onto itself (move-next/prev then do nothing).
	ws, ok = project_ws_step(project_ws_on(0, 2, existing), "Pallas 2", 1)
	testing.expect(t, ok && ws == "Pallas 2")
}
