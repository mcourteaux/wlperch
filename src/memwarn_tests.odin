// Unit tests for the low-memory warning (memwarn.odin) and the bar's memory
// module states. No process is ever signalled here.
package main

import "core:os"
import "core:testing"

@(test)
test_memwarn_hysteresis :: proc(t: ^testing.T) {
	low := false
	// Above the threshold: nothing.
	low = memwarn_step(low, 40, 15); testing.expect(t, !low)
	low = memwarn_step(low, 15, 15); testing.expect(t, !low) // not below
	// Drops below: fires.
	low = memwarn_step(low, 14.9, 15); testing.expect(t, low)
	// Recovers a little: stays low (no flapping around the threshold).
	low = memwarn_step(low, 16, 15); testing.expect(t, low)
	low = memwarn_step(low, 14, 15); testing.expect(t, low)
	low = memwarn_step(low, 19.9, 15); testing.expect(t, low)
	// threshold + MEMWARN_HYST: re-armed.
	low = memwarn_step(low, 15 + MEMWARN_HYST, 15); testing.expect(t, !low)
	// And fires again next time.
	low = memwarn_step(low, 10, 15); testing.expect(t, low)
	// 0 = off, whatever the memory.
	testing.expect(t, !memwarn_step(false, 1, 0))
	testing.expect(t, !memwarn_step(true, 1, 0))
}

@(test)
test_memwarn_sample_episodes :: proc(t: ^testing.T) {
	saved_cfg := config.memory_free_warn_pct
	saved := memwarn
	defer {
		config.memory_free_warn_pct = saved_cfg
		memwarn = saved
	}
	config.memory_free_warn_pct = 15
	memwarn = {}
	// Not low: no offender scan, no episode. (memwarn_sample wakes the main
	// loop only when low, and the test never goes low through it.)
	memwarn_sample(50, 100)
	testing.expect(t, !memwarn.low)
	testing.expect_value(t, memwarn.episode, 0)
	testing.expect_value(t, memwarn.avail, u64(50))
	// The saved / restored state across re-execs.
	memwarn.low, memwarn.episode, memwarn.dismissed = true, 3, 3
	low, dismissed := memwarn_saved()
	testing.expect(t, low && dismissed)
	memwarn.dismissed = 2
	low, dismissed = memwarn_saved()
	testing.expect(t, low && !dismissed)
	memwarn = {}
	memwarn_restore(true, true)
	testing.expect(t, memwarn.low && memwarn.dismissed == memwarn.episode)
}

@(test)
test_memwarn_protected :: proc(t: ^testing.T) {
	me := i32(4242)
	testing.expect(t, memwarn_protected({pid = 1, name = "systemd"}, me))
	testing.expect(t, memwarn_protected({pid = 1, name = "anything"}, me))
	testing.expect(t, memwarn_protected({pid = 777, name = "foo"}, 777)) // ourselves
	testing.expect(t, memwarn_protected({pid = 900, name = "sway", comm = "sway"}, me))
	testing.expect(t, memwarn_protected({pid = 901, name = "wlperch", comm = "wlperch-bar"}, me))
	testing.expect(t, memwarn_protected({pid = 902, name = "systemd", comm = "systemd"}, me)) // user manager
	testing.expect(t, memwarn_protected({pid = 903, name = "Xwayland"}, me))
	testing.expect(t, !memwarn_protected({pid = 904, name = "firefox", comm = "Isolated Web Co"}, me))
	testing.expect(t, !memwarn_protected({pid = 905, name = "sleep"}, me))
}

@(test)
test_memwarn_grouping :: proc(t: ^testing.T) {
	MiB :: u64(1 << 20)
	UID :: u32(1000)
	ME :: i32(50)
	ps := []Mw_Proc {
		{pid = 1, uid = 0, rss = 900 * MiB, name = "systemd"},       // root: left out
		{pid = 10, uid = 0, rss = 5000 * MiB, name = "postgres"},    // other user: left out
		{pid = 11, uid = 1001, rss = 4000 * MiB, name = "java"},     // other user: left out
		{pid = 20, uid = UID, rss = 3000 * MiB, name = "sway"},      // protected, ranks first
		{pid = 30, uid = UID, rss = 500 * MiB, name = "firefox"},
		{pid = 31, uid = UID, rss = 700 * MiB, name = "firefox"},
		{pid = 32, uid = UID, rss = 900 * MiB, name = "firefox"},    // firefox ×3 = 2100
		{pid = 40, uid = UID, rss = 1800 * MiB, name = "code"},
		{pid = 41, uid = UID, rss = 100 * MiB, name = "code"},       // code ×2 = 1900
		{pid = ME, uid = UID, rss = 1500 * MiB, name = "foo"},       // ourselves: protected
		{pid = 60, uid = UID, rss = 300 * MiB, name = "sleep"},
		{pid = 61, uid = UID, rss = 200 * MiB, name = "a"},
		{pid = 62, uid = UID, rss = 150 * MiB, name = "b"},
		{pid = 63, uid = UID, rss = 100 * MiB, name = "c"},          // 6th killable: cut
		{pid = 64, uid = UID, rss = 0, name = "kthread"},            // no memory: left out
		{pid = 65, uid = UID, rss = 50 * MiB, name = "wlperch"},     // protected, below the cut
	}
	out: [MEMWARN_ROWS]Mw_Group
	n := memwarn_group(ps, UID, ME, out[:])
	names := [?]string{"sway", "firefox", "code", "foo", "sleep", "a", "b"}
	testing.expect_value(t, n, len(names))
	for want, i in names {
		if i < n {testing.expect_value(t, mw_group_name(&out[i]), want)}
	}
	testing.expect(t, out[0].protected) // sway
	testing.expect(t, out[3].protected) // ourselves
	killable := 0
	for &g in out[:n] {
		if !g.protected {killable += 1}
		// Nothing of another user, never PID 1.
		for pid in g.pids[:g.npids] {testing.expect(t, pid != 1 && pid != 10 && pid != 11)}
	}
	testing.expect_value(t, killable, MEMWARN_TOP)
	// The group signals every PID it stands for.
	ff := &out[1]
	testing.expect_value(t, ff.count, 3)
	testing.expect_value(t, ff.npids, 3)
	testing.expect_value(t, ff.rss, 2100 * MiB)
	testing.expect(t, ff.pids[0] == 30 && ff.pids[1] == 31 && ff.pids[2] == 32)
	testing.expect_value(t, out[2].count, 2)

	// Protected groups after the last killable one are dropped; a row cap holds.
	small := []Mw_Proc {
		{pid = 70, uid = UID, rss = 900 * MiB, name = "sleep"},
		{pid = 71, uid = UID, rss = 100 * MiB, name = "sway"},
	}
	n = memwarn_group(small, UID, ME, out[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, mw_group_name(&out[0]), "sleep")
	two: [2]Mw_Group
	testing.expect_value(t, memwarn_group(ps, UID, ME, two[:]), 2)
	testing.expect_value(t, memwarn_group(nil, UID, ME, out[:]), 0)
}

@(test)
test_bar_mem_level :: proc(t: ^testing.T) {
	testing.expect_value(t, bar_mem_level(50, 100, 75, 90), Bar_Mem_State.Normal)
	testing.expect_value(t, bar_mem_level(74, 100, 75, 90), Bar_Mem_State.Normal)
	testing.expect_value(t, bar_mem_level(75, 100, 75, 90), Bar_Mem_State.Warn)
	testing.expect_value(t, bar_mem_level(89, 100, 75, 90), Bar_Mem_State.Warn)
	testing.expect_value(t, bar_mem_level(90, 100, 75, 90), Bar_Mem_State.Critical)
	testing.expect_value(t, bar_mem_level(10, 0, 75, 90), Bar_Mem_State.Normal)
	p := bar_mem_pulse()
	testing.expect(t, p >= 0 && p <= 1)
}

// A config from before [memory] existed (the old key in [system]) loads, and
// the old key still sets the critical level. (Chained lookups on a missing
// section used to crash config_load.)
@(test)
test_config_memory_section :: proc(t: ^testing.T) {
	DIR :: "/tmp/wlperch-test-config-memory"
	dir := DIR
	os.make_directory_all(DIR + "/wlperch")
	defer os.remove_all(dir)
	old_xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	defer os.set_env("XDG_CONFIG_HOME", old_xdg)
	os.set_env("XDG_CONFIG_HOME", dir)
	saved := config
	defer config = saved

	_ = os.write_entire_file(DIR + "/wlperch/config.ini", "[popup]\nwidth = 860\n\n[system]\nhistory_seconds = 120\nmemory_warn_percent = 70\n")
	config_load()
	testing.expect_value(t, config.memory_warn_pct, 70)
	testing.expect_value(t, config.memory_free_warn_pct, 15)
	testing.expect_value(t, config.memory_bar_warn_pct, 75)

	_ = os.write_entire_file(DIR + "/wlperch/config.ini", "[popup]\nwidth = 860\n")
	config_load()
	testing.expect_value(t, config.memory_warn_pct, 90)

	_ = os.write_entire_file(DIR + "/wlperch/config.ini", "[system]\nmemory_warn_percent = 70\n\n[memory]\nwarn_free_percent = 10\nbar_warn_percent = 60\ncritical_percent = 85\n")
	config_load()
	testing.expect_value(t, config.memory_warn_pct, 85)
	testing.expect_value(t, config.memory_free_warn_pct, 10)
	testing.expect_value(t, config.memory_bar_warn_pct, 60)
}
