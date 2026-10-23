// Tuya sensors via the tuya-sensors PoC: its watcher (`tuya_sensors.py --watch`)
// catches the battery sensors' short wake-ups and keeps state.json current; we
// read names/units from devices.json (never the keys) and values from state.json.
package main

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

Sensors :: struct {
	mu:       sync.Mutex,
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
}

@(private = "file")
mtime :: proc(path: string) -> i64 {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {return 0}
	return time.to_unix_nanoseconds(fi.modification_time)
}

sensors_start :: proc() {
	if config.sensors_dir == "" || !os.exists(config.sensors_dir) {return}
	reload()
	// Reload whenever the watcher rewrites state.json.
	thread.create_and_start(proc() {
		path := strings.concatenate({config.sensors_dir, "/state.json"})
		last := mtime(path)
		for {
			time.sleep(3 * time.Second)
			if m := mtime(path); m != last {
				last = m
				reload()
				wake_ui()
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
