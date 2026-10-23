# wlwidgets — TODO

Legend: `[x]` done · `[ ]` open · `[~]` partially done / needs polish

## Infrastructure
- [ ] Build script (`build.sh`): fetch + build odin-imgui (opengl3 backend), generate wayland bindings, build app
- [ ] Odin wayland-scanner (`tools/wlscan`) generating bindings from protocol XML
- [ ] Hand-written libwayland-client core bindings (display, proxy, marshal)
- [ ] Protocols: wayland core, xdg-shell, wlr-layer-shell, cursor-shape (+ stubs)
- [ ] EGL + OpenGL 3.3 core context on a wl_egl_window, transparent background
- [ ] xkbcommon bindings for keyboard (keysyms, utf8 text)
- [ ] Dear ImGui platform layer for Wayland (pointer, scroll, keyboard, text, cursor shapes)
- [ ] Event loop: poll(wayland fd, wake eventfd, control socket, timer); idle CPU ≈ 0 when hidden
- [ ] Single-instance daemon + control socket: `wlwidgets toggle|show|hide|quit`
- [ ] Layer-shell popup (overlay, anchored top-right by default, configurable) on focused output
- [ ] Hide on Escape and on focus loss (keyboard leave)
- [ ] Auto-size popup height to content
- [ ] HiDPI: integer buffer scale (wl_surface.preferred_buffer_scale / output scale)
- [ ] Config file `~/.config/wlwidgets/config.ini` with defaults written on first run
- [ ] Background sampler threads; UI reads snapshots under mutex
- [ ] Safe subprocess helper (posix_spawn, captured stdout, timeouts)

## Look & feel
- [ ] Embedded fonts (Inter UI, JetBrains Mono digits, Nerd Font symbols for icons)
- [ ] Custom dark theme: rounded card panels, accent colors, subtle borders
- [ ] Soft drop-shadow + rounded transparent window corners
- [ ] Custom widgets: section card, pill toggle switch, sparkline/area graphs, chips
- [ ] Two-column layout that reads well at a glance

## Widgets
### Audio
- [ ] List output sinks, select default (pactl set-default-sink) + move streams
- [ ] List input sources (exclude monitors), select default
- [ ] Volume sliders + mute for default sink/source
- [ ] HDMI card profiles: list per card, switch profile (pactl set-card-profile)
- [ ] Resolve HDMI profile → port → ELD monitor name → sway output connector (e.g. DP-1)
- [ ] Mark unavailable profiles (no monitor plugged)
- [ ] Live refresh via `pactl subscribe`

### Night light
- [ ] Show wlsunset running state
- [ ] Toggle wlsunset on/off (configurable args)

### System
- [ ] CPU % history graph (/proc/stat), current %, per-core mini bars
- [ ] GPU % history graph (NVML via dlopen; AMD sysfs `gpu_busy_percent` fallback), VRAM + temperature
- [ ] Keep history sampling while popup is hidden

### Keyboard
- [ ] Show active xkb layout (sway IPC get_inputs)
- [ ] Switch layout (sway IPC `input type:keyboard xkb_switch_layout N`)

### Weather
- [ ] Configurable location (name → geocoding, or lat/lon)
- [ ] Today's forecast via open-meteo: current temp, hi/lo, condition icon, hourly strip, precipitation
- [ ] Cache + refresh every 15 min; error state

### Clocks
- [ ] List of configurable timezones (IANA names + label), local time highlighted
- [ ] Day offset indicator (+1 / −1 day) and UTC offset

### Network
- [ ] Public IP (configurable URL, refresh 10 min, click to copy)
- [ ] Internal IPs per interface (getifaddrs), skip loopback/virtual by config
- [ ] Copy to clipboard (wl-copy)

### Bluetooth
- [ ] Connected devices via org.bluez (busctl JSON)
- [ ] Battery % via org.bluez.Battery1, fallback to UPower
- [ ] Device-type icons

### Displays
- [ ] Visual screen layout from sway IPC get_outputs (scaled rects, names, resolution, rotation)
- [ ] Discover preset scripts (desk.sh and siblings), parse their sway `output` lines for preview
- [ ] Drop-down list of presets with mini layout preview, apply runs the script
- [ ] Highlight currently active preset (compare to current layout)

## Integration & docs
- [ ] Waybar custom module snippet + sway keybinding snippet in README
- [ ] README with build/run/config instructions
- [ ] Test: run under sway, screenshot (grim) and verify each widget
- [ ] Check memory/CPU usage while idle and while shown
