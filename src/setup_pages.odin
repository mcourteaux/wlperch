// The setup window's pages: a sidebar of categories, each holding the
// components to install (cards) and the settings groups that belong to them,
// so a feature is set up and configured in one place.
package main

import "core:strings"

Setup_Page :: enum {Overview, Basics, Bar, Look, Lock, Notifications, Launcher, Time, Ssh}

Page_Info :: struct {
	name:   string, // `wlperch setup <name>`
	title:  string,
	sub:    string, // under the title
	icon:   string,
	comps:  []Comp_Id,
	groups: []string, // SETTINGS_GROUPS shown on the page
}

SETUP_PAGES := [Setup_Page]Page_Info {
	.Overview      = {"overview", "Overview", "What's set up, what needs a look, and updates.", ICON_HOME, {}, {}},
	.Basics        = {"basics", "Basics", "The program, its background service, the settings file and sway's part.", ICON_TUNE, {.Program, .Service, .Config, .Sway, .Launcher}, {"Updates", "Setup window"}},
	.Bar           = {"bar", "Bar & panels", "wlperch's bar or waybar's buttons, and what the panels show.", ICON_MONITORS, {.Bar, .Waybar, .Rapl}, {"Bar", "Panel", "Clock and weather", "Memory", "GitHub"}},
	.Look          = {"look", "Look", "Dark and light, Neovim, GTK apps and the wallpapers.", ICON_THEME, {.Theme, .Nvim, .Portal, .Wallpaper}, {"Wallpapers", "Dark theme", "Light theme"}},
	.Lock          = {"lock", "Lock & idle", "The lock screen, locking on idle and turning the monitors off.", ICON_LOCK, {.Lock, .Idle}, {"Idle lock", "Lock screen", "Lock screen info"}},
	.Notifications = {"notifications", "Notifications", "Popups, their history and do not disturb.", ICON_BELL, {.Notifications}, {"Notifications"}},
	.Launcher      = {"launcher", "Launcher", "Apps, a calculator, emoji and commands as you type.", ICON_APPS, {.Menu}, {"Launcher"}},
	.Time          = {"time", "Time tracking", "Hours per project, breaks and Claude's background work.", ICON_PROGRESS_CLOCK, {}, {"Time tracking"}},
	.Ssh           = {"ssh", "SSH keys", "OpenSSH's agent, for the SSH keys panel and the bar's key icon.", ICON_KEY, {.Ssh}, {"SSH keys"}},
}

// The page's colour (theme colours are variables: not in the table).
page_accent :: proc(p: Setup_Page) -> u32 {
	switch p {
	case .Overview, .Basics: return C_BLUE
	case .Bar:               return C_TEAL
	case .Look:              return C_YELLOW
	case .Lock:              return C_PURPLE
	case .Notifications:     return C_YELLOW
	case .Launcher, .Time:   return C_GREEN
	case .Ssh:               return C_YELLOW
	}
	return C_BLUE
}

setup_page: Setup_Page
// The search box in the sidebar (all pages).
setup_search: [128]u8
// Open Look scrolled to the wallpapers (`wlperch setup wallpapers`).
setup_scroll_wallpapers: bool

// The page a component's card is on.
comp_page :: proc(id: Comp_Id) -> Setup_Page {
	for p in Setup_Page {for c in SETUP_PAGES[p].comps {if c == id {return p}}}
	return .Overview
}

// The page a settings group is on.
group_page :: proc(group: string) -> Setup_Page {
	for p in Setup_Page {for g in SETUP_PAGES[p].groups {if g == group {return p}}}
	return .Overview
}

// `wlperch setup <name>`: a page name, or one of the old tab names.
setup_page_parse :: proc(name: string) -> (page: Setup_Page, wallpapers: bool, ok: bool) {
	n := strings.to_lower(strings.trim_space(name), context.temp_allocator)
	for p in Setup_Page {if SETUP_PAGES[p].name == n {return p, false, true}}
	switch n {
	case "components", "home":       return .Overview, false, true
	case "settings":                 return .Basics, false, true
	case "wallpapers", "wallpaper":  return .Look, true, true
	case "theme", "themes":          return .Look, false, true
	case "panels", "panel", "waybar": return .Bar, false, true
	case "idle", "screen":           return .Lock, false, true
	case "menu", "apps":             return .Launcher, false, true
	case "timetracker", "tracker", "hours": return .Time, false, true
	case "keys", "ssh-agent":        return .Ssh, false, true
	}
	return .Overview, false, false
}

// The search text, lowercased ("" when empty).
setup_search_filter :: proc() -> string {
	return strings.to_lower(strings.trim_space(string(cstring(raw_data(setup_search[:])))), context.temp_allocator)
}
