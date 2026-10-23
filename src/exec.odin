// Subprocess helpers built on posix_spawn (thread-safe, unlike fork in a
// multi-threaded process).
package main

import "core:c"
import "core:log"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

foreign import libc "system:c"

@(private = "file")
Spawn_File_Actions :: struct {
	_: [80]u8, // glibc posix_spawn_file_actions_t
}

@(private = "file")
@(default_calling_convention = "c")
foreign libc {
	posix_spawn_file_actions_init :: proc(fa: ^Spawn_File_Actions) -> c.int ---
	posix_spawn_file_actions_destroy :: proc(fa: ^Spawn_File_Actions) -> c.int ---
	posix_spawn_file_actions_adddup2 :: proc(fa: ^Spawn_File_Actions, fd, newfd: c.int) -> c.int ---
	posix_spawn_file_actions_addopen :: proc(fa: ^Spawn_File_Actions, fd: c.int, path: cstring, oflag: c.int, mode: c.uint) -> c.int ---
	pipe2 :: proc(fds: ^[2]c.int, flags: c.int) -> c.int ---
}

@(private = "file")
O_CLOEXEC :: 0o2000000

@(private = "file")
spawn :: proc(argv: []string, stdout_fd: c.int) -> (pid: posix.pid_t, ok: bool) {
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv {cargv[i] = strings.clone_to_cstring(a, context.temp_allocator)}

	fa: Spawn_File_Actions
	posix_spawn_file_actions_init(&fa)
	defer posix_spawn_file_actions_destroy(&fa)
	posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", 0, 0)
	if stdout_fd >= 0 {
		posix_spawn_file_actions_adddup2(&fa, stdout_fd, 1)
	} else {
		posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", 1, 0)
	}
	posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", 1, 0)

	if err := posix.posix_spawnp(&pid, cargv[0], &fa, nil, raw_data(cargv), posix.environ); err != .NONE {
		log.debugf("spawn %v failed: %v", argv, err)
		return 0, false
	}
	return pid, true
}

// Run a command and capture its stdout. `ok` is true when it exited with 0.
run :: proc(argv: []string, timeout := 10 * time.Second, allocator := context.allocator) -> (out: string, ok: bool) {
	fds: [2]c.int
	if pipe2(&fds, O_CLOEXEC) != 0 {return}
	pid, spawned := spawn(argv, fds[1])
	posix.close(posix.FD(fds[1]))
	rfd := posix.FD(fds[0])
	defer posix.close(rfd)
	if !spawned {return}

	buf: [dynamic]u8
	buf.allocator = allocator
	deadline := time.tick_add(time.tick_now(), timeout)
	chunk: [4096]u8
	timed_out := false
	for {
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 {
			timed_out = true
			break
		}
		pfd := posix.pollfd{fd = rfd, events = {.IN}}
		r := posix.poll(&pfd, 1, i32(time.duration_milliseconds(remaining)) + 1)
		if r < 0 {
			if posix.errno() == .EINTR {continue}
			break
		}
		if r == 0 {continue}
		n := posix.read(rfd, &chunk[0], len(chunk))
		if n < 0 && posix.errno() == .EINTR {continue}
		if n <= 0 {break}
		append(&buf, ..chunk[:n])
	}
	if timed_out {
		log.debugf("command timed out: %v", argv)
		posix.kill(pid, .SIGKILL)
	}
	status: c.int
	for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	ok = !timed_out && posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0
	return string(buf[:]), ok
}

// Start a long-running child whose stdout we read line by line (e.g. `pactl subscribe`).
Stream :: struct {
	pid: posix.pid_t,
	fd:  posix.FD,
	buf: [dynamic]u8,
}

// Long-running children, so they can be stopped before we re-exec.
@(private = "file")
streams_mu: sync.Mutex
@(private = "file")
stream_pids: [dynamic]posix.pid_t

stop_children :: proc() {
	sync.guard(&streams_mu)
	for pid in stream_pids {posix.kill(pid, .SIGTERM)}
	for pid in stream_pids {
		status: c.int
		posix.waitpid(pid, &status, {})
	}
	clear(&stream_pids)
}

stream_start :: proc(argv: []string) -> (s: Stream, ok: bool) {
	fds: [2]c.int
	if pipe2(&fds, O_CLOEXEC) != 0 {return}
	pid, spawned := spawn(argv, fds[1])
	posix.close(posix.FD(fds[1]))
	if !spawned {
		posix.close(posix.FD(fds[0]))
		return
	}
	{
		sync.guard(&streams_mu)
		append(&stream_pids, pid)
	}
	return Stream{pid = pid, fd = posix.FD(fds[0])}, true
}

// Blocks until a full line is available. Returns false on EOF.
stream_read_line :: proc(s: ^Stream, allocator := context.temp_allocator) -> (line: string, ok: bool) {
	chunk: [1024]u8
	for {
		if i := index_byte(s.buf[:], '\n'); i >= 0 {
			line = strings.clone(string(s.buf[:i]), allocator)
			remove_range(&s.buf, 0, i + 1)
			return line, true
		}
		n := posix.read(s.fd, &chunk[0], len(chunk))
		if n < 0 && posix.errno() == .EINTR {continue}
		if n <= 0 {return "", false}
		append(&s.buf, ..chunk[:n])
	}
}

stream_stop :: proc(s: ^Stream) {
	{
		sync.guard(&streams_mu)
		for p, i in stream_pids {
			if p == s.pid {
				unordered_remove(&stream_pids, i)
				break
			}
		}
	}
	if s.pid > 0 {
		posix.kill(s.pid, .SIGTERM)
		status: c.int
		posix.waitpid(s.pid, &status, {})
	}
	if s.fd > 0 {posix.close(s.fd)}
	delete(s.buf)
	s^ = {}
}

@(private = "file")
index_byte :: proc(b: []u8, c: u8) -> int {
	for x, i in b {if x == c {return i}}
	return -1
}

// Launch a command fully detached from us (own session, reparented to init).
launch_detached :: proc(argv: []string) -> bool {
	full := make([dynamic]string, 0, len(argv) + 2, context.temp_allocator)
	append(&full, "setsid", "-f")
	append(&full, ..argv)
	// No stdout pipe: the detached grandchild would keep it open forever.
	pid, ok := spawn(full[:], -1)
	if !ok {return false}
	status: c.int
	for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	return posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0
}

// Launch a shell command line detached.
launch_shell :: proc(cmdline: string) -> bool {
	return launch_detached({"sh", "-c", cmdline})
}
