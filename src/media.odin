// Media players over MPRIS (org.mpris.MediaPlayer2.* on the session bus):
// what's playing, play/pause, next, previous. The daemon polls on its own
// thread while the popup is open; `wlperch status media` and
// `wlperch media <cmd>` talk to the bus directly.
package main

import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

MPRIS_PREFIX :: "org.mpris.MediaPlayer2."
MPRIS_PATH :: "/org/mpris/MediaPlayer2"
MPRIS_PLAYER :: "org.mpris.MediaPlayer2.Player"

Media_Status :: enum {Stopped, Paused, Playing}

Media_Player :: struct {
	bus_name:    string,
	identity:    string, // "Spotify", "Mozilla Firefox"
	desktop:     string, // desktop entry, for the app icon
	status:      Media_Status,
	title:       string,
	artist:      string,
	album:       string,
	art:         string, // local file (downloaded when the player gives a URL)
	length_us:   i64,
	position_us: i64,
	sampled:     time.Tick, // when position_us was read
	can_next:    bool,
	can_prev:    bool,
	can_play:    bool,
	can_pause:   bool,
}

Media :: struct {
	mu:           sync.Mutex,
	players:      [dynamic]Media_Player,
	pinned:       string, // bus name the user picked in the card ("" = automatic)
	last_playing: string, // preferred among paused players
	cmd_target:   string,
	cmd_member:   string,
	wake:         sync.Sema,
	started:      bool,
}
media: Media

media_player_free :: proc(p: ^Media_Player) {
	delete(p.bus_name); delete(p.identity); delete(p.desktop)
	delete(p.title); delete(p.artist); delete(p.album); delete(p.art)
}

// ---- Reading the bus ----------------------------------------------------------------

@(private = "file")
read_s :: proc(m: ^Sd_Bus_Message) -> string {
	s: cstring
	if sd_bus_message_read_basic(m, 's', &s) < 0 {return ""}
	return string(s)
}

@(private = "file")
read_int :: proc(m: ^Sd_Bus_Message, t: string) -> i64 {
	switch t {
	case "x": v: i64; sd_bus_message_read_basic(m, 'x', &v); return v
	case "t": v: u64; sd_bus_message_read_basic(m, 't', &v); return i64(v)
	case "i": v: i32; sd_bus_message_read_basic(m, 'i', &v); return i64(v)
	case "u": v: u32; sd_bus_message_read_basic(m, 'u', &v); return i64(v)
	case "d": v: f64; sd_bus_message_read_basic(m, 'd', &v); return i64(v)
	}
	sd_bus_message_skip(m, strings.clone_to_cstring(t, context.temp_allocator))
	return 0
}

// Walk an a{sv}; `field` is called for each entry while positioned inside
// the variant (it must consume the value or return false to skip it).
@(private = "file")
read_dict :: proc(m: ^Sd_Bus_Message, p: ^Media_Player, field: proc(m: ^Sd_Bus_Message, p: ^Media_Player, key, t: string) -> bool) {
	if sd_bus_message_enter_container(m, 'a', "{sv}") <= 0 {return}
	for sd_bus_message_enter_container(m, 'e', "sv") > 0 {
		key := strings.clone(read_s(m), context.temp_allocator)
		t: u8
		contents: cstring
		sd_bus_message_peek_type(m, &t, &contents)
		if sd_bus_message_enter_container(m, 'v', contents) > 0 {
			ct := strings.clone(string(contents), context.temp_allocator)
			if !field(m, p, key, ct) {sd_bus_message_skip(m, contents)}
			sd_bus_message_exit_container(m)
		}
		sd_bus_message_exit_container(m)
	}
	sd_bus_message_exit_container(m)
}

@(private = "file")
get_all :: proc(bus: ^Sd_Bus, name, iface: string, p: ^Media_Player, field: proc(m: ^Sd_Bus_Message, p: ^Media_Player, key, t: string) -> bool) -> bool {
	err: Sd_Bus_Error
	reply: ^Sd_Bus_Message
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	ciface := strings.clone_to_cstring(iface, context.temp_allocator)
	r := sd_bus_call_method(bus, cname, MPRIS_PATH, "org.freedesktop.DBus.Properties", "GetAll", &err, &reply, "s", ciface)
	sd_bus_error_free(&err)
	if r < 0 {return false}
	defer sd_bus_message_unref(reply)
	read_dict(reply, p, field)
	return true
}

@(private = "file")
root_field :: proc(m: ^Sd_Bus_Message, p: ^Media_Player, key, t: string) -> bool {
	if t != "s" {return false}
	switch key {
	case "Identity":     p.identity = strings.clone(read_s(m)); return true
	case "DesktopEntry": p.desktop = strings.clone(read_s(m)); return true
	}
	return false
}

@(private = "file")
meta_field :: proc(m: ^Sd_Bus_Message, p: ^Media_Player, key, t: string) -> bool {
	switch key {
	case "xesam:title":
		if t == "s" {p.title = strings.clone(read_s(m)); return true}
	case "xesam:album":
		if t == "s" {p.album = strings.clone(read_s(m)); return true}
	case "mpris:artUrl":
		if t == "s" {p.art = strings.clone(read_s(m)); return true}
	case "mpris:length":
		p.length_us = read_int(m, t)
		return true
	case "xesam:artist":
		if t == "as" {
			strv: [^]cstring
			if sd_bus_message_read_strv(m, &strv) >= 0 && strv != nil {
				parts: [dynamic]string
				parts.allocator = context.temp_allocator
				for i := 0; strv[i] != nil; i += 1 {
					append(&parts, strings.clone(string(strv[i]), context.temp_allocator))
					c_free(rawptr(strv[i]))
				}
				c_free(strv)
				p.artist = strings.join(parts[:], ", ")
			}
			return true
		}
		if t == "s" {p.artist = strings.clone(read_s(m)); return true}
	}
	return false
}

@(private = "file")
player_field :: proc(m: ^Sd_Bus_Message, p: ^Media_Player, key, t: string) -> bool {
	switch key {
	case "PlaybackStatus":
		if t != "s" {return false}
		switch read_s(m) {
		case "Playing": p.status = .Playing
		case "Paused":  p.status = .Paused
		case:           p.status = .Stopped
		}
		return true
	case "Metadata":
		if t != "a{sv}" {return false}
		read_dict(m, p, meta_field)
		return true
	case "Position":
		p.position_us = read_int(m, t)
		p.sampled = time.tick_now()
		return true
	case "CanGoNext", "CanGoPrevious", "CanPlay", "CanPause":
		if t != "b" {return false}
		b: b32
		sd_bus_message_read_basic(m, 'b', &b)
		switch key {
		case "CanGoNext":     p.can_next = bool(b)
		case "CanGoPrevious": p.can_prev = bool(b)
		case "CanPlay":       p.can_play = bool(b)
		case "CanPause":      p.can_pause = bool(b)
		}
		return true
	}
	return false
}

// Remote album art (Spotify & co): fetched once into the cache.
@(private = "file")
local_art :: proc(url: string) -> string {
	if strings.has_prefix(url, "file://") {return strings.clone(url[len("file://"):])}
	if !strings.has_prefix(url, "http://") && !strings.has_prefix(url, "https://") {return ""}
	base := os.get_env("XDG_CACHE_HOME", context.temp_allocator)
	if base == "" {base = strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.cache"}, context.temp_allocator)}
	dir := strings.concatenate({base, "/wlperch/art"}, context.temp_allocator)
	path := fmt.aprintf("%s/%x", dir, hash.fnv64a(transmute([]u8)url))
	if !os.exists(path) {
		os.make_directory_all(dir)
		tmp := strings.concatenate({path, ".part"}, context.temp_allocator)
		if _, ok := run({"curl", "-sfL", "--max-time", "6", "-o", tmp, url}, 8 * time.Second, context.temp_allocator); !ok {
			os.remove(tmp)
			delete(path)
			return ""
		}
		os.rename(tmp, path)
	}
	return path
}

// All players on the bus, in bus order.
media_scan :: proc(bus: ^Sd_Bus) -> [dynamic]Media_Player {
	out: [dynamic]Media_Player
	err: Sd_Bus_Error
	reply: ^Sd_Bus_Message
	r := sd_bus_call_method(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames", &err, &reply, "")
	sd_bus_error_free(&err)
	if r < 0 {return out}
	names: [dynamic]string
	names.allocator = context.temp_allocator
	strv: [^]cstring
	if sd_bus_message_read_strv(reply, &strv) >= 0 && strv != nil {
		for i := 0; strv[i] != nil; i += 1 {
			if strings.has_prefix(string(strv[i]), MPRIS_PREFIX) {append(&names, strings.clone(string(strv[i]), context.temp_allocator))}
			c_free(rawptr(strv[i]))
		}
		c_free(strv)
	}
	sd_bus_message_unref(reply)
	for name in names {
		p := Media_Player{bus_name = strings.clone(name)}
		get_all(bus, name, "org.mpris.MediaPlayer2", &p, root_field)
		if !get_all(bus, name, MPRIS_PLAYER, &p, player_field) {
			media_player_free(&p)
			continue
		}
		if p.identity == "" {p.identity = strings.clone(name[len(MPRIS_PREFIX):])}
		if p.art != "" {
			url := p.art
			p.art = local_art(url)
			delete(url)
		}
		append(&out, p)
	}
	return out
}

// The player the card and the bar show: the one the user picked, else one
// that's playing (the last one that was, first), else the last one that was
// playing, else the first.
media_pick :: proc(players: []Media_Player, pinned, last_playing: string) -> int {
	for p, i in players {if p.bus_name == pinned {return i}}
	for p, i in players {if p.status == .Playing && p.bus_name == last_playing {return i}}
	for p, i in players {if p.status == .Playing {return i}}
	for p, i in players {if p.bus_name == last_playing {return i}}
	for p, i in players {if p.status == .Paused {return i}}
	return len(players) > 0 ? 0 : -1
}

media_open_bus :: proc() -> ^Sd_Bus {
	bus: ^Sd_Bus
	if sd_bus_open_user(&bus) < 0 {return nil}
	sd_bus_set_method_call_timeout(bus, 800_000) // a hung player must not stall us
	return bus
}

media_call :: proc(bus: ^Sd_Bus, name, member: string) -> bool {
	err: Sd_Bus_Error
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	cmember := strings.clone_to_cstring(member, context.temp_allocator)
	r := sd_bus_call_method(bus, cname, MPRIS_PATH, MPRIS_PLAYER, cmember, &err, nil, "")
	sd_bus_error_free(&err)
	return r >= 0
}

// ---- Daemon ---------------------------------------------------------------------

media_start :: proc() {
	if media.started {return}
	media.started = true
	thread.create_and_start(proc() {
		bus := media_open_bus()
		if bus == nil {return}
		for {
			// Poll every second while the popup is open; otherwise sleep until asked.
			if plat_visible_flag {
				sync.sema_wait_with_timeout(&media.wake, time.Second)
			} else {
				sync.sema_wait(&media.wake)
			}
			target, member: string
			{
				sync.guard(&media.mu)
				target, member = media.cmd_target, media.cmd_member
				media.cmd_target, media.cmd_member = "", ""
			}
			if member != "" {
				media_call(bus, target, member)
				delete(target)
				delete(member)
				time.sleep(150 * time.Millisecond) // let the player update its state
			}
			players := media_scan(bus)
			{
				sync.guard(&media.mu)
				for &p in media.players {media_player_free(&p)}
				delete(media.players)
				media.players = players
				for p in players {
					if p.status == .Playing && p.bus_name != media.last_playing {
						delete(media.last_playing)
						media.last_playing = strings.clone(p.bus_name)
					}
				}
			}
			wake_ui()
			free_all(context.temp_allocator)
		}
	})
}

media_refresh_async :: proc() {
	if !media.started {media_start()}
	sync.sema_post(&media.wake)
}

media_command_async :: proc(bus_name, member: string) {
	{
		sync.guard(&media.mu)
		delete(media.cmd_target)
		delete(media.cmd_member)
		media.cmd_target = strings.clone(bus_name)
		media.cmd_member = strings.clone(member)
		// Show the new state right away; the next scan confirms it.
		for &p in media.players {
			if p.bus_name != bus_name || member != "PlayPause" {continue}
			if p.status == .Playing {
				p.position_us += i64(time.duration_microseconds(time.tick_since(p.sampled)))
				p.status = .Paused
			} else {
				p.status = .Playing
			}
			p.sampled = time.tick_now()
		}
	}
	sync.sema_post(&media.wake)
}

// Interpolated playback position.
media_position :: proc(p: Media_Player) -> i64 {
	pos := p.position_us
	if p.status == .Playing && p.sampled != {} {pos += i64(time.duration_microseconds(time.tick_since(p.sampled)))}
	if p.length_us > 0 {pos = min(pos, p.length_us)}
	return max(pos, 0)
}

media_fmt_time :: proc(us: i64) -> string {
	s := us / 1_000_000
	if s >= 3600 {return fmt.tprintf("%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)}
	return fmt.tprintf("%d:%02d", s / 60, s % 60)
}

// ---- CLI and waybar ----------------------------------------------------------------

// `wlperch media play-pause|next|previous|play|pause [player]`.
media_cli :: proc(args: []string) -> int {
	if len(args) == 0 {
		fmt.eprintln("usage: wlperch media play-pause|play|pause|next|previous")
		return 2
	}
	member: string
	switch args[0] {
	case "play-pause", "toggle": member = "PlayPause"
	case "play":                 member = "Play"
	case "pause":                member = "Pause"
	case "next":                 member = "Next"
	case "previous", "prev":     member = "Previous"
	case:
		fmt.eprintln("usage: wlperch media play-pause|play|pause|next|previous")
		return 2
	}
	bus := media_open_bus()
	if bus == nil {
		fmt.eprintln("no session bus")
		return 1
	}
	defer sd_bus_flush_close_unref(bus)
	players := media_scan(bus)
	i := media_pick(players[:], "", "")
	if len(args) > 1 {
		i = -1
		for p, j in players {
			if strings.contains(strings.to_lower(p.bus_name, context.temp_allocator), strings.to_lower(args[1], context.temp_allocator)) {i = j; break}
		}
	}
	if i < 0 {
		fmt.eprintln("no media player")
		return 1
	}
	return media_call(bus, players[i].bus_name, member) ? 0 : 1
}

@(private = "file")
json_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		switch r {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '&':  strings.write_string(&b, "&amp;") // waybar renders Pango markup
		case '<':  strings.write_string(&b, "&lt;")
		case '>':  strings.write_string(&b, "&gt;")
		case:
			if r < 0x20 {continue}
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
clip_runes :: proc(s: string, n: int) -> string {
	i := 0
	for _, off in s {
		if i == n {return strings.concatenate({strings.trim_right_space(s[:off]), "…"}, context.temp_allocator)}
		i += 1
	}
	return s
}

// `wlperch status media [prev|next]`: the track with a play/pause glyph
// (click toggles), or a lone previous/next button. Empty text (module
// hidden) when nothing plays.
status_media_loop :: proc(part: string) {
	bus := media_open_bus()
	last_playing: string
	for {
		text, tooltip, class: string
		class = "none"
		if bus != nil {
			players := media_scan(bus)
			for p in players {
				if p.status == .Playing && p.bus_name != last_playing {
					delete(last_playing)
					last_playing = strings.clone(p.bus_name)
				}
			}
			if i := media_pick(players[:], "", last_playing); i >= 0 {
				p := players[i]
				class = p.status == .Playing ? "playing" : p.status == .Paused ? "paused" : "stopped"
				track := p.title != "" ? p.title : p.identity
				if p.artist != "" && p.title != "" {track = fmt.tprintf("%s — %s", p.artist, p.title)}
				tooltip = json_escape(fmt.tprintf("%s · %s\n%s%s", p.identity, class, track, p.album != "" ? fmt.tprintf("\n%s", p.album) : ""))
				switch part {
				case "prev": if p.can_prev {text = ICON_SKIP_PREV}
				case "next": if p.can_next {text = ICON_SKIP_NEXT}
				case:
					icon := p.status == .Playing ? ICON_PAUSE : ICON_PLAY
					text = fmt.tprintf("%s  %s", icon, json_escape(clip_runes(track, 40)))
				}
			}
			for &p in players {media_player_free(&p)}
			delete(players)
		}
		line := fmt.tprintf(`{{"text": "%s", "tooltip": "%s", "class": "%s"}}` + "\n", text, tooltip, class)
		if _, err := os.write_string(os.stdout, line); err != nil {return}
		free_all(context.temp_allocator)
		time.sleep(time.Second)
	}
}

