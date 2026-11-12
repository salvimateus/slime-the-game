shader_type canvas_item;
// Moves the decoration on the GPU, so a frame costs no GDScript for it. Each point carries its motion in UV
// (see decor_painter.gd): UV.x = kind + phase * 0.98, UV.y = the parameter of the kind. Reactive pieces (mushrooms
// that squash, hanging pieces that sway after a touch) read their state from the react slots that DecorLive fills.

const int SLOTS = 16;
const float ID_STRIDE = 1024.0;

// Time of the level in seconds (pauses with the game); motion 0 freezes every idle motion.
uniform float t = 0.0;
uniform float motion = 1.0;
// x: piece id (-1 is a free slot), y: squash, z: lean or sway angle.
uniform vec4 react[16];
// Pivot of each slot (the foot of a mushroom).
uniform vec2 pivot[16];
uniform float pulse_hz = 0.35;
uniform float drop_period = 2.8;
uniform float drop_gravity = 1500.0;
uniform float rise_rate = 0.5;
uniform float idle_sway = 0.035;

int find_slot(float id) {
	for (int k = 0; k < SLOTS; k++) {
		if (abs(react[k].x - id) < 0.5) {
			return k;
		}
	}
	return -1;
}

void vertex() {
	float kind = floor(UV.x + 0.001);
	if (kind > 0.5) {
		float phase = fract(UV.x) / 0.98 * TAU;
		float pulse = 0.72 + 0.28 * sin(t * TAU * pulse_hz + phase) * motion;
		if (kind == 1.0 || kind == 8.0) {
			float id = floor(UV.y / ID_STRIDE);
			float depth = UV.y - id * ID_STRIDE;
			float angle = sin(t * 0.9 + phase) * idle_sway * motion;
			int slot = find_slot(id);
			if (slot >= 0) {
				angle += react[slot].z;
			}
			VERTEX.x += angle * depth;
			VERTEX.y -= 0.5 * angle * angle * depth;
			if (kind == 8.0) {
				COLOR.a *= pulse;
			}
		} else if (kind == 6.0 || kind == 7.0) {
			int slot = find_slot(floor(UV.y / ID_STRIDE));
			if (slot >= 0) {
				vec2 local = VERTEX - pivot[slot];
				float s = react[slot].y;
				VERTEX = pivot[slot] + vec2(local.x * (1.0 + 0.6 * s) + local.y * react[slot].z, local.y * (1.0 - s));
			}
			if (kind == 7.0) {
				COLOR.a *= pulse;
			}
		} else if (kind == 2.0) {
			COLOR.a *= pulse;
		} else if (kind == 3.0) {
			float env = pow(max(sin(t * TAU / max(UV.y, 0.5) + phase), 0.0), 24.0);
			COLOR.a *= mix(0.0, env, motion);
		} else if (kind == 4.0) {
			float cycle = mod(t + phase / TAU * drop_period, drop_period);
			float fall = max(cycle - 0.4, 0.0);
			float dy = 0.5 * drop_gravity * fall * fall;
			VERTEX.y += min(dy, UV.y);
			float alive = (cycle < 0.4 ? cycle / 0.4 : 1.0) * step(dy, UV.y);
			COLOR.a *= alive * motion;
		} else if (kind == 5.0) {
			float u = fract(t * rise_rate + phase / TAU);
			VERTEX += vec2(sin(u * 6.0 + phase) * 6.0, -u * UV.y);
			COLOR.a *= (1.0 - u) * motion;
		}
	}
}
