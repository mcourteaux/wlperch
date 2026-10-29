// Unit tests for the wallpaper sets (wallpapers.odin) and thumbnails (setup_wallpapers.odin).
package main

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(test)
test_wallpaper_sets_roundtrip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	home := os.get_env("HOME", context.temp_allocator)
	text := "# comment\n" +
		"dark\t10-ab\t~/Pictures/w/castle.jpg\n" +
		"light,dark\t20-cd\t~/Pictures/w/field = day; [1].png\n" + // INI-hostile names are fine
		"\t30-ef\t~/Pictures/w/none.jpg\n" + // no mode: dropped
		"broken line\n" +
		"dark\t50-02\tno-folder.jpg\n" + // not a path: dropped
		"light\t40-01\t/srv/walls/summer.png\n"
	e := wallpaper_sets_parse(text)
	testing.expect_value(t, len(e), 3)
	testing.expect(t, e[0].dark && !e[0].light && e[0].name == "castle.jpg" && e[0].print == "10-ab")
	testing.expect_value(t, e[0].dir, strings.concatenate({home, "/Pictures/w"}))
	testing.expect(t, e[1].dark && e[1].light && e[1].name == "field = day; [1].png")
	testing.expect(t, !e[2].dark && e[2].light && e[2].dir == "/srv/walls")
	out := wallpaper_sets_format(e[:])
	testing.expect(t, strings.contains(out, "dark,light\t20-cd\t~/Pictures/w/field = day; [1].png\n"))
	testing.expect(t, strings.contains(out, "light\t40-01\t/srv/walls/summer.png\n"))
	again := wallpaper_sets_parse(out)
	testing.expect_value(t, len(again), 3)
	for x in again {
		found := false
		for y in e {if x == y {found = true}}
		testing.expect(t, found, x.name)
	}
}

@(test)
test_wallpaper_pick :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	entries := []Wallpaper_Entry {
		{dir = "/w", name = "a.jpg", dark = true},
		{dir = "/w", name = "b.jpg", dark = true, light = true},
		{dir = "/w", name = "gone.jpg", dark = true, light = true}, // not in the folder
		{dir = "/other", name = "c.png", dark = true}, // another folder's marks
		{dir = "/w", name = "c.png", light = true},
	}
	files := []string{"a.jpg", "b.jpg", "c.png", "unmarked.jpg"}
	state := rand.create(u64(42))
	gen := rand.default_random_generator(&state)

	// Never the one showing, never a missing or unmarked file, both picked over time.
	seen: map[string]int
	for _ in 0 ..< 200 {seen[wallpaper_pick(entries, "/w", files, .Dark, "a.jpg", gen)] += 1}
	testing.expect_value(t, len(seen), 1)
	testing.expect_value(t, seen["b.jpg"], 200)
	clear(&seen)
	for _ in 0 ..< 200 {seen[wallpaper_pick(entries, "/w", files, .Dark, "", gen)] += 1}
	testing.expect(t, len(seen) == 2 && seen["a.jpg"] > 0 && seen["b.jpg"] > 0)

	// The only one of the set: picked even though it shows.
	testing.expect_value(t, wallpaper_pick(entries[2:], "/w", files, .Light, "c.png", gen), "c.png")
	// An empty set: leave the wallpaper alone.
	testing.expect_value(t, wallpaper_pick(entries[:1], "/w", files, .Light, "", gen), "")
	testing.expect_value(t, wallpaper_pick(nil, "/w", files, .Dark, "", gen), "")
	testing.expect_value(t, wallpaper_pick(entries, "/other", files, .Light, "", gen), "")
}

@(test)
test_wallpaper_files_and_renames :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := fmt.tprintf("/tmp/wlperch-test-wallpapers-%d", posix.getpid())
	os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/sub.png", root)) == nil)
	write :: proc(root, name, text: string) {_ = os.write_entire_file(fmt.tprintf("%s/%s", root, name), text)}
	write(root, "b.PNG", "bbbb")
	write(root, "a.jpg", "aaaa")
	write(root, "c.jpeg", "cccc")
	write(root, "notes.txt", "x")
	write(root, ".hidden.jpg", "x")
	files := wallpaper_files(root)
	testing.expect_value(t, len(files), 3)
	testing.expect(t, files[0] == "a.jpg" && files[1] == "b.PNG" && files[2] == "c.jpeg")

	// a.jpg renamed to renamed.jpg: its entry follows by fingerprint.
	print := strings.clone(wallpaper_fingerprint(fmt.tprintf("%s/a.jpg", root)))
	testing.expect(t, strings.has_prefix(print, "4-"))
	testing.expect(t, print != wallpaper_fingerprint(fmt.tprintf("%s/b.PNG", root)))
	entries := []Wallpaper_Entry {
		{dir = root, name = "a.jpg", print = print, dark = true},
		{dir = root, name = "removed.jpg", print = "9-00", light = true},
		{dir = "/elsewhere", name = "gone.jpg", print = print, light = true}, // another folder: never moved in
	}
	testing.expect(t, !wallpaper_follow_renames(entries, root, files)) // nothing renamed yet... but removed.jpg has no match
	testing.expect(t, os.rename(fmt.tprintf("%s/a.jpg", root), fmt.tprintf("%s/renamed.jpg", root)) == nil)
	files = wallpaper_files(root)
	testing.expect(t, wallpaper_follow_renames(entries, root, files))
	testing.expect_value(t, entries[0].name, "renamed.jpg")
	testing.expect_value(t, entries[1].name, "removed.jpg") // gone: kept, skipped by the pick
	testing.expect_value(t, entries[2].name, "gone.jpg")
}

@(test)
test_wallpaper_thumb_cover :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// 400 x 100 (wider than 16:9): left quarter red, the rest blue. The crop
	// keeps the middle 178 columns, all blue.
	w, h := 400, 100
	src := make([]u8, w * h * 4)
	for y in 0 ..< h {
		for x in 0 ..< w {
			p := src[(y * w + x) * 4:]
			if x < 100 {p[0] = 255} else {p[2] = 255}
			p[3] = 255
		}
	}
	out := make([]u8, THUMB_W * THUMB_H * 4)
	wallpaper_thumb_cover(src, w, h, out)
	for i in 0 ..< THUMB_W * THUMB_H {
		if out[i * 4] != 0 || out[i * 4 + 2] != 255 || out[i * 4 + 3] != 255 {
			testing.fail_now(t, fmt.tprintf("pixel %d is %v", i, out[i * 4:i * 4 + 4]))
		}
	}
	// A tiny tall image (upscaled): no out-of-range reads, all filled.
	small := []u8{10, 20, 30, 255, 10, 20, 30, 255}
	wallpaper_thumb_cover(small, 1, 2, out)
	testing.expect(t, out[0] == 10 && out[len(out) - 4] == 10 && out[len(out) - 1] == 255)
}
