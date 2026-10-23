// wlscan: a small wayland-scanner replacement that emits Odin bindings.
//
// Usage: wlscan <out_dir> <package> <protocol.xml>...
//
// Emits <out_dir>/proto_<protocol>.odin per input file. Interfaces from all
// input files are known to each other, so cross-protocol references resolve.
//
// For every interface it generates:
//   - an opaque proxy type (`wl_surface` -> `Surface`, `zwlr_layer_shell_v1` -> `Zwlr_Layer_Shell_V1`)
//   - the `Interface`/`Message` tables libwayland needs, filled in an @(init) proc
//   - request wrappers calling `proxy_marshal_flags`
//   - a listener struct + `<iface>_add_listener` for events
//   - enum values as untyped constants
package wlscan

import "core:encoding/xml"
import "core:fmt"
import "core:os"
import "core:strings"

Arg :: struct {
	name:      string,
	type:      string,
	iface:     string,
	allow_nil: bool,
}

Message :: struct {
	name:       string,
	since:      int,
	destructor: bool,
	args:       [dynamic]Arg,
}

Enum_Entry :: struct {
	name:  string,
	value: string,
}

Enum :: struct {
	name:     string,
	bitfield: bool,
	entries:  [dynamic]Enum_Entry,
}

Interface :: struct {
	name:     string,
	version:  int,
	requests: [dynamic]Message,
	events:   [dynamic]Message,
	enums:    [dynamic]Enum,
}

KEYWORDS := []string{
	"map", "proc", "type", "context", "in", "struct", "enum", "union", "import", "package",
	"foreign", "when", "where", "if", "else", "for", "switch", "case", "defer", "return",
	"distinct", "dynamic", "using", "or_else", "or_return", "not_in", "cast", "transmute",
	"auto_cast", "bit_set", "matrix", "string", "fallthrough", "break", "continue", "bit_field",
}

safe_ident :: proc(s: string) -> string {
	for k in KEYWORDS {
		if s == k {return strings.concatenate({s, "_"})}
	}
	return s
}

// "wl_surface" -> "surface"; other prefixes are kept so names stay unique across protocols.
short_name :: proc(iface: string) -> string {
	if strings.has_prefix(iface, "wl_") {return iface[3:]}
	return iface
}

type_name :: proc(iface: string) -> string {
	return strings.to_ada_case(short_name(iface))
}

attr :: proc(doc: ^xml.Document, id: xml.Element_ID, key: string) -> (string, bool) {
	return xml.find_attribute_val_by_key(doc, id, key)
}

parse_message :: proc(doc: ^xml.Document, id: xml.Element_ID) -> Message {
	m: Message
	m.name, _ = attr(doc, id, "name")
	m.since = 1
	if s, ok := attr(doc, id, "since"); ok {
		v := 0
		for c in s {v = v * 10 + int(c - '0')}
		m.since = v
	}
	if t, ok := attr(doc, id, "type"); ok && t == "destructor" {m.destructor = true}
	for v in doc.elements[id].value {
		cid, is_el := v.(xml.Element_ID)
		if !is_el || doc.elements[cid].ident != "arg" {continue}
		a: Arg
		a.name, _ = attr(doc, cid, "name")
		a.type, _ = attr(doc, cid, "type")
		a.iface, _ = attr(doc, cid, "interface")
		if n, ok := attr(doc, cid, "allow-null"); ok && n == "true" {a.allow_nil = true}
		append(&m.args, a)
	}
	return m
}

parse_protocol :: proc(doc: ^xml.Document) -> (name: string, ifaces: [dynamic]Interface) {
	root := xml.Element_ID(0)
	name, _ = attr(doc, root, "name")
	for v in doc.elements[root].value {
		iid, is_el := v.(xml.Element_ID)
		if !is_el || doc.elements[iid].ident != "interface" {continue}
		it: Interface
		it.name, _ = attr(doc, iid, "name")
		vs, _ := attr(doc, iid, "version")
		for c in vs {it.version = it.version * 10 + int(c - '0')}
		for cv in doc.elements[iid].value {
			cid, ok := cv.(xml.Element_ID)
			if !ok {continue}
			switch doc.elements[cid].ident {
			case "request":
				append(&it.requests, parse_message(doc, cid))
			case "event":
				append(&it.events, parse_message(doc, cid))
			case "enum":
				e: Enum
				e.name, _ = attr(doc, cid, "name")
				if b, bok := attr(doc, cid, "bitfield"); bok && b == "true" {e.bitfield = true}
				for ev in doc.elements[cid].value {
					eid, eok := ev.(xml.Element_ID)
					if !eok || doc.elements[eid].ident != "entry" {continue}
					en: Enum_Entry
					en.name, _ = attr(doc, eid, "name")
					en.value, _ = attr(doc, eid, "value")
					append(&e.entries, en)
				}
				append(&it.enums, e)
			}
		}
		append(&ifaces, it)
	}
	return
}

signature :: proc(m: Message) -> string {
	b := strings.builder_make()
	if m.since > 1 {fmt.sbprintf(&b, "%d", m.since)}
	for a in m.args {
		if a.allow_nil {strings.write_byte(&b, '?')}
		switch a.type {
		case "int":    strings.write_byte(&b, 'i')
		case "uint":   strings.write_byte(&b, 'u')
		case "fixed":  strings.write_byte(&b, 'f')
		case "string": strings.write_byte(&b, 's')
		case "object": strings.write_byte(&b, 'o')
		case "array":  strings.write_byte(&b, 'a')
		case "fd":     strings.write_byte(&b, 'h')
		case "new_id":
			if a.iface == "" {strings.write_string(&b, "sun")} else {strings.write_byte(&b, 'n')}
		}
	}
	return strings.to_string(b)
}

odin_arg_type :: proc(a: Arg) -> string {
	switch a.type {
	case "int", "fd": return "i32"
	case "uint":      return "u32"
	case "fixed":     return "Fixed"
	case "string":    return "cstring"
	case "array":     return "^Array"
	case "object", "new_id":
		if a.iface == "" || !known[a.iface] {return "rawptr"}
		return fmt.aprintf("^%s", type_name(a.iface))
	}
	return "rawptr"
}

known: map[string]bool

iface_ref :: proc(name: string) -> string {
	if name == "" || !known[name] {return "nil"}
	return fmt.aprintf("&%s_interface", short_name(name))
}

emit_messages :: proc(b: ^strings.Builder, it: Interface, msgs: []Message, kind: string) {
	sn := short_name(it.name)
	if len(msgs) == 0 {return}
	for m, mi in msgs {
		n := 0
		for a in m.args {n += (a.type == "new_id" && a.iface == "") ? 3 : 1}
		if n > 0 {
			fmt.sbprintf(b, "\t@(static) %s_%s_%d_types: [%d]^Interface\n", sn, kind, mi, n)
			k := 0
			for a in m.args {
				if a.type == "new_id" && a.iface == "" {
					k += 3
					continue
				}
				if a.type == "object" || a.type == "new_id" {
					fmt.sbprintf(b, "\t%s_%s_%d_types[%d] = %s\n", sn, kind, mi, k, iface_ref(a.iface))
				}
				k += 1
			}
		}
	}
	fmt.sbprintf(b, "\t@(static) %s_%s: [%d]Message\n", sn, kind, len(msgs))
	for m, mi in msgs {
		n := 0
		for a in m.args {n += (a.type == "new_id" && a.iface == "") ? 3 : 1}
		types := n > 0 ? fmt.aprintf("&%s_%s_%d_types[0]", sn, kind, mi) : "nil"
		fmt.sbprintf(b, "\t%s_%s[%d] = {{\"%s\", \"%s\", %s}}\n", sn, kind, mi, m.name, signature(m), types)
	}
}

main :: proc() {
	if len(os.args) < 4 {
		fmt.eprintln("usage: wlscan <out_dir> <package> <protocol.xml>...")
		os.exit(1)
	}
	out_dir, pkg := os.args[1], os.args[2]

	Proto :: struct {
		name:   string,
		ifaces: [dynamic]Interface,
	}
	protos: [dynamic]Proto
	for in_path in os.args[3:] {
		doc, err := xml.load_from_file(in_path)
		if err != nil {
			fmt.eprintfln("wlscan: failed to parse %s: %v", in_path, err)
			os.exit(1)
		}
		name, ifaces := parse_protocol(doc)
		for it in ifaces {known[it.name] = true}
		append(&protos, Proto{name, ifaces})
	}
	for p in protos {
		out_path := fmt.aprintf("%s/proto_%s.odin", out_dir, strings.to_snake_case(p.name))
		generate(out_path, pkg, p.name, p.ifaces[:])
	}
}

generate :: proc(out_path, pkg, proto: string, ifaces: []Interface) {
	b := strings.builder_make()
	fmt.sbprintf(&b, "// Code generated by tools/wlscan from %s. DO NOT EDIT.\n", proto)
	fmt.sbprintf(&b, "package %s\n\n", pkg)

	for it in ifaces {
		tn := type_name(it.name)
		sn := short_name(it.name)
		fmt.sbprintf(&b, "// ---- %s (v%d) ----\n\n", it.name, it.version)
		fmt.sbprintf(&b, "%s :: struct {{}}\n", tn)
		fmt.sbprintf(&b, "%s_interface: Interface\n\n", sn)

		// enums
		for e in it.enums {
			for en in e.entries {
				cname := strings.to_upper(fmt.aprintf("%s_%s_%s", sn, e.name, en.name))
				fmt.sbprintf(&b, "%s :: %s\n", cname, en.value)
			}
			strings.write_string(&b, "\n")
		}

		// user data helpers
		fmt.sbprintf(&b, "%s_set_user_data :: #force_inline proc \"contextless\" (self: ^%s, data: rawptr) {{ proxy_set_user_data(cast(^Proxy)self, data) }}\n", sn, tn)
		fmt.sbprintf(&b, "%s_get_user_data :: #force_inline proc \"contextless\" (self: ^%s) -> rawptr {{ return proxy_get_user_data(cast(^Proxy)self) }}\n", sn, tn)
		fmt.sbprintf(&b, "%s_get_version :: #force_inline proc \"contextless\" (self: ^%s) -> u32 {{ return proxy_get_version(cast(^Proxy)self) }}\n", sn, tn)

		has_destroy := false
		for r in it.requests {if r.name == "destroy" {has_destroy = true}}
		if !has_destroy && it.name != "wl_display" {
			fmt.sbprintf(&b, "%s_destroy :: #force_inline proc \"contextless\" (self: ^%s) {{ proxy_destroy(cast(^Proxy)self) }}\n", sn, tn)
		}
		strings.write_string(&b, "\n")

		// requests
		for r, op in it.requests {
			ret := ""
			ret_iface := ""
			untyped_new := false
			params := strings.builder_make()
			fmt.sbprintf(&params, "self: ^%s", tn)
			call_args := strings.builder_make()
			for a in r.args {
				if a.type == "new_id" {
					if a.iface == "" {
						untyped_new = true
						fmt.sbprintf(&params, ", iface: ^Interface, version: u32")
						strings.write_string(&call_args, ", iface.name, version, rawptr(nil)")
						ret = "rawptr"
					} else {
						ret = fmt.aprintf("^%s", type_name(a.iface))
						ret_iface = a.iface
						strings.write_string(&call_args, ", rawptr(nil)")
					}
					continue
				}
				an := safe_ident(a.name)
				fmt.sbprintf(&params, ", %s: %s", an, odin_arg_type(a))
				fmt.sbprintf(&call_args, ", %s", an)
			}
			flags := r.destructor ? "MARSHAL_FLAG_DESTROY" : "0"
			iface_arg := "nil"
			version := "proxy_get_version(cast(^Proxy)self)"
			if untyped_new {
				iface_arg = "iface"
				version = "version"
			} else if ret_iface != "" {
				iface_arg = iface_ref(ret_iface)
			}
			if ret != "" {
				fmt.sbprintf(&b, "%s_%s :: proc \"contextless\" (%s) -> %s {{\n", sn, r.name, strings.to_string(params), ret)
				fmt.sbprintf(&b, "\treturn cast(%s)proxy_marshal_flags(cast(^Proxy)self, %d, %s, %s, %s%s)\n}}\n", ret, op, iface_arg, version, flags, strings.to_string(call_args))
			} else {
				fmt.sbprintf(&b, "%s_%s :: proc \"contextless\" (%s) {{\n", sn, r.name, strings.to_string(params))
				fmt.sbprintf(&b, "\tproxy_marshal_flags(cast(^Proxy)self, %d, nil, %s, %s%s)\n}}\n", op, version, flags, strings.to_string(call_args))
			}
		}

		// events
		if len(it.events) > 0 {
			fmt.sbprintf(&b, "\n%s_Listener :: struct {{\n", tn)
			for e in it.events {
				fmt.sbprintf(&b, "\t%s: proc \"c\" (data: rawptr, self: ^%s", safe_ident(e.name), tn)
				for a in e.args {
					fmt.sbprintf(&b, ", %s: %s", safe_ident(a.name), odin_arg_type(a))
				}
				strings.write_string(&b, "),\n")
			}
			strings.write_string(&b, "}\n")
			fmt.sbprintf(&b, "%s_add_listener :: proc \"contextless\" (self: ^%s, listener: ^%s_Listener, data: rawptr) -> i32 {{\n", sn, tn, tn)
			strings.write_string(&b, "\treturn proxy_add_listener(cast(^Proxy)self, rawptr(listener), data)\n}\n")
		}
		strings.write_string(&b, "\n")
	}

	// interface tables
	fmt.sbprintf(&b, "@(init, private)\n_init_%s :: proc \"contextless\" () {{\n", strings.to_snake_case(proto))
	for it in ifaces {
		sn := short_name(it.name)
		emit_messages(&b, it, it.requests[:], "requests")
		emit_messages(&b, it, it.events[:], "events")
		reqs := len(it.requests) > 0 ? fmt.aprintf("&%s_requests[0]", sn) : "nil"
		evs := len(it.events) > 0 ? fmt.aprintf("&%s_events[0]", sn) : "nil"
		fmt.sbprintf(&b, "\t%s_interface = {{\"%s\", %d, %d, %s, %d, %s}}\n\n", sn, it.name, it.version, len(it.requests), reqs, len(it.events), evs)
	}
	strings.write_string(&b, "}\n")

	if werr := os.write_entire_file(out_path, strings.to_string(b)); werr != nil {
		fmt.eprintfln("wlscan: cannot write %s: %v", out_path, werr)
		os.exit(1)
	}
}
