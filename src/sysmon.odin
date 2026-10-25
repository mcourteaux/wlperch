// CPU / GPU / memory sampling at 1 Hz. Runs even while the popup is hidden so
// the history graphs are populated the moment the popup opens.
package main

import "core:dynlib"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

MAX_CORES :: 256

// History, history_push, …: perf_history.odin

Sysmon :: struct {
	mu:          sync.Mutex,
	cpu:         History,
	cpu_now:     f32,
	cores:       [MAX_CORES]f32,
	core_count:  int,
	cpu_name:    string,
	cpu_temp:    f32,

	gpu_ok:      bool,
	gpu:         History,
	gpu_now:     f32,
	gpu_name:    string,
	vram_used:   u64,
	vram_total:  u64,
	gpu_temp:    f32,
	gpu_power:   f32, // watts

	mem_used:    u64,
	mem_total:   u64,
	mem_cached:  u64, // page cache + reclaimable slab
	swap_used:   u64,
	swap_total:  u64,
	mem:         History, // memory in use, MiB
	swap:        History, // swap in use, MiB
	vram:        History, // VRAM in use, MiB
	load:        [3]f32,  // 1/5/15 min load average
	uptime:      f64,     // seconds
}
sysmon: Sysmon

sysmon_lock :: proc() {sync.mutex_lock(&sysmon.mu)}
sysmon_unlock :: proc() {sync.mutex_unlock(&sysmon.mu)}

// ---- NVML ------------------------------------------------------------------

@(private = "file")
Nvml_Device :: distinct rawptr
@(private = "file")
Nvml_Util :: struct {
	gpu, memory: u32,
}
@(private = "file")
Nvml_Mem :: struct {
	total, free, used: u64,
}

@(private = "file")
Nvml :: struct {
	lib:              dynlib.Library,
	init:             proc "c" () -> i32,
	get_handle:       proc "c" (index: u32, dev: ^Nvml_Device) -> i32,
	get_utilization:  proc "c" (dev: Nvml_Device, util: ^Nvml_Util) -> i32,
	get_memory:       proc "c" (dev: Nvml_Device, mem: ^Nvml_Mem) -> i32,
	get_temperature:  proc "c" (dev: Nvml_Device, sensor: u32, temp: ^u32) -> i32,
	get_power:        proc "c" (dev: Nvml_Device, mw: ^u32) -> i32,
	get_name:         proc "c" (dev: Nvml_Device, name: [^]u8, len: u32) -> i32,
	dev:              Nvml_Device,
}

@(private = "file")
nvml: Nvml

@(private = "file")
nvml_open :: proc() -> bool {
	lib, ok := dynlib.load_library("libnvidia-ml.so.1")
	if !ok {return false}
	nvml.lib = lib
	sym :: proc(name: string) -> rawptr {
		p, _ := dynlib.symbol_address(nvml.lib, name)
		return p
	}
	nvml.init = auto_cast sym("nvmlInit_v2")
	nvml.get_handle = auto_cast sym("nvmlDeviceGetHandleByIndex_v2")
	nvml.get_utilization = auto_cast sym("nvmlDeviceGetUtilizationRates")
	nvml.get_memory = auto_cast sym("nvmlDeviceGetMemoryInfo")
	nvml.get_temperature = auto_cast sym("nvmlDeviceGetTemperature")
	nvml.get_power = auto_cast sym("nvmlDeviceGetPowerUsage")
	nvml.get_name = auto_cast sym("nvmlDeviceGetName")
	if nvml.init == nil || nvml.get_handle == nil || nvml.get_utilization == nil {return false}
	if nvml.init() != 0 {return false}
	if nvml.get_handle(0, &nvml.dev) != 0 {return false}
	if nvml.get_name != nil {
		buf: [96]u8
		if nvml.get_name(nvml.dev, &buf[0], len(buf)) == 0 {
			sysmon.gpu_name = strings.clone(strings.trim_right_null(string(buf[:])))
		}
	}
	return true
}

@(private = "file")
nvml_sample :: proc() -> bool {
	u: Nvml_Util
	if nvml.get_utilization(nvml.dev, &u) != 0 {return false}
	m: Nvml_Mem
	temp, power: u32
	if nvml.get_memory != nil {nvml.get_memory(nvml.dev, &m)}
	if nvml.get_temperature != nil {nvml.get_temperature(nvml.dev, 0, &temp)}
	if nvml.get_power != nil {nvml.get_power(nvml.dev, &power)}
	sync.guard(&sysmon.mu)
	sysmon.gpu_now = f32(u.gpu)
	history_push(&sysmon.gpu, f32(u.gpu))
	sysmon.vram_used, sysmon.vram_total = m.used, m.total
	if m.total > 0 {history_push(&sysmon.vram, f32(f64(m.used) / PERF_MIB))}
	sysmon.gpu_temp = f32(temp)
	sysmon.gpu_power = f32(power) / 1000
	return true
}

// ---- AMD / generic DRM fallback ----------------------------------------------

@(private = "file")
drm_dev: string

@(private = "file")
read_trim :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return ""}
	return strings.trim_space(string(data))
}

@(private = "file")
drm_open :: proc() -> bool {
	for i in 0 ..< 8 {
		dev := strings.concatenate({"/sys/class/drm/card", int_to_string(i), "/device"})
		if os.exists(strings.concatenate({dev, "/gpu_busy_percent"}, context.temp_allocator)) {
			drm_dev = dev
			sysmon.gpu_name = "GPU"
			return true
		}
		delete(dev)
	}
	return false
}

@(private = "file")
drm_sample :: proc() -> bool {
	busy, ok := strconv.parse_f64(read_trim(strings.concatenate({drm_dev, "/gpu_busy_percent"}, context.temp_allocator)))
	if !ok {return false}
	used, _ := strconv.parse_u64(read_trim(strings.concatenate({drm_dev, "/mem_info_vram_used"}, context.temp_allocator)))
	total, _ := strconv.parse_u64(read_trim(strings.concatenate({drm_dev, "/mem_info_vram_total"}, context.temp_allocator)))
	sync.guard(&sysmon.mu)
	sysmon.gpu_now = f32(busy)
	history_push(&sysmon.gpu, f32(busy))
	sysmon.vram_used, sysmon.vram_total = used, total
	if total > 0 {history_push(&sysmon.vram, f32(f64(used) / PERF_MIB))}
	return true
}

// ---- CPU ---------------------------------------------------------------------

@(private = "file")
prev_cpu: [MAX_CORES + 1]Cpu_Jiffies
@(private = "file")
first_cpu_sample := true

@(private = "file")
cpu_temp_path: string

@(private = "file")
find_cpu_temp :: proc() {
	// k10temp (AMD) / coretemp (Intel): temp1_input of the matching hwmon.
	for i in 0 ..< 16 {
		base := strings.concatenate({"/sys/class/hwmon/hwmon", int_to_string(i)}, context.temp_allocator)
		name := read_trim(strings.concatenate({base, "/name"}, context.temp_allocator))
		if name == "k10temp" || name == "coretemp" || name == "zenpower" {
			cpu_temp_path = strings.concatenate({base, "/temp1_input"})
			return
		}
	}
}

@(private = "file")
cpu_sample :: proc() {
	data, err := os.read_entire_file("/proc/stat", context.temp_allocator)
	if err != nil {return}
	usage: [MAX_CORES + 1]f32
	n := 0
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if !strings.has_prefix(line, "cpu") {break}
		if n > MAX_CORES {break}
		t, _ := cpu_jiffies_parse(line)
		usage[n] = cpu_busy_pct(prev_cpu[n], t)
		prev_cpu[n] = t
		n += 1
	}
	temp: f32
	if cpu_temp_path != "" {
		v, _ := strconv.parse_f64(read_trim(cpu_temp_path))
		temp = f32(v / 1000)
	}

	mem_total, mem_avail, cached, sreclaim, swap_total, swap_free: u64
	if mi, merr := os.read_entire_file("/proc/meminfo", context.temp_allocator); merr == nil {
		mt := string(mi)
		for line in strings.split_lines_iterator(&mt) {
			f := strings.fields(line, context.temp_allocator)
			if len(f) < 2 {continue}
			v, _ := strconv.parse_u64(f[1])
			switch f[0] {
			case "MemTotal:":     mem_total = v * 1024
			case "MemAvailable:": mem_avail = v * 1024
			case "Cached:":       cached = v * 1024
			case "SReclaimable:": sreclaim = v * 1024
			case "SwapTotal:":    swap_total = v * 1024
			case "SwapFree:":     swap_free = v * 1024
			}
		}
	}
	mem_test_override(mem_total, &mem_avail)
	load: [3]f32
	if la, lerr := os.read_entire_file("/proc/loadavg", context.temp_allocator); lerr == nil {
		for f, i in strings.fields(string(la), context.temp_allocator) {
			if i < 3 {load[i] = f32(strconv.parse_f64(f) or_else 0)}
		}
	}
	uptime: f64
	if up, uerr := os.read_entire_file("/proc/uptime", context.temp_allocator); uerr == nil {
		if f := strings.fields(string(up), context.temp_allocator); len(f) > 0 {uptime = strconv.parse_f64(f[0]) or_else 0}
	}

	sync.guard(&sysmon.mu)
	sysmon.cpu_now = usage[0]
	// The very first sample has no baseline (e.g. right after a re-exec).
	if !first_cpu_sample {history_push(&sysmon.cpu, usage[0])}
	first_cpu_sample = false
	sysmon.core_count = max(n - 1, 0)
	copy(sysmon.cores[:], usage[1:n])
	sysmon.cpu_temp = temp
	sysmon.mem_total = mem_total
	sysmon.mem_used = mem_total - mem_avail
	sysmon.mem_cached = cached + sreclaim
	sysmon.swap_total = swap_total
	sysmon.swap_used = swap_total - swap_free
	sysmon.load = load
	sysmon.uptime = uptime
	if mem_total > 0 {history_push(&sysmon.mem, f32(f64(sysmon.mem_used) / PERF_MIB))}
	if swap_total > 0 {history_push(&sysmon.swap, f32(f64(sysmon.swap_used) / PERF_MIB))}
}

@(private = "file")
cpu_model_name :: proc() -> string {
	data, err := os.read_entire_file("/proc/cpuinfo", context.temp_allocator)
	if err != nil {return "CPU"}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "model name") {
			if i := strings.index_byte(line, ':'); i >= 0 {
				name := strings.trim_space(line[i + 1:])
				// "AMD Ryzen 7 2700X Eight-Core Processor" -> "AMD Ryzen 7 2700X"
				for suffix in ([]string{" Eight-Core", " Six-Core", " Twelve-Core", " Sixteen-Core", " Quad-Core", " Processor", " CPU"}) {
					if j := strings.index(name, suffix); j > 0 {name = name[:j]}
				}
				name, _ = strings.replace_all(name, "(R)", "", context.temp_allocator)
				name, _ = strings.replace_all(name, "(TM)", "", context.temp_allocator)
				return strings.clone(strings.trim_space(name))
			}
		}
	}
	return "CPU"
}

int_to_string :: proc(i: int, allocator := context.temp_allocator) -> string {
	buf: [32]u8
	return strings.clone(strconv.write_int(buf[:], i64(i), 10), allocator)
}

nvml_dev_handle :: proc() -> rawptr {
	if nvml.lib == nil {return nil}
	return rawptr(nvml.dev)
}

sysmon_start :: proc() {
	sysmon.cpu_name = cpu_model_name()
	thermals_init()
	find_cpu_temp()
	if nvml_open() {
		sysmon.gpu_ok = true
	} else if drm_open() {
		sysmon.gpu_ok = true
	}
	thread.create_and_start(proc() {
		for {
			cpu_sample()
			if sysmon.gpu_ok {
				if nvml.lib != nil {nvml_sample()} else {drm_sample()}
			}
			thermals_sample()
			{
				sysmon_lock()
				used, total := sysmon.mem_used, sysmon.mem_total
				sysmon_unlock()
				memwarn_sample(used, total)
			}
			wake_ui_lazy()
			free_all(context.temp_allocator)
			// Align samples to whole seconds so graph steps line up with the clock tick.
			now := time.to_unix_nanoseconds(time.now())
			time.sleep(time.Duration(i64(time.Second) - now % i64(time.Second)) + 5 * time.Millisecond)
		}
	})
}
