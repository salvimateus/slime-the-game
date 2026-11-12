shader_type canvas_item;
// Goo iris: a dark cover with a round hole whose edge wobbles and carries a thin goo rim.

uniform vec2 center = vec2(0.5);
uniform float radius = 1.5;
uniform vec4 color : source_color = vec4(0.03, 0.04, 0.07, 1.0);
uniform vec4 rim_color : source_color = vec4(0.65, 0.84, 0.24, 1.0);
uniform vec4 rim_dark : source_color = vec4(0.31, 0.37, 0.14, 1.0);
uniform float rim_width = 0.022;
// Ring mesh (screen_fx.gd): the mesh skips the open hole, which the iris leaves untouched. UV.x is the angle of a
// vertex in turns and UV.y is 0 on the inner circle and 1 far outside the screen. Off: a full-screen rect.
uniform bool ring_mesh = false;
uniform vec2 screen_size = vec2(1280.0, 720.0);
// Below the smallest wobble of the edge, so the hole of the mesh never cuts into the cover.
const float HOLE_MARGIN = 0.021;
const float FAR_RADIUS = 8.0;

varying vec2 screen_uv;

void vertex() {
	screen_uv = UV;
	if (ring_mesh) {
		float a = UV.x * TAU;
		vec2 dir = vec2(cos(a), sin(a));
		float r = UV.y < 0.5 ? clamp(radius - HOLE_MARGIN, 0.0, FAR_RADIUS * 0.99) : FAR_RADIUS;
		vec2 aspect = vec2(screen_size.x / max(screen_size.y, 1.0), 1.0);
		screen_uv = center + dir * r / aspect;
		VERTEX = screen_uv * screen_size;
	}
}

void fragment() {
	vec2 size = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 d = (screen_uv - center) * vec2(size.x / size.y, 1.0);
	float ang = atan(d.y, d.x);
	float wobble = 0.012 * sin(ang * 7.0 + TIME * 3.0) + 0.008 * sin(ang * 13.0 - TIME * 5.0);
	float dist = length(d) - (radius + wobble);
	float px = SCREEN_PIXEL_SIZE.y * 1.5;
	float cover = smoothstep(0.0, px, dist);
	float rim = 1.0 - smoothstep(rim_width - px, rim_width, dist);
	vec3 goo = mix(rim_color.rgb, rim_dark.rgb, clamp(dist / rim_width, 0.0, 1.0));
	vec3 col = mix(color.rgb, goo, rim);
	COLOR = vec4(col, cover * color.a);
}
