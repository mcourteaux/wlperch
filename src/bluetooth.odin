// Bluetooth devices from BlueZ (via busctl JSON), batteries from
// org.bluez.Battery1 with UPower as a fallback / for charging state.
package main

import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

BT_Device :: struct {
	path:      string,
	address:   string,
	name:      string,
	icon:      string, // freedesktop icon name from BlueZ
	connected: bool,
	paired:    bool,
	battery:   int, // -1 = unknown
	charging:  bool,
}

Bluetooth :: struct {
	mu:        sync.Mutex,
	ok:        bool,
	powered:   bool,
	adapter:   bool, // at least one Bluetooth adapter present
	devices:   [dynamic]BT_Device,
	busy:      string, // address of a device being (dis)connected
}
bluetooth: Bluetooth

@(private = "file")
trigger: sync.Sema

bt_icon :: proc(icon: string) -> string {
	switch {
	case strings.contains(icon, "headset"):    return ICON_HEADSET
	case strings.contains(icon, "headphone"):  return ICON_HEADPHONES
	case strings.contains(icon, "audio"):      return ICON_SPEAKER
	case strings.contains(icon, "keyboard"):   return ICON_KEYBOARD
	case strings.contains(icon, "mouse"):      return ICON_MOUSE
	case strings.contains(icon, "gaming"):     return ICON_GAMEPAD
	case strings.contains(icon, "phone"):      return "\U000F03F2"
	case strings.contains(icon, "computer"):   return ICON_DESKTOP
	}
	return ICON_BLUETOOTH
}

@(private = "file")
dbus_data :: proc(v: json.Value) -> json.Value {
	return jobj(v, "data")
}

@(private = "file")
UPower_Battery :: struct {
	serial:   string,
	model:    string,
	percent:  int,
	charging: bool,
}

@(private = "file")
upower_batteries :: proc() -> [dynamic]UPower_Battery {
	out: [dynamic]UPower_Battery
	out.allocator = context.temp_allocator
	list, ok := run({"busctl", "--system", "--json=short", "call", "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.UPower", "EnumerateDevices"}, 3 * time.Second, context.temp_allocator)
	if !ok {return out}
	v, _ := jparse(list)
	paths := jarr(jidx(jobj(v, "data"), 0))
	for p in paths {
		path := jstr(p)
		if strings.contains(path, "DisplayDevice") || strings.contains(path, "line_power") {continue}
		props_s, pok := run({"busctl", "--system", "--json=short", "call", "org.freedesktop.UPower", path, "org.freedesktop.DBus.Properties", "GetAll", "s", "org.freedesktop.UPower.Device"}, 3 * time.Second, context.temp_allocator)
		if !pok {continue}
		pv, _ := jparse(props_s)
		data := jarr(jobj(pv, "data"))
		if len(data) == 0 {continue}
		props := data[0]
		if !jbool(dbus_data(jobj(props, "IsPresent")), true) {continue}
		state := jint(dbus_data(jobj(props, "State"))) // 1 charging, 4 fully charged
		append(&out, UPower_Battery {
			serial   = strings.to_lower(jstr(dbus_data(jobj(props, "Serial"))), context.temp_allocator),
			model    = jstr(dbus_data(jobj(props, "Model"))),
			percent  = int(jfloat(dbus_data(jobj(props, "Percentage")))),
			charging = state == 1,
		})
	}
	return out
}

bluetooth_refresh_now :: proc() {
	out, ok := run({"busctl", "--system", "--json=short", "call", "org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects"}, 3 * time.Second, context.temp_allocator)
	if !ok {
		sync.guard(&bluetooth.mu)
		bluetooth.ok = false
		return
	}
	v, _ := jparse(out)
	objs := jarr(jobj(v, "data"))
	batteries := upower_batteries()

	sync.guard(&bluetooth.mu)
	for d in bluetooth.devices {
		delete(d.path); delete(d.address); delete(d.name); delete(d.icon)
	}
	clear(&bluetooth.devices)
	bluetooth.powered = false
	bluetooth.adapter = false
	if len(objs) == 0 {return}
	root, _ := objs[0].(json.Object)
	for path, ifaces in root {
		if adapter := jobj(ifaces, "org.bluez.Adapter1"); adapter != nil {
			bluetooth.adapter = true
			if jbool(dbus_data(jobj(adapter, "Powered"))) {bluetooth.powered = true}
		}
		dev := jobj(ifaces, "org.bluez.Device1")
		if dev == nil {continue}
		paired := jbool(dbus_data(jobj(dev, "Paired")))
		connected := jbool(dbus_data(jobj(dev, "Connected")))
		if !paired && !connected {continue}
		name := jstr(dbus_data(jobj(dev, "Alias")))
		if name == "" {name = jstr(dbus_data(jobj(dev, "Name")))}
		addr := jstr(dbus_data(jobj(dev, "Address")))
		d := BT_Device {
			path      = strings.clone(path),
			address   = strings.clone(addr),
			name      = strings.clone(name),
			icon      = strings.clone(jstr(dbus_data(jobj(dev, "Icon")))),
			connected = connected,
			paired    = paired,
			battery   = -1,
		}
		if bat := jobj(ifaces, "org.bluez.Battery1"); bat != nil {
			d.battery = int(jint(dbus_data(jobj(bat, "Percentage")), -1))
		}
		lower := strings.to_lower(addr, context.temp_allocator)
		for b in batteries {
			if b.serial == lower || (b.model != "" && b.model == name) {
				if d.battery < 0 {d.battery = b.percent}
				d.charging = b.charging
			}
		}
		append(&bluetooth.devices, d)
	}
	// Connected first, then by name.
	for i in 1 ..< len(bluetooth.devices) {
		for j := i; j > 0; j -= 1 {
			a, b := bluetooth.devices[j - 1], bluetooth.devices[j]
			if (b.connected && !a.connected) || (a.connected == b.connected && b.name < a.name) {
				bluetooth.devices[j - 1], bluetooth.devices[j] = b, a
			} else {
				break
			}
		}
	}
	bluetooth.ok = true
}

bluetooth_refresh_async :: proc() {
	sync.sema_post(&trigger)
}

bluetooth_toggle_connection :: proc(address: string, connect: bool) {
	{
		sync.guard(&bluetooth.mu)
		delete(bluetooth.busy)
		bluetooth.busy = strings.clone(address)
	}
	run_async({"bluetoothctl", "--timeout", "15", connect ? "connect" : "disconnect", address}, proc() {
		{
			sync.guard(&bluetooth.mu)
			delete(bluetooth.busy)
			bluetooth.busy = ""
		}
		bluetooth_refresh_async()
	}, 20 * time.Second)
}

bluetooth_start :: proc() {
	thread.create_and_start(proc() {
		for {
			bluetooth_refresh_now()
			wake_ui()
			free_all(context.temp_allocator)
			// Poll while visible (batteries/connections change), rarely otherwise.
			wait := plat_visible_flag ? 5 * time.Second : 60 * time.Second
			sync.sema_wait_with_timeout(&trigger, wait)
			for sync.sema_wait_with_timeout(&trigger, 0) {}
		}
	})
}
