# wlwidgets — TODO

Legend: `[x]` done · `[ ]` open · `[~]` partially done / needs polish

## Infrastructure
- [x] Build script (`build.sh`): fetch + build odin-imgui (opengl3 backend, FreeType, 32-bit ImWchar), generate wayland bindings, build app
- [x] Odin wayland-scanner (`tools/wlscan`) generating bindings from protocol XML
- [x] Hand-written libwayland-client core bindings (display, proxy, marshal)
- [x] Protocols: wayland core, xdg-shell, wlr-layer-shell, cursor-shape, viewporter, single-pixel-buffer, fractional-scale (+ unknown-interface stubs)
- [x] EGL + OpenGL 3.3 core context on a wl_egl_window, transparent background
- [x] xkbcommon bindings for keyboard (keysyms, utf8 text, key repeat)
- [x] Dear ImGui platform layer for Wayland (pointer, scroll, keyboard, text, cursor shapes)
- [x] Event loop: poll(wayland fd, wake pipe, control socket, timer); 0% CPU when hidden
- [x] Single-instance daemon + control socket: `wlwidgets toggle|show|hide|quit|daemon`
- [x] Layer-shell popup (overlay, anchored top-right by default, configurable) on focused output — floats, never in the tiling tree
- [x] Hide on Escape and on click outside (transparent backdrop layer; sway drops on-demand focus so keyboard is exclusive)
- [x] Auto-size popup height to content (clamped to output height)
- [x] HiDPI: integer buffer scale (wl_surface.preferred_buffer_scale / output scale)
- [x] Fractional scaling (wp_fractional_scale_v1 + viewporter), tested at 1.5×
- [x] Config file `~/.config/wlwidgets/config.ini` with defaults written on first run
- [x] Background sampler threads; UI reads snapshots under mutex, actions applied after unlock
- [x] Safe subprocess helper (posix_spawn, captured stdout, timeouts, detached launches)
- [x] Lean idle daemon: lazy EGL, NVIDIA-only glvnd vendor, re-exec after 30 s hidden (history kept via memfd), small temp arenas → ~38 MB RSS
- [x] Unit tests (`./build.sh test`, 7 tests)
- [x] Independent correctness review; all 9 findings fixed (sway name UAF race, per-card port lookup, ambiguous monitor models, bluetoothctl timeout, setenv vs spawn race, child registry for re-exec, SIGPIPE default for children, wl_output.release, first-sample dip, stale input on seat loss)
- [x] UI test tool: `tools/vptr` virtual pointer (click/scroll at layout coords)

## Look & feel
- [x] Embedded fonts (Inter UI, JetBrains Mono digits, Nerd Font symbols for icons)
- [x] Custom dark theme: rounded card panels, accent colors, subtle borders
- [x] Soft drop-shadow + rounded transparent window corners
- [x] Custom widgets: card, device rows, slim sliders, pill toggle, segmented control, gradient area graphs, usage bars, toast
- [x] Two-column layout that reads well at a glance
- [x] Open animation (fade/slide)

## Widgets
### Audio
- [x] List output sinks, select default (pactl set-default-sink)
- [x] List input sources (exclude monitors), select default
- [x] Volume sliders (drag + scroll wheel, up to 150%) + mute for default sink/source
- [x] HDMI card profiles: list per card, switch profile (pactl set-card-profile)
- [x] Resolve HDMI profile → port → ELD monitor name → sway output connector (e.g. DP-1)
- [x] Other plugged HDMI/DP monitors offered directly in the Output list (switch profile + default sink)
- [x] Mark unavailable profiles (no monitor plugged)
- [x] Live refresh via `pactl subscribe`

### Night light
- [x] Show wlsunset running state
- [x] Toggle wlsunset on/off (configurable command, `{lat}`/`{lon}` from weather location)

### System
- [x] CPU % history graph (/proc/stat), current %, per-core strip, temperature
- [x] GPU % history graph (NVML via dlopen; AMD sysfs `gpu_busy_percent` fallback), VRAM, temperature, power
- [x] Memory usage bar
- [x] Memory warning at configurable % (`memory_warn_percent`): red row in popup + red, pulsing waybar button via `wlwidgets status`
- [x] Keep history sampling while popup is hidden

### Keyboard
- [x] Show active xkb layout (sway IPC get_inputs, event driven)
- [x] Switch layout (sway IPC `input type:keyboard xkb_switch_layout N`)

### Weather
- [x] Configurable location (auto via IP, place name → geocoding, or lat,lon)
- [x] Today's forecast via open-meteo: current temp, feels-like, hi/lo, condition icon, rain %, wind, humidity, sunrise/sunset, hourly strip
- [x] Refresh every 15 min (on show when stale); error state + retry

### Clocks
- [x] List of configurable timezones (IANA names + label), local time highlighted
- [x] Day offset badge (tomorrow / yesterday), UTC offset and relative offset

### Network
- [x] Public IP (configurable URL, refresh 10 min, click to copy)
- [x] Internal IPs per interface (getifaddrs), default-route interface highlighted, ignore list
- [x] Copy to clipboard (wl-copy) with toast

### Bluetooth
- [x] Connected + paired devices via org.bluez (busctl JSON)
- [x] Battery % via org.bluez.Battery1, UPower fallback (+ charging state)
- [x] Device-type icons; click to connect/disconnect

### Displays
- [x] Visual screen layout from sway IPC get_outputs (scaled rects, names, resolution, refresh, rotation)
- [x] Discover preset scripts (desk.sh and siblings), parse their sway `output` lines (incl. `$((a+b))`) for preview
- [x] Drop-down list of presets with mini layout preview; selecting applies (runs the script)
- [x] Highlight currently active preset (compare to current layout)

## Panels (modular popups)
- [x] `[panel.NAME]` sections: modules in columns, width, header/title; first = default
- [x] `wlwidgets toggle|show <panel>`; switching panels in place (resize + fade)
- [x] Restart keeps the open panel
- [x] perf panel: cpu (load, per-core, uptime), memory (history, used/cache/free, swap, warning), gpu (VRAM), processes (top CPU / memory, grouped by executable, sampled only while shown)
- [x] sensors panel: Tuya rooms (temp/humidity/battery/age), air quality (CO2 verdict, PM, HCHO), heater; watcher kept running by the daemon
- [x] waybar accessors: memory → perf, `wlwidgets status sensors` pill → sensors (CO2 warning classes)
- [x] Time tracker: [project.*] config, per-monitor project workspaces (create/recreate/pin), counting while focused, idle pause via ext-idle-notify-v1, TSV log + crash-safe heartbeat, today/week views, quick switch, `wlwidgets track`, waybar timer pill
- [x] Group lock: monitors follow each other into/out of project workspaces (toggle + `track lock`), decision logic unit-tested
- [x] Today timeline: 24 h, zoom on scroll (15 min–24 h, around the pointer), drag to pan, double-click to reset, adaptive tick labels
- [x] Breaks: idle periods logged per project (or "(no project)"), crash-safe; "Away from keyboard" stats (count, time away, work between breaks)
- [ ] Group lock: live end-to-end check (not run while the user was working)
- [x] Keep empty workspaces: placeholder xdg_toplevel windows (single-pixel buffer), placed via for_window, removed when a real window arrives, back when it leaves; verified live without focus changes
- [ ] Time tracker: visual check of the panel (screen was locked during the test run)
- [ ] Time tracker: optional window-rule assignment on numbered workspaces (e.g. by app/title)
- [x] Sensor history graphs: readings persisted to sensors.tsv, 24 h graphs on hover (tooltips grow the popup surface)

## Setup window (self-install)
- [x] `wlwidgets setup` (and auto-open when run from a download): xdg_toplevel window with the same renderer
- [x] Components with live status + actions: program, service, config, sway file, waybar files + hook (comment-aware JSONC patch, backups), RAPL udev rule (pkexec), launcher entry
- [x] File previews; "Install recommended"; ⚙ button in panels
- [x] Tested end-to-end in a headless nested sway with a fake HOME

## Integration & docs
- [x] Waybar custom module snippet + sway keybinding snippet in README
- [x] Integrated into the user's waybar: button rightmost, redundant modules removed (memory kept), bar restyled to match
- [x] README with build/run/config instructions
- [x] Tested under sway with grim + vptr: layout switch, outside click, Escape, IPC toggle, HDMI output switch (both ways), volume wheel, mute, night light, copy IP, preset dropdown, scrolling, fractional 1.5x, re-exec/state hand-over
- [x] Panel tabs at the top of every popup (labels, or icons only when narrow)
- [x] Performance panel renamed to "system" (`toggle perf` still works); storage card lives there
- [x] Main panel is quick settings + misc: toggle tiles (night light, do not disturb, Bluetooth, group lock, keep workspaces), keyboard layouts, links to the other panels; system graphs moved out (perf panel)
- [x] Perf graphs zoomable (scroll; 1 h of history), live until you look back; double-click or reopen returns to live
- [x] Storage module: drives and mounted volumes with free space; external drives mount / open / eject via udisks; rescans while open
- [ ] Applying a preset live (not run: desk.sh switches audio to the currently unavailable hdmi-stereo-extra2)
- [x] Check memory/CPU usage while idle and while shown
