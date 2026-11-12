shader_type canvas_item;

uniform float strength = 0.35;
uniform float danger = 0.0;
uniform vec4 danger_color : source_color = vec4(0.75, 0.08, 0.12, 1.0);
// Ring mesh (screen_fx.gd): the mesh skips the clear centre, where the vignette adds nothing. UV.x is the angle of a
// vertex in turns and UV.y is 0 on the inner ellipse and 1 far outside the screen. Off: a full-screen rect.
uniform bool ring_mesh = false;
uniform vec2 screen_size = vec2(1280.0, 720.0);

varying vec2 screen_uv;

float inner_radius() {
	// Danger pulls the dark ring inward, so the pulse reads as the screen closing in.
	return 0.35 - danger * 0.12;
}

void vertex() {
	screen_uv = UV;
	if (ring_mesh) {
		float a = UV.x * TAU;
		vec2 dir = vec2(cos(a), sin(a));
		// The inner vertices sit on the ellipse where the vignette is zero, so every chord between them stays inside it.
		vec2 off = UV.y < 0.5 ? dir * inner_radius() / vec2(1.0, 0.8) : dir * 2.0;
		screen_uv = 0.5 + off;
		VERTEX = screen_uv * screen_size;
	}
}

void fragment() {
	vec2 d = (screen_uv - 0.5) * vec2(1.0, 0.8);
	float v = smoothstep(inner_radius(), 0.85, length(d));
	COLOR = vec4(mix(vec3(0.0), danger_color.rgb, danger), v * (strength + danger * 0.55));
}
