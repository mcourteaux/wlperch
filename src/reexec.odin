// The GPU driver doesn't give its memory back when we tear EGL down, so once
// the popup has been hidden for a while the daemon re-executes itself. The
// control socket is inherited (no window where `wlwidgets toggle` fails) and
// the CPU/GPU history is handed over in a memfd so the graphs stay intact.
package main

import "core:c"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"

@(private = "file")
STATE_MAGIC :: u32(0x57_4c_57_31) // "WLW1"

@(private = "file")
Saved_State :: struct {
	magic: u32,
	cpu:   History,
	gpu:   History,
}

@(private = "file")
clear_cloexec :: proc(fd: posix.FD) {
	posix.fcntl(fd, .SETFD, i32(0))
}

// Replace the process image with a fresh copy of ourselves. Only returns on failure.
reexec_self :: proc() {
	state := new(Saved_State, context.temp_allocator)
	state.magic = STATE_MAGIC
	{
		sysmon_lock()
		defer sysmon_unlock()
		state.cpu = sysmon.cpu
		state.gpu = sysmon.gpu
	}

	mfd, err := linux.memfd_create("wlwidgets-state", {})
	if err != .NONE {
		log.warnf("memfd_create failed: %v", err)
		return
	}
	data := ([^]u8)(state)[:size_of(Saved_State)]
	off := 0
	for off < len(data) {
		n, werr := linux.write(mfd, data[off:])
		if werr != .NONE || n <= 0 {
			linux.close(mfd)
			return
		}
		off += n
	}

	stop_children()
	// Some drivers (NVIDIA) open their device files without O_CLOEXEC; don't
	// let them leak into the new image.
	if entries, derr := os.read_all_directory_by_path("/proc/self/fd", context.temp_allocator); derr == nil {
		for e in entries {
			fd, ok := strconv.parse_int(e.name)
			if !ok || fd <= 2 || fd == int(app.ipc_fd) || fd == int(mfd) {continue}
			posix.fcntl(posix.FD(fd), .SETFD, i32(posix.FD_CLOEXEC))
		}
	}
	clear_cloexec(app.ipc_fd)

	// Exec the real path so the process keeps its name; fall back to
	// /proc/self/exe if the binary was replaced (e.g. rebuilt) meanwhile.
	exe := "/proc/self/exe"
	if target, lerr := os.read_link("/proc/self/exe", context.temp_allocator); lerr == nil && !strings.has_suffix(target, " (deleted)") {
		exe = target
	}
	args := []cstring {
		"wlwidgets",
		"daemon",
		"--resume",
		strings.clone_to_cstring(int_to_string(int(app.ipc_fd)), context.temp_allocator),
		strings.clone_to_cstring(int_to_string(int(mfd)), context.temp_allocator),
		nil,
	}
	log.debug("re-executing to release GPU memory")
	posix.execv(strings.clone_to_cstring(exe, context.temp_allocator), raw_data(args))
	log.errorf("execv failed: %v", posix.errno())
	posix.fcntl(app.ipc_fd, .SETFD, i32(posix.FD_CLOEXEC))
	linux.close(mfd)
}

// Called early in main() when started with `daemon --resume <ipc fd> <state fd>`.
resume_from_args :: proc() -> (ipc_fd: posix.FD, ok: bool) {
	if len(os.args) < 5 || os.args[2] != "--resume" {return -1, false}
	ifd, ok1 := strconv.parse_int(os.args[3])
	sfd, ok2 := strconv.parse_int(os.args[4])
	if !ok1 || !ok2 {return -1, false}
	set_cloexec_nonblock(posix.FD(ifd))

	state: Saved_State
	buf := ([^]u8)(&state)[:size_of(Saved_State)]
	linux.lseek(linux.Fd(sfd), 0, .SET)
	off := 0
	for off < len(buf) {
		n, err := linux.read(linux.Fd(sfd), buf[off:])
		if err != .NONE || n <= 0 {break}
		off += n
	}
	linux.close(linux.Fd(sfd))
	if off == len(buf) && state.magic == STATE_MAGIC {
		sysmon.cpu = state.cpu
		sysmon.gpu = state.gpu
	}
	reap_children()
	return posix.FD(ifd), true
}

// Reap children inherited from our previous image (e.g. `pactl subscribe`).
reap_children :: proc() {
	status: c.int
	for posix.waitpid(-1, &status, {.NOHANG}) > 0 {}
}
