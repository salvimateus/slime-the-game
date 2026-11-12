shader_type canvas_item;
// Props and bubbles inside the slime (cargo.gd, geometry from cargo_mesh.gd). The geometry stays fixed; this shader
// places, turns, sizes, tints and fades each prop and bubble from per-step data and per-frame data of the cargo.
// deform_point is a copy of SlimeBody._shape_point and _deform (scenes/player/slime_body.gd), the source of the
// deformation. cargo.gd _shader_deform mirrors this function in GDScript, and cargo.gd check_deform compares that
// mirror with the body at boot: change the three together. cargo.gd _pack_frame fills `frame`.

// Per prop slot: position before and after the last step (body radii); turn before and after it, prop radius,
// flags (share inside the body, + 2 when drawn in the front item, + 4 when it is the next shot).
uniform vec4 item_pos[32];
uniform vec4 item_data[32];
// Per bubble slot: position before and after the step; size, age share before and after, 1 while it lives.
uniform vec4 bubble_pos[32];
uniform vec4 bubble_data[32];
// [0] step share, time, cargo radius, crowd scale; [1] ember, frost, warm-up, body radius with swell;
// [2] sx, sy, ex, ey; [3] crawl dx, press, press side, feet; [4] ceiling, lean, body frost, aim pull;
// [5] aim dir, roll; [6] roll pivot.
uniform vec4 frame[7];

uniform float radius_full = 60.0;
uniform float soft_edge = 1.2;
uniform float edge_width;
uniform float edge_alpha;
uniform float next_edge_alpha;
uniform float lighten;
uniform float next_lighten;
uniform float next_scale;
uniform float next_pulse;
uniform float next_pulse_hz;
uniform float gloss_alpha;
uniform float ember_glow;
uniform float ember_tint;
uniform float ember_pulse_hz;
uniform float frost_tint;
uniform float carry_alpha = 1.0;
uniform float bubble_alpha;
uniform vec3 ember_hot;
uniform vec3 ember_core;
uniform vec3 frost_color;
uniform vec2 mid_shift = vec2(-0.06, -0.08);
uniform vec2 light_shift = vec2(-0.22, -0.26);
uniform vec2 spot_shift = vec2(-0.38, -0.42);
uniform float press_narrow;
uniform float press_tall;
uniform float ceiling_depth;
uniform float ceiling_bulge;
uniform float aim_stretch;
uniform float aim_shift;

varying vec2 v_tex;

vec2 deform_point(vec2 p) {
	vec4 f1 = frame[1];
	vec4 f2 = frame[2];
	vec4 f3 = frame[3];
	vec4 f4 = frame[4];
	vec4 f5 = frame[5];
	float r = f1.w;
	vec2 q = vec2(p.x * f2.x, p.y * f2.y + r * (1.0 - f2.y));
	q.x = q.x * f2.z + f3.x;
	q.y = r - (r - q.y) * f2.w;
	if (f3.y > 0.001) {
		float anchor = f3.z * f3.w;
		q.x = anchor + (q.x - anchor) * (1.0 - press_narrow * f3.y);
		q.y = r - (r - q.y) * (1.0 + press_tall * f3.y);
	}
	if (abs(f4.x) > 0.001) {
		float top = clamp(-q.y / max(r, 0.001), 0.0, 1.0);
		float mid = clamp(1.0 - abs(q.y) / max(r, 0.001), 0.0, 1.0);
		q.y += top * f4.x * ceiling_depth * r;
		q.x *= 1.0 + ceiling_bulge * f4.x * mid;
	}
	float span = max(r * 2.0, 0.001);
	float h = clamp((r - q.y) / span, 0.0, 1.2);
	q.x += f4.y * span * h * (0.5 + 0.5 * h) * (1.0 - f4.z);
	if (abs(f4.w) > 0.001) {
		vec2 back = -f5.xy;
		float along = max(dot(q, back) / max(r, 0.001), 0.0);
		q += back * f4.w * r * (aim_stretch * along + aim_shift) * (1.0 - f4.z);
	}
	if (f5.z != 0.0) {
		vec2 pivot = frame[6].xy;
		float c = cos(f5.z);
		float s = sin(f5.z);
		q = pivot + mat2(vec2(c, s), vec2(-s, c)) * (q - pivot);
	}
	return q;
}

vec2 rim_normal(float packed) {
	float q = floor(packed + 0.5);
	float qx = floor(q / 2048.0);
	return vec2(qx, q - qx * 2048.0) / 256.0 - 4.0;
}

void vertex() {
	int code = int(UV.x + 0.5);
	int layer = code % 16;
	int slot = code / 32;
	bool front = (code / 16) % 2 == 1;
	vec4 f0 = frame[0];
	vec4 f1 = frame[1];
	float share = f0.x;
	float time = f0.y;
	float r = f0.z;
	bool warm = f1.z > 0.5;
	if (r <= 1.0 && warm) {
		r = radius_full;
	}
	bool shown = r > 1.0;
	vec2 pos = vec2(0.0);
	vec4 col = COLOR;
	v_tex = vec2(0.5);
	if (layer == 9) {
		vec4 bp = bubble_pos[slot];
		vec4 bd = bubble_data[slot];
		shown = shown && bd.w > 0.5;
		float t = mix(bd.y, bd.z, share);
		// A bubble swells a little and fades just before it pops.
		float pop = smoothstep(0.8, 1.0, t);
		float size = bd.x * clamp(r / radius_full, 0.5, 1.0) * (1.0 + 0.35 * pop);
		pos = deform_point(mix(bp.xy, bp.zw, share) * r) + VERTEX * size;
		col = vec4(1.0, 1.0, 1.0, (warm ? 0.01 : bubble_alpha) * smoothstep(0.0, 0.12, t) * (1.0 - pop));
		v_tex = VERTEX * 0.5 + 0.5;
	} else {
		vec4 ip = item_pos[slot];
		vec4 id = item_data[slot];
		float flags = id.w;
		bool next = flags >= 3.5;
		flags -= next ? 4.0 : 0.0;
		bool on_top = flags >= 1.5;
		float inside = flags - (on_top ? 2.0 : 0.0);
		shown = shown && on_top == front && id.z > 0.0;
		float radius = id.z * clamp(r / radius_full, 0.55, 1.0) * f0.w;
		float lit = lighten;
		float edge_a = edge_alpha;
		if (next) {
			radius *= next_scale * (1.0 + next_pulse * (0.5 + 0.5 * sin(time * TAU * next_pulse_hz)));
			lit = next_lighten;
			edge_a = next_edge_alpha;
		}
		vec3 tint = vec3(1.0);
		float amount = lit * inside;
		float glow_a = 0.0;
		float glow_scale = 1.5;
		if (f1.x > 0.01) {
			// Heated before the shot: a red glow that pulses, hotter on the next prop.
			float pulse = 0.5 + 0.5 * sin(time * TAU * ember_pulse_hz + float(slot) * 1.7);
			float heat = f1.x * (next ? 1.0 : 0.75);
			glow_a = ember_glow * heat;
			glow_scale = 1.5 + 0.3 * pulse;
			tint = mix(ember_hot, ember_core, 0.3 + 0.5 * pulse);
			amount = mix(amount, ember_tint, heat);
		} else if (f1.y > 0.01) {
			tint = frost_color;
			amount = mix(amount, frost_tint, f1.y);
		}
		float body_a = mix(1.0, carry_alpha, inside);
		float angle = mix(id.x, id.y, share);
		float c = cos(angle);
		float s = sin(angle);
		mat2 turn = mat2(vec2(c, s), vec2(-s, c));
		float rim = COLOR.a <= 0.0 ? soft_edge : 0.0;
		vec2 local = VERTEX;
		float weight = 0.0;
		float alpha = body_a;
		if (layer == 0) {
			local = VERTEX * (radius * (1.0 + edge_width) + rim);
			alpha = edge_a * inside;
		} else if (layer == 1) {
			local = VERTEX * (radius * glow_scale + rim);
			alpha = glow_a;
			shown = shown && f1.x > 0.01;
		} else if (layer == 2) {
			local = turn * (VERTEX * radius);
			weight = 0.5;
		} else if (layer <= 5) {
			local = turn * (VERTEX * radius);
			local += layer == 4 ? mid_shift * radius : (layer == 5 ? light_shift * radius : vec2(0.0));
			weight = 1.0;
		} else if (layer == 6) {
			float half_width = max(radius * 0.12, 1.0) * 0.5;
			local = turn * (VERTEX * radius + rim_normal(UV.y) * (half_width + rim));
			weight = 0.5;
		} else if (layer == 7) {
			local = spot_shift * radius + VERTEX * (max(radius * 0.13, 0.8) + rim);
			weight = 0.5;
		} else {
			float half_width = max(radius * 0.18, 1.0) * 0.5;
			local = VERTEX * radius * 0.95 + rim_normal(UV.y) * (half_width + rim);
			alpha = gloss_alpha * inside;
		}
		pos = deform_point(mix(ip.xy, ip.zw, share) * r) + local;
		col = vec4(mix(COLOR.rgb, tint, clamp(amount * weight, 0.0, 1.0)), COLOR.a * clamp(alpha, 0.0, 1.0));
	}
	if (!shown) {
		pos = vec2(0.0);
		col.a = 0.0;
	}
	VERTEX = pos;
	COLOR = col;
}

void fragment() {
	COLOR = COLOR * texture(TEXTURE, v_tex);
}
