// Unit tests for the setup window's pages (setup_pages.odin).
package main

import "core:testing"

// Every component card and every settings group is on exactly one page, and
// every setting's group is one of the listed groups.
@(test)
test_setup_pages_cover_everything :: proc(t: ^testing.T) {
	for id in Comp_Id {
		n := 0
		for p in Setup_Page {for c in SETUP_PAGES[p].comps {if c == id {n += 1}}}
		testing.expectf(t, n == 1, "component %v is on %d pages", id, n)
	}
	for g in SETTINGS_GROUPS {
		n := 0
		for p in Setup_Page {for pg in SETUP_PAGES[p].groups {if pg == g {n += 1}}}
		testing.expectf(t, n == 1, "settings group %q is on %d pages", g, n)
	}
	for p in Setup_Page {
		for pg in SETUP_PAGES[p].groups {
			known := false
			for g in SETTINGS_GROUPS {if g == pg {known = true}}
			testing.expectf(t, known, "page %v lists unknown group %q", p, pg)
		}
	}
	for s in SETTINGS {
		testing.expectf(t, group_page(s.group) != .Overview, "[%s] %s: group %q has no page", s.section, s.key, s.group)
	}
	testing.expect(t, len(SETUP_PAGES[.Overview].comps) == 0 && len(SETUP_PAGES[.Overview].groups) == 0)
	testing.expect_value(t, comp_page(.Idle), Setup_Page.Lock)
	testing.expect_value(t, group_page("Dark theme"), Setup_Page.Look)
}

// `wlperch setup <name>`: page names, the old tab names, and nothing else.
@(test)
test_setup_page_parse :: proc(t: ^testing.T) {
	for p in Setup_Page {
		got, wp, ok := setup_page_parse(SETUP_PAGES[p].name)
		testing.expect(t, ok && got == p && !wp)
	}
	got, wp, ok := setup_page_parse("components")
	testing.expect(t, ok && got == .Overview && !wp)
	got, wp, ok = setup_page_parse("settings")
	testing.expect(t, ok && got == .Basics && !wp)
	got, wp, ok = setup_page_parse("Wallpapers")
	testing.expect(t, ok && got == .Look && wp)
	got, wp, ok = setup_page_parse("idle")
	testing.expect(t, ok && got == .Lock)
	_, _, ok = setup_page_parse("nonsense")
	testing.expect(t, !ok)
}
