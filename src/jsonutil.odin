// Tiny helpers for walking core:encoding/json values.
package main

import "core:encoding/json"

jobj :: proc(v: json.Value, key: string) -> json.Value {
	if o, ok := v.(json.Object); ok {
		return o[key]
	}
	return nil
}

jarr :: proc(v: json.Value) -> json.Array {
	a, _ := v.(json.Array)
	return a
}

// Element i of a JSON array, or nil when out of range / not an array.
jidx :: proc(v: json.Value, i: int) -> json.Value {
	a := jarr(v)
	if i < 0 || i >= len(a) {return nil}
	return a[i]
}

jstr :: proc(v: json.Value, def := "") -> string {
	if s, ok := v.(json.String); ok {return s}
	return def
}

jint :: proc(v: json.Value, def: i64 = 0) -> i64 {
	#partial switch x in v {
	case json.Integer: return x
	case json.Float:   return i64(x)
	}
	return def
}

jfloat :: proc(v: json.Value, def: f64 = 0) -> f64 {
	#partial switch x in v {
	case json.Integer: return f64(x)
	case json.Float:   return x
	}
	return def
}

jbool :: proc(v: json.Value, def := false) -> bool {
	if b, ok := v.(json.Boolean); ok {return b}
	return def
}

// Parse JSON into the temp allocator (values are only valid for this frame/tick).
jparse :: proc(data: string) -> (json.Value, bool) {
	v, err := json.parse_string(data, .JSON5, parse_integers = true, allocator = context.temp_allocator)
	return v, err == nil
}
