// Tuya LAN protocol, read-only: discovery broadcasts (UDP 6666/6667/7000) and
// status queries over TCP 6668 for protocol 3.3 (AES-ECB + CRC32), 3.4
// (session key + HMAC-SHA256) and 3.5 (session key + AES-GCM, 0x6699 frames).
// Ported from tinytuya. Only DP_QUERY / DP_QUERY_NEW are ever sent: never
// CONTROL / CONTROL_NEW, so nothing here can change a device's state.
package main

import "core:crypto"
import "core:crypto/aes"
import chash "core:crypto/hash"
import "core:crypto/hmac"
import "core:crypto/legacy/md5"
import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:strings"
import "core:sys/posix"
import "core:time"

TUYA_PREFIX_55AA :: 0x000055AA
TUYA_SUFFIX_55AA :: 0x0000AA55
TUYA_PREFIX_6699 :: 0x00006699
TUYA_SUFFIX_6699 :: 0x00009966

TUYA_SESS_KEY_START  :: 0x03
TUYA_SESS_KEY_RESP   :: 0x04
TUYA_SESS_KEY_FINISH :: 0x05
TUYA_STATUS          :: 0x08
TUYA_DP_QUERY        :: 0x0a
TUYA_DP_QUERY_NEW    :: 0x10
TUYA_REQ_DEVINFO     :: 0x25

TUYA_TCP_PORT   :: 6668
TUYA_UDP_PORTS  :: [3]u16{6666, 6667, 7000}
TUYA_MAX_FRAME  :: 4096

Tuya_Version :: enum {V33, V34, V35}

// "3.3" / "3.4" / "3.5" (3.1 and 3.2 talk like 3.3 for status queries).
tuya_version :: proc(s: string) -> (Tuya_Version, bool) {
	switch strings.trim_space(s) {
	case "3.1", "3.2", "3.3": return .V33, true
	case "3.4":               return .V34, true
	case "3.5":               return .V35, true
	}
	return .V33, false
}

@(private = "file")
version_bytes :: proc(v: Tuya_Version) -> string {
	switch v {
	case .V33: return "3.3"
	case .V34: return "3.4"
	case .V35: return "3.5"
	}
	return "3.3"
}

// The well-known key for UDP broadcasts: md5("yGAdlopoPVldABfn").
tuya_udp_key :: proc() -> (key: [16]byte) {
	ctx: md5.Context
	md5.init(&ctx)
	md5.update(&ctx, transmute([]byte)string("yGAdlopoPVldABfn"))
	md5.final(&ctx, key[:])
	return
}

// AES-128-ECB with PKCS#7 padding (`pad`), as Tuya uses it.
tuya_ecb_encrypt :: proc(key, plain: []byte, pad := true, allocator := context.temp_allocator) -> []byte {
	n := len(plain)
	padded := pad ? (n / 16 + 1) * 16 : n
	buf := make([]byte, padded, allocator)
	copy(buf, plain)
	for i in n ..< padded {buf[i] = byte(padded - n)}
	ctx: aes.Context_ECB
	aes.init_ecb(&ctx, key)
	defer aes.reset_ecb(&ctx)
	for i := 0; i + 16 <= padded; i += 16 {aes.encrypt_ecb(&ctx, buf[i:i + 16], buf[i:i + 16])}
	return buf
}

// Decrypts and strips the padding (lenient like tinytuya: only the length byte is checked).
tuya_ecb_decrypt :: proc(key, data: []byte, allocator := context.temp_allocator) -> ([]byte, bool) {
	if len(data) == 0 || len(data) % 16 != 0 {return nil, false}
	buf := make([]byte, len(data), allocator)
	ctx: aes.Context_ECB
	aes.init_ecb(&ctx, key)
	defer aes.reset_ecb(&ctx)
	for i := 0; i < len(data); i += 16 {aes.decrypt_ecb(&ctx, buf[i:i + 16], data[i:i + 16])}
	pad := int(buf[len(buf) - 1])
	if pad < 1 || pad > 16 {return nil, false}
	return buf[:len(buf) - pad], true
}

@(private = "file")
put_be32 :: proc(out: ^[dynamic]byte, v: u32) {b: [4]byte; endian.put_u32(b[:], .Big, v); append(out, ..b[:])}

@(private = "file")
be32 :: proc(b: []byte) -> u32 {v, _ := endian.get_u32(b, .Big); return v}

// One frame. 0x55AA: header, payload, CRC32 (no key) or HMAC-SHA256 (key),
// suffix. 0x6699 (needs key): header, 12-byte IV, AES-GCM ciphertext with the
// header as AAD, 16-byte tag, suffix. `iv` = nil picks a random one.
// Frames we send carry no return code.
tuya_pack :: proc(prefix: u32, seq, cmd: u32, payload: []byte, key: []byte = nil, iv: []byte = nil, allocator := context.temp_allocator) -> []byte {
	out := make([dynamic]byte, 0, len(payload) + 64, allocator)
	if prefix == TUYA_PREFIX_6699 {
		put_be32(&out, TUYA_PREFIX_6699)
		append(&out, 0, 0)
		put_be32(&out, seq)
		put_be32(&out, cmd)
		put_be32(&out, u32(12 + len(payload) + 16))
		nonce: [12]byte
		if iv != nil {copy(nonce[:], iv)} else {crypto.rand_bytes(nonce[:])}
		aad: [14]byte
		copy(aad[:], out[4:18])
		append(&out, ..nonce[:])
		start := len(out)
		resize(&out, start + len(payload) + 16)
		ctx: aes.Context_GCM
		aes.init_gcm(&ctx, key)
		defer aes.reset_gcm(&ctx)
		aes.seal_gcm(&ctx, out[start:start + len(payload)], out[start + len(payload):], nonce[:], aad[:], payload)
		put_be32(&out, TUYA_SUFFIX_6699)
		return out[:]
	}
	end_len := key != nil ? 32 + 4 : 4 + 4
	put_be32(&out, TUYA_PREFIX_55AA)
	put_be32(&out, seq)
	put_be32(&out, cmd)
	put_be32(&out, u32(len(payload) + end_len))
	append(&out, ..payload)
	if key != nil {
		mac: [32]byte
		hmac.sum(.SHA256, mac[:], out[:], key)
		append(&out, ..mac[:])
	} else {
		put_be32(&out, hash.crc32(out[:]))
	}
	put_be32(&out, TUYA_SUFFIX_55AA)
	return out[:]
}

// Total size of the frame at the start of `data`: 0 = need more bytes, -1 = garbage.
tuya_frame_size :: proc(data: []byte) -> int {
	if len(data) < 4 {return 0}
	switch be32(data[0:4]) {
	case TUYA_PREFIX_55AA:
		if len(data) < 16 {return 0}
		n := int(be32(data[12:16]))
		if n < 8 || n > TUYA_MAX_FRAME {return -1}
		return 16 + n
	case TUYA_PREFIX_6699:
		if len(data) < 18 {return 0}
		n := int(be32(data[14:18]))
		if n < 28 || n > TUYA_MAX_FRAME {return -1}
		return 18 + n + 4
	}
	return -1
}

Tuya_Frame :: struct {
	seq, cmd, retcode: u32,
	payload:           []byte,
}

// Whether a received frame starts with a 4-byte return code: device replies
// over TCP always do; UDP broadcasts only sometimes (.Auto: when the JSON starts after it).
Tuya_Retcode :: enum {Always, Never, Auto}

// Parses and verifies one whole frame (CRC, HMAC or GCM tag, with `key` for
// the latter two). The payload is still ECB-encrypted for 0x55AA frames.
tuya_unpack :: proc(data: []byte, key: []byte = nil, retcode := Tuya_Retcode.Always, allocator := context.temp_allocator) -> (f: Tuya_Frame, ok: bool) {
	size := tuya_frame_size(data)
	if size <= 0 || size > len(data) {return}
	data := data[:size]
	switch be32(data[0:4]) {
	case TUYA_PREFIX_55AA:
		f.seq, f.cmd = be32(data[4:8]), be32(data[8:12])
		end_len := key != nil ? 36 : 8
		if size < 16 + end_len {return}
		body := data[16:size - end_len]
		check := data[size - end_len:size - 4]
		if key != nil {
			if !hmac.verify(.SHA256, check, data[:size - end_len], key) {return}
		} else if hash.crc32(data[:size - end_len]) != be32(check) {return}
		if retcode != .Never && len(body) >= 4 && (retcode == .Always || (body[0] != '{' && len(body) > 4 && body[4] == '{')) {
			f.retcode = be32(body[:4])
			body = body[4:]
		}
		f.payload = body
		return f, true
	case TUYA_PREFIX_6699:
		if key == nil {return}
		f.seq, f.cmd = be32(data[6:10]), be32(data[10:14])
		iv := data[18:30]
		ct := data[30:size - 4 - 16]
		tag := data[size - 4 - 16:size - 4]
		plain := make([]byte, len(ct), allocator)
		ctx: aes.Context_GCM
		aes.init_gcm(&ctx, key)
		defer aes.reset_gcm(&ctx)
		if !aes.open_gcm(&ctx, plain, iv, data[4:18], ct, tag) {return}
		body := plain
		if retcode != .Never && len(body) >= 4 && (retcode == .Always || (body[0] != '{' && len(body) > 4 && body[4] == '{')) {
			f.retcode = be32(body[:4])
			body = body[4:]
		}
		f.payload = body
		return f, true
	}
	return
}

// A discovery broadcast (any of the three ports) -> its JSON text.
tuya_decrypt_udp :: proc(data: []byte, allocator := context.temp_allocator) -> (string, bool) {
	key := tuya_udp_key()
	switch tuya_frame_size(data) {
	case -1, 0:
		// Bare ECB (some old firmware), or plain JSON on 6666.
		if len(data) > 0 && data[0] == '{' {return string(data), true}
		plain, ok := tuya_ecb_decrypt(key[:], data, allocator)
		return string(plain), ok
	}
	if be32(data[0:4]) == TUYA_PREFIX_55AA {
		f, ok := tuya_unpack(data, nil, .Always, allocator)
		if !ok {return "", false}
		p := f.payload
		if len(p) > 0 && p[0] == '{' && p[len(p) - 1] == '}' {return string(p), true}
		plain, dok := tuya_ecb_decrypt(key[:], p, allocator)
		return string(plain), dok
	}
	f, ok := tuya_unpack(data, key[:], .Auto, allocator)
	if !ok {return "", false}
	return strings.trim_right(string(f.payload), "\x00"), true
}

// The "who is there" probe that makes 3.5 devices announce themselves on UDP 7000.
tuya_discovery_request :: proc(local_ip: string, iv: []byte = nil, allocator := context.temp_allocator) -> []byte {
	key := tuya_udp_key()
	payload := fmt.tprintf(`{{"from":"app","ip":"%s"}}`, local_ip)
	return tuya_pack(TUYA_PREFIX_6699, 0, TUYA_REQ_DEVINFO, transmute([]byte)payload, key[:], iv, allocator)
}

// 3.4/3.5 session key from both nonces: the XOR, encrypted with the local key
// (ECB for 3.4; GCM with the first 12 bytes of our nonce as IV for 3.5).
tuya_session_key :: proc(v: Tuya_Version, local_key, local_nonce, remote_nonce: []byte) -> (key: [16]byte) {
	for i in 0 ..< 16 {key[i] = local_nonce[i] ~ remote_nonce[i]}
	if v == .V34 {
		copy(key[:], tuya_ecb_encrypt(local_key, key[:], false))
	} else {
		ctx: aes.Context_GCM
		aes.init_gcm(&ctx, local_key)
		defer aes.reset_gcm(&ctx)
		out: [16]byte
		tag: [16]byte
		aes.seal_gcm(&ctx, out[:], tag[:], local_nonce[:12], nil, key[:])
		key = out
	}
	return
}

// One outgoing message, encrypted and framed for the version. Status queries
// and the key negotiation go without the "3.x" version header.
tuya_encode :: proc(v: Tuya_Version, key: []byte, seq, cmd: u32, payload: []byte, iv: []byte = nil) -> []byte {
	header := !(cmd == TUYA_DP_QUERY || cmd == TUYA_DP_QUERY_NEW || cmd == 0x09 || (cmd >= TUYA_SESS_KEY_START && cmd <= TUYA_SESS_KEY_FINISH))
	switch v {
	case .V33:
		enc := tuya_ecb_encrypt(key, payload)
		if header {enc = transmute([]byte)strings.concatenate({version_bytes(v), "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", string(enc)}, context.temp_allocator)}
		return tuya_pack(TUYA_PREFIX_55AA, seq, cmd, enc)
	case .V34:
		p := payload
		if header {p = transmute([]byte)strings.concatenate({version_bytes(v), "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", string(p)}, context.temp_allocator)}
		return tuya_pack(TUYA_PREFIX_55AA, seq, cmd, tuya_ecb_encrypt(key, p), key)
	case .V35:
		p := payload
		if header {p = transmute([]byte)strings.concatenate({version_bytes(v), "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", string(p)}, context.temp_allocator)}
		return tuya_pack(TUYA_PREFIX_6699, seq, cmd, p, key, iv)
	}
	return nil
}

// A received payload -> JSON text: decrypt (3.3/3.4) and drop the "3.x" header.
tuya_decode_payload :: proc(v: Tuya_Version, key, payload: []byte) -> (string, bool) {
	p := payload
	if v == .V34 {
		ok: bool
		if p, ok = tuya_ecb_decrypt(key, p); !ok {return "", false}
	}
	if len(p) >= 15 && p[0] == '3' && p[1] == '.' {p = p[15:]}
	if v == .V33 && len(p) > 0 && p[0] != '{' {
		ok: bool
		if p, ok = tuya_ecb_decrypt(key, p); !ok {return "", false}
	}
	if len(p) == 0 || p[0] != '{' {return "", false}
	return string(p), true
}

// The status query for a version: DP_QUERY with the ids (3.3), DP_QUERY_NEW with {} (3.4+).
tuya_query :: proc(v: Tuya_Version, id: string, now: i64) -> (cmd: u32, payload: string) {
	if v == .V33 {
		return TUYA_DP_QUERY, fmt.tprintf(`{{"gwId":"%s","devId":"%s","uid":"%s","t":"%d"}}`, id, id, id, now)
	}
	return TUYA_DP_QUERY_NEW, "{}"
}

// ---- Network ----------------------------------------------------------------

@(private = "file")
Conn :: struct {
	fd:       posix.FD,
	buf:      [dynamic]byte,
	deadline: time.Tick,
}

@(private = "file")
conn_send :: proc(c: ^Conn, data: []byte) -> bool {
	sent := 0
	for sent < len(data) {
		pfd := posix.pollfd{fd = c.fd, events = {.OUT}}
		left := time.tick_diff(time.tick_now(), c.deadline)
		if left <= 0 || posix.poll(&pfd, 1, i32(time.duration_milliseconds(left)) + 1) <= 0 {return false}
		rest := len(data) - sent
		n := posix.send(c.fd, raw_data(data[sent:]), uint(rest), {.NOSIGNAL})
		if n <= 0 {return false}
		sent += int(n)
	}
	return true
}

// Next whole frame from the stream (skips junk before a prefix).
@(private = "file")
conn_frame :: proc(c: ^Conn) -> ([]byte, bool) {
	for {
		// Resync on a known prefix.
		for len(c.buf) >= 4 && tuya_frame_size(c.buf[:]) == -1 {remove_range(&c.buf, 0, 1)}
		if size := tuya_frame_size(c.buf[:]); size > 0 && size <= len(c.buf) {
			frame := make([]byte, size, context.temp_allocator)
			copy(frame, c.buf[:size])
			remove_range(&c.buf, 0, size)
			return frame, true
		}
		pfd := posix.pollfd{fd = c.fd, events = {.IN}}
		left := time.tick_diff(time.tick_now(), c.deadline)
		if left <= 0 || posix.poll(&pfd, 1, i32(time.duration_milliseconds(left)) + 1) <= 0 {return nil, false}
		tmp: [2048]byte
		n := posix.recv(c.fd, &tmp[0], len(tmp), {})
		if n <= 0 {return nil, false}
		append(&c.buf, ..tmp[:n])
	}
}

@(private = "file")
tcp_connect :: proc(ip: string, port: u16, timeout: time.Duration) -> (posix.FD, bool) {
	addr := posix.sockaddr_in{sin_family = .INET, sin_port = posix.in_port_t(port)}
	if posix.inet_pton(.INET, strings.clone_to_cstring(ip, context.temp_allocator), &addr.sin_addr) != .SUCCESS {return -1, false}
	fd := posix.socket(.INET, .STREAM)
	if fd < 0 {return -1, false}
	posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC))
	posix.fcntl(fd, .SETFL, posix.fcntl(fd, .GETFL) | i32(posix.O_Flags{.NONBLOCK}))
	if posix.connect(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK && posix.errno() != .EINPROGRESS {
		posix.close(fd)
		return -1, false
	}
	pfd := posix.pollfd{fd = fd, events = {.OUT}}
	if posix.poll(&pfd, 1, i32(time.duration_milliseconds(timeout))) <= 0 {
		posix.close(fd)
		return -1, false
	}
	err: i32
	l := posix.socklen_t(size_of(err))
	posix.getsockopt(fd, posix.SOL_SOCKET, .ERROR, &err, &l)
	if err != 0 {
		posix.close(fd)
		return -1, false
	}
	return fd, true
}

// Asks one awake device for its data points: connect, negotiate a session
// key (3.4/3.5), send the status query, return the reply's JSON text (temp
// allocator). `err` never contains key material.
tuya_read_status :: proc(ip, id: string, local_key: []byte, v: Tuya_Version, timeout := 5 * time.Second) -> (reply: string, err: string) {
	if len(local_key) != 16 {return "", "local key must be 16 characters"}
	fd, ok := tcp_connect(ip, TUYA_TCP_PORT, timeout)
	if !ok {return "", fmt.tprintf("cannot connect to %s:%d", ip, TUYA_TCP_PORT)}
	c := Conn{fd = fd, deadline = time.tick_add(time.tick_now(), timeout)}
	c.buf.allocator = context.temp_allocator
	defer posix.close(fd)

	key := local_key
	seq: u32 = 1
	if v != .V33 {
		local_nonce: [16]byte
		crypto.rand_bytes(local_nonce[:])
		start := v == .V34 ? tuya_ecb_encrypt(local_key, local_nonce[:]) : local_nonce[:]
		if !conn_send(&c, tuya_pack(v == .V34 ? TUYA_PREFIX_55AA : TUYA_PREFIX_6699, seq, TUYA_SESS_KEY_START, start, local_key)) {return "", "session key: send failed"}
		seq += 1
		frame, fok := conn_frame(&c)
		if !fok {return "", "session key: no answer"}
		f, uok := tuya_unpack(frame, local_key)
		if !uok || f.cmd != TUYA_SESS_KEY_RESP {return "", "session key: bad answer (wrong key or version?)"}
		p := f.payload
		if v == .V34 {
			dok: bool
			if p, dok = tuya_ecb_decrypt(local_key, p); !dok {return "", "session key: cannot decrypt answer"}
		}
		if len(p) < 48 {return "", "session key: short answer"}
		remote_nonce := p[:16]
		if !hmac.verify(.SHA256, p[16:48], local_nonce[:], local_key) {return "", "session key: HMAC mismatch (wrong key?)"}
		mac: [32]byte
		hmac.sum(.SHA256, mac[:], remote_nonce, local_key)
		finish := v == .V34 ? tuya_ecb_encrypt(local_key, mac[:]) : mac[:]
		if !conn_send(&c, tuya_pack(v == .V34 ? TUYA_PREFIX_55AA : TUYA_PREFIX_6699, seq, TUYA_SESS_KEY_FINISH, finish, local_key)) {return "", "session key: send failed"}
		seq += 1
		session := tuya_session_key(v, local_key, local_nonce[:], remote_nonce)
		key = make([]byte, 16, context.temp_allocator)
		copy(key, session[:])
	}

	cmd, payload := tuya_query(v, id, time.to_unix_seconds(time.now()))
	if !conn_send(&c, tuya_encode(v, key, seq, cmd, transmute([]byte)payload)) {return "", "send failed"}
	mac_key := v == .V33 ? nil : key
	// Devices may send an empty ack or a pushed STATUS before the answer.
	for {
		frame, fok := conn_frame(&c)
		if !fok {return "", "no answer (timeout)"}
		f, uok := tuya_unpack(frame, mac_key)
		if !uok {return "", "bad frame (wrong key or version?)"}
		if len(f.payload) == 0 {continue}
		text, dok := tuya_decode_payload(v, key, f.payload)
		if !dok {return "", "cannot decrypt the answer (wrong key or version?)"}
		if strings.contains(text, "data unvalid") {
			// tinytuya then retries with CONTROL_NEW; we never send control commands.
			return "", "device wants the CONTROL_NEW status variant (\"device22\"), not supported"
		}
		if strings.contains(text, `"dps"`) {return text, ""}
		if f.cmd == cmd {return text, ""}
	}
}
