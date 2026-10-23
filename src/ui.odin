package main

import im "third_party:odin-imgui"

last_content_height: i32

on_show :: proc() {}
on_hide :: proc() {}
services_start :: proc() {}

draw_ui :: proc() -> f32 {
	io := im.GetIO()
	im.SetNextWindowPos({0, 0})
	im.SetNextWindowSize(io.DisplaySize)
	im.PushStyleColorImVec4(.WindowBg, rgba(C_BG, 0.97))
	im.Begin("main", nil, {.NoTitleBar, .NoResize, .NoScrollbar, .NoCollapse, .NoMove, .NoSavedSettings})
	im.PopStyleColor()
	im.PushFontFloat(fonts.bold, SZ_BIG)
	im.Text("wlwidgets      ")
	im.PopFont()
	im.Text("Hello from Odin over raw Wayland + EGL")
	im.End()
	return 600
}
