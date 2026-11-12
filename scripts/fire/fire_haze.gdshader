shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Heat shimmer over a flame: the quad (UV.y 1 at the flame, 0 at the top) bends the screen behind it with a
// noise that rises. The bend fades to zero at every edge, so the quad has no seam. Vertex alpha is the strength.
// The screen is read from the copy that the BackBufferCopy of fire_shimmer.gd makes just before this item.

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform sampler2D noise_tex : repeat_enable, filter_linear;
// Largest bend in screen pixels, the noise scale in world pixels and its rise speed.
uniform float bend_px = 5.0;
uniform float noise_scale = 0.01;
uniform float rise_speed = 0.9;

varying vec2 world;

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec2 edge = min(UV, 1.0 - UV) * 2.0;
	float mask = smoothstep(0.0, 1.0, edge.x) * smoothstep(0.0, 0.6, edge.y) * (0.5 + UV.y * 0.5) * COLOR.a;
	vec2 n = texture(noise_tex, world * noise_scale + vec2(0.0, TIME * rise_speed)).rg - 0.5;
	vec2 uv = clamp(SCREEN_UV + n * mask * bend_px * SCREEN_PIXEL_SIZE * 2.0, vec2(0.0), vec2(1.0));
	COLOR = vec4(texture(screen_tex, uv).rgb, 1.0);
}
