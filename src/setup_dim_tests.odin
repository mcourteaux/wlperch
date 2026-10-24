// Unit tests for the setup window's dim (setup_dim.odin): the pieces around
// the hole.
package main

import "core:testing"

@(test)
test_dim_layout :: proc(t: ^testing.T) {
	// No hole on this output: one band covers it.
	p := dim_layout(1920, 1080, {}, false, 18)
	testing.expect_value(t, p[0], Dim_Rect{0, 0, 1920, 1080})
	for i in 1 ..< 8 {testing.expect_value(t, p[i], Dim_Rect{})}
	// A hole wholly on another output: the same.
	p = dim_layout(1920, 1080, {2000, 100, 400, 300}, true, 18)
	testing.expect_value(t, p[0], Dim_Rect{0, 0, 1920, 1080})

	// A card in the middle: four bands that tile the rest, corners inside it.
	p = dim_layout(1920, 1080, {100, 200, 800, 600}, true, 18)
	testing.expect_value(t, p[0], Dim_Rect{0, 0, 1920, 200})     // above
	testing.expect_value(t, p[1], Dim_Rect{0, 800, 1920, 280})   // below
	testing.expect_value(t, p[2], Dim_Rect{0, 200, 100, 600})    // left
	testing.expect_value(t, p[3], Dim_Rect{900, 200, 1020, 600}) // right
	testing.expect_value(t, p[4], Dim_Rect{100, 200, 18, 18})
	testing.expect_value(t, p[5], Dim_Rect{882, 200, 18, 18})
	testing.expect_value(t, p[6], Dim_Rect{100, 782, 18, 18})
	testing.expect_value(t, p[7], Dim_Rect{882, 782, 18, 18})
	area: i32
	for r in p[:4] {area += r.w * r.h}
	testing.expect_value(t, area, 1920 * 1080 - 800 * 600)

	// Square (tiled / server-side decorated): no corners.
	p = dim_layout(1920, 1080, {100, 200, 800, 600}, true, 0)
	for i in 4 ..< 8 {testing.expect_value(t, p[i], Dim_Rect{})}

	// Spanning to the next output on the right: no band right of it, and
	// only the corners on this side.
	p = dim_layout(1920, 1080, {1600, 100, 800, 600}, true, 18)
	testing.expect_value(t, p[2], Dim_Rect{0, 100, 1600, 600})
	testing.expect_value(t, p[3], Dim_Rect{})
	testing.expect_value(t, p[4], Dim_Rect{1600, 100, 18, 18})
	testing.expect_value(t, p[5], Dim_Rect{})
	testing.expect_value(t, p[7], Dim_Rect{})
	// ... and seen from that output (the hole starts left of it).
	p = dim_layout(2560, 1440, {1600 - 1920, 100, 800, 600}, true, 18)
	testing.expect_value(t, p[2], Dim_Rect{})
	testing.expect_value(t, p[3], Dim_Rect{480, 100, 2080, 600})
	testing.expect_value(t, p[4], Dim_Rect{})
	testing.expect_value(t, p[5], Dim_Rect{462, 100, 18, 18})

	// Filling the output (e.g. the whole height): no zero-sized bands.
	p = dim_layout(1920, 1080, {0, 0, 1920, 1080}, true, 0)
	for r in p {testing.expect_value(t, r, Dim_Rect{})}
}

@(test)
test_dim_alpha :: proc(t: ^testing.T) {
	testing.expect_value(t, dim_alpha(40, false), 0.4)
	testing.expect(t, dim_alpha(40, true) < dim_alpha(40, false))
}
