// Audio devices via pactl (works with PulseAudio and PipeWire-pulse).
// HDMI card profiles are resolved to the monitor (via the ELD name PipeWire
// puts on each port) and then to the sway output connector.
package main

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Audio_Device :: struct {
	name:        string,
	label:       string, // short human name
	sublabel:    string, // e.g. "HDMI 2 · DP-3"
	icon:        string,
	volume:      f32, // 0..1.5
	mute:        bool,
	is_default:  bool,
}

Audio_Profile :: struct {
	name:      string,
	label:     string,
	monitor:   string, // ELD monitor name for HDMI profiles
	connector: string, // sway output connector driving that monitor
	available: bool,
	active:    bool,
}

Audio_Card :: struct {
	name:     string,
	label:    string,
	profiles: [dynamic]Audio_Profile,
}

Audio_State :: struct {
	mu:       sync.Mutex,
	ok:       bool,
	sinks:    [dynamic]Audio_Device,
	sources:  [dynamic]Audio_Device,
	cards:    [dynamic]Audio_Card,
	arena:    [dynamic]string, // owned strings, freed on refresh
}
audio: Audio_State

@(private = "file")
refresh_sema: sync.Sema

audio_refresh_async :: proc() {
	sync.sema_post(&refresh_sema)
}

@(private = "file")
own :: proc(s: string) -> string {
	c := strings.clone(s)
	append(&audio.arena, c)
	return c
}

@(private = "file")
parse_volume :: proc(v: json.Value) -> f32 {
	// Average of all channels' "value_percent" ("58%").
	o, ok := v.(json.Object)
	if !ok {return 0}
	sum: f32
	n := 0
	for _, ch in o {
		p := jstr(jobj(ch, "value_percent"))
		p = strings.trim_suffix(p, "%")
		if f, fok := strconv.parse_f32(p); fok {
			sum += f
			n += 1
		}
	}
	return n > 0 ? sum / f32(n) / 100 : 0
}

// Find the sway connector whose monitor model matches an ELD monitor name.
// Returns "" when unknown or ambiguous (two monitors of the same model).
// The result is allocated with `allocator` (sway's strings may be freed any time).
connector_for_monitor :: proc(monitor: string, allocator := context.temp_allocator) -> string {
	if monitor == "" {return ""}
	sync.guard(&sway.mu)
	found := ""
	matches := 0
	for o in sway.outputs {
		if o.model == monitor {
			found = o.name
			matches += 1
		}
	}
	if matches != 1 {return ""}
	return strings.clone(found, allocator)
}

@(private = "file")
device_icon :: proc(props: json.Value, port_type: string, is_sink: bool) -> string {
	bus := jstr(jobj(props, "device.bus"))
	form := jstr(jobj(props, "device.form_factor"))
	switch {
	case port_type == "HDMI":                       return ICON_MONITOR
	case bus == "bluetooth":                        return is_sink ? ICON_HEADPHONES : ICON_HEADSET
	case form == "headset" || form == "headphone":  return ICON_HEADPHONES
	case form == "webcam":                          return ICON_WEBCAM
	case bus == "usb":                              return is_sink ? ICON_SPEAKER : ICON_MIC
	}
	return is_sink ? ICON_SPEAKER : ICON_MIC
}

@(private = "file")
refresh :: proc() {
	sinks_s, ok1 := run({"pactl", "-f", "json", "list", "sinks"}, allocator = context.temp_allocator)
	sources_s, ok2 := run({"pactl", "-f", "json", "list", "sources"}, allocator = context.temp_allocator)
	cards_s, ok3 := run({"pactl", "-f", "json", "list", "cards"}, allocator = context.temp_allocator)
	def_sink, _ := run({"pactl", "get-default-sink"}, allocator = context.temp_allocator)
	def_source, _ := run({"pactl", "get-default-source"}, allocator = context.temp_allocator)
	if !ok1 || !ok2 || !ok3 {
		sync.guard(&audio.mu)
		audio.ok = false
		return
	}
	def_sink = strings.trim_space(def_sink)
	def_source = strings.trim_space(def_source)
	sinks_v, _ := jparse(sinks_s)
	sources_v, _ := jparse(sources_s)
	cards_v, _ := jparse(cards_s)

	sync.guard(&audio.mu)
	for s in audio.arena {delete(s)}
	clear(&audio.arena)
	clear(&audio.sinks)
	clear(&audio.sources)
	for &c in audio.cards {delete(c.profiles)}
	clear(&audio.cards)

	// Port name -> monitor (ELD) per card, for HDMI.
	Port_Info :: struct {
		card, port, monitor: string,
		profiles:            json.Array,
	}
	ports: [dynamic]Port_Info
	ports.allocator = context.temp_allocator
	for card in jarr(cards_v) {
		if pobj, ok := jobj(card, "ports").(json.Object); ok {
			for pname, port in pobj {
				append(&ports, Port_Info {
					card = jstr(jobj(card, "name")),
					port = pname,
					monitor = jstr(jobj(jobj(port, "properties"), "device.product.name")),
					profiles = jarr(jobj(port, "profiles")),
				})
			}
		}
	}
	monitor_for_port :: proc(ports: []Port_Info, port: string, card: string) -> string {
		for p in ports {if p.port == port && p.card == card {return p.monitor}}
		return ""
	}

	make_dev :: proc(d: json.Value, is_sink: bool, def: string, ports: []Port_Info) -> Audio_Device {
		props := jobj(d, "properties")
		active_port := jstr(jobj(d, "active_port"))
		port_type := ""
		port_desc := ""
		for p in jarr(jobj(d, "ports")) {
			if jstr(jobj(p, "name")) == active_port {
				port_type = jstr(jobj(p, "type"))
				port_desc = jstr(jobj(p, "description"))
			}
		}
		dev := Audio_Device {
			name       = own(jstr(jobj(d, "name"))),
			volume     = parse_volume(jobj(d, "volume")),
			mute       = jbool(jobj(d, "mute")),
			icon       = device_icon(props, port_type, is_sink),
		}
		dev.is_default = dev.name == def
		desc := jstr(jobj(d, "description"))
		profile_desc := jstr(jobj(props, "device.profile.description"))
		card_desc := jstr(jobj(props, "device.description"))
		if port_type == "HDMI" {
			monitor := monitor_for_port(ports, active_port, jstr(jobj(props, "device.name")))
			conn := connector_for_monitor(monitor)
			hdmi := strings.trim_suffix(strings.trim_prefix(profile_desc, "Digital Stereo ("), ")")
			dev.label = own(monitor != "" ? monitor : desc)
			dev.sublabel = own(conn != "" ? fmt.tprintf("%s · %s", hdmi, conn) : hdmi)
		} else if jstr(jobj(props, "device.bus")) == "bluetooth" {
			dev.label = own(desc)
			dev.sublabel = "Bluetooth"
		} else {
			// "C505e HD Webcam Mono" -> label "C505e HD Webcam", sublabel "Mono"
			if card_desc != "" && strings.has_prefix(desc, card_desc) && len(desc) > len(card_desc) {
				dev.label = own(card_desc)
				dev.sublabel = own(strings.trim_space(desc[len(card_desc):]))
			} else {
				dev.label = own(desc)
				dev.sublabel = own(port_desc)
			}
		}
		return dev
	}

	for d in jarr(sinks_v) {
		append(&audio.sinks, make_dev(d, true, def_sink, ports[:]))
	}
	for d in jarr(sources_v) {
		if jstr(jobj(d, "monitor_source")) != "" {continue} // skip "Monitor of ..." sources
		append(&audio.sources, make_dev(d, false, def_source, ports[:]))
	}

	for card in jarr(cards_v) {
		cname := jstr(jobj(card, "name"))
		active := jstr(jobj(card, "active_profile"))
		c := Audio_Card {
			name  = own(cname),
			label = own(jstr(jobj(jobj(card, "properties"), "device.description"))),
		}
		pobj, _ := jobj(card, "profiles").(json.Object)
		for pname, p in pobj {
			if !strings.has_prefix(pname, "output:") || strings.contains(pname, "+input") {continue}
			prof := Audio_Profile {
				name      = own(pname),
				label     = own(strings.trim_suffix(jstr(jobj(p, "description")), " Output")),
				available = jbool(jobj(p, "available")),
				active    = pname == active,
			}
			for port in ports {
				if port.card != cname {continue}
				for pp in port.profiles {
					if jstr(pp) == pname {
						prof.monitor = own(port.monitor)
						prof.connector = own(connector_for_monitor(port.monitor))
					}
				}
			}
			append(&c.profiles, prof)
		}
		// Only cards that offer a real choice of output profiles are interesting.
		if len(c.profiles) < 2 {
			delete(c.profiles)
			continue
		}
		// Stable order: available first, then by name.
		for i in 1 ..< len(c.profiles) {
			for j := i; j > 0; j -= 1 {
				a, b := c.profiles[j - 1], c.profiles[j]
				if (b.available && !a.available) || (a.available == b.available && b.name < a.name) {
					c.profiles[j - 1], c.profiles[j] = b, a
				} else {
					break
				}
			}
		}
		append(&audio.cards, c)
	}
	audio.ok = true
}

audio_set_default :: proc(name: string, is_sink: bool) {
	run_async({"pactl", is_sink ? "set-default-sink" : "set-default-source", name}, audio_refresh_async)
	// Optimistic update so the UI reacts immediately.
	sync.guard(&audio.mu)
	for &d in (is_sink ? audio.sinks : audio.sources) {d.is_default = d.name == name}
}

audio_toggle_mute :: proc(name: string, is_sink: bool) {
	run_async({"pactl", is_sink ? "set-sink-mute" : "set-source-mute", name, "toggle"}, audio_refresh_async)
	sync.guard(&audio.mu)
	for &d in (is_sink ? audio.sinks : audio.sources) {if d.name == name {d.mute = !d.mute}}
}

audio_set_profile :: proc(card, profile: string) {
	run_async({"pactl", "set-card-profile", card, profile}, audio_refresh_async)
	sync.guard(&audio.mu)
	for &c in audio.cards {
		if c.name != card {continue}
		for &p in c.profiles {p.active = p.name == profile}
	}
}

// Volume changes while dragging are coalesced by a dedicated thread.
@(private = "file")
vol_mu: sync.Mutex
@(private = "file")
vol_pending: struct {
	name:    [256]u8,
	len:     int,
	is_sink: bool,
	value:   f32,
	dirty:   bool,
}
@(private = "file")
vol_sema: sync.Sema

audio_set_volume :: proc(name: string, is_sink: bool, v: f32) {
	{
		sync.guard(&vol_mu)
		vol_pending.len = copy(vol_pending.name[:], name)
		vol_pending.is_sink = is_sink
		vol_pending.value = v
		vol_pending.dirty = true
	}
	sync.sema_post(&vol_sema)
	sync.guard(&audio.mu)
	for &d in (is_sink ? audio.sinks : audio.sources) {if d.name == name {d.volume = v}}
}

audio_start :: proc() {
	// Refresher: waits for a trigger (or a slow periodic poll as safety net).
	thread.create_and_start(proc() {
		for {
			refresh()
			wake_ui()
			free_all(context.temp_allocator)
			sync.sema_wait_with_timeout(&refresh_sema, 30 * time.Second)
			// Debounce bursts of events.
			time.sleep(60 * time.Millisecond)
			for sync.sema_wait_with_timeout(&refresh_sema, 0) {}
		}
	})
	// Event listener.
	thread.create_and_start(proc() {
		for {
			s, ok := stream_start({"pactl", "subscribe"})
			if !ok {
				time.sleep(5 * time.Second)
				continue
			}
			for {
				line, lok := stream_read_line(&s)
				if !lok {break}
				if strings.contains(line, " sink") || strings.contains(line, " source") || strings.contains(line, " card") || strings.contains(line, " server") {
					if !strings.contains(line, "sink-input") && !strings.contains(line, "source-output") {
						audio_refresh_async()
					}
				}
				free_all(context.temp_allocator)
			}
			stream_stop(&s)
			time.sleep(2 * time.Second)
		}
	})
	// Volume applier.
	thread.create_and_start(proc() {
		for {
			sync.sema_wait(&vol_sema)
			name: string
			is_sink: bool
			v: f32
			{
				sync.guard(&vol_mu)
				if !vol_pending.dirty {continue}
				vol_pending.dirty = false
				name = strings.clone(string(vol_pending.name[:vol_pending.len]), context.temp_allocator)
				is_sink = vol_pending.is_sink
				v = vol_pending.value
			}
			pct := fmt.tprintf("%d%%", int(v * 100 + 0.5))
			run({"pactl", is_sink ? "set-sink-volume" : "set-source-volume", name, pct}, allocator = context.temp_allocator)
			free_all(context.temp_allocator)
		}
	})
}

// Switch a card to another output profile (e.g. a different HDMI/DP port)
// and make the resulting sink the default.
audio_switch_output_profile :: proc(card, profile: string) {
	// Sink names follow "alsa_output.<card id>.<profile id>".
	card_id := strings.trim_prefix(card, "alsa_card.")
	prof_id := strings.trim_prefix(profile, "output:")
	sink := fmt.tprintf("alsa_output.%s.%s", card_id, prof_id)
	script := fmt.tprintf(
		"pactl set-card-profile '%s' '%s' && for i in 1 2 3 4 5 6 7 8 9 10; do pactl set-default-sink '%s' 2>/dev/null && break; sleep 0.1; done",
		card, profile, sink,
	)
	run_shell_async(script, audio_refresh_async)
	audio_set_profile_optimistic(card, profile)
}

@(private = "file")
audio_set_profile_optimistic :: proc(card, profile: string) {
	sync.guard(&audio.mu)
	for &c in audio.cards {
		if c.name != card {continue}
		for &p in c.profiles {p.active = p.name == profile}
	}
}
