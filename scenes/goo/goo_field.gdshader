shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;

// The CanvasGroup children add a scalar field into R; G and B carry the hue of each source (see GooMath.source_color).
// This pass thresholds it into one surface and shades it as translucent gelatin: lime where the light hits,
// moss in the shade, the lower part and the dense outline, a clear centre and slow bubbles in the slime body.
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform float threshold = 0.35;
uniform vec4 lime_color : source_color = vec4(0.65, 0.84, 0.24, 1.0);
uniform vec4 body_color : source_color = vec4(0.43, 0.62, 0.165, 1.0);
uniform vec4 deep_color : source_color = vec4(0.31, 0.37, 0.14, 1.0);
uniform vec4 rim_color : source_color = vec4(0.17, 0.21, 0.08, 1.0);
uniform vec4 spec_color : source_color = vec4(0.84, 0.94, 0.48, 1.0);
uniform vec4 center_color : source_color = vec4(0.51, 0.72, 0.2, 1.0);
uniform vec4 flash_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 warn_color : source_color = vec4(0.95, 0.33, 0.28, 1.0);
uniform vec3 light_dir = vec3(-0.5, -0.7, 0.6);
uniform float normal_px = 3.0;
uniform float normal_z = 0.08;
uniform float rim_width = 0.05;
uniform float spec_power = 40.0;
uniform float spec_strength = 0.45;
uniform float sheen_power = 6.0;
uniform float sheen_strength = 0.06;
uniform float edge_light_strength = 0.3;
// Lit share where moss turns to mid (x) and mid turns to lime (y).
uniform vec2 tone_steps = vec2(0.3, 0.62);
uniform float lower_shade = 0.55;
// Deep inside the goo the RGBA8 field clips at 1.0; flatter normals there hide the clip seams of overlapping sources.
uniform vec2 interior_flatten = vec2(0.6, 0.95);
uniform float interior_flatten_strength = 3.0;
// Alpha at the outline (x) and in the thick centre (y), and the field rise over which it changes.
uniform vec2 alpha_range = vec2(0.97, 0.5);
uniform float density_depth = 0.3;
uniform float glow = 0.1;
// Off: no normal taps and no bubbles, for slow GPUs; the body keeps its dome shading and highlight.
uniform bool gloss = true;
// Slime body frame in world units (radius 0: no body), and a bubble time that stops with the game.
uniform vec2 body_center = vec2(0.0);
uniform float body_radius = 0.0;
uniform float bubble_time = 0.0;
uniform float bubble_cells = 4.0;
uniform float bubble_rise = 0.11;
uniform float bubble_density = 0.5;
uniform vec2 bubble_size = vec2(0.1, 0.32);
uniform float bubble_wobble = 0.12;
uniform float bubble_wobble_hz = 0.3;
uniform float bubble_alpha = 0.6;
uniform float bubble_inner = 0.78;
// Body signals: hit flash and danger share, a status tint with a pulsing light (ember, frost), and the colour swirl
// of a mix: the turn shown before it, the contact point in the body frame and its progress (1 or more: done).
uniform float body_flash = 0.0;
uniform float body_warn = 0.0;
uniform vec4 status_color : source_color = vec4(1.0, 0.5, 0.1, 1.0);
uniform float status_amount = 0.0;
uniform float status_glow = 0.0;
uniform float status_pulse_hz = 1.4;
uniform vec2 mix_from = vec2(1.0, 0.0);
uniform vec2 mix_center = vec2(0.0);
uniform float mix_t = 1.0;
uniform float mix_swirl = 1.4;
// Gulp wave: entry point in body units, progress 0 to 1 (1 is off) and strength.
uniform vec2 gulp_center = vec2(0.0, -1.0);
uniform float gulp_t = 1.0;
uniform float gulp_strength = 0.0;
// (cos, sin) of the hue offset where the G, B hue code is cut open (Tuning.goo_hue_cut).
uniform vec2 hue_cut = vec2(1.0, 0.0);
uniform vec2 chroma_range = vec2(0.8, 2.0);
// Clearer gelatin over the carried props: zone centre and half size in body radii, alpha there, and how much it applies.
uniform vec4 clear_zone = vec4(0.0, 0.35, 0.6, 0.45);
uniform float clear_alpha = 0.35;
uniform float clear_amount = 0.0;

varying vec2 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

// Cheap stand-in for pow(x, n) on [0, 1]: (1 - n (1 - x) / 8)^8, three squarings, close to x^n near the highlight.
float fast_pow(float x, float n) {
	float t = max(1.0 - n * (1.0 - x) * 0.125, 0.0);
	t *= t;
	t *= t;
	return t * t;
}

// Hash with no trigonometry, so every GPU gives the same bubbles.
vec3 hash32(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yzz) * p3.zyx);
}

// Smooth triangle wave in [-1, 1]: a sine look with no sin().
float wave(float x) {
	float t = abs(fract(x) - 0.5) * 2.0;
	t = t * t * (3.0 - 2.0 * t);
	return t * 2.0 - 1.0;
}

// Turns the chroma of an sRGB colour (YCoCg plane) by rot = (cos, sin); lightness stays.
vec3 hue_turn(vec3 c, vec2 rot) {
	float y = dot(c, vec3(0.25, 0.5, 0.25));
	float co = 0.5 * (c.r - c.b);
	float cg = -0.25 * c.r + 0.5 * c.g - 0.25 * c.b;
	vec2 t = vec2(co * rot.x - cg * rot.y, co * rot.y + cg * rot.x);
	return max(vec3(y + t.x - t.y, y + t.y, y - t.x - t.y), vec3(0.0));
}

// Premultiplied bubble light (rgb) and extra cover (a) at body point q (in body radii); zero outside every bubble.
vec4 bubbles(vec2 q, float f) {
	float zone = 1.0 - smoothstep(bubble_inner * 0.7, bubble_inner, length(q));
	zone *= smoothstep(threshold + 0.1, threshold + 0.3, f);
	if (zone <= 0.001) {
		return vec4(0.0);
	}
	vec2 g = q * bubble_cells;
	g.y += bubble_time * bubble_rise * bubble_cells;
	vec3 h = hash32(floor(g));
	if (h.z > bubble_density) {
		return vec4(0.0);
	}
	float size = mix(bubble_size.x, bubble_size.y, h.x * h.x);
	float room = max(0.5 - size - bubble_wobble, 0.0);
	vec2 c = vec2((h.y * 2.0 - 1.0) * room + wave(bubble_time * bubble_wobble_hz + h.x * 3.7) * bubble_wobble, (h.x - 0.5) * room);
	vec2 d = (fract(g) - 0.5 - c) / size;
	float r2 = dot(d, d);
	if (r2 >= 1.0) {
		return vec4(0.0);
	}
	float r = sqrt(r2);
	float ring = smoothstep(0.55, 0.9, r) * (1.0 - smoothstep(0.9, 1.0, r));
	vec2 s = d + vec2(0.38, 0.42);
	float spot = 1.0 - smoothstep(0.0, 0.09, dot(s, s));
	float k = (ring * 0.7 + spot + 0.12) * zone * bubble_alpha;
	return vec4(spec_color.rgb * k, k * 0.5);
}

void fragment() {
	vec4 s = textureLod(screen_texture, SCREEN_UV, 0.0);
	float f = s.r;
	float w = max(fwidth(f), 0.002);
	float a = smoothstep(threshold - w, threshold + w, f);
	if (a <= 0.001) {
		discard;
	}
	vec3 n = vec3(0.0, 0.0, 1.0);
	if (gloss) {
		vec2 px = SCREEN_PIXEL_SIZE * normal_px;
		float fx = textureLod(screen_texture, SCREEN_UV + vec2(px.x, 0.0), 0.0).r - textureLod(screen_texture, SCREEN_UV - vec2(px.x, 0.0), 0.0).r;
		float fy = textureLod(screen_texture, SCREEN_UV + vec2(0.0, px.y), 0.0).r - textureLod(screen_texture, SCREEN_UV - vec2(0.0, px.y), 0.0).r;
		float flatten = 1.0 + interior_flatten_strength * smoothstep(interior_flatten.x, interior_flatten.y, f);
		n = normalize(vec3(-fx, -fy, normal_z * flatten));
	}
	vec3 l = normalize(light_dir);
	float depth = smoothstep(threshold, threshold + density_depth, f);
	// Body frame: the slime reads as a dome of gelatin, lit on the upper side, its lower half in moss shade.
	vec2 q = vec2(0.0, 2.0);
	float body = 0.0;
	if (body_radius > 0.0) {
		q = (world_pos - body_center) / body_radius;
		body = 1.0 - smoothstep(0.9, 1.3, length(q));
		vec2 dq = q * 0.85;
		vec3 dome = vec3(dq, sqrt(max(1.0 - dot(dq, dq), 0.0)));
		n = normalize(mix(n, dome, body * (0.35 + 0.55 * depth)));
	}
	// Hue of the sources here, as a turn of the green palette.
	// The direction of (G, B) is phi; the hue turn is e^(i (4 phi + cut)), from two complex squarings.
	vec2 rot = vec2(1.0, 0.0);
	float hl = length(s.gb);
	if (hl > 0.004) {
		vec2 u = s.gb / hl;
		u = vec2(u.x * u.x - u.y * u.y, 2.0 * u.x * u.y);
		u = vec2(u.x * u.x - u.y * u.y, 2.0 * u.x * u.y);
		rot = vec2(u.x * hue_cut.x - u.y * hue_cut.y, u.x * hue_cut.y + u.y * hue_cut.x);
		// The length of (G, B) over 0.4 R (GooMath.HUE_CODE_SCALE) is the chroma scale; a clipped R only makes it larger, so it is clamped.
		rot *= clamp(hl / max(0.4 * f, 0.001) * chroma_range.y, chroma_range.x, chroma_range.y);
	}
	// Wide body mask for the signals that belong to the slime only.
	float bodyw = body_radius > 0.0 ? 1.0 - smoothstep(1.15, 1.5, length(q * vec2(0.8, 1.0))) : 0.0;
	if (mix_t < 1.0 && bodyw > 0.0) {
		// The new colour swirls in from the contact point: a front that grows, bent by a cheap twist and wobble.
		vec2 dq = q - mix_center;
		float d = length(dq);
		vec2 sw = q + vec2(-dq.y, dq.x) * mix_swirl * (1.0 - mix_t) * (1.0 - smoothstep(0.0, 1.4, d));
		// Two slanted waves that drift apart: wavy tongues of the new colour, not a grid of spots.
		float wob = wave(sw.x * 1.6 + sw.y * 0.9 + mix_t * 1.3) + wave(sw.y * 1.9 - sw.x * 0.7 - mix_t * 0.9);
		float front = mix_t * 2.6;
		float m = 1.0 - smoothstep(front - 0.45, front, d + wob * 0.28);
		float k = m * bodyw + (1.0 - bodyw);
		vec2 r2 = mix(mix_from, rot, k);
		float rl = length(r2);
		rot = rl > 0.0001 ? r2 / rl * mix(length(mix_from), length(rot), k) : rot;
	}
	float lit = clamp(dot(n, l), 0.0, 1.0);
	lit *= 1.0 - lower_shade * smoothstep(-0.15, 0.85, q.y) * body;
	float to_mid = smoothstep(tone_steps.x - 0.12, tone_steps.x + 0.12, lit);
	float to_lime = smoothstep(tone_steps.y - 0.1, tone_steps.y + 0.1, lit);
	vec3 col = mix(mix(deep_color.rgb, body_color.rgb, to_mid), lime_color.rgb, to_lime);
	// depth: 0 at the outline, 1 where the gelatin is thick and clear.
	col = mix(col, center_color.rgb * (0.75 + 0.35 * to_lime), depth * 0.45);
	float rim = 1.0 - smoothstep(threshold, threshold + rim_width, f);
	// Thin lime band just inside the dark rim on the lit side: reads as a wet meniscus.
	float band = smoothstep(threshold + rim_width, threshold + rim_width * 2.0, f) * (1.0 - smoothstep(threshold + rim_width * 2.0, threshold + rim_width * 4.0, f));
	col = mix(col, lime_color.rgb, band * to_lime * edge_light_strength * 2.0);
	col = mix(col, rim_color.rgb, rim * 0.85);
	float warn = body_warn * bodyw * 0.85;
	float flash = body_flash * bodyw;
	float alpha = mix(alpha_range.x, alpha_range.y, depth);
	// Moss shade is dense gelatin, so the cave colour does not turn it blue.
	alpha = mix(alpha, alpha_range.x, (1.0 - to_mid) * 0.4);
	if (clear_amount > 0.0) {
		vec2 cz = (q - clear_zone.xy) / clear_zone.zw;
		float zone = (1.0 - smoothstep(0.6, 1.0, dot(cz, cz))) * bodyw * clear_amount;
		alpha = mix(alpha, min(alpha, clear_alpha), zone);
	}
	alpha = mix(alpha, 1.0, max(warn, flash));
	vec3 light = col * alpha + lime_color.rgb * glow * depth * to_lime * (1.0 - rim);
	float base_alpha = alpha;
	// The highlight stays in the cheap path: there n is the body dome (no taps), so the slime keeps its gloss spot.
	float rv = clamp(dot(reflect(-l, n), vec3(0.0, 0.0, 1.0)), 0.0, 1.0);
	float spec = fast_pow(rv, spec_power) * spec_strength + fast_pow(rv, sheen_power) * sheen_strength;
	light += spec_color.rgb * (spec * (1.0 - rim));
	if (gloss) {
		if (body_radius > 0.0) {
			vec4 b = bubbles(q, f);
			light += b.rgb;
			alpha = min(alpha + b.a, 1.0);
		}
	}
	// The palette, gloss and bubbles turn together to the hue of this goo.
	light = hue_turn(light, rot);
	light = mix(light, warn_color.rgb, warn);
	if (status_amount > 0.0 || status_glow > 0.0) {
		float sb = bodyw;
		float pulse = 0.5 + 0.5 * wave(bubble_time * status_pulse_hz);
		vec3 tinted = status_color.rgb * (0.45 + 0.75 * lit) * base_alpha;
		light = mix(light, tinted, clamp(status_amount, 0.0, 1.0) * sb);
		light += status_color.rgb * status_glow * (0.35 + 0.65 * pulse) * depth * sb * 0.6;
		alpha = mix(alpha, 1.0, status_glow * sb * 0.3);
	}
	if (gulp_t < 1.0 && bodyw > 0.0) {
		float front = gulp_t * 2.2;
		float band = 1.0 - smoothstep(0.0, 0.4, abs(length(q - gulp_center) - front));
		float g = band * (1.0 - gulp_t) * gulp_strength * bodyw * (1.0 - rim);
		light += hue_turn(lime_color.rgb, rot) * g * base_alpha;
		alpha = min(alpha + g * 0.25, 1.0);
	}
	light = mix(light, flash_color.rgb, flash);
	COLOR = vec4(light, alpha) * a;
}
