// Temperatures (hwmon + NVML), fans and power (NVML for the GPU, RAPL energy
// counters for the CPU package when readable), sampled with the 1 Hz sysmon.
package main

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

MAX_SENSORS :: 24
MAX_FANS :: 8

Temp_Reading :: struct {
	label:  [32]u8,
	llen:   int,
	group:  enum {CPU, GPU, Storage, Board, Other},
	value:  f32, // °C
}

Fan_Reading :: struct {
	label: [24]u8,
	llen:  int,
	rpm:   int,
}

Thermals :: struct {
	mu:          sync.Mutex,
	temps:       [MAX_SENSORS]Temp_Reading,
	n_temps:     int,
	fans:        [MAX_FANS]Fan_Reading,
	n_fans:      int,
	cpu_temp_h:  History, // °C
	gpu_temp_h:  History, // °C
	cpu_watts:   f32,
	cpu_power_ok: bool,   // RAPL energy counter readable
	cpu_power_h: History, // W
	gpu_watts:   f32,
	gpu_limit:   f32,     // W (enforced power limit), 0 = unknown
	gpu_power_h: History, // W
}
thermals: Thermals

reading_label :: proc(r: ^Temp_Reading) -> string {return string(r.label[:r.llen])}
fan_label :: proc(f: ^Fan_Reading) -> string {return string(f.label[:f.llen])}

@(private = "file")
read_num :: proc(path: string) -> (f64, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return 0, false}
	return strconv.parse_f64(strings.trim_space(string(data)))
}

@(private = "file")
read_str :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return ""}
	return strings.trim_space(string(data))
}

// Friendly names for common motherboard (Nuvoton/ITE) inputs; unlabelled
// AUXTIN* inputs are usually unconnected and read garbage, so they're skipped.
@(private = "file")
board_label :: proc(label: string) -> (string, bool) {
	switch {
	case label == "SYSTIN":                     return "System", true
	case label == "CPUTIN":                     return "CPU socket", true
	case strings.has_prefix(label, "SMBUSMASTER"): return fmt.tprintf("SMBus %s", strings.trim_space(label[11:])), true
	case strings.has_prefix(label, "AUXTIN"),
	     strings.has_prefix(label, "PCH_"),
	     strings.has_prefix(label, "TSI"):     return "", false // junk, or duplicates of the CPU sensor
	}
	return label, true
}

@(private = "file")
scan_hwmon :: proc(temps: ^[MAX_SENSORS]Temp_Reading, n: ^int, fans: ^[MAX_FANS]Fan_Reading, nf: ^int) {
	dir, err := os.open("/sys/class/hwmon")
	if err != nil {return}
	entries, _ := os.read_all_directory(dir, context.temp_allocator)
	os.close(dir)
	add_temp :: proc(temps: ^[MAX_SENSORS]Temp_Reading, n: ^int, label: string, group: type_of(Temp_Reading{}.group), v: f32) {
		if n^ >= MAX_SENSORS {return}
		r := &temps[n^]
		r.llen = copy(r.label[:], label)
		r.group = group
		r.value = v
		n^ += 1
	}
	for e in entries {
		base := strings.concatenate({"/sys/class/hwmon/", e.name}, context.temp_allocator)
		name := read_str(strings.concatenate({base, "/name"}, context.temp_allocator))
		for i in 1 ..= 16 {
			input := fmt.tprintf("%s/temp%d_input", base, i)
			v, ok := read_num(input)
			if !ok {continue}
			c := f32(v / 1000)
			// Unconnected inputs read 0, negative or absurd values.
			if c <= 1 || c > 125 {continue}
			label := read_str(fmt.tprintf("%s/temp%d_label", base, i))
			switch {
			case name == "k10temp" || name == "coretemp" || name == "zenpower":
				if label == "" {label = "CPU"}
				if label == "Tctl" {continue} // offset copy of Tdie on many Ryzens
				if label == "Tdie" {label = "CPU"}
				add_temp(temps, n, label, .CPU, c)
			case name == "nvme":
				add_temp(temps, n, label == "Composite" || label == "" ? "NVMe SSD" : fmt.tprintf("NVMe %s", label), .Storage, c)
			case name == "amdgpu":
				add_temp(temps, n, label == "" ? "GPU" : fmt.tprintf("GPU %s", label), .GPU, c)
			case strings.has_prefix(name, "nct") || strings.has_prefix(name, "it87") || name == "asus_ec_sensors":
				if pretty, keep := board_label(label); keep {add_temp(temps, n, pretty, .Board, c)}
			case strings.has_prefix(name, "iwlwifi") || strings.has_prefix(name, "hid") || strings.has_suffix(name, "battery"):
				// Wi-Fi card / peripherals: not interesting here.
			case:
				add_temp(temps, n, label != "" ? label : name, .Other, c)
			}
		}
		for i in 1 ..= 10 {
			v, ok := read_num(fmt.tprintf("%s/fan%d_input", base, i))
			if !ok || v <= 0 || nf^ >= MAX_FANS {continue}
			label := read_str(fmt.tprintf("%s/fan%d_label", base, i))
			if label == "" {label = fmt.tprintf("Fan %d", i)}
			f := &fans[nf^]
			f.llen = copy(f.label[:], label)
			f.rpm = int(v)
			nf^ += 1
		}
	}
}

// ---- CPU package power via RAPL (also present on AMD as "intel-rapl") ------
@(private = "file") rapl_path := "/sys/class/powercap/intel-rapl:0/energy_uj"
@(private = "file") rapl_prev: f64
@(private = "file") rapl_prev_t: time.Tick
@(private = "file") rapl_max: f64

@(private = "file")
sample_rapl :: proc() -> (watts: f32, ok: bool) {
	e, rok := read_num(rapl_path)
	if !rok {return 0, false} // root-only by default (PLATYPUS mitigation)
	if rapl_max == 0 {rapl_max, _ = read_num("/sys/class/powercap/intel-rapl:0/max_energy_range_uj")}
	now := time.tick_now()
	defer {
		rapl_prev = e
		rapl_prev_t = now
	}
	if rapl_prev_t == {} {return 0, true}
	de := e - rapl_prev
	if de < 0 {de += rapl_max} // counter wrapped
	dt := time.duration_seconds(time.tick_diff(rapl_prev_t, now))
	if dt <= 0 {return 0, true}
	return f32(de / 1e6 / dt), true
}

// ---- GPU power limit (NVML) -----------------------------------------------
@(private = "file") nvml_limit_fn: proc "c" (dev: rawptr, mw: ^u32) -> i32

thermals_init :: proc() {
	if lib, ok := dynlib.load_library("libnvidia-ml.so.1"); ok {
		p, _ := dynlib.symbol_address(lib, "nvmlDeviceGetEnforcedPowerLimit")
		nvml_limit_fn = auto_cast p
	}
}

// Called from the sysmon thread once per second.
thermals_sample :: proc() {
	temps: [MAX_SENSORS]Temp_Reading
	fans: [MAX_FANS]Fan_Reading
	n, nf: int
	scan_hwmon(&temps, &n, &fans, &nf)
	cpu_w, cpu_ok := sample_rapl()

	gpu_temp, gpu_w: f32
	gpu_limit: f32
	{
		sync.guard(&sysmon.mu)
		gpu_temp = sysmon.gpu_temp
		gpu_w = sysmon.gpu_power
	}
	if nvml_limit_fn != nil && nvml_dev_handle() != nil {
		mw: u32
		if nvml_limit_fn(nvml_dev_handle(), &mw) == 0 {gpu_limit = f32(mw) / 1000}
	}
	if gpu_temp > 0 && n < MAX_SENSORS {
		r := &temps[n]
		r.llen = copy(r.label[:], "GPU")
		r.group = .GPU
		r.value = gpu_temp
		n += 1
	}
	// CPU first, then GPU, storage, board.
	for i in 1 ..< n {
		for j := i; j > 0 && temps[j].group < temps[j - 1].group; j -= 1 {temps[j], temps[j - 1] = temps[j - 1], temps[j]}
	}

	sync.guard(&thermals.mu)
	thermals.temps = temps
	thermals.n_temps = n
	thermals.fans = fans
	thermals.n_fans = nf
	cpu_t: f32
	for i in 0 ..< n {if temps[i].group == .CPU {cpu_t = max(cpu_t, temps[i].value)}}
	if cpu_t > 0 {history_push(&thermals.cpu_temp_h, cpu_t)}
	if gpu_temp > 0 {history_push(&thermals.gpu_temp_h, gpu_temp)}
	thermals.cpu_power_ok = cpu_ok
	if cpu_ok && rapl_prev_t != {} {
		thermals.cpu_watts = cpu_w
		history_push(&thermals.cpu_power_h, cpu_w)
	}
	thermals.gpu_watts = gpu_w
	thermals.gpu_limit = gpu_limit
	if gpu_w > 0 {history_push(&thermals.gpu_power_h, gpu_w)}
}
