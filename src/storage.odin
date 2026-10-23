// Disks and external drives from lsblk; mounting and ejecting through udisks.
package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Volume :: struct {
	path:        string,   // /dev/sdc2
	label:       string,
	fstype:      string,
	mountpoints: []string, // empty = not mounted
	size:        u64,      // partition size
	used, total: u64,      // filesystem usage (mounted only)
}

Drive :: struct {
	path:     string, // /dev/sdc
	model:    string,
	tran:     string, // usb, sata, nvme…
	size:     u64,
	external: bool,
	volumes:  [dynamic]Volume,
}

Storage :: struct {
	mu:       sync.Mutex,
	ok:       bool,
	drives:   [dynamic]Drive,
	busy:     string, // device path being mounted / ejected
	message:  string, // result of the last action
	msg_ok:   bool,
	watching: bool,   // popup open: rescan every few seconds for plugged drives
}
storage: Storage

@(private = "file")
trigger: sync.Sema

@(private = "file")
free_drives :: proc() {
	for &d in storage.drives {
		for v in d.volumes {
			delete(v.path); delete(v.label); delete(v.fstype)
			for m in v.mountpoints {delete(m)}
			delete(v.mountpoints)
		}
		delete(d.volumes)
		delete(d.path); delete(d.model); delete(d.tran)
	}
	clear(&storage.drives)
}

// Partitions that aren't worth showing: boot / EFI system partitions, swap,
// and small unlabelled helper partitions (Windows "reserved", BIOS boot…).
@(private = "file")
boring :: proc(v: Volume) -> bool {
	if v.fstype == "" || v.fstype == "swap" || v.fstype == "crypto_LUKS" {return true}
	for m in v.mountpoints {
		if m == "/boot" || strings.has_prefix(m, "/boot/") || m == "/efi" || m == "[SWAP]" {return true}
	}
	if v.label == "EFI" || v.label == "System Reserved" {return true}
	return v.size < 1 << 30 && len(v.mountpoints) == 0
}

storage_refresh_now :: proc() {
	out, ok := run({"lsblk", "-J", "-b", "-o", "NAME,PATH,SIZE,FSTYPE,LABEL,MOUNTPOINTS,FSUSED,FSSIZE,RM,HOTPLUG,TRAN,TYPE,MODEL"}, 5 * time.Second, context.temp_allocator)
	if !ok {
		sync.guard(&storage.mu)
		storage.ok = false
		return
	}
	v, _ := jparse(out)
	sync.guard(&storage.mu)
	free_drives()
	storage.ok = true
	for dev in jarr(jobj(v, "blockdevices")) {
		if jstr(jobj(dev, "type")) != "disk" {continue} // loop, zram, rom…
		tran := jstr(jobj(dev, "tran"))
		d := Drive {
			path     = strings.clone(jstr(jobj(dev, "path"))),
			model    = strings.clone(strings.trim_space(jstr(jobj(dev, "model")))),
			tran     = strings.clone(tran),
			size     = u64(jint(jobj(dev, "size"))),
			external = jbool(jobj(dev, "hotplug")) || jbool(jobj(dev, "rm")) || tran == "usb",
		}
		// A filesystem straight on the disk (no partition table) counts as one volume.
		parts := jarr(jobj(dev, "children"))[:]
		whole := [1]json.Value{dev}
		if len(parts) == 0 && jstr(jobj(dev, "fstype")) != "" {parts = whole[:]}
		for p in parts {
			mps: [dynamic]string
			for m in jarr(jobj(p, "mountpoints")) {
				if s := jstr(m); s != "" {append(&mps, strings.clone(s))}
			}
			vol := Volume {
				path        = strings.clone(jstr(jobj(p, "path"))),
				label       = strings.clone(jstr(jobj(p, "label"))),
				fstype      = strings.clone(jstr(jobj(p, "fstype"))),
				mountpoints = mps[:],
				size        = u64(jint(jobj(p, "size"))),
				used        = u64(jint(jobj(p, "fsused"))),
				total       = u64(jint(jobj(p, "fssize"))),
			}
			// Internal partitions only matter when mounted.
			if boring(vol) || (!d.external && len(mps) == 0) {
				delete(vol.path); delete(vol.label); delete(vol.fstype)
				for m in mps {delete(m)}
				delete(mps)
				continue
			}
			append(&d.volumes, vol)
		}
		if len(d.volumes) == 0 && !d.external {
			delete(d.volumes); delete(d.path); delete(d.model); delete(d.tran)
			continue
		}
		append(&storage.drives, d)
	}
	// Internal drives first (system drive on top), then external ones.
	for i in 1 ..< len(storage.drives) {
		for j := i; j > 0 && drive_less(storage.drives[j], storage.drives[j - 1]); j -= 1 {
			storage.drives[j], storage.drives[j - 1] = storage.drives[j - 1], storage.drives[j]
		}
	}
}

@(private = "file")
drive_less :: proc(a, b: Drive) -> bool {
	if a.external != b.external {return !a.external}
	return has_root(a) && !has_root(b)
}

@(private = "file")
has_root :: proc(d: Drive) -> bool {
	for v in d.volumes {for m in v.mountpoints {if m == "/" {return true}}}
	return false
}

storage_refresh_async :: proc() {sync.sema_post(&trigger)}

storage_on_show :: proc() {
	storage.watching = true
	storage_refresh_async()
}

storage_on_hide :: proc() {storage.watching = false}

storage_start :: proc() {
	thread.create_and_start(proc() {
		for {
			// While the popup is open, rescan every few seconds so a drive
			// that's plugged in shows up without reopening.
			if storage.watching {
				sync.sema_wait_with_timeout(&trigger, 3 * time.Second)
			} else {
				sync.sema_wait(&trigger)
			}
			storage_refresh_now()
			free_all(context.temp_allocator)
			request_redraw()
		}
	})
}

// ---- Actions (udisks: no root needed for removable drives) ------------------

@(private = "file")
Job :: struct {
	device: string,
	steps:  [dynamic][]string,
	done:   string, // message on success
}

@(private = "file")
run_job :: proc(job: ^Job) {
	{
		sync.guard(&storage.mu)
		delete(storage.busy)
		storage.busy = strings.clone(job.device)
		delete(storage.message)
		storage.message = ""
	}
	request_redraw()
	thread.create_and_start_with_data(job, proc(data: rawptr) {
		job := (^Job)(data)
		failed := ""
		for argv in job.steps {
			out, code := run_code(argv, 30 * time.Second, context.temp_allocator)
			if code != 0 {
				failed = strings.trim_space(out)
				if failed == "" {failed = fmt.tprintf("%s failed", argv[1])}
				break
			}
		}
		{
			sync.guard(&storage.mu)
			delete(storage.busy)
			storage.busy = ""
			if failed != "" {
				// udisks errors look like "Error unmounting /dev/sdc2: GDBus.Error:…: target is busy"
				if i := strings.last_index(failed, ": "); i >= 0 && strings.contains(failed, "GDBus") {failed = failed[i + 2:]}
				storage.message = strings.clone(failed)
			} else if job.done != "" {
				storage.message = strings.clone(job.done)
			}
			storage.msg_ok = failed == ""
		}
		for argv in job.steps {
			for a in argv {delete(a)}
			delete(argv)
		}
		delete(job.steps)
		delete(job.device)
		delete(job.done)
		free(job)
		free_all(context.temp_allocator)
		storage_refresh_now()
		request_redraw()
	}, self_cleanup = true)
}

@(private = "file")
step :: proc(job: ^Job, args: ..string) {
	argv := make([]string, len(args))
	for a, i in args {argv[i] = strings.clone(a)}
	append(&job.steps, argv)
}

storage_mount :: proc(vol_path: string) {
	job := new(Job)
	job.device = strings.clone(vol_path)
	step(job, "udisksctl", "mount", "--no-user-interaction", "-b", vol_path)
	run_job(job)
}

// Unmount every mounted volume, then power the drive off so it's safe to unplug.
storage_eject :: proc(drive_path: string) {
	job := new(Job)
	job.device = strings.clone(drive_path)
	{
		sync.guard(&storage.mu)
		for d in storage.drives {
			if d.path != drive_path {continue}
			for v in d.volumes {
				if len(v.mountpoints) > 0 {step(job, "udisksctl", "unmount", "--no-user-interaction", "-b", v.path)}
			}
			job.done = strings.clone(fmt.tprintf("%s can be unplugged", d.model != "" ? d.model : d.path))
		}
	}
	step(job, "udisksctl", "power-off", "--no-user-interaction", "-b", drive_path)
	run_job(job)
}

// Decimal units, as printed on drives and shown by file managers.
fmt_disk :: proc(b: u64) -> string {
	f := f64(b)
	switch {
	case f >= 1e13: return fmt.tprintf("%.0f TB", f / 1e12)
	case f >= 1e12: return fmt.tprintf("%.1f TB", f / 1e12)
	case f >= 1e11: return fmt.tprintf("%.0f GB", f / 1e9)
	case f >= 1e9:  return fmt.tprintf("%.1f GB", f / 1e9)
	case f >= 1e6:  return fmt.tprintf("%.0f MB", f / 1e6)
	}
	return fmt.tprintf("%.0f kB", f / 1e3)
}
