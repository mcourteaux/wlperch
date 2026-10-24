// Single-instance control socket. The daemon listens on
// $XDG_RUNTIME_DIR/wlperch.sock; `wlperch <cmd>` sends one line to it.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

ipc_socket_path :: proc() -> string {
	dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if dir == "" {dir = "/tmp"}
	disp := os.get_env("WAYLAND_DISPLAY", context.temp_allocator)
	if disp == "" {disp = "wayland-0"}
	return fmt.aprintf("%s/wlperch-%s.sock", dir, disp)
}

@(private = "file")
make_addr :: proc(path: string) -> (addr: posix.sockaddr_un) {
	addr.sun_family = .UNIX
	n := min(len(path), len(addr.sun_path) - 1)
	for i in 0 ..< n {addr.sun_path[i] = c_char(path[i])}
	return
}

@(private = "file")
c_char :: type_of(posix.sockaddr_un{}.sun_path[0])

// Try to deliver a command to a running daemon. Returns false if none runs.
ipc_send :: proc(cmd: string) -> bool {
	path := ipc_socket_path()
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {return false}
	defer posix.close(fd)
	addr := make_addr(path)
	if posix.connect(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK {return false}
	line := strings.concatenate({cmd, "\n"}, context.temp_allocator)
	posix.send(fd, raw_data(line), len(line), {})
	// Wait for the daemon to acknowledge so callers can rely on ordering.
	buf: [64]u8
	posix.recv(fd, &buf[0], len(buf), {})
	return true
}

// Send a command and return the daemon's reply ("" and false when none is running).
ipc_query :: proc(cmd: string, allocator := context.temp_allocator) -> (string, bool) {
	path := ipc_socket_path()
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {return "", false}
	defer posix.close(fd)
	addr := make_addr(path)
	if posix.connect(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK {return "", false}
	tv := posix.timeval{tv_sec = 2}
	posix.setsockopt(fd, posix.SOL_SOCKET, .RCVTIMEO, &tv, size_of(tv))
	line := strings.concatenate({cmd, "\n"}, context.temp_allocator)
	posix.send(fd, raw_data(line), len(line), {})
	// Until the daemon closes the connection (replies can be a few lines long).
	out: [dynamic]u8
	out.allocator = context.temp_allocator
	buf: [4096]u8
	for len(out) < 1 << 20 {
		n := posix.recv(fd, &buf[0], len(buf), {})
		if n <= 0 {break}
		append(&out, ..buf[:n])
	}
	if len(out) == 0 {return "", false}
	return strings.clone(string(out[:]), allocator), true
}

ipc_listen :: proc() -> posix.FD {
	path := ipc_socket_path()
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {return -1}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	posix.unlink(cpath) // stale socket from a crashed instance; ipc_send already failed
	addr := make_addr(path)
	if posix.bind(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK {
		posix.close(fd)
		return -1
	}
	posix.listen(fd, 8)
	set_cloexec_nonblock(fd)
	return fd
}

set_cloexec_nonblock :: proc(fd: posix.FD) {
	flags := posix.fcntl(fd, .GETFL)
	posix.fcntl(fd, .SETFL, flags | i32(posix.O_Flags{.NONBLOCK}))
	posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC))
}

// Accept one pending client and read its command line.
ipc_accept :: proc(listen_fd: posix.FD) -> (cmd: string, client: posix.FD, ok: bool) {
	client = posix.accept(listen_fd, nil, nil)
	if client < 0 {return}
	// Commands are tiny; a short blocking read with timeout is fine.
	tv := posix.timeval{tv_sec = 1}
	posix.setsockopt(client, posix.SOL_SOCKET, .RCVTIMEO, &tv, size_of(tv))
	buf: [256]u8
	n := posix.recv(client, &buf[0], len(buf), {})
	if n <= 0 {
		posix.close(client)
		return
	}
	cmd = strings.trim_space(strings.clone(string(buf[:n]), context.temp_allocator))
	return cmd, client, true
}

ipc_reply :: proc(client: posix.FD, msg: string) {
	posix.send(client, raw_data(msg), len(msg), {})
	posix.close(client)
}
