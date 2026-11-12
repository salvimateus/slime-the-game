extends Node2D
## Eyes and mouth of the slime. Reads the SlimeBody shape and draws above the goo surface.

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

var body: Node2D
var _expression: StringName = &"normal"
var _expression_timer := 0.0
var _blink := 0.0
var _blink_timer := 2.0
var _look := Vector2.ZERO
var _rng := RandomNumberGenerator.new()
var _time := 0.0
var _dead_time := 0.0
var _last_anchor := Vector2.ZERO
var _last_spread := 0.0
var _last_eye_r := 0.0
var _lag_anchor := Vector2.ZERO
var _lag_vel := Vector2.ZERO
var _lag_ready := false
var _batch := ShapeBatch.new()
## Roll turn of the body this frame; every face point goes through it, so the face turns with the ball.
var _spin := Transform2D.IDENTITY
## Ink of this frame: a dark tone of the body colour, so the face reads on any body (see _update_ink()).
var _ink := Tuning.face_ink_color
## Quantized drawn state of the last redraw; the face redraws only when it changes. The anchor and the roll turn are
## in the node transform, so the breath and the motion of the body move the face with no redraw.
var _key := []
var _player: Node2D
var _player_has := {}


func _ready() -> void:
	# The transform is written in _process from the interpolated body shape, so it must not be interpolated again.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_rng.seed = 99
	_player = get_parent() as Node2D
	for method: StringName in [&"aim_look", &"move_look", &"temperature_expression", &"pose_expression", &"status_tint"]:
		_player_has[method] = _player != null and _player.has_method(method)


func set_expression(expression: StringName, seconds: float) -> void:
	_expression = expression
	_expression_timer = seconds
	if expression == &"dead":
		_dead_time = 0.0


func _process(delta: float) -> void:
	_time += delta
	if _expression != &"normal" and _expression_timer > 0.0:
		_expression_timer -= delta
		if _expression_timer <= 0.0:
			_expression = &"normal"
	_blink = maxf(_blink - delta, 0.0)
	_blink_timer -= delta
	if _blink_timer <= 0.0:
		_blink = Tuning.face_blink_time
		_blink_timer = _rng.randf_range(Tuning.face_blink_interval.x, Tuning.face_blink_interval.y)
	if _expression == &"dead" and _body_radius() <= 1.0:
		_dead_time += delta
	_look = _look.lerp(_look_target(), 1.0 - exp(-delta * Tuning.face_look_smooth))
	_follow_anchor(delta)
	if _lag_ready and is_instance_valid(body):
		var spin: Transform2D = body.call(&"spin")
		transform = spin * Transform2D(0.0, _lag_anchor)
	var key := _draw_key()
	if key != _key:
		_key = key
		queue_redraw()


## Everything the face draw reads, quantized: a redraw happens only when one of these changes. Faces that move on
## their own (dizzy, panic, frozen, melty, sweat, the dead fade) add a clock at face_anim_hz.
func _draw_key() -> Array:
	if not is_instance_valid(body):
		return [&"none"]
	var player := _player
	var r := _body_radius()
	var scale_xy: Vector2 = body.call(&"face_scale")
	var velocity: Vector2 = player.get("velocity") if player else Vector2.ZERO
	var mass: float = player.get("mass") if player else Tuning.mass_max
	var temper: StringName = player.call(&"temperature_expression") if _player_has[&"temperature_expression"] else &""
	var pose: StringName = player.call(&"pose_expression") if _player_has[&"pose_expression"] else &""
	var danger := mass > 0.0 and mass < Tuning.mass_danger
	var animated := danger or temper != &"" or pose == &"dizzy" or _expression == &"tired" or _expression == &"dead"
	var q := Tuning.face_redraw_step
	var ink := Tuning.face_ink_color
	if is_instance_valid(Game.field) and Game.field.has_method(&"body_goo_color"):
		ink = Game.field.call(&"body_goo_color")
	var status: Variant = player.call(&"status_tint") if _player_has[&"status_tint"] else null
	return [_expression, _blink > 0.0, Vector2i((_look * 40.0).round()), Vector2i((scale_xy * 100.0).round()),
		roundi(r / q), _lag_ready, velocity.y > Tuning.face_fall_fast_speed, danger, temper, pose,
		ink.to_rgba32(), (status as Color).to_rgba32() if status is Color else 0, int(_time * Tuning.face_anim_hz) if animated else 0]


func _look_target() -> Vector2:
	var player := _player
	if player == null:
		return Vector2.ZERO
	if _player_has[&"aim_look"]:
		var aim: Vector2 = player.call(&"aim_look")
		if aim != Vector2.ZERO:
			return aim
	if _player_has[&"move_look"]:
		var move_look: Vector2 = player.call(&"move_look")
		if move_look != Vector2.ZERO:
			return move_look
	var velocity: Vector2 = player.get("velocity")
	var speed := velocity.length()
	if speed > Tuning.face_look_speed_min:
		return velocity / speed * clampf(speed / maxf(Tuning.run_speed, 1.0), 0.3, 1.0)
	if is_instance_valid(Game.field) and Game.field.has_method(&"nearest_piece"):
		var target: Variant = Game.field.call(&"nearest_piece", player.global_position, Tuning.face_look_piece_distance)
		if target is Vector2:
			var to_piece: Vector2 = target - player.global_position
			if to_piece.length_squared() > 1.0:
				return to_piece.normalized()
	if is_instance_valid(Game.props) and Game.props.has_method(&"nearest"):
		var prop: Variant = Game.props.call(&"nearest", player.global_position, Tuning.face_look_piece_distance)
		if prop is Vector2:
			var to_prop: Vector2 = prop - player.global_position
			if to_prop.length_squared() > 1.0:
				return to_prop.normalized()
	var facing: float = player.get("facing")
	return Vector2(facing * 0.3, 0.15)


func _follow_anchor(delta: float) -> void:
	if _body_radius() <= 1.0:
		_lag_ready = false
		return
	var target: Vector2 = body.call(&"face_anchor")
	if not _lag_ready:
		_lag_anchor = target
		_lag_vel = Vector2.ZERO
		_lag_ready = true
		return
	_lag_vel += ((target - _lag_anchor) * Tuning.face_lag_stiffness - _lag_vel * Tuning.face_lag_damping) * delta
	_lag_anchor += _lag_vel * delta
	var offset := _lag_anchor - target
	if offset.length() > Tuning.face_lag_max:
		_lag_anchor = target + offset.limit_length(Tuning.face_lag_max)


func _body_radius() -> float:
	if not is_instance_valid(body) or not body.has_method(&"radius"):
		return 0.0
	return float(body.call(&"radius"))


func _draw() -> void:
	_batch.clear()
	_build_face()
	_batch.commit(get_canvas_item())


## The ink takes the hue of the body colour (with the ember or frost tint of the temperature) at a dark value.
func _update_ink(player: Node2D) -> void:
	var base := Tuning.face_ink_color
	if is_instance_valid(Game.field) and Game.field.has_method(&"body_goo_color"):
		base = Game.field.call(&"body_goo_color")
	var status: Variant = player.call(&"status_tint") if player != null and player.has_method(&"status_tint") else null
	if status is Color:
		base = base.lerp(status, (status as Color).a)
	_ink = Color.from_hsv(base.h, clampf(base.s + 0.2, 0.0, 1.0), Tuning.face_ink_value)


func _build_face() -> void:
	if not is_instance_valid(body):
		return
	_update_ink(_player)
	# The node transform holds the roll turn and the anchor: the face is drawn around the origin.
	_spin = Transform2D.IDENTITY
	_batch.transform = _spin
	var r := _body_radius()
	if _expression == &"dead":
		if r <= 1.0:
			if _dead_time < Tuning.face_dead_eyes_time and _last_eye_r > 0.0:
				var fade := 1.0 - _dead_time / Tuning.face_dead_eyes_time
				_draw_dead_eyes(_last_anchor, _last_spread, _last_eye_r, fade)
			return
	if r <= 1.0:
		return
	if not _lag_ready:
		return
	var anchor := Vector2.ZERO
	var scale_xy: Vector2 = body.call(&"face_scale")
	# The face keeps the size it has on a body of Tuning.face_radius; only a smaller body shrinks it.
	var body_k := r / maxf(Tuning.radius_full, 1.0)
	var face_r := minf(r, Tuning.face_radius)
	var k := face_r / maxf(Tuning.face_radius, 1.0)
	var squash := scale_xy.y / maxf(scale_xy.x, 0.001)
	var eye_h := clampf(lerpf(1.0, squash, 0.6), 0.6, 1.3)
	var appear := smoothstep(0.0, Tuning.face_appear_radius, r)
	var eye_r := clampf(10.0 * k, 4.5, 11.0) * appear
	var sx := scale_xy.x / maxf(body_k, 0.001)
	var spread := maxf(0.36 * face_r * sx, eye_r * 1.15)
	anchor += _look * eye_r * 0.15
	_last_anchor = anchor
	_last_spread = spread
	_last_eye_r = eye_r
	var player := get_parent() as Node2D
	var velocity: Vector2 = player.get("velocity") if player else Vector2.ZERO
	var mass: float = player.get("mass") if player else Tuning.mass_max
	var danger := mass > 0.0 and mass < Tuning.mass_danger
	var mouth_pos := anchor + Vector2(0.0, eye_r * 1.25 * eye_h) + _look * eye_r * 0.1
	var temper: StringName = player.call(&"temperature_expression") if player and player.has_method(&"temperature_expression") else &""
	if _draw_temperature_face(temper, anchor, spread, eye_r, eye_h, mouth_pos, face_r * sx, face_r):
		return
	match _expression:
		&"dead":
			_draw_dead_eyes(anchor, spread, eye_r, 1.0)
		&"happy":
			for side: float in [-1.0, 1.0]:
				var c := anchor + Vector2(side * spread, eye_r * 0.3)
				_batch.arc(c, eye_r * 0.75, PI + 0.4, TAU - 0.4, eye_r * 0.38, _ink, false)
			_draw_open_smile(mouth_pos, eye_r * 0.7)
		&"spit":
			# Squeezed eyes and a round mouth blown wide open.
			_draw_eyes(anchor, spread, eye_r, eye_h * 0.45, 0.55, 0.0)
			_draw_ellipse(mouth_pos + Vector2(0.0, eye_r * 0.15), eye_r * 0.55, eye_r * 0.5, Tuning.face_mouth_color)
		&"strain", &"grit", &"alarm", &"dizzy", &"squish":
			_draw_pose(_expression, anchor, spread, eye_r, eye_h, mouth_pos)
		&"surprise":
			_draw_eyes(anchor, spread, eye_r * 1.2, eye_h * 1.15, 0.28, 1.0)
			_draw_raised_brows(anchor, spread, eye_r * 1.2)
			_draw_ellipse(mouth_pos + Vector2(0.0, eye_r * 0.15), eye_r * 0.4, eye_r * 0.45, Tuning.face_mouth_color)
		&"tired":
			_draw_eyes(anchor + Vector2(0.0, eye_r * 0.15), spread, eye_r, eye_h * 0.4, 0.5, 0.0)
			_draw_wavy_mouth(mouth_pos + Vector2(0.0, eye_r * 0.1), eye_r * 0.45)
			_draw_sweat(anchor, face_r * sx, face_r, eye_r)
		&"hurt":
			for side: float in [-1.0, 1.0]:
				var c := anchor + Vector2(side * spread, 0.0)
				var w := eye_r * 0.6 * -side
				var h := eye_r * 0.55
				_batch.stroke(PackedVector2Array([c + Vector2(-w, -h), c + Vector2(w, 0.0), c + Vector2(-w, h)]), eye_r * 0.32, _ink, false, false)
			_draw_wavy_mouth(mouth_pos, eye_r * 0.6)
		_:
			var pose: StringName = player.call(&"pose_expression") if player and player.has_method(&"pose_expression") else &""
			if pose != &"" and velocity.y <= Tuning.face_fall_fast_speed:
				_draw_pose(pose, anchor, spread, eye_r, eye_h, mouth_pos)
			elif velocity.y > Tuning.face_fall_fast_speed:
				_draw_eyes(anchor, spread, eye_r * 1.15, eye_h * 1.1, 0.3, 1.0)
				_draw_ellipse(mouth_pos + Vector2(0.0, eye_r * 0.1), eye_r * 0.32, eye_r * 0.45, Tuning.face_mouth_color)
			else:
				var lid := 0.1 if _blink > 0.0 else 1.0
				_draw_eyes(anchor, spread, eye_r, eye_h * lid, 0.55, lid)
				if danger:
					_draw_brows(anchor, spread, eye_r)
					_draw_wavy_mouth(mouth_pos, eye_r * 0.5)
				else:
					var mw := eye_r * 0.5
					_batch.arc(mouth_pos - Vector2(0.0, mw * 0.6), mw, 0.45, PI - 0.45, eye_r * 0.22, _ink, false)
	if danger and _expression != &"dead":
		_draw_sweat(anchor, face_r * sx, face_r, eye_r)


func _draw_eyes(anchor: Vector2, spread: float, eye_r: float, height: float, pupil_ratio: float, shine: float) -> void:
	for side: float in [-1.0, 1.0]:
		var c := anchor + Vector2(side * spread, 0.0)
		_batch.transform = _spin * Transform2D(0.0, Vector2(1.0, height), 0.0, c)
		_batch.disc(Vector2.ZERO, eye_r + 1.4, _ink)
		_batch.disc(Vector2.ZERO, eye_r, Tuning.face_sclera_color)
		var pupil := _look * eye_r * 0.35
		_batch.disc(pupil, eye_r * pupil_ratio, Tuning.face_pupil_color)
		if shine > 0.5:
			_batch.disc(pupil + Vector2(-0.3, -0.35) * eye_r * pupil_ratio * 1.4, eye_r * 0.2, Tuning.face_shine_color)
	_batch.transform = _spin


## Faces of the moves: grit (run, wall), alarm (skid), strain (dodge, push, hard bonk), dizzy (roll), squish (crouch).
func _draw_pose(pose: StringName, anchor: Vector2, spread: float, eye_r: float, eye_h: float, mouth_pos: Vector2) -> void:
	match pose:
		&"grit":
			_draw_eyes(anchor, spread, eye_r, eye_h * 0.62, 0.6, 1.0)
			# Determined brows: high at the outer end, low toward the nose.
			for side: float in [-1.0, 1.0]:
				var b := anchor + Vector2(side * spread, -eye_r * 1.2)
				_batch.stroke(PackedVector2Array([b + Vector2(side * eye_r * 0.75, -eye_r * 0.35), b + Vector2(-side * eye_r * 0.55, eye_r * 0.1)]), eye_r * 0.26, _ink, false, true)
			var w := eye_r * 0.55
			_batch.stroke(PackedVector2Array([mouth_pos + Vector2(-w, eye_r * 0.05), mouth_pos + Vector2(0.0, -eye_r * 0.05), mouth_pos + Vector2(w, eye_r * 0.05)]), maxf(eye_r * 0.22, 1.0), _ink, false, false)
		&"alarm":
			_draw_eyes(anchor, spread, eye_r * 1.22, eye_h * 1.15, 0.26, 1.0)
			_draw_raised_brows(anchor, spread, eye_r * 1.22)
			_draw_ellipse(mouth_pos + Vector2(0.0, eye_r * 0.2), eye_r * 0.62, eye_r * 0.38, Tuning.face_mouth_color)
		&"strain":
			for side: float in [-1.0, 1.0]:
				var c := anchor + Vector2(side * spread, 0.0)
				var w := eye_r * 0.7
				_batch.stroke(PackedVector2Array([c + Vector2(-w, -eye_r * 0.3 * side), c + Vector2(w, eye_r * 0.3 * side)]), eye_r * 0.36, _ink, false, true)
			_draw_ellipse(mouth_pos + Vector2(0.0, eye_r * 0.1), eye_r * 0.3, eye_r * 0.26, Tuning.face_mouth_color)
		&"dizzy":
			var turn := _time * 9.0
			for side: float in [-1.0, 1.0]:
				var c := anchor + Vector2(side * spread, 0.0)
				_batch.disc(c, eye_r * 1.05, Tuning.face_sclera_color)
				_batch.arc(c, eye_r * 0.72, turn, turn + TAU * 0.75, eye_r * 0.22, _ink, true)
				_batch.arc(c, eye_r * 0.36, turn + PI, turn + PI + TAU * 0.6, eye_r * 0.2, _ink, true)
			_draw_wavy_mouth(mouth_pos, eye_r * 0.45)
		_:
			var lid := 0.1 if _blink > 0.0 else 0.62
			_draw_eyes(anchor, spread, eye_r, eye_h * lid, 0.6, lid)
			var mw := eye_r * 0.4
			_batch.arc(mouth_pos - Vector2(0.0, mw * 0.6), mw, 0.45, PI - 0.45, eye_r * 0.2, _ink, false)


## Faces of the temperature. Panic (burning) wins over every timed face but the hurt and death ones; the ice cube
## face cannot change at all; the melted face only replaces the resting face. Returns true when it drew one.
func _draw_temperature_face(temper: StringName, anchor: Vector2, spread: float, eye_r: float, eye_h: float, mouth_pos: Vector2, half_width: float, r: float) -> bool:
	if _expression == &"dead":
		return false
	match temper:
		&"panic":
			if _expression == &"hurt":
				return false
			var jitter := Vector2(sin(_time * 53.0), cos(_time * 47.0)) * eye_r * 0.12
			_draw_eyes(anchor + jitter, spread, eye_r * 1.25, eye_h * 1.2, 0.18, 1.0)
			_draw_raised_brows(anchor + jitter, spread, eye_r * 1.3)
			var scream := 1.0 + 0.15 * sin(_time * 31.0)
			_draw_ellipse(mouth_pos + Vector2(0.0, eye_r * 0.35), eye_r * 0.5, eye_r * 0.75 * scream, Tuning.face_mouth_color)
			_draw_ellipse(mouth_pos + Vector2(0.0, eye_r * 0.7), eye_r * 0.28, eye_r * 0.22, Tuning.face_tongue_color)
			_draw_sweat(anchor, half_width, r, eye_r)
			_draw_sweat(anchor + Vector2(-half_width * 1.9, eye_r * 0.4), half_width, r, eye_r * 0.8)
			return true
		&"frozen":
			# Wide, fixed eyes with no blink, and teeth that chatter behind a stiff mouth.
			_draw_eyes(anchor, spread, eye_r * 1.05, eye_h * 0.85, 0.42, 1.0)
			var w := eye_r * 0.7
			var chatter := eye_r * 0.08 * sin(_time * 40.0)
			var teeth := PackedVector2Array()
			for i: int in 7:
				var t := float(i) / 6.0
				teeth.append(mouth_pos + Vector2(lerpf(-w, w, t) + chatter, (eye_r * 0.12) * (1.0 if i % 2 == 0 else -1.0)))
			_draw_ellipse(mouth_pos, w * 1.1, eye_r * 0.32, Tuning.face_mouth_color)
			_batch.stroke(teeth, maxf(eye_r * 0.14, 1.0), Tuning.face_sclera_color, false, false)
			_draw_brows(anchor, spread, eye_r)
			return true
		&"melty":
			if _expression != &"normal":
				return false
			# Eyes that sag at the outer side and a mouth that runs down at the corners.
			var droop := 0.15 * sin(_time * 2.0)
			for side: float in [-1.0, 1.0]:
				var c := anchor + Vector2(side * spread, eye_r * 0.2)
				_batch.transform = _spin * Transform2D(side * (0.25 + droop), Vector2(1.0, eye_h * 0.75), 0.0, c)
				_batch.disc(Vector2.ZERO, eye_r + 1.4, _ink)
				_batch.disc(Vector2.ZERO, eye_r, Tuning.face_sclera_color)
				_batch.disc(_look * eye_r * 0.35 + Vector2(0.0, eye_r * 0.25), eye_r * 0.5, Tuning.face_pupil_color)
				_batch.arc(Vector2(0.0, -eye_r * 0.25), eye_r * 0.8, PI + 0.15, TAU - 0.15, eye_r * 0.55, _ink, false)
			_batch.transform = _spin
			var mw := eye_r * 0.65
			var points := PackedVector2Array()
			for i: int in 9:
				var t := float(i) / 8.0
				points.append(mouth_pos + Vector2(lerpf(-mw, mw, t), -sin(PI * t) * eye_r * 0.25 + absf(t - 0.5) * eye_r * 0.5))
			_batch.stroke(points, maxf(eye_r * 0.22, 1.0), _ink, false, false)
			return true
	return false


func _draw_raised_brows(anchor: Vector2, spread: float, eye_r: float) -> void:
	for side: float in [-1.0, 1.0]:
		var c := anchor + Vector2(side * spread, -eye_r * 1.35)
		_batch.arc(c, eye_r * 0.7, PI + 0.5, TAU - 0.5, eye_r * 0.22, _ink, true)


func _draw_dead_eyes(anchor: Vector2, spread: float, eye_r: float, alpha: float) -> void:
	var ink := Color(_ink, alpha)
	var s := eye_r * 0.6
	for side: float in [-1.0, 1.0]:
		var c := anchor + Vector2(side * spread, 0.0)
		_batch.stroke(PackedVector2Array([c + Vector2(-s, -s), c + Vector2(s, s)]), eye_r * 0.32, ink, false, false)
		_batch.stroke(PackedVector2Array([c + Vector2(-s, s), c + Vector2(s, -s)]), eye_r * 0.32, ink, false, false)


func _draw_open_smile(center: Vector2, width: float) -> void:
	var points := PackedVector2Array()
	var segments := 10
	for i: int in segments + 1:
		var a := PI * float(i) / float(segments)
		points.append(center + Vector2(cos(a) * width, sin(a) * width * 0.8))
	_batch.feather = 0.0
	_batch.polygon(points, Tuning.face_mouth_color)
	_batch.feather = ShapeBatch.SOFT_EDGE
	_batch.disc(center + Vector2(0.0, width * 0.5), width * 0.32, Tuning.face_tongue_color)
	_batch.stroke(points, maxf(width * 0.18, 1.0), _ink, true)


func _draw_wavy_mouth(center: Vector2, width: float) -> void:
	var points := PackedVector2Array()
	var segments := 8
	for i: int in segments + 1:
		var t := float(i) / float(segments)
		points.append(center + Vector2(lerpf(-width, width, t), sin(t * TAU * 1.5) * width * 0.18))
	_batch.stroke(points, maxf(width * 0.3, 1.0), _ink, false, false)


func _draw_brows(anchor: Vector2, spread: float, eye_r: float) -> void:
	for side: float in [-1.0, 1.0]:
		var c := anchor + Vector2(side * spread, -eye_r * 1.45)
		_batch.stroke(PackedVector2Array([c + Vector2(-side * eye_r * 0.7, -eye_r * 0.3), c + Vector2(side * eye_r * 0.5, eye_r * 0.05)]), eye_r * 0.25, _ink, false, false)


func _draw_sweat(anchor: Vector2, half_width: float, r: float, eye_r: float) -> void:
	var t := fmod(_time, Tuning.face_sweat_cycle) / Tuning.face_sweat_cycle
	var size := maxf(2.5, eye_r * 0.4)
	var c := anchor + Vector2(half_width * 0.95 + size, -r * 0.2 + t * r * 0.45)
	var color := Color(Tuning.face_sweat_color, Tuning.face_sweat_color.a * (1.0 - t * t))
	_batch.disc(c, size, color)
	_batch.feather = 0.0
	_batch.polygon(PackedVector2Array([c + Vector2(-size * 0.85, -size * 0.5), c + Vector2(0.0, -size * 2.2), c + Vector2(size * 0.85, -size * 0.5)]), color)
	_batch.feather = ShapeBatch.SOFT_EDGE
	_batch.disc(c + Vector2(-size * 0.35, -size * 0.2), size * 0.3, Color(1.0, 1.0, 1.0, color.a * 0.8))


func _draw_ellipse(center: Vector2, rx: float, ry: float, color: Color) -> void:
	_batch.polygon(ShapeBatch.circle_points(center, Vector2(rx, ry), 0.0), color)
