// Minimal Linux-PAM bindings for the lock screen: authenticate the current
// user with one password, answering every hidden prompt with it.
package main

import "base:runtime"
import "core:c"
import "core:mem"
import "core:strings"
import "core:sys/posix"

foreign import pam "system:pam"

@(private = "file")
Pam_Handle :: struct {}

@(private = "file")
Pam_Message :: struct {
	msg_style: c.int,
	msg:       cstring,
}

@(private = "file")
Pam_Response :: struct {
	resp:         [^]u8, // malloc'd; PAM frees it
	resp_retcode: c.int,
}

@(private = "file")
Pam_Conv :: struct {
	conv:        proc "c" (num_msg: c.int, msg: [^]^Pam_Message, resp: ^[^]Pam_Response, appdata: rawptr) -> c.int,
	appdata_ptr: rawptr,
}

@(private = "file") PAM_SUCCESS :: 0
@(private = "file") PAM_BUF_ERR :: 5
@(private = "file") PAM_CONV_ERR :: 19
@(private = "file") PAM_REFRESH_CRED :: 0x0010
@(private = "file") PAM_PROMPT_ECHO_OFF :: 1
@(private = "file") PAM_PROMPT_ECHO_ON :: 2
@(private = "file") PAM_ERROR_MSG :: 3
@(private = "file") PAM_TEXT_INFO :: 4

@(default_calling_convention = "c")
@(private = "file")
foreign pam {
	pam_start :: proc(service, user: cstring, conv: ^Pam_Conv, pamh: ^^Pam_Handle) -> c.int ---
	pam_authenticate :: proc(pamh: ^Pam_Handle, flags: c.int) -> c.int ---
	pam_setcred :: proc(pamh: ^Pam_Handle, flags: c.int) -> c.int ---
	pam_end :: proc(pamh: ^Pam_Handle, status: c.int) -> c.int ---
}

foreign import libc_pam "system:c"
@(default_calling_convention = "c")
@(private = "file")
foreign libc_pam {
	calloc :: proc(n, size: c.size_t) -> rawptr ---
	malloc :: proc(size: c.size_t) -> rawptr ---
}

@(private = "file")
Conv_Data :: struct {
	password: []u8,
	info:     proc(msg: string), // PAM_TEXT_INFO / PAM_ERROR_MSG (e.g. fingerprint prompts)
}

@(private = "file")
conversation :: proc "c" (num_msg: c.int, msg: [^]^Pam_Message, resp: ^[^]Pam_Response, appdata: rawptr) -> c.int {
	data := (^Conv_Data)(appdata)
	out := ([^]Pam_Response)(calloc(c.size_t(num_msg), size_of(Pam_Response)))
	if out == nil {return PAM_BUF_ERR}
	for i in 0 ..< int(num_msg) {
		switch msg[i].msg_style {
		case PAM_PROMPT_ECHO_OFF, PAM_PROMPT_ECHO_ON:
			p := ([^]u8)(malloc(c.size_t(len(data.password) + 1)))
			if p == nil {
				for j in 0 ..< i {
					if out[j].resp != nil {c_free(out[j].resp)}
				}
				c_free(out)
				return PAM_BUF_ERR
			}
			mem.copy(p, raw_data(data.password), len(data.password))
			p[len(data.password)] = 0
			out[i].resp = p
		case PAM_TEXT_INFO, PAM_ERROR_MSG:
			if data.info != nil && msg[i].msg != nil {
				context = runtime.default_context()
				data.info(string(msg[i].msg))
			}
		}
	}
	resp^ = out
	return PAM_SUCCESS
}

// The login name of the user running us.
current_user :: proc(allocator := context.allocator) -> string {
	pw := posix.getpwuid(posix.getuid())
	if pw == nil || pw.pw_name == nil {return ""}
	return strings.clone(string(pw.pw_name), allocator)
}

// Blocks (PAM modules may sleep, e.g. pam_faildelay): run off the UI thread.
pam_check_password :: proc(service: string, password: []u8, info: proc(msg: string) = nil) -> bool {
	user := current_user(context.temp_allocator)
	if user == "" {return false}
	data := Conv_Data{password = password, info = info}
	conv := Pam_Conv{conversation, &data}
	h: ^Pam_Handle
	csvc := strings.clone_to_cstring(service, context.temp_allocator)
	cuser := strings.clone_to_cstring(user, context.temp_allocator)
	if pam_start(csvc, cuser, &conv, &h) != PAM_SUCCESS {return false}
	r := pam_authenticate(h, 0)
	if r == PAM_SUCCESS {pam_setcred(h, PAM_REFRESH_CRED)} // e.g. renew Kerberos tickets
	pam_end(h, r)
	return r == PAM_SUCCESS
}
