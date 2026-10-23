// Tuya sensors via the tuya-sensors PoC: its watcher (`tuya_sensors.py --watch`)
// catches the battery sensors' short wake-ups and keeps state.json current; we
// read names/units from devices.json (never the keys) and values from state.json.
package main

import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
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
	watching: bool,
}
sensors: Sensors

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

// "MT15/MT29 bedroom " -> "Bedroom", "Keuken SRW-TH03" -> "Keuken", "Your Eurom Heater" -> "Eurom Heater"
@(private = "file")
clean_name :: proc(name, product: string) -> string {
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

sensors_reload :: proc() {reload()}

@(private = "file")
reload :: proc() {
	dir := config.sensors_dir
	devs_s, err1 := os.read_entire_file(strings.concatenate({dir, "/devices.json"}, context.temp_allocator), context.temp_allocator)
	state_s, err2 := os.read_entire_file(strings.concatenate({dir, "/state.json"}, context.temp_allocator), context.temp_allocator)
	if err1 != nil {
		sync.guard(&sensors.mu)
		sensors.ok = false
		delete(sensors.error)
		sensors.error = strings.clone(fmt.tprintf("No devices.json in %s", dir))
		return
	}
	devs, _ := jparse(string(devs_s))
	state: json.Value
	if err2 == nil {state, _ = jparse(string(state_s))}

	sync.guard(&sensors.mu)
	for &d in sensors.devices {delete(d.values)}
	clear(&sensors.devices)
	for s in strs {delete(s)}
	clear(&strs)

	for d in jarr(devs) {
		id := jstr(jobj(d, "id"))
		product := jstr(jobj(d, "product_name"))
		dev := Sensor_Device {
			id   = own(id),
			name = own(clean_name(jstr(jobj(d, "name")), product)),
		}
		switch jstr(jobj(d, "category")) {
		case "wsdcg": dev.kind = .Climate
		case "hjjcy", "co2bj", "pm25": dev.kind = .Air
		case "qn", "rs": dev.kind = .Heater
		}
		mapping := jobj(d, "mapping")
		dps, _ := jobj(state, id).(json.Object)
		for dp, entry in dps {
			m := jobj(mapping, dp)
			code := jstr(jobj(m, "code"), fmt.tprintf("dp%s", dp))
			values := jobj(m, "values")
			if s, is_str := values.(json.String); is_str {values, _ = jparse(s)}
			unit := jstr(jobj(values, "unit"))
			scale := jint(jobj(values, "scale"))
			raw := jobj(entry, "v")
			v := Sensor_Value{code = own(code), unit = own(unit), t = jfloat(jobj(entry, "t"))}
			#partial switch x in raw {
			case json.Integer, json.Float:
				v.is_num = true
				v.num = jfloat(raw)
				for _ in 0 ..< scale {v.num /= 10}
			case json.String:
				v.text = own(x)
			case json.Boolean:
				v.text = x ? "on" : "off"
			}
			dev.last_t = max(dev.last_t, v.t)
			append(&dev.values, v)
		}
		append(&sensors.devices, dev)
	}
	// Rooms first (alphabetical), then air quality, heaters, others.
	for i in 1 ..< len(sensors.devices) {
		for j := i; j > 0; j -= 1 {
			a, b := sensors.devices[j - 1], sensors.devices[j]
			if int(b.kind == .Climate ? 0 : b.kind == .Air ? 1 : b.kind == .Heater ? 2 : 3) < int(a.kind == .Climate ? 0 : a.kind == .Air ? 1 : a.kind == .Heater ? 2 : 3) || (a.kind == b.kind && b.name < a.name) {
				sensors.devices[j - 1], sensors.devices[j] = b, a
			} else {
				break
			}
		}
	}
	sensors.ok = true
	if !sensors_read_only {record_history()}
}

@(private = "file")
mtime :: proc(path: string) -> i64 {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {return 0}
	return time.to_unix_nanoseconds(fi.modification_time)
}

SENSOR_HISTORY_DAYS :: 7

// Set by `wlwidgets status sensors`: only the daemon writes the history file.
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

sensors_start :: proc() {
	if config.sensors_dir == "" || !os.exists(config.sensors_dir) {return}
	load_history()
	reload()
	// Reload whenever the watcher rewrites state.json.
	thread.create_and_start(proc() {
		path := strings.concatenate({config.sensors_dir, "/state.json"})
		last := mtime(path)
		last_trim := time.tick_now()
		for {
			time.sleep(3 * time.Second)
			if m := mtime(path); m != last {
				last = m
				reload()
				wake_ui()
			}
			// Age out old samples even when no new readings arrive.
			if !sensors_read_only && time.tick_since(last_trim) > time.Hour {
				last_trim = time.tick_now()
				sync.guard(&sensors.mu)
				if history_trim(&sensors.history, history_cutoff()) {save_history()}
			}
			free_all(context.temp_allocator)
		}
	})
	// Optionally keep the watcher running (restarted if it exits).
	if config.sensors_watch != "" {
		thread.create_and_start(proc() {
			cmd := fmt.aprintf("cd '%s' && exec %s", config.sensors_dir, config.sensors_watch)
			for {
				s, ok := stream_start({"sh", "-c", cmd})
				if !ok {
					time.sleep(30 * time.Second)
					continue
				}
				sensors.watching = true
				for {
					_, lok := stream_read_line(&s)
					if !lok {break}
					free_all(context.temp_allocator)
				}
				sensors.watching = false
				stream_stop(&s)
				log.warn("sensor watcher exited; restarting in 30 s")
				time.sleep(30 * time.Second)
			}
		})
	}
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

_ :: strconv
