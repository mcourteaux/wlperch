// Lock screen "blur" background, animated ([lock] blur_animate_ms): the
// frosted screenshot starts (nearly) sharp and its blur grows to the static
// strength. Each frame blurs the previous frame's result a little more
// instead of starting over: blurring a blurred image composes, the variances
// add up. The work happens on a small copy (the screen reduced D x D),
// kept at 16 bits per channel so hundreds of passes don't drift.
//
// Each step is one generalised box pass per axis (ping-pong between two
// buffers): 2r+1 taps of weight 1 plus one of weight f at either end, so any
// variance can be added, not just the r(r+1)/3 steps of a plain box. Many
// passes in a row add up to a Gaussian. Once the blur is wide enough the copy
// is halved (variance / 4), so the later frames get cheaper.
//
// The effective blur is tracked in native pixels²: a D x D box reduction
// adds (D²-1)/12, the passes D²·v, and the bilinear upscale about D²/6.
// The animation eases that sigma from the start to what the static copy
// (lock_reduce_and_blur) shows; the last frame is the static picture itself.
package main

import "core:math"

Blur_Anim :: struct {
	planes: [2][]u16, // R, G and B planes of w*h each, value << 8
	cur:    int, // which of planes holds the picture
	w, h:   int,
	D:      int, // native pixels per working pixel
	D_max:  int, // the static copy's reduction: halve no further
	v:      f64, // blur variance applied so far, in working pixels²
	s0, s1: f64, // effective sigma (native px) at the start and at the end
	s:      f64, // effective sigma now
	bias:   [3]f64, // static copy's mean minus the source's, per channel (levels)
	small:  []u32, // packed 0x00RRGGBB copy, for drawing
}

// What lock_reduce_and_blur hands the animation: the unblurred reduction and
// the static copy's parameters.
Blur_Anim_Source :: struct {
	img:      Blur_Image, // reduced D x D, oriented, not blurred
	D:        int,
	D_static: int,
	s_from:   f64, // sigma the animation starts at (native px)
	s_static: f64, // effective sigma of the static copy (native px)
	bias:     [3]f64, // the static copy's mean minus img's, per channel
}

// Effective sigma² of a picture reduced D x D and blurred by v working px²,
// as shown after the bilinear upscale.
blur_anim_shown_var :: proc(D: int, v: f64) -> f64 {
	d2 := f64(D * D)
	return (d2 - 1) / 12 + d2 * v + d2 / 6
}

// Takes over src.img's pixels (and frees them).
blur_anim_init :: proc(src: Blur_Anim_Source) -> (a: Blur_Anim) {
	img := src.img
	defer delete(img.px)
	n := img.w * img.h
	a.w, a.h, a.D, a.D_max = img.w, img.h, src.D, max(src.D_static, src.D)
	a.planes = {make([]u16, 3 * n), make([]u16, 3 * n)}
	a.small = make([]u32, n)
	p := a.planes[0]
	for c, i in img.px {
		p[i] = u16((c >> 16) & 0xff) << 8
		p[n + i] = u16((c >> 8) & 0xff) << 8
		p[2 * n + i] = u16(c & 0xff) << 8
	}
	a.s0 = max(src.s_from, math.sqrt(blur_anim_shown_var(a.D, 0)))
	a.s1 = max(src.s_static, a.s0)
	a.bias = src.bias
	blur_anim_step(&a, a.s0)
	return
}

blur_anim_free :: proc(a: ^Blur_Anim) {
	delete(a.planes[0])
	delete(a.planes[1])
	delete(a.small)
	a^ = {}
}

// Sigma at progress p (0..1): ease-out cubic, fast at first, settling softly.
blur_anim_sigma_at :: proc(a: ^Blur_Anim, p: f64) -> f64 {
	q := 1 - clamp(p, 0, 1)
	return a.s0 + (a.s1 - a.s0) * (1 - q * q * q)
}

// Blurs the copy further until it shows sigma s (never less blur than now).
blur_anim_step :: proc(a: ^Blur_Anim, s: f64) {
	// Halve once the blur spans a few working pixels: a 2x2 average then
	// loses nothing visible, and v scales by exactly 1/4.
	for a.D * 2 <= a.D_max && a.v >= 9 && a.w >= 8 && a.h >= 8 {
		src, dst := a.planes[a.cur], a.planes[1 - a.cur]
		w2, h2 := a.w / 2, a.h / 2
		for c in 0 ..< 3 {
			sp, dp := src[c * a.w * a.h:], dst[c * w2 * h2:]
			for y in 0 ..< h2 {
				r0, r1 := sp[2 * y * a.w:], sp[(2 * y + 1) * a.w:]
				o := dp[y * w2:]
				#no_bounds_check for x in 0 ..< w2 {
					o[x] = u16((u32(r0[2 * x]) + u32(r0[2 * x + 1]) + u32(r1[2 * x]) + u32(r1[2 * x + 1]) + 2) >> 2)
				}
			}
		}
		a.cur = 1 - a.cur
		a.w, a.h, a.D, a.v = w2, h2, a.D * 2, a.v / 4
	}
	a.s = max(a.s, s)
	d2 := f64(a.D * a.D)
	target := (s * s - d2 / 6 - (d2 - 1) / 12) / d2
	dv := target - a.v
	if dv < 0.01 {return}
	// A pass much wider than the blur so far would show its box shape:
	// split those (only the first frames from a sharp start).
	n := clamp(int(math.ceil(dv / max(a.v, 0.5))), 1, 3)
	for _ in 0 ..< n {blur_anim_pass(a, dv / f64(n))}
	a.v = target
}

// One pass per axis adding variance dv: plane -> other plane (horizontal),
// and back (vertical).
@(private = "file")
blur_anim_pass :: proc(a: ^Blur_Anim, dv: f64) {
	// Box of 2r+1 ones has variance r(r+1)/3; ends of weight f in between.
	r := int((math.sqrt(1 + 12 * dv) - 1) / 2)
	rf := f64(r)
	f := (2 * rf + 1) * (dv - rf * (rf + 1) / 3) / (2 * (rf + 1) * (rf + 1) - 2 * dv)
	fq := u64(clamp(math.round(f * 256), 0, 256))
	wq := u64(2 * r + 1) * 256 + 2 * fq
	rec := ((u64(1) << 32) + wq / 2) / wq
	n := a.w * a.h
	src, dst := a.planes[a.cur], a.planes[1 - a.cur]
	pad := make([]u16, a.w + 2 * r + 2, context.temp_allocator)
	sum := make([]u32, a.w, context.temp_allocator)
	for c in 0 ..< 3 {
		hpass(src[c * n:][:n], dst[c * n:][:n], a.w, a.h, r, fq, rec, pad)
		vpass(dst[c * n:][:n], src[c * n:][:n], a.w, a.h, r, fq, rec, sum)
	}
}

@(private = "file")
weigh :: #force_inline proc "contextless" (s: u64, edges: u64, fq, rec: u64) -> u16 {
	return u16(min((((s << 8) + fq * edges) * rec + (1 << 31)) >> 32, 0xffff))
}

@(private = "file")
hpass :: proc(src, dst: []u16, w, h, r: int, fq, rec: u64, pad: []u16) {
	for y in 0 ..< h {
		row := src[y * w:][:w]
		out := dst[y * w:][:w]
		// Edges clamped: the row with r+1 copies of its end pixels either side.
		for i in 0 ..= r {pad[i] = row[0]; pad[w + r + 1 + i] = row[w - 1]}
		copy(pad[r + 1:], row)
		s: u64
		for i in 1 ..= 2 * r + 1 {s += u64(pad[i])}
		#no_bounds_check for x in 0 ..< w {
			i := x + r + 1
			out[x] = weigh(s, u64(pad[i - r - 1]) + u64(pad[i + r + 1]), fq, rec)
			s += u64(pad[i + r + 1])
			s -= u64(pad[i - r])
		}
	}
}

// Row by row with a running column sum, so every access is sequential.
@(private = "file")
vpass :: proc(src, dst: []u16, w, h, r: int, fq, rec: u64, sum: []u32) {
	row :: #force_inline proc(src: []u16, w, h, y: int) -> []u16 {return src[clamp(y, 0, h - 1) * w:][:w]}
	for &s in sum {s = 0}
	for j in -r ..= r {
		p := row(src, w, h, j)
		for x in 0 ..< w {sum[x] += u32(p[x])}
	}
	for y in 0 ..< h {
		pa, pb, pc := row(src, w, h, y - r - 1), row(src, w, h, y + r + 1), row(src, w, h, y - r)
		out := dst[y * w:][:w]
		#no_bounds_check for x in 0 ..< w {
			out[x] = weigh(u64(sum[x]), u64(pa[x]) + u64(pb[x]), fq, rec)
			sum[x] = sum[x] + u32(pb[x]) - u32(pc[x])
		}
	}
}

// The current picture, packed for blur_draw / blur_draw_fast (valid until the next step).
blur_anim_image :: proc(a: ^Blur_Anim) -> Blur_Image {
	n := a.w * a.h
	p := a.planes[a.cur]
	// The brightness shift toward the static copy, by how far the blur got.
	k := a.s1 > a.s0 ? (a.s - a.s0) / (a.s1 - a.s0) : 1
	off: [3]i32
	for c in 0 ..< 3 {off[c] = i32(math.round(a.bias[c] * k * 256)) + 128}
	#no_bounds_check for i in 0 ..< n {
		r := u32(clamp((i32(p[i]) + off[0]) >> 8, 0, 255))
		g := u32(clamp((i32(p[n + i]) + off[1]) >> 8, 0, 255))
		b := u32(clamp((i32(p[2 * n + i]) + off[2]) >> 8, 0, 255))
		a.small[i] = r << 16 | g << 8 | b
	}
	return {a.small[:n], a.w, a.h}
}
