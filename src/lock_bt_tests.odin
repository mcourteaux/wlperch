// Lock screen Bluetooth row: BlueZ objects (from a fake busctl) through the
// daemon's "lockinfo" lines to what the lock parses.
package main

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
BT_FIXTURE :: `{"type":"a{oa{sa{sv}}}","data":[{` +
	`"/org/bluez/hci0":{"org.bluez.Adapter1":{"Powered":{"type":"b","data":%s}}},` +
	`"/org/bluez/hci0/dev_1":{"org.bluez.Device1":{"Address":{"type":"s","data":"AA:BB:CC:DD:EE:01"},"Alias":{"type":"s","data":"MX Master 3"},"Icon":{"type":"s","data":"input-mouse"},"Paired":{"type":"b","data":true},"Connected":{"type":"b","data":true}},"org.bluez.Battery1":{"Percentage":{"type":"y","data":15}}},` +
	`"/org/bluez/hci0/dev_2":{"org.bluez.Device1":{"Address":{"type":"s","data":"AA:BB:CC:DD:EE:02"},"Alias":{"type":"s","data":"Keychron K2"},"Icon":{"type":"s","data":"input-keyboard"},"Paired":{"type":"b","data":true},"Connected":{"type":"b","data":true}}},` +
	`"/org/bluez/hci0/dev_3":{"org.bluez.Device1":{"Address":{"type":"s","data":"AA:BB:CC:DD:EE:03"},"Alias":{"type":"s","data":"A Very Long Headphone Name That Goes On And On Forever"},"Icon":{"type":"s","data":"audio-headset"},"Paired":{"type":"b","data":true},"Connected":{"type":"b","data":true}},"org.bluez.Battery1":{"Percentage":{"type":"y","data":80}}},` +
	`"/org/bluez/hci0/dev_4":{"org.bluez.Device1":{"Address":{"type":"s","data":"AA:BB:CC:DD:EE:04"},"Alias":{"type":"s","data":"Old Phone"},"Icon":{"type":"s","data":"phone"},"Paired":{"type":"b","data":true},"Connected":{"type":"b","data":false}}}` +
	`}]}`

@(private = "file")
bt_lockinfo :: proc(t: ^testing.T, powered: string) -> []Lock_BT {
	dir :: "/tmp/wlperch-test/lockbt"
	os.make_directory_all(dir)
	json, _ := strings.replace_all(BT_FIXTURE, "%s", powered, context.temp_allocator)
	testing.expect(t, os.write_entire_file(dir + "/objects.json", json) == nil)
	script := "#!/bin/sh\ncase \"$*\" in *GetManagedObjects*) cat " + dir + "/objects.json ;; *) exit 1 ;; esac\n"
	testing.expect(t, os.write_entire_file(dir + "/busctl", script, os.Permissions_Default_File + {.Execute_User}) == nil)
	old := os.get_env("PATH", context.temp_allocator)
	os.set_env("PATH", strings.concatenate({dir, ":", old}, context.temp_allocator))
	defer os.set_env("PATH", old)
	bluetooth_refresh_now()

	out: [dynamic]Lock_BT
	out.allocator = context.temp_allocator
	for line in strings.split_lines(lock_info_reply(), context.temp_allocator) {
		k, _, v := strings.partition(line, " ")
		if k != "bt" {continue}
		d, ok := lock_bt_parse(v)
		testing.expect(t, ok, line)
		append(&out, d)
	}
	return out[:]
}

@(test)
test_lock_bluetooth_lines :: proc(t: ^testing.T) {
	devs := bt_lockinfo(t, "true")
	// Connected only (not "Old Phone"), sorted by name; no addresses.
	testing.expect_value(t, len(devs), 3)
	if len(devs) != 3 {return}
	testing.expect_value(t, devs[0].name, "A Very Long Headphone Name That Goes On And On F")
	testing.expect_value(t, devs[0].battery, 80)
	testing.expect_value(t, devs[0].icon, "audio-headset")
	testing.expect_value(t, devs[1].name, "Keychron K2")
	testing.expect_value(t, devs[1].battery, -1)
	testing.expect_value(t, devs[2].name, "MX Master 3")
	testing.expect_value(t, devs[2].battery, 15)
	testing.expect_value(t, devs[2].charging, false)
	testing.expect(t, !strings.contains(lock_info_reply(), "AA:BB"), "addresses must not reach the lock")

	// Bluetooth off: no lines at all.
	testing.expect_value(t, len(bt_lockinfo(t, "false")), 0)
}

@(test)
test_lock_bluetooth_parse :: proc(t: ^testing.T) {
	d, ok := lock_bt_parse("-1 0 - ")
	testing.expect(t, ok)
	testing.expect_value(t, d.battery, -1)
	testing.expect_value(t, d.icon, "")
	testing.expect_value(t, d.name, "Bluetooth device")
	d, ok = lock_bt_parse("42 1 input-mouse  My  Mouse ")
	testing.expect_value(t, d.battery, 42)
	testing.expect(t, d.charging)
	testing.expect_value(t, d.name, "My  Mouse")
	_, ok = lock_bt_parse("garbage")
	testing.expect(t, !ok)
}
