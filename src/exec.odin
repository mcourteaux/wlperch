// Subprocess helpers built on posix_spawn (thread-safe, unlike fork in a
// multi-threaded process).
package main

import "core:c"
import "core:log"
import "core:os"
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
Spawn_Attr :: struct {
	_: [336]u8, // glibc posix_spawnattr_t
}

@(private = "file")
POSIX_SPAWN_SETSIGDEF :: 0x04

@(private = "file")
@(default_calling_convention = "c")
foreign libc {
	posix_spawnattr_init :: proc(attr: ^Spawn_Attr) -> c.int ---
	posix_spawnattr_destroy :: proc(attr: ^Spawn_Attr) -> c.int ---
	posix_spawnattr_setflags :: proc(attr: ^Spawn_Attr, flags: c.short) -> c.int ---
	posix_spawnattr_setsigdefault :: proc(attr: ^Spawn_Attr, set: ^posix.sigset_t) -> c.int ---
	posix_spawn_file_actions_init :: proc(fa: ^Spawn_File_Actions) -> c.int ---
	posix_spawn_file_actions_destroy :: proc(fa: ^Spawn_File_Actions) -> c.int ---
	posix_spawn_file_actions_adddup2 :: proc(fa: ^Spawn_File_Actions, fd, newfd: c.int) -> c.int ---
	posix_spawn_file_actions_addopen :: proc(fa: ^Spawn_File_Actions, fd: c.int, path: cstring, oflag: c.int, mode: c.uint) -> c.int ---
	pipe2 :: proc(fds: ^[2]c.int, flags: c.int) -> c.int ---
}

@(private = "file")
O_CLOEXEC :: 0o2000000

// Every child we spawn, so they can all be stopped before we re-exec
// (otherwise they'd linger as zombies of the new image).
@(private = "file")
children_mu: sync.Mutex
@(private = "file")
children: [dynamic]posix.pid_t
@(private = "file")
stopping: bool

@(private = "file")
child_forget :: proc(pid: posix.pid_t) {
	sync.guard(&children_mu)
	for p, i in children {
		if p == pid {
			unordered_remove(&children, i)
			return
		}
	}
}

// Kill and reap all children; no new ones are spawned afterwards.
stop_children :: proc() {
	sync.guard(&children_mu)
	stopping = true
	for pid in children {posix.kill(pid, .SIGKILL)}
	for pid in children {
		status: c.int
		posix.waitpid(pid, &status, {})
	}
	clear(&children)
}

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

	// We ignore SIGPIPE; children (shell scripts!) must get the default back.
	attr: Spawn_Attr
	posix_spawnattr_init(&attr)
	defer posix_spawnattr_destroy(&attr)
	sigs: posix.sigset_t
	posix.sigemptyset(&sigs)
	posix.sigaddset(&sigs, .SIGPIPE)
	posix_spawnattr_setsigdefault(&attr, &sigs)
	posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF)

	sync.guard(&children_mu)
	if stopping {return 0, false}
	if err := posix.posix_spawnp(&pid, cargv[0], &fa, &attr, raw_data(cargv), posix.environ); err != .NONE {
		log.debugf("spawn %v failed: %v", argv, err)
		return 0, false
	}
	append(&children, pid)
	return pid, true
}

// Run a command and capture its stdout. `ok` is true when it exited with 0.
run :: proc(argv: []string, timeout := 10 * time.Second, allocator := context.allocator) -> (out: string, ok: bool) {
	code: int
	out, code = run_code(argv, timeout, allocator)
	return out, code == 0
}

// Like run, but returns the exit code (-1 if it didn't exit normally or timed out).
run_code :: proc(argv: []string, timeout := 10 * time.Second, allocator := context.allocator) -> (out: string, code: int) {
	code = -1
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
	child_forget(pid)
	if !timed_out && posix.WIFEXITED(status) {code = int(posix.WEXITSTATUS(status))}
	return string(buf[:]), code
}

// Start a long-running child whose stdout we read line by line (e.g. `pactl subscribe`).
Stream :: struct {
	pid: posix.pid_t,
	fd:  posix.FD,
	buf: [dynamic]u8,
}

stream_start :: proc(argv: []string) -> (s: Stream, ok: bool) {
	fds: [2]c.int
	if pipe2(&fds, O_CLOEXEC) != 0 {return}
	// A stream outlives nothing: if we die without cleaning up (SIGKILL,
	// crash, exec), the kernel stops it. Plain SIGPIPE doesn't, since e.g.
	// pactl ignores it and kept running for hours. The parent "thread" for
	// PDEATHSIG is the long-lived reader thread that starts the stream.
	full := argv
	if os.exists("/usr/bin/setpriv") {
		wrapped := make([dynamic]string, 0, len(argv) + 4, context.temp_allocator)
		append(&wrapped, "/usr/bin/setpriv", "--pdeathsig", "TERM", "--")
		append(&wrapped, ..argv)
		full = wrapped[:]
	}
	pid, spawned := spawn(full, fds[1])
	posix.close(posix.FD(fds[1]))
	if !spawned {
		posix.close(posix.FD(fds[0]))
		return
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
	if s.pid > 0 {
		posix.kill(s.pid, .SIGTERM)
		status: c.int
		posix.waitpid(s.pid, &status, {})
		child_forget(s.pid)
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
	child_forget(pid)
	return posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0
}

// Launch a shell command line detached.
launch_shell :: proc(cmdline: string) -> bool {
	return launch_detached({"sh", "-c", cmdline})
}
