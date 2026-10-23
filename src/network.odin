// Public IP (HTTP lookup) and interface addresses (getifaddrs).
package main

import "core:c"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

foreign import libc_net "system:c"

@(private = "file")
Ifaddrs :: struct {
	next:      ^Ifaddrs,
	name:      cstring,
	flags:     c.uint,
	addr:      ^posix.sockaddr,
	netmask:   ^posix.sockaddr,
	broadaddr: ^posix.sockaddr,
	data:      rawptr,
}

@(private = "file")
@(default_calling_convention = "c")
foreign libc_net {
	getifaddrs :: proc(ifap: ^^Ifaddrs) -> c.int ---
	freeifaddrs :: proc(ifa: ^Ifaddrs) ---
}

IFF_UP :: 0x1
IFF_LOOPBACK :: 0x8

PUBLIC_IP_REFRESH :: 10 * time.Minute

Net_Addr :: struct {
	iface:   string,
	addr:    string,
	prefix:  int,
	v6:      bool,
	wifi:    bool,
	primary: bool, // carries the default route
}

Network :: struct {
	mu:          sync.Mutex,
	public_ip:   string,
	public_ok:   bool,
	public_err:  bool,
	public_time: time.Time,
	addrs:       [dynamic]Net_Addr,
}
network: Network

@(private = "file")
trigger: sync.Sema

@(private = "file")
default_route_iface :: proc() -> string {
	data, err := os.read_entire_file("/proc/net/route", context.temp_allocator)
	if err != nil {return ""}
	text := string(data)
	first := true
	for line in strings.split_lines_iterator(&text) {
		if first {
			first = false
			continue
		}
		f := strings.fields(line, context.temp_allocator)
		if len(f) >= 2 && f[1] == "00000000" {return f[0]}
	}
	return ""
}

@(private = "file")
prefix_len :: proc(mask: ^posix.sockaddr) -> int {
	if mask == nil {return 0}
	n := 0
	bytes: []u8
	if mask.sa_family == .INET {
		m := cast(^posix.sockaddr_in)mask
		bytes = (cast([^]u8)&m.sin_addr)[:4]
	} else {
		m := cast(^posix.sockaddr_in6)mask
		bytes = (cast([^]u8)&m.sin6_addr)[:16]
	}
	for b in bytes {
		for i in 0 ..< 8 {if b & (0x80 >> u8(i)) != 0 {n += 1}}
	}
	return n
}

network_refresh_local :: proc() {
	list: ^Ifaddrs
	if getifaddrs(&list) != 0 {return}
	defer freeifaddrs(list)
	primary := default_route_iface()

	sync.guard(&network.mu)
	for a in network.addrs {
		delete(a.iface)
		delete(a.addr)
	}
	clear(&network.addrs)
	for it := list; it != nil; it = it.next {
		if it.addr == nil || it.flags & IFF_UP == 0 || it.flags & IFF_LOOPBACK != 0 {continue}
		name := string(it.name)
		skip := false
		for p in config.ignore_interfaces {if strings.has_prefix(name, p) {skip = true}}
		if skip {continue}
		buf: [64]u8
		fam := it.addr.sa_family
		if fam == .INET {
			sin := cast(^posix.sockaddr_in)it.addr
			posix.inet_ntop(.INET, &sin.sin_addr, raw_data(buf[:]), len(buf))
		} else if fam == .INET6 {
			sin6 := cast(^posix.sockaddr_in6)it.addr
			b := cast([^]u8)&sin6.sin6_addr
			if b[0] == 0xfe && b[1] & 0xc0 == 0x80 {continue} // link-local
			posix.inet_ntop(.INET6, &sin6.sin6_addr, raw_data(buf[:]), len(buf))
		} else {
			continue
		}
		wifi := os.exists(strings.concatenate({"/sys/class/net/", name, "/wireless"}, context.temp_allocator))
		append(&network.addrs, Net_Addr {
			iface   = strings.clone(name),
			addr    = strings.clone(string(cstring(&buf[0]))),
			prefix  = prefix_len(it.netmask),
			v6      = fam == .INET6,
			wifi    = wifi,
			primary = name == primary,
		})
	}
	// Primary interface first, IPv4 before IPv6.
	for i in 1 ..< len(network.addrs) {
		for j := i; j > 0; j -= 1 {
			a, b := network.addrs[j - 1], network.addrs[j]
			ka := (a.primary ? 0 : 2) + (a.v6 ? 1 : 0)
			kb := (b.primary ? 0 : 2) + (b.v6 ? 1 : 0)
			if kb < ka || (kb == ka && b.iface < a.iface) {
				network.addrs[j - 1], network.addrs[j] = b, a
			} else {
				break
			}
		}
	}
}

@(private = "file")
refresh_public :: proc() {
	out, ok := run({"curl", "-sf", "--max-time", "6", config.public_ip_url}, 8 * time.Second, context.temp_allocator)
	ip := strings.trim_space(out)
	// Sanity check: an IP address is short and has no spaces/markup.
	if ok && len(ip) > 0 && len(ip) < 64 && strings.index_any(ip, " <>{") < 0 {
		sync.guard(&network.mu)
		delete(network.public_ip)
		network.public_ip = strings.clone(ip)
		network.public_ok = true
		network.public_err = false
		network.public_time = time.now()
	} else {
		sync.guard(&network.mu)
		network.public_err = true
	}
}

network_refresh_async :: proc() {
	sync.sema_post(&trigger)
}

network_start :: proc() {
	network_refresh_local()
	thread.create_and_start(proc() {
		for {
			refresh_public()
			wake_ui()
			free_all(context.temp_allocator)
			wait := network.public_err ? time.Minute : PUBLIC_IP_REFRESH
			sync.sema_wait_with_timeout(&trigger, wait)
			for sync.sema_wait_with_timeout(&trigger, 0) {}
		}
	})
}

network_on_show :: proc() {
	network_refresh_local()
	if !network.public_ok || time.since(network.public_time) > PUBLIC_IP_REFRESH {
		sync.sema_post(&trigger)
	}
}

copy_to_clipboard :: proc(text: string) {
	run_async({"wl-copy", "--", text})
}
