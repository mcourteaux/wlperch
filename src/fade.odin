// Open animation: the frame is premultiplied, so scaling every channel by a
// constant fades the whole popup (including custom-drawn text) uniformly.
package main

import gl "vendor:OpenGL"

@(private = "file")
fade_program: u32
@(private = "file")
fade_vao: u32

@(private = "file")
FADE_VS :: `#version 330 core
void main() {
	// Fullscreen triangle.
	vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
	gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`

@(private = "file")
FADE_FS :: `#version 330 core
out vec4 color;
void main() { color = vec4(0.0); }`

fade_apply :: proc(alpha: f32) {
	if fade_program == 0 {
		ok: bool
		fade_program, ok = gl.load_shaders_source(FADE_VS, FADE_FS)
		if !ok {return}
		gl.GenVertexArrays(1, &fade_vao)
	}
	gl.UseProgram(fade_program)
	gl.BindVertexArray(fade_vao)
	gl.Enable(gl.BLEND)
	gl.Disable(gl.SCISSOR_TEST)
	gl.BlendColor(0, 0, 0, alpha)
	gl.BlendFuncSeparate(gl.ZERO, gl.CONSTANT_ALPHA, gl.ZERO, gl.CONSTANT_ALPHA)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.BindVertexArray(0)
	gl.UseProgram(0)
}

// GL objects die with the context (see gl_down / re-exec).
fade_reset :: proc() {
	if fade_program != 0 {
		gl.DeleteProgram(fade_program)
		gl.DeleteVertexArrays(1, &fade_vao)
	}
	fade_program, fade_vao = 0, 0
}
