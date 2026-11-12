extends RefCounted
## One round goo button of the touch controls: state, hit test, jelly spring, splash and drawing.
## TouchControls owns every instance, calls update() once per frame and draw() into its shared ShapeBatch.

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

const BODY_POINTS := 40
const SPRING_MAX_STEP := 1.0 / 120.0
const SPLASH_RADIUS := Vector2(2.5, 5.5)
const APPEAR_MIN_SCALE := 0.55
## Glyph strokes are drawn in units of this share of the radius.
const GLYPH_UNIT := 0.42
## Above this room the load shows as a gauge arc and a number instead of pips.
const PIP_MAX := 6
const GAUGE_SPAN := 1.6

var kind: StringName
var action: StringName
var accent: Color
var center := Vector2.ZERO
var radius := 50.0
var shown := true
## Fingers on the button; it stays pressed until the last one lifts.
var fingers := 0
var pressed: bool:
	get:
		return fingers > 0
## 0..1 pulsing halo that calls for a press (the jump button on the goal screen).
var lit := 0.0
## 0..1 blend of the rim toward the cancel colour (the aim button while a release would cancel).
var alert := 0.0
## Carried props and carry room (quick shot only): pips for a small room, else a gauge arc with the count drawn by
## TouchControls; capacity 0 draws none.
var pip_load := 0
var pip_capacity := 0
var appear := 0.0

var _squash := 1.0
var _squash_vel := 0.0
var _glow := 0.0
var _wobble := 0.0
var _wobble_phase := 0.0
var _ripple := 1.0
var _ripple_from := Vector2.ZERO
var _splash: Array[Dictionary] = []
var _time := 0.0


func _init(p_kind: StringName, p_action: StringName, p_accent: Color) -> void:
	kind = p_kind
	action = p_action
	accent = p_accent


func hit(p: Vector2) -> bool:
	return shown and appear > 0.5 and p.distance_to(center) <= radius * Tuning.touch_hit_slop


func press(p: Vector2) -> void:
	fingers += 1
	if fingers == 1:
		_glow = 1.0
		burst(p)


func release() -> void:
	if fingers <= 0:
		return
	fingers -= 1
	if fingers == 0:
		_squash_vel += Tuning.touch_release_kick
		_wobble = maxf(_wobble, Tuning.touch_wobble_amount * 0.6)


## Drops every finger with no release pop, for a cancel or a hide.
func clear() -> void:
	fingers = 0


## Ripple, wobble and goo splash from a point, with no change of the pressed state.
func burst(from: Vector2) -> void:
	_ripple = 0.0
	_ripple_from = (from - center).limit_length(radius * 0.6)
	_wobble = Tuning.touch_wobble_amount
	for i in Tuning.touch_splash_count:
		var angle := -PI * 0.5 + randf_range(-1.2, 1.2) + (PI if i % 3 == 2 else 0.0)
		var dir := Vector2.from_angle(angle)
		_splash.append({
			"p": dir * radius * 0.9,
			"v": dir * randf_range(Tuning.touch_splash_speed.x, Tuning.touch_splash_speed.y),
			"life": Tuning.touch_splash_life,
			"r": randf_range(SPLASH_RADIUS.x, SPLASH_RADIUS.y),
		})


func update(delta: float) -> void:
	_time += delta
	appear = move_toward(appear, 1.0 if shown else 0.0, delta / maxf(Tuning.touch_appear_time, 0.001))
	var target := Tuning.touch_press_squash if pressed else 1.0
	var remaining := delta
	while remaining > 0.0:
		var step := minf(remaining, SPRING_MAX_STEP)
		_squash_vel += ((target - _squash) * Tuning.touch_spring_stiffness - _squash_vel * Tuning.touch_spring_damping) * step
		_squash += _squash_vel * step
		remaining -= step
	if not pressed:
		_glow = move_toward(_glow, 0.0, delta * 5.0)
	_wobble *= exp(-Tuning.touch_wobble_decay * delta)
	_wobble_phase += delta * 17.0
	_ripple = minf(_ripple + delta / maxf(Tuning.touch_ripple_time, 0.001), 1.0)
	for i in range(_splash.size() - 1, -1, -1):
		var drop: Dictionary = _splash[i]
		drop.life = float(drop.life) - delta
		if float(drop.life) <= 0.0:
			_splash.remove_at(i)
			continue
		drop.v = Vector2(drop.v) + Vector2(0.0, Tuning.touch_splash_gravity * delta)
		drop.p = Vector2(drop.p) + Vector2(drop.v) * delta


## Everything draw() reads, with the springs and decays snapped below a visible step, so a caller can skip a redraw
## while the key stays the same.
func visual_key() -> Array:
	if appear <= 0.0:
		return []
	var key := [appear, center, radius, accent, alert, _glow, pip_load, pip_capacity, snappedf(_squash, 0.0001), _ripple]
	if _wobble * radius >= 0.01:
		key.append_array([snappedf(_wobble, 0.0005), _wobble_phase])
	if lit > 0.0 or not _splash.is_empty():
		key.append_array([lit, _time])
	return key


func draw(batch: ShapeBatch) -> void:
	if appear <= 0.0:
		return
	var a := ease(appear, 0.4)
	var grow := lerpf(APPEAR_MIN_SCALE, 1.0, _ease_out_back(appear))
	var sx := grow * (1.0 + (1.0 - _squash) * 0.7)
	var sy := grow * _squash
	# A pressed jelly sinks: its bottom stays put while the top comes down.
	var c := center + Vector2(0.0, radius * (grow - sy) * 0.5)
	var rim_color := accent.lerp(Tuning.touch_accent_cancel, alert)
	var base_alpha := lerpf(Tuning.touch_button_idle_alpha, Tuning.touch_button_pressed_alpha, _glow)
	if lit > 0.0:
		var pulse := 0.5 + 0.5 * sin(_time * TAU * Tuning.touch_goal_pulse_hz)
		var halo := radius * (1.15 + 0.2 * pulse) * grow
		batch.disc(c, halo, Color(rim_color, a * lit * 0.18 * (0.5 + pulse)))
		batch.ring(c, halo, radius * 0.05, Color(rim_color, a * lit * 0.6))
	var body := _body_points(c, sx, sy, 1.0)
	batch.polygon(_offset(body, Vector2(0.0, radius * 0.1)), Color(0.0, 0.0, 0.0, a * 0.22))
	var fill := Tuning.touch_fill_color.lerp(rim_color.darkened(0.55), _glow * 0.7)
	batch.polygon(body, Color(fill, a * base_alpha))
	batch.polygon(_body_points(c + Vector2(0.0, radius * 0.1 * sy), sx * 0.8, sy * 0.74, 0.6), Color(rim_color, a * (0.14 + 0.3 * _glow)))
	batch.stroke(body, radius * 0.075, Color(rim_color, a * (0.8 + 0.2 * _glow)), true)
	batch.disc(c + Vector2(-0.38 * sx, -0.44 * sy) * radius, radius * 0.15 * grow, Color(1.0, 1.0, 1.0, a * 0.3))
	batch.disc(c + Vector2(-0.16 * sx, -0.6 * sy) * radius, radius * 0.06 * grow, Color(1.0, 1.0, 1.0, a * 0.35))
	_draw_glyph(batch, c, Vector2(sx, sy) * radius * GLYPH_UNIT, Color(rim_color.lightened(0.55), a * 0.95))
	if pip_capacity > 0:
		_draw_pips(batch, c, grow, a)
	if _ripple < 1.0:
		var t := ease(_ripple, 0.5)
		batch.ring(c + _ripple_from * (1.0 - t), radius * (0.7 + 0.75 * t) * grow, radius * 0.06 * (1.0 - t) + 1.0, Color(rim_color, a * (1.0 - _ripple) * 0.7))
	for drop: Dictionary in _splash:
		var life := float(drop.life) / Tuning.touch_splash_life
		batch.disc(center + Vector2(drop.p), float(drop.r) * (0.4 + 0.6 * life), Color(rim_color, a * life * 0.9))


## Outline of the jelly with its decaying wobble, as a closed point list (first point not repeated).
func _body_points(c: Vector2, sx: float, sy: float, wobble_share: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	points.resize(BODY_POINTS)
	for i in BODY_POINTS:
		var angle := TAU * i / BODY_POINTS
		var wob := 1.0 + _wobble * wobble_share * sin(angle * Tuning.touch_wobble_lobes + _wobble_phase)
		points[i] = c + Vector2(cos(angle) * sx, sin(angle) * sy) * radius * wob
	return points


func _offset(points: PackedVector2Array, by: Vector2) -> PackedVector2Array:
	var out := points.duplicate()
	for i in out.size():
		out[i] += by
	return out


## Glyph points are in units where 1 is GLYPH_UNIT radii, +y down.
func _draw_glyph(batch: ShapeBatch, c: Vector2, unit: Vector2, color: Color) -> void:
	var w := unit.y * 0.34
	# Secondary strokes are darker, not more transparent, so their round caps do not show through.
	var faint := Color(color.lerp(Tuning.touch_fill_color, 0.45), color.a)
	match kind:
		&"jump":
			batch.stroke(_glyph_line(c, unit, [Vector2(-0.8, 0.05), Vector2(0.0, -0.75), Vector2(0.8, 0.05)]), w, color)
			batch.stroke(_glyph_line(c, unit, [Vector2(-0.55, 0.75), Vector2(0.0, 0.2), Vector2(0.55, 0.75)]), w * 0.8, faint)
		&"shoot":
			var rock := PackedVector2Array()
			for i in 7:
				var angle := TAU * i / 7.0 + 0.3
				var bump := 0.85 + 0.15 * (i % 2)
				rock.append(c + Vector2(0.38 + cos(angle) * 0.5 * bump, sin(angle) * 0.5 * bump) * unit)
			batch.polygon(rock, color)
			for y: float in [-0.35, 0.0, 0.35]:
				var tail := -1.2 if y == 0.0 else -1.05
				batch.stroke(_glyph_line(c, unit, [Vector2(tail, y), Vector2(-0.42, y)]), w * 0.6, faint)
		&"aim":
			for i in 5:
				var t := i / 4.0
				var p := Vector2(lerpf(-0.95, 0.55, t), 0.75 - 2.1 * t + 1.3 * t * t)
				batch.disc(c + p * unit, w * lerpf(0.7, 0.45, t), color)
			batch.ring(c + Vector2(0.72, 0.15) * unit, unit.y * 0.32, w * 0.55, color)
		&"restart":
			var arc_r := unit.y * 0.72
			var start := -PI * 0.35
			batch.arc(c, arc_r, start, start + TAU * 0.78, w * 0.9, color)
			var tip := c + Vector2.from_angle(start) * arc_r
			var forward := Vector2.from_angle(start - PI * 0.5)
			var side := Vector2.from_angle(start)
			batch.polygon(PackedVector2Array([tip + side * w * 1.3, tip + forward * w * 1.6, tip - side * w * 1.3]), color)
		&"dodge":
			# A goo ball with two swoosh arcs behind it.
			batch.ring(c + Vector2(0.35, 0.0) * unit, unit.y * 0.48, w * 0.8, color)
			batch.disc(c + Vector2(0.22, -0.14) * unit, w * 0.45, color)
			batch.arc(c + Vector2(0.35, 0.0) * unit, unit.y * 0.95, PI * 0.75, PI * 1.05, w * 0.6, faint)
			batch.arc(c + Vector2(0.35, 0.0) * unit, unit.y * 0.95, PI * 0.95, PI * 1.25, w * 0.6, faint)
		&"perf":
			var heights: Array[float] = [0.55, 1.1, 0.8]
			for i in 3:
				var x := (i - 1) * 0.6
				batch.stroke(_glyph_line(c, unit, [Vector2(x, 0.65), Vector2(x, 0.65 - heights[i])]), w * 0.9, color)


func _glyph_line(c: Vector2, unit: Vector2, points: Array[Vector2]) -> PackedVector2Array:
	var line := PackedVector2Array()
	for p: Vector2 in points:
		line.append(c + p * unit)
	return line


func _draw_pips(batch: ShapeBatch, c: Vector2, grow: float, a: float) -> void:
	if pip_capacity > PIP_MAX:
		_draw_gauge(batch, c, grow, a)
		return
	var step := deg_to_rad(20.0)
	var first := -PI * 0.5 - step * (pip_capacity - 1) * 0.5
	var pip_r := radius * 0.11 * grow
	for i in pip_capacity:
		var p := c + Vector2.from_angle(first + step * i) * radius * 1.24 * grow
		if i < pip_load:
			batch.disc(p, pip_r, Color(accent, a))
			batch.disc(p + Vector2(-0.3, -0.3) * pip_r, pip_r * 0.35, Color(1.0, 1.0, 1.0, a * 0.6))
		else:
			batch.ring(p, pip_r * 0.8, 1.5, Color(accent, a * 0.45))


static func _ease_out_back(t: float) -> float:
	var s := 1.70158
	var u := t - 1.0
	return 1.0 + (s + 1.0) * u * u * u + s * u * u


## Load gauge over the top of the button: a dim arc for the room and a lit arc for the load.
func _draw_gauge(batch: ShapeBatch, c: Vector2, grow: float, a: float) -> void:
	var arc_r := radius * 1.2 * grow
	var start := -PI * 0.5 - GAUGE_SPAN * 0.5
	var width := radius * 0.1 * grow
	batch.arc(c, arc_r, start, start + GAUGE_SPAN, width, Color(accent, a * 0.3))
	var share := clampf(float(pip_load) / float(maxi(pip_capacity, 1)), 0.0, 1.0)
	if share > 0.0:
		batch.arc(c, arc_r, start, start + GAUGE_SPAN * share, width, Color(accent, a))


## Where TouchControls writes the load count (top of the gauge), or a negative radius when no count shows.
func count_anchor() -> Vector3:
	if pip_capacity <= PIP_MAX or appear <= 0.0:
		return Vector3(0.0, 0.0, -1.0)
	return Vector3(center.x, center.y - radius * 1.2, radius * 0.34)
