// Fire-and-forget command execution for UI actions, so the UI never blocks
// on a subprocess.
package main

import "core:strings"
import "core:thread"
import "core:time"

@(private = "file")
Async_Job :: struct {
	argv:    []string,
	after:   proc(),
	timeout: time.Duration,
}

// Runs argv on a short-lived thread, then calls `after` (on that thread).
run_async :: proc(argv: []string, after: proc() = nil, timeout := 10 * time.Second) {
	job := new(Async_Job)
	job.argv = make([]string, len(argv))
	for a, i in argv {job.argv[i] = strings.clone(a)}
	job.after = after
	job.timeout = timeout
	thread.create_and_start_with_data(job, proc(data: rawptr) {
		job := cast(^Async_Job)data
		run(job.argv, job.timeout, context.temp_allocator)
		if job.after != nil {job.after()}
		for a in job.argv {delete(a)}
		delete(job.argv)
		free(job)
		free_all(context.temp_allocator)
	}, self_cleanup = true)
}

// Same as run_async but for a shell command line.
run_shell_async :: proc(cmdline: string, after: proc() = nil) {
	run_async({"sh", "-c", cmdline}, after)
}
