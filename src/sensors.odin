// Tuya sensors, read natively over the LAN (see tuya.odin). Devices come from
// a tuya-sensors / tinytuya devices.json ([sensors] dir) and/or [sensor.*]
// sections in the config. A listener thread catches the discovery broadcasts
// (battery sensors only wake for a few seconds), queries the device that
// announced itself, and keeps the last value of every data point in
// <data>/sensors-state.json, which `wlperch status sensors` reads too.
package main

import "core:encoding/endian"
import "core:encoding/ini"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

Sensor_Kind :: enum {
	Other,
	Climate, // thermo-hygrometer
	Air,     // air quality monitor
	Heater,
}

Sensor_Value :: struct {
	code:  string,
	num:   f64,
	text:  string, // non-numeric values ("level_1", true, ...)
	is_num: bool,
	unit:  string,
	t:     f64, // unix time of the report
}

Sensor_Device :: struct {
	id:     string,
	name:   string,
	kind:   Sensor_Kind,
	values: [dynamic]Sensor_Value,
	last_t: f64,
}

Sensor_Sample :: struct {
	t: f64, // unix seconds
	v: f32,
}

Sensors :: struct {
	mu:       sync.Mutex,
	// History of every numeric value, keyed "<device id>/<code>"; persisted in
	// <data>/sensors.bin (last SENSOR_HISTORY_DAYS days only).
	history:  map[string][dynamic]Sensor_Sample,
	ok:       bool,
	error:    string,
	devices:  [dynamic]Sensor_Device,
	watching: bool, // the discovery listener is up
}
sensors: Sensors

// How one data point reads: tinytuya's mapping, reduced to what we show.
Sensor_Dp :: struct {
	code:  string,
	unit:  string,
	scale: int, // value / 10^scale
}

// A configured device. `key` is the local key: it is only ever used to talk
// to the device, never logged.
Sensor_Def :: struct {
	id, name, key: string,
	ip, version:   string, // optional; normally learned from the broadcasts
	kind:          Sensor_Kind,
	dps:           map[string]Sensor_Dp, // "1" -> va_temperature
}

// Loaded with the config; read-only afterwards.
sensor_defs: [dynamic]Sensor_Def

// Built-in DP layouts for [sensor.*] sections without dpN lines: the usual
// Tuya thermo-hygrometer (wsdcg), the common MT15/MT29-style air monitor
// (hjjcy) and a basic heater (qn). "dp = code scale unit".
@(private = "file")
BUILTIN_DPS := [Sensor_Kind]string {
	.Other   = "",
	.Climate = "1=va_temperature 1 ℃, 2=humidity_value 0 %, 3=battery_state, 4=battery_percentage 0 %",
	.Air     = "1=air_quality_index, 2=temp_current 0 ℃, 3=humidity_value 0 %, 4=co2_value 0 ppm, 5=ch2o_value 3 mg/m³, 7=pm25_value 0 ug/m³, 8=pm1 0 ug/m³, 9=pm10 0 ug/m³, 22=battery_percentage 0 %, 23=charge_state",
	.Heater  = "1=switch, 2=temp_set 0 ℃, 3=temp_current 0 ℃, 4=mode, 6=mode_eco",
}

// "va_temperature 1 ℃" -> {code, scale 1, unit}
sensor_parse_dp :: proc(s: string) -> (dp: Sensor_Dp, ok: bool) {
	f := strings.fields(s, context.temp_allocator)
	if len(f) == 0 {return}
	dp.code = strings.clone(f[0])
	if len(f) > 1 {dp.scale = strconv.parse_int(f[1]) or_else 0}
	if len(f) > 2 {dp.unit = strings.clone(strings.join(f[2:], " ", context.temp_allocator))}
	return dp, true
}

@(private = "file")
kind_from_text :: proc(s: string) -> Sensor_Kind {
	switch strings.to_lower(strings.trim_space(s), context.temp_allocator) {
	case "room", "climate", "wsdcg":              return .Climate
	case "air", "hjjcy", "co2bj", "pm25":         return .Air
	case "heater", "qn", "rs":                    return .Heater
	}
	return .Other
}

// Kind from the data point codes, for devices without a known category.
sensor_kind_from_dps :: proc(dps: map[string]Sensor_Dp) -> Sensor_Kind {
	kind := Sensor_Kind.Other
	for _, m in dps {
		switch m.code {
		case "co2_value", "pm25_value", "ch2o_value", "air_quality_index": return .Air
		case "temp_set":                                                    kind = .Heater
		case "va_temperature", "va_humidity", "humidity_value":            if kind == .Other {kind = .Climate}
		}
	}
	return kind
}

// "MT15/MT29 attic " -> "Attic", "Kitchen SRW-TH03" -> "Kitchen", "Your Acme Heater" -> "Acme Heater"
clean_sensor_name :: proc(name, product: string) -> string {
	n := strings.trim_space(name)
	if product != "" {
		if strings.has_prefix(n, product) {n = n[len(product):]}
		if strings.has_suffix(n, product) {n = n[:len(n) - len(product)]}
	}
	n = strings.trim_space(n)
	if n == "" {n = strings.trim_space(product)}
	n = strings.trim_prefix(n, "Your ")
	if len(n) > 0 && n[0] >= 'a' && n[0] <= 'z' {
		return strings.concatenate({strings.to_upper(n[:1], context.temp_allocator), n[1:]}, context.temp_allocator)
	}
	return n
}

@(private = "file")
def_find :: proc(id: string) -> ^Sensor_Def {
	for &d in sensor_defs {if d.id == id {return &d}}
	return nil
}

// Devices from <dir>/devices.json (tinytuya format: id, name, key, ip,
// version, category, product_name, mapping{dp: {code, values: {unit, scale}}}).
sensor_defs_from_devices_json :: proc(text: string, out: ^[dynamic]Sensor_Def) {
	devs, ok := jparse(text)
	if !ok {return}
	for d in jarr(devs) {
		id := jstr(jobj(d, "id"))
		if id == "" {continue}
		def := Sensor_Def {
			id      = strings.clone(id),
			name    = strings.clone(clean_sensor_name(jstr(jobj(d, "name")), jstr(jobj(d, "product_name")))),
			key     = strings.clone(jstr(jobj(d, "key"))),
			ip      = strings.clone(jstr(jobj(d, "ip"))),
			version = strings.clone(jstr(jobj(d, "version"))),
			kind    = kind_from_text(jstr(jobj(d, "category"))),
		}
		if m, is_obj := jobj(d, "mapping").(json.Object); is_obj {
			for dp, entry in m {
				values := jobj(entry, "values")
				if s, is_str := values.(json.String); is_str {values, _ = jparse(s)}
				def.dps[strings.clone(dp)] = {
					code  = strings.clone(jstr(jobj(entry, "code"), fmt.tprintf("dp%s", dp))),
					unit  = strings.clone(jstr(jobj(values, "unit"))),
					scale = int(jint(jobj(values, "scale"))),
				}
			}
		}
		if def.kind == .Other {def.kind = sensor_kind_from_dps(def.dps)}
		append(out, def)
	}
}

// [sensor.<name>] sections: id, key, optional name / ip / version / kind and
// dpN = "code scale unit" lines (else the built-in layout for the kind).
// A section with the id of a devices.json entry overrides what it sets.
sensor_defs_from_ini :: proc(m: ini.Map, out: ^[dynamic]Sensor_Def) {
	sections: [dynamic]string
	sections.allocator = context.temp_allocator
	for section in m {if strings.has_prefix(section, "sensor.") {append(&sections, section)}}
	slice.sort(sections[:])
	for section in sections {
		kv := m[section]
		get :: proc(kv: map[string]string, key: string) -> string {return unquote(strings.trim_space(kv[key]))}
		id := get(kv, "id")
		if id == "" {
			log.warnf("[%s] has no id; skipped", section)
			continue
		}
		def: ^Sensor_Def
		for &d in out {if d.id == id {def = &d}}
		if def == nil {
			append(out, Sensor_Def{id = strings.clone(id)})
			def = &out[len(out) - 1]
			def.name = strings.clone(clean_sensor_name(section[len("sensor."):], ""))
		}
		if v := get(kv, "name"); v != "" {def.name = strings.clone(v)}
		if v := get(kv, "key"); v != "" {def.key = strings.clone(v)}
		if v := get(kv, "ip"); v != "" {def.ip = strings.clone(v)}
		if v := get(kv, "version"); v != "" {def.version = strings.clone(v)}
		if v := get(kv, "kind"); v != "" {def.kind = kind_from_text(v)}
		has_dps := false
		for k, v in kv {
			if !strings.has_prefix(k, "dp") {continue}
			if _, num_ok := strconv.parse_int(k[2:]); !num_ok {continue}
			if dp, dp_ok := sensor_parse_dp(unquote(strings.trim_space(v))); dp_ok {
				def.dps[strings.clone(k[2:])] = dp
				has_dps = true
			}
		}
		if !has_dps && len(def.dps) == 0 {
			if def.kind == .Other {def.kind = .Climate}
			for entry in strings.split(BUILTIN_DPS[def.kind], ",", context.temp_allocator) {
				eq := strings.index_byte(entry, '=')
				if dp, dp_ok := sensor_parse_dp(entry[eq + 1:]); dp_ok {
					def.dps[strings.clone(strings.trim_space(entry[:eq]))] = dp
				}
			}
		}
		if def.kind == .Other {def.kind = sensor_kind_from_dps(def.dps)}
	}
}

// Called from config_load.
sensors_load_defs :: proc(m: ini.Map) {
	clear(&sensor_defs) // config is loaded once per process; old entries are not freed
	if config.sensors_dir != "" {
		if data, err := os.read_entire_file(strings.concatenate({config.sensors_dir, "/devices.json"}, context.temp_allocator), context.temp_allocator); err == nil {
			sensor_defs_from_devices_json(string(data), &sensor_defs)
		} else {
			log.warnf("[sensors] dir: no devices.json in %s", config.sensors_dir)
		}
	}
	sensor_defs_from_ini(m, &sensor_defs)
}

// ---- Last value of every data point -------------------------------------
// {"<id>": {"<dp>": {"v": <raw JSON value>, "t": <unix time>}}}, the format of
// the tuya-sensors tool's state.json (seeded from it once).

Sensor_State_Entry :: struct {
	raw: string, // JSON text of the raw value: 215, "level_1", true
	t:   f64,
}

Sensor_State :: map[string]map[string]Sensor_State_Entry

@(private = "file")
state: Sensor_State

@(private = "file")
state_path :: proc() -> string {return strings.concatenate({data_dir(), "/sensors-state.json"}, context.temp_allocator)}

@(private = "file")
state_clear :: proc() {
	for id, &dps in state {
		for dp, e in dps {delete(dp); delete(e.raw)}
		delete(dps)
		delete(id)
	}
	clear(&state)
}

// Merge {"<dp>": <raw value>} reported at time t.
sensor_state_merge :: proc(st: ^Sensor_State, id: string, dps: json.Object, t: f64) {
	if id not_in st^ {st[strings.clone(id)] = {}}
	entry := &st[id]
	for dp, v in dps {
		raw, err := json.marshal(v, allocator = context.temp_allocator)
		if err != nil {continue}
		if old, has := entry[dp]; has {
			delete(old.raw)
			entry[dp] = {strings.clone(string(raw)), t}
		} else {
			entry[strings.clone(dp)] = {strings.clone(string(raw)), t}
		}
	}
}

@(private = "file")
state_parse :: proc(text: string) {
	state_clear()
	v, ok := jparse(text)
	if !ok {return}
	devs, _ := v.(json.Object)
	for id, dps in devs {
		obj, _ := dps.(json.Object)
		for dp, e in obj {
			one: json.Object
			one.allocator = context.temp_allocator
			one[dp] = jobj(e, "v")
			sensor_state_merge(&state, id, one, jfloat(jobj(e, "t")))
		}
	}
}

sensor_state_encode :: proc(st: Sensor_State) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{")
	first := true
	for id, dps in st {
		fmt.sbprintf(&b, "%s\n %q: {{", first ? "" : ",", id)
		first = false
		first_dp := true
		for dp, e in dps {
			fmt.sbprintf(&b, "%s\n  %q: {{\"v\": %s, \"t\": %.3f}}", first_dp ? "" : ",", dp, e.raw, e.t)
			first_dp = false
		}
		strings.write_string(&b, "\n }")
	}
	strings.write_string(&b, "\n}\n")
	return strings.to_string(b)
}

@(private = "file")
state_save :: proc() {
	os.make_directory_all(data_dir())
	path := state_path()
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, sensor_state_encode(state)) != nil {return}
	if os.rename(tmp, path) != nil {_ = os.remove(tmp)}
}

@(private = "file")
state_load :: proc() {
	path := state_path()
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil && !sensors_read_only && config.sensors_dir != "" {
		// First run after the switch from the tuya-sensors watcher: start from its values.
		data, err = os.read_entire_file(strings.concatenate({config.sensors_dir, "/state.json"}, context.temp_allocator), context.temp_allocator)
		if err == nil {log.infof("sensors: seeded %s from %s/state.json", path, config.sensors_dir)}
	}
	if err != nil {
		state_clear()
		return
	}
	state_parse(string(data))
	if !sensors_read_only && !os.exists(path) {state_save()}
}

// ---- Snapshot for the UI ------------------------------------------------

@(private = "file")
strs: [dynamic]string // everything owned by the current snapshot

@(private = "file")
own :: proc(s: string) -> string {
	c := strings.clone(s)
	append(&strs, c)
	return c
}

sensor_value :: proc(d: ^Sensor_Device, code: string) -> (v: Sensor_Value, ok: bool) {
	for x in d.values {
		if x.code == code {return x, true}
	}
	return {}, false
}

// One raw data point through the device's mapping (strings in temp memory).
sensor_decode :: proc(def: ^Sensor_Def, dp: string, entry: Sensor_State_Entry) -> Sensor_Value {
	m, has := def.dps[dp]
	v := Sensor_Value{code = has ? m.code : fmt.tprintf("dp%s", dp), unit = m.unit, t = entry.t}
	raw, _ := jparse(entry.raw)
	#partial switch x in raw {
	case json.Integer, json.Float:
		v.is_num = true
		v.num = jfloat(raw)
		if m.scale > 0 {v.num /= math.pow(10, f64(m.scale))}
	case json.String:
		v.text = x
	case json.Boolean:
		v.text = x ? "on" : "off"
	}
	return v
}

// Re-read the state file (for `wlperch status sensors`, which has no listener).
sensors_reload :: proc() {
	state_load()
	sync.guard(&sensors.mu)
	rebuild()
}

// sensors.devices from the definitions and the state. Called with sensors.mu held.
@(private = "file")
rebuild :: proc() {
	for &d in sensors.devices {delete(d.values)}
	clear(&sensors.devices)
	for s in strs {delete(s)}
	clear(&strs)

	for &def in sensor_defs {
		dev := Sensor_Device {
			id   = own(def.id),
			name = own(def.name != "" ? def.name : def.id),
			kind = def.kind,
		}
		reported: map[string]Sensor_State_Entry
		if len(state) > 0 {reported = state[def.id]} // (indexing a never-allocated map crashes)
		for dp, entry in reported {
			v := sensor_decode(&def, dp, entry)
			v.code, v.unit, v.text = own(v.code), own(v.unit), own(v.text)
			dev.last_t = max(dev.last_t, v.t)
			append(&dev.values, v)
		}
		append(&sensors.devices, dev)
	}
	// Rooms first (alphabetical), then air quality, heaters, others.
	order :: proc(k: Sensor_Kind) -> int {return k == .Climate ? 0 : k == .Air ? 1 : k == .Heater ? 2 : 3}
	for i in 1 ..< len(sensors.devices) {
		for j := i; j > 0; j -= 1 {
			a, b := sensors.devices[j - 1], sensors.devices[j]
			if order(b.kind) < order(a.kind) || (a.kind == b.kind && b.name < a.name) {
				sensors.devices[j - 1], sensors.devices[j] = b, a
			} else {
				break
			}
		}
	}
	sensors.ok = true
	if !sensors_read_only {record_history()}
}

SENSOR_HISTORY_DAYS :: 7

// Set by `wlperch status sensors`: only the daemon writes the history file.
sensors_read_only: bool

// History file: "WLSH", u32 version, u32 key count, then per key a u16-length
// name and a u32 sample count followed by (f64 time, f32 value) pairs, all
// little-endian. Rewritten whole on every change, holding only the last
// SENSOR_HISTORY_DAYS days, so it never grows past that.
SENSOR_HISTORY_MAGIC :: "WLSH"
SENSOR_HISTORY_VERSION :: 1

@(private = "file")
history_path :: proc() -> string {return strings.concatenate({data_dir(), "/sensors.bin"}, context.temp_allocator)}

// Text log written by earlier versions; imported once, then removed.
@(private = "file")
legacy_history_path :: proc() -> string {return strings.concatenate({data_dir(), "/sensors.tsv"}, context.temp_allocator)}

@(private = "file")
history_key :: proc(dev_id, code: string) -> string {return fmt.tprintf("%s/%s", dev_id, code)}

history_cutoff :: proc() -> f64 {return f64(time.to_unix_seconds(time.now())) - SENSOR_HISTORY_DAYS * 86400}

// Drop samples older than `cutoff` from every list.
history_trim :: proc(h: ^map[string][dynamic]Sensor_Sample, cutoff: f64) -> (dropped: bool) {
	for _, &list in h {
		old := 0
		for old < len(list) && list[old].t < cutoff {old += 1}
		if old > 0 {
			remove_range(&list, 0, old)
			dropped = true
		}
	}
	return
}

// Append a sample to one list; false if it isn't newer than the last one or
// already outside the window.
history_append :: proc(h: ^map[string][dynamic]Sensor_Sample, key: string, t: f64, v: f32, cutoff: f64) -> bool {
	if t < cutoff {return false}
	list, has := &h[key]
	if !has {
		h[strings.clone(key)] = {}
		list = &h[key]
	}
	if n := len(list); n > 0 && t <= list[n - 1].t {return false}
	append(list, Sensor_Sample{t, v})
	return true
}

history_encode :: proc(h: map[string][dynamic]Sensor_Sample, allocator := context.allocator) -> []byte {
	out: [dynamic]byte
	out.allocator = allocator
	put_u16 :: proc(out: ^[dynamic]byte, v: u16) {b: [2]byte; endian.put_u16(b[:], .Little, v); append(out, ..b[:])}
	put_u32 :: proc(out: ^[dynamic]byte, v: u32) {b: [4]byte; endian.put_u32(b[:], .Little, v); append(out, ..b[:])}
	append(&out, SENSOR_HISTORY_MAGIC)
	put_u32(&out, SENSOR_HISTORY_VERSION)
	keys := 0
	for k, list in h {if len(list) > 0 && len(k) <= int(max(u16)) {keys += 1}}
	put_u32(&out, u32(keys))
	for k, list in h {
		if len(list) == 0 || len(k) > int(max(u16)) {continue}
		put_u16(&out, u16(len(k)))
		append(&out, k)
		put_u32(&out, u32(len(list)))
		for s in list {
			b: [12]byte
			endian.put_f64(b[0:8], .Little, s.t)
			endian.put_f32(b[8:12], .Little, s.v)
			append(&out, ..b[:])
		}
	}
	return out[:]
}

// Reads what it can: a truncated or damaged file keeps the samples before the damage.
history_decode :: proc(data: []byte, h: ^map[string][dynamic]Sensor_Sample, cutoff: f64) -> bool {
	if len(data) < 12 || string(data[:4]) != SENSOR_HISTORY_MAGIC {return false}
	if v, _ := endian.get_u32(data[4:8], .Little); v != SENSOR_HISTORY_VERSION {return false}
	keys, _ := endian.get_u32(data[8:12], .Little)
	pos := 12
	for _ in 0 ..< keys {
		if pos + 2 > len(data) {return false}
		klen, _ := endian.get_u16(data[pos:pos + 2], .Little)
		pos += 2
		if pos + int(klen) + 4 > len(data) {return false}
		key := string(data[pos:pos + int(klen)])
		pos += int(klen)
		n, _ := endian.get_u32(data[pos:pos + 4], .Little)
		pos += 4
		for _ in 0 ..< n {
			if pos + 12 > len(data) {return false}
			t, _ := endian.get_f64(data[pos:pos + 8], .Little)
			v, _ := endian.get_f32(data[pos + 8:pos + 12], .Little)
			pos += 12
			history_append(h, key, t, v, cutoff)
		}
	}
	return true
}

@(private = "file")
save_history :: proc() {
	data := history_encode(sensors.history, context.temp_allocator)
	os.make_directory_all(data_dir())
	path := history_path()
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, data) != nil {return}
	if os.rename(tmp, path) != nil {_ = os.remove(tmp)}
}

@(private = "file")
load_history :: proc() {
	cutoff := history_cutoff()
	sync.guard(&sensors.mu)
	if data, err := os.read_entire_file(history_path(), context.temp_allocator); err == nil {
		history_decode(data, &sensors.history, cutoff)
	}
	if sensors_read_only {return}
	// One-time import of the old text log ("time dev code value" lines).
	legacy := legacy_history_path()
	if data, err := os.read_entire_file(legacy, context.temp_allocator); err == nil {
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			f := strings.split(line, "\t", context.temp_allocator)
			if len(f) < 4 {continue}
			t, ok1 := strconv.parse_f64(f[0])
			v, ok2 := strconv.parse_f64(f[3])
			if !ok1 || !ok2 {continue}
			history_append(&sensors.history, history_key(f[1], f[2]), t, f32(v), cutoff)
		}
	}
	// Rewrite: drops whatever aged out while the daemon wasn't running.
	save_history()
	if os.exists(history_path()) {_ = os.remove(legacy)}
}

// New readings since the last reload go into memory and the history file.
// Called with sensors.mu held.
@(private = "file")
record_history :: proc() {
	cutoff := history_cutoff()
	changed := history_trim(&sensors.history, cutoff)
	for &d in sensors.devices {
		for v in d.values {
			if !v.is_num || v.t <= 0 {continue}
			if history_append(&sensors.history, history_key(d.id, v.code), v.t, f32(v.num), cutoff) {changed = true}
		}
	}
	if changed {save_history()}
}

// Samples of one value within [from, now] (temp copy; call with sensors.mu held).
sensor_history :: proc(dev_id, code: string, from: f64) -> []Sensor_Sample {
	list, has := sensors.history[history_key(dev_id, code)]
	if !has {return nil}
	i := len(list)
	for i > 0 && list[i - 1].t >= from {i -= 1}
	// Keep the sample just before the window so the step line starts at the left edge.
	if i > 0 {i -= 1}
	out := make([]Sensor_Sample, len(list) - i, context.temp_allocator)
	copy(out, list[i:])
	return out
}


// ---- Listener -----------------------------------------------------------

@(private = "file") READ_COOLDOWN :: 30 * time.Second // awake devices announce every few seconds
@(private = "file") PROBE_EVERY   :: 6 * time.Second  // 3.5 devices only announce when asked
@(private = "file") POLL_FIXED    :: 5 * time.Minute  // devices with a configured ip + version

@(private = "file")
udp_socket :: proc(port: u16) -> posix.FD {
	fd := posix.socket(.INET, .DGRAM)
	if fd < 0 {return -1}
	posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC))
	one: i32 = 1
	// Shared with any other listener (e.g. tinytuya) on the same ports.
	posix.setsockopt(fd, posix.SOL_SOCKET, .REUSEADDR, &one, size_of(one))
	posix.setsockopt(fd, posix.SOL_SOCKET, .BROADCAST, &one, size_of(one))
	if port != 0 {
		addr := posix.sockaddr_in{sin_family = .INET, sin_port = posix.in_port_t(port)}
		if posix.bind(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK {
			posix.close(fd)
			return -1
		}
	}
	return fd
}

// Our address on the LAN (the source of broadcasts), for the discovery probe.
@(private = "file")
local_ip :: proc(fd: posix.FD) -> string {
	s := udp_socket(0)
	if s < 0 {return "0.0.0.0"}
	defer posix.close(s)
	addr := posix.sockaddr_in{sin_family = .INET, sin_port = 7000, sin_addr = {s_addr = posix.in_addr_t(posix.INADDR_BROADCAST)}}
	if posix.connect(s, cast(^posix.sockaddr)&addr, size_of(addr)) != .OK {return "0.0.0.0"}
	l := posix.socklen_t(size_of(addr))
	if posix.getsockname(s, cast(^posix.sockaddr)&addr, &l) != .OK {return "0.0.0.0"}
	return string(posix.inet_ntoa(addr.sin_addr))
}

@(private = "file")
send_probe :: proc(fd: posix.FD) {
	msg := tuya_discovery_request(local_ip(fd))
	addr := posix.sockaddr_in{sin_family = .INET, sin_port = 7000, sin_addr = {s_addr = posix.in_addr_t(posix.INADDR_BROADCAST)}}
	posix.sendto(fd, raw_data(msg), len(msg), {}, cast(^posix.sockaddr)&addr, size_of(addr))
}

// Query one device and merge what it reports.
@(private = "file")
read_device :: proc(def: ^Sensor_Def, ip, version: string) {
	v, vok := tuya_version(version)
	if !vok {log.debugf("sensors: %s announced unknown protocol %q; trying 3.3", def.name, version)}
	text, err := tuya_read_status(ip, def.id, transmute([]byte)def.key, v)
	if err != "" {
		log.debugf("sensors: %s (%s, v%s): %s", def.name, ip, version, err)
		return
	}
	reply, _ := jparse(text)
	dps := jobj(reply, "dps")
	if dps == nil {dps = jobj(jobj(reply, "data"), "dps")}
	obj, is_obj := dps.(json.Object)
	log.debugf("sensors: %s (%s, v%s): %d data points", def.name, ip, version, len(obj))
	if !is_obj || len(obj) == 0 {return}
	{
		sync.guard(&sensors.mu)
		sensor_state_merge(&state, def.id, obj, f64(time.to_unix_nanoseconds(time.now())) / 1e9)
		state_save()
		rebuild()
	}
	wake_ui()
}

@(private = "file")
sensors_listen :: proc() {
	socks: [len(TUYA_UDP_PORTS)]posix.FD
	for warned := false; ; warned = true {
		ok: bool
		if socks, ok = open_listeners(); ok {break}
		if !warned {log.warnf("sensors: cannot listen on UDP %v; retrying", TUYA_UDP_PORTS)}
		time.sleep(30 * time.Second)
	}
	probe := udp_socket(0)
	sensors.watching = true
	log.debugf("sensors: listening on UDP %v for %d devices", TUYA_UDP_PORTS, len(sensor_defs))

	last_read: map[string]time.Tick // device id -> last query
	unknown: map[string]bool        // ids already logged as unknown
	next_probe, next_fixed := time.tick_now(), time.tick_now()
	last_trim := time.tick_now()
	for {
		now := time.tick_now()
		if time.tick_diff(next_probe, now) >= 0 {
			if probe >= 0 {send_probe(probe)}
			next_probe = time.tick_add(now, PROBE_EVERY)
		}
		if time.tick_diff(next_fixed, now) >= 0 {
			next_fixed = time.tick_add(now, POLL_FIXED)
			for &d in sensor_defs {
				if d.ip == "" || d.version == "" || d.key == "" {continue}
				last_read[d.id] = now
				read_device(&d, d.ip, d.version)
			}
		}
		// Age out old samples even when no new readings arrive.
		if !sensors_read_only && time.tick_since(last_trim) > time.Hour {
			last_trim = time.tick_now()
			sync.guard(&sensors.mu)
			if history_trim(&sensors.history, history_cutoff()) {save_history()}
		}
		free_all(context.temp_allocator)

		wait := time.tick_diff(time.tick_now(), next_probe)
		for a in receive_announcements(socks[:], wait) {
			def := def_find(a.id)
			if def == nil || def.key == "" {
				if a.id not_in unknown {
					unknown[strings.clone(a.id)] = true
					log.debugf("sensors: unconfigured Tuya device %s at %s (v%s)", a.id, a.ip, a.version)
				}
				continue
			}
			if last, seen := last_read[a.id]; seen && time.tick_diff(last, time.tick_now()) < READ_COOLDOWN {continue}
			if a.id not_in last_read {last_read[strings.clone(a.id)] = {}}
			last_read[a.id] = time.tick_now()
			read_device(def, def.ip != "" ? def.ip : a.ip, def.version != "" ? def.version : a.version)
		}
	}
}

@(private = "file")
Announcement :: struct {
	id, ip, version: string,
}

// Wait up to `wait` for discovery broadcasts; returns the devices heard (temp memory).
@(private = "file")
receive_announcements :: proc(socks: []posix.FD, wait: time.Duration) -> []Announcement {
	out := make([dynamic]Announcement, context.temp_allocator)
	pfds := make([]posix.pollfd, len(socks), context.temp_allocator)
	for fd, i in socks {pfds[i] = {fd = fd, events = {.IN}}}
	if posix.poll(raw_data(pfds), posix.nfds_t(len(pfds)), i32(max(time.duration_milliseconds(wait), 0)) + 1) <= 0 {return out[:]}
	buf: [TUYA_MAX_FRAME]byte
	for p in pfds {
		if .IN not_in p.revents {continue}
		from: posix.sockaddr_in
		l := posix.socklen_t(size_of(from))
		n := posix.recvfrom(p.fd, &buf[0], len(buf), {}, cast(^posix.sockaddr)&from, &l)
		if n <= 0 {continue}
		text, ok := tuya_decrypt_udp(buf[:n])
		if !ok {continue}
		msg, _ := jparse(text)
		id := jstr(jobj(msg, "gwId"))
		if id == "" {continue} // e.g. a discovery probe
		ip := jstr(jobj(msg, "ip"), strings.clone_from_cstring(posix.inet_ntoa(from.sin_addr), context.temp_allocator))
		append(&out, Announcement{id, ip, jstr(jobj(msg, "version"))})
	}
	return out[:]
}

@(private = "file")
open_listeners :: proc() -> (socks: [len(TUYA_UDP_PORTS)]posix.FD, ok: bool) {
	for port, i in TUYA_UDP_PORTS {
		if socks[i] = udp_socket(port); socks[i] < 0 {
			for j in 0 ..< i {posix.close(socks[j])}
			return socks, false
		}
	}
	return socks, true
}

sensors_configured :: proc() -> bool {return len(sensor_defs) > 0}

sensors_start :: proc() {
	if config.sensors_watch != "" {
		log.info("[sensors] watch is no longer used (wlperch reads the devices itself); ignored")
	}
	if !sensors_configured() {return}
	load_history()
	state_load()
	{
		sync.guard(&sensors.mu)
		rebuild()
	}
	thread.create_and_start(sensors_listen)
}

// `wlperch sensors scan [seconds]` / `wlperch sensors read <name|id>`: find
// devices on the LAN, or query one once. Read-only, prints no keys, and
// doesn't touch the daemon's state file.
sensors_cli :: proc(args: []string) -> int {
	sensors_read_only = true
	sub := len(args) > 0 ? args[0] : "scan"
	socks, ok := open_listeners()
	if !ok {
		fmt.eprintfln("cannot listen on UDP %v", TUYA_UDP_PORTS)
		return 1
	}
	probe := udp_socket(0)
	switch sub {
	case "scan":
		secs := len(args) > 1 ? strconv.parse_int(args[1]) or_else 20 : 20
		fmt.printfln("listening %d s for Tuya devices (battery sensors only announce when they wake)…", secs)
		seen: map[string]bool
		end := time.tick_add(time.tick_now(), time.Duration(secs) * time.Second)
		for time.tick_diff(time.tick_now(), end) > 0 {
			send_probe(probe)
			until := min(time.tick_diff(time.tick_now(), end), PROBE_EVERY)
			stop := time.tick_add(time.tick_now(), until)
			for time.tick_diff(time.tick_now(), stop) > 0 {
				for a in receive_announcements(socks[:], time.tick_diff(time.tick_now(), stop)) {
					if a.id in seen {continue}
					seen[strings.clone(a.id)] = true
					def := def_find(a.id)
					what := def == nil ? "not configured" : def.key == "" ? fmt.tprintf("%s (no key)", def.name) : def.name
					fmt.printfln("%s  %-15s  v%-4s  %s", a.id, a.ip, a.version, what)
				}
			}
			free_all(context.temp_allocator)
		}
		if len(seen) == 0 {fmt.println("no devices heard")}
		return 0
	case "read":
		if len(args) < 2 {
			fmt.eprintln("usage: wlperch sensors read <name|id>")
			return 2
		}
		def: ^Sensor_Def
		for &d in sensor_defs {
			if d.id == args[1] || strings.equal_fold(d.name, args[1]) {def = &d}
		}
		if def == nil || def.key == "" {
			fmt.eprintfln("%s: not a configured device with a key", args[1])
			return 1
		}
		ip, version := def.ip, def.version
		if ip == "" || version == "" {
			fmt.printfln("waiting up to 60 s for %s to announce itself…", def.name)
			end := time.tick_add(time.tick_now(), 60 * time.Second)
			wait: for time.tick_diff(time.tick_now(), end) > 0 {
				send_probe(probe)
				for a in receive_announcements(socks[:], PROBE_EVERY) {
					if a.id != def.id {continue}
					if ip == "" {ip = strings.clone(a.ip)}
					if version == "" {version = strings.clone(a.version)}
					break wait
				}
			}
			if ip == "" {
				fmt.eprintfln("%s did not announce itself (asleep?)", def.name)
				return 1
			}
		}
		v, _ := tuya_version(version)
		text, err := tuya_read_status(ip, def.id, transmute([]byte)def.key, v)
		if err != "" {
			fmt.eprintfln("%s (%s, v%s): %s", def.name, ip, version, err)
			return 1
		}
		reply, _ := jparse(text)
		dps := jobj(reply, "dps")
		if dps == nil {dps = jobj(jobj(reply, "data"), "dps")}
		obj, _ := dps.(json.Object)
		fmt.printfln("%s (%s, v%s): %d data points", def.name, ip, version, len(obj))
		keys := make([dynamic]string, context.temp_allocator)
		for k in obj {append(&keys, k)}
		slice.sort_by(keys[:], proc(a, b: string) -> bool {return (strconv.parse_int(a) or_else 0) < (strconv.parse_int(b) or_else 0)})
		for k in keys {
			raw, _ := json.marshal(obj[k], allocator = context.temp_allocator)
			x := sensor_decode(def, k, {raw = string(raw)})
			value := x.is_num ? fmt.tprintf("%v", x.num) : x.text
			fmt.printfln("  %3s  %-22s %s%s", k, x.code, value, x.unit)
		}
		return 0
	}
	fmt.eprintln("usage: wlperch sensors [scan [seconds] | read <name|id>]")
	return 2
}

// "4m", "2h", "3d"
age_text :: proc(t: f64) -> string {
	if t <= 0 {return "—"}
	s := f64(time.to_unix_seconds(time.now())) - t
	switch {
	case s < 60:    return "now"
	case s < 3600:  return fmt.tprintf("%.0fm", s / 60)
	case s < 86400: return fmt.tprintf("%.0fh", s / 3600)
	}
	return fmt.tprintf("%.0fd", s / 86400)
}
