shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;

// Every piece of fire in one shader, so one canvas item draws a whole fire in one call (see fire_quad.gd).
// The integer part of UV.x picks the piece of each quad (kind * 2 + u):
//   0 band: a bed of flames over the bottom of the quad (floor flames); rgb = width / 2048, height / 512, seed;
//     a = strength. band_lean bends it.
//   1 glow: soft additive light; rgb colour, a strength.
//   4 ember: a coal at the bottom of the quad and, while fresh, a tiny flame above it; r heat, g fresh, b seed.
//   5 body: the fire around the slime body, from the body_* uniforms (one material per burning body).
// Fire only adds light (alpha near 0 under premultiplied blend); smoke covers what is behind it a little.
// The motion is all here, on TIME: noise that rises, tears tongues off and swells them; the CPU sets a few uniforms.
// Kinds 2 and 3 are free (sparks and puffs are engine particle nodes).

uniform sampler2D noise_tex : repeat_enable, filter_linear;
uniform vec4 core_color : source_color = vec4(1.0, 0.96, 0.78, 1.0);
uniform vec4 yellow_color : source_color = vec4(1.0, 0.78, 0.26, 1.0);
uniform vec4 orange_color : source_color = vec4(1.0, 0.42, 0.08, 1.0);
uniform vec4 red_color : source_color = vec4(0.62, 0.08, 0.03, 1.0);
// Thin smoke over the flame tips, premultiplied in the blend: rgb colour, a its strength.
uniform vec4 smoke_color : source_color = vec4(0.32, 0.28, 0.3, 0.2);
// Rise of the tongues in px per second, size of a tongue and of a height swell along the fire, in px.
uniform float rise_speed = 150.0;
uniform float tongue_px = 34.0;
uniform float swell_px = 90.0;
uniform float swell_speed = 0.35;
// How hard the fine noise tears the upper flame, brightness, the share of a flame that hides what is behind it.
uniform float erosion = 1.3;
uniform float flame_gain = 1.5;
uniform float flame_cover = 0.1;
// 1 adds the inner flame: a hotter, faster core (one more texture read).
uniform float inner_layer = 1.0;
uniform float inner_speed = 1.6;
uniform float glow_noise = 0.5;
uniform float glow_noise_scale = 0.003;
// Floor flames: the sideways bend at one bed height, in bed heights (the wake of the slime).
uniform float band_lean = 0.0;
// Body fire: centre and radii of the body (world px), flame height (px), lean (offset of a tip per flame height),
// strength, flicker depth, spread front (cosine of the caught angle around touch_dir), inner glow colour.
uniform vec2 body_center = vec2(0.0);
uniform vec2 body_radii = vec2(60.0);
uniform float body_flame_height = 100.0;
uniform vec2 body_lean = vec2(0.0);
uniform float body_power = 0.0;
uniform float body_wild = 0.3;
uniform float body_heat = 0.8;
uniform float body_side_reach = 0.35;
uniform float body_spread_cos = -1.0;
uniform vec2 body_touch = vec2(0.0, 1.0);
uniform vec4 body_glow : source_color = vec4(1.0, 0.5, 0.12, 0.55);
uniform float body_halo = 0.25;
// The point that caught fire flashes while the flames run from it (1 at the touch, 0 when done).
uniform float body_flash = 0.0;

// Texture repeats per feature of each noise channel: R (coarse) and G (fine), as built in fire_assets.gd.
const float COARSE_CELL = 0.25;
const float FINE_CELL = 0.13;

varying vec2 world;

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

// Black body colour of a temperature 0..1: deep red at the cool end, white-yellow at the hot end.
vec3 fire_ramp(float t) {
	vec3 c = red_color.rgb * smoothstep(0.0, 0.22, t);
	c = mix(c, orange_color.rgb, smoothstep(0.18, 0.48, t));
	c = mix(c, yellow_color.rgb, smoothstep(0.45, 0.74, t));
	return mix(c, core_color.rgb, smoothstep(0.72, 1.0, t));
}

// Flames over a surface, in px: s along it, a above it, h the local flame height, seed a noise offset, base the
// strength of the flame root there (gaps between flames). Returns the light (rgb) and how much it hides (a).
vec4 flames(float s, float a, float h, float heat, float seed, float base) {
	float v = a / max(h, 1.0);
	float t = TIME * rise_speed;
	float fine = texture(noise_tex, vec2(s / tongue_px + seed, (a - t) / (tongue_px * 1.6)) * FINE_CELL).g;
	float root = smoothstep(-0.12 * h, 0.04 * h, a) * base;
	// The noise only eats the flame, more and more toward the tip, so tongues tear off and nothing burns above h.
	float density = (1.0 - v) * root - max(fine - 0.15, 0.0) * erosion * (0.15 + v);
	float temperature = max(density, 0.0) * max(1.2 - v, 0.0) * heat;
	if (inner_layer > 0.5) {
		float core = texture(noise_tex, vec2(s / (tongue_px * 0.8) + seed + 0.5, (a - t * inner_speed) / tongue_px) * FINE_CELL).g;
		float inner = (1.0 - v * 1.8) * root - max(core - 0.15, 0.0) * erosion * (0.2 + v) * 1.3;
		temperature += max(inner, 0.0) * 0.45;
	}
	float emit = smoothstep(0.0, 0.3, max(density, temperature * 0.5));
	vec4 light = vec4(fire_ramp(clamp(temperature, 0.0, 1.0)) * emit * flame_gain, emit * flame_cover);
	// Smoke rises slower from the tips, spreads and thins out by 2.3 flame heights.
	float rise = (v - 0.7) / 1.6;
	if (rise > 0.0 && rise < 1.0) {
		float wisp = texture(noise_tex, vec2(s / (tongue_px * 2.4) + seed * 2.0, (a - t * 0.35) / (tongue_px * 2.2)) * FINE_CELL).r;
		float puff = smoothstep(0.5, 0.85, wisp + 0.15 * base) * rise * (1.0 - rise) * 4.0 * smoke_color.a;
		light += vec4(smoke_color.rgb * puff, puff);
	}
	return light;
}

void fragment() {
	float kind = floor(UV.x * 0.5 + 0.25);
	vec2 q = vec2(UV.x - kind * 2.0, UV.y);
	vec4 data = COLOR;
	if (kind < 0.5) {
		// Band: floor at 12 % of the quad height from its bottom; flames up to 1.25 bed heights.
		float width = data.r * 2048.0;
		float quad_h = data.g * 512.0;
		float bed_h = quad_h / 1.37;
		float s = q.x * width;
		float a = (1.0 - q.y) * quad_h - bed_h * 0.12;
		// The wake of the slime bends the bed: a point at height a comes from a root further back.
		s -= band_lean * max(a, 0.0) * max(a, 0.0) / bed_h;
		float swell = texture(noise_tex, vec2(s / swell_px + data.b * 7.0, TIME * swell_speed) * COARSE_CELL).r;
		float end = smoothstep(0.0, 0.22, min(q.x, 1.0 - q.x));
		float h = bed_h * (0.4 + 0.9 * swell) * mix(0.35, 1.0, end);
		vec4 fire = flames(s, a, h, mix(0.6, 1.0, end), data.b * 3.0, 1.0) * smoothstep(0.0, 0.08, min(q.x, 1.0 - q.x));
		// The coal bed: a hot strip at the floor that breathes with the swell.
		float coal = smoothstep(-0.14 * bed_h, -0.02 * bed_h, a) * smoothstep(0.1 * bed_h, 0.0, a) * end * (0.55 + 0.6 * swell);
		COLOR = vec4((fire.rgb + fire_ramp(0.55 + 0.3 * swell) * coal) * data.a, fire.a * data.a);
	} else if (kind < 1.5) {
		vec2 p = (q - 0.5) * 2.0;
		float g = max(1.0 - dot(p, p), 0.0);
		g *= g;
		float n = texture(noise_tex, world * glow_noise_scale + vec2(0.0, TIME * 0.5)).r;
		g *= mix(1.0, 0.35 + n * 1.3, glow_noise);
		COLOR = vec4(data.rgb * g * data.a, 0.0);
	} else if (kind < 4.5) {
		// Ember: the coal sits at 82 % of the quad height; the quad is 7 coal radii wide and 12 tall.
		// r heat (life share), g fresh (tiny flame and smoke), b seed.
		vec2 p = (q - vec2(0.5, 0.82)) * vec2(7.0, 12.0);
		float r2 = dot(p, p);
		float pulse = 0.82 + 0.1 * sin(TIME * 7.1 + data.b * 40.0) + 0.08 * sin(TIME * 12.3 + data.b * 17.0);
		float heat = data.r * pulse;
		// Both lights of the coal reach zero inside the quad, so its edges never show.
		float core = max(1.0 - r2 / 4.4, 0.0) / (1.0 + r2 * 2.2);
		// The halo ends at 2 coal radii: the quad bottom is only 2.16 radii under the coal.
		float halo = max(1.0 - r2 / 4.0, 0.0);
		vec3 light = fire_ramp(heat * 0.95) * (core * 1.4 + halo * halo * 0.5) * (0.35 + 0.65 * heat);
		float smoke = 0.0;
		if (data.g > 0.01) {
			// The tiny flame of a fresh ember, one tongue over the coal, and a thread of smoke above it.
			float v = (0.82 - q.y) / 0.42;
			float x = (q.x - 0.5) * 2.0;
			float n = texture(noise_tex, vec2(q.x * 0.6 + data.b * 9.0, q.y * 1.2 + TIME * 2.2) * FINE_CELL).g;
			x += (n - 0.5) * 0.8 * clamp(v, 0.0, 2.0);
			float body = 1.0 - abs(x) / ((1.0 - clamp(v, 0.0, 1.0)) * 0.45 + 0.02);
			float density = body * smoothstep(-0.05, 0.12, v) - max(v, 0.0) * (0.6 + n * 0.8) * (1.4 - data.g);
			float emit = smoothstep(0.0, 0.25, density);
			light += fire_ramp(clamp(density * 1.4 * data.g, 0.0, 1.0)) * emit * flame_gain * data.g;
			float column = max(1.0 - abs(x) * 3.0, 0.0) * smoothstep(0.7, 1.2, v) * smoothstep(2.0, 1.4, v);
			smoke = column * smoothstep(0.35, 0.75, n) * smoke_color.a * data.g;
		}
		COLOR = vec4((light + smoke_color.rgb * smoke) * data.a, smoke * data.a);
	} else {
		// Body: flames over the upper surface of the slime, bent by the lean, with the light inside the gelatin.
		// The air bends the flames: a point at height y over the body top comes from a root further back, by the
		// lean times y squared over the flame height, so the flames curve away from the motion.
		vec2 p = world - body_center;
		float r_mean = 0.5 * (body_radii.x + body_radii.y);
		float sx = clamp(p.x / body_radii.x, -1.0, 1.0);
		float above = max(-body_radii.y * sqrt(1.0 - sx * sx) - p.y, 0.0);
		vec2 pb = vec2(p.x - body_lean.x * above * above / max(body_flame_height, 1.0), p.y);
		vec2 dir = pb / body_radii;
		float rr = length(dir);
		dir /= max(rr, 0.001);
		float a = (rr - 1.0) * r_mean;
		float top = clamp(-dir.y + body_side_reach, 0.0, 1.0);
		float caught = clamp((dot(dir, body_touch) - body_spread_cos) * 2.5, 0.0, 1.0);
		float swell = texture(noise_tex, vec2(pb.x / swell_px + 0.37, TIME * swell_speed * 1.6) * COARSE_CELL).r;
		float h = body_flame_height * (1.0 - body_wild + 2.0 * body_wild * swell) * mix(0.2, 1.0, top * top) * caught;
		vec4 fire = flames(pb.x, a, h, body_heat, 0.71, smoothstep(0.15, 0.65, swell)) * caught * smoothstep(0.0, 0.25, top);
		float inside = max(1.0 - rr * rr, 0.0);
		// A warm rim of light in the air over the upper body; it fades out well inside the quad.
		float outside = max(1.0 - a / (body_flame_height * 0.45), 0.0) * step(0.0, a) * smoothstep(0.0, 0.6, top);
		vec3 glow = body_glow.rgb * body_glow.a * (inside * (0.75 + 0.5 * swell) + outside * outside * body_halo);
		vec2 from_touch = dir * min(rr, 1.0) - body_touch;
		float flash = body_flash * max(1.0 - dot(from_touch, from_touch) * 1.6, 0.0);
		COLOR = vec4((fire.rgb + glow + core_color.rgb * flash * flash) * body_power, fire.a * body_power);
	}
}
