extends Node2D
## Look of the temperature on the slime body, drawn over the goo and under the face: a frost crust, cracks, corner
## glints and cold breath while it freezes and steam wisps while it melts, in one batch; the fire is its BodyFire
## child (scripts/fire/body_fire.gd). The body tint itself goes through GooField.set_body_status (player.gd).
## Visual only: it uses its own RNG and never touches gameplay state.

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")
const BodyFire := preload("res://scripts/fire/body_fire.gd")

const PUFF_MAX := 40
const EDGE_POINTS := 28
const CRACKS := [
	[Vector2(-0.55, -0.35), Vector2(-0.2, -0.1), Vector2(-0.3, 0.3)],
	[Vector2(0.15, -0.6), Vector2(0.35, -0.2), Vector2(0.65, -0.05)],
	[Vector2(0.1, 0.15), Vector2(0.4, 0.45)],
]
const CORNERS := [Vector2(-1.0, -1.0), Vector2(1.0, -1.0), Vector2(1.0, 1.0), Vector2(-1.0, 1.0)]

enum Puff { BREATH, STEAM }

var body: Node2D:
	set(value):
		body = value
		_fire.body = value
var _melt := 0.0
var _frost := 0.0
var _facing := 1.0
var _time := 0.0
var _breath_wait := 0.0
var _steam_wait := 0.0
var _rng := RandomNumberGenerator.new()
var _batch := ShapeBatch.new()
var _drawn := false
var _fire := BodyFire.new()

var _p_pos := PackedVector2Array()
var _p_vel := PackedVector2Array()
var _p_life := PackedFloat32Array()
var _p_life_max := PackedFloat32Array()
var _p_size := PackedFloat32Array()
var _p_kind := PackedByteArray()
var _p_count := 0


func _ready() -> void:
	_rng.seed = 4242
	_p_pos.resize(PUFF_MAX)
	_p_vel.resize(PUFF_MAX)
	_p_life.resize(PUFF_MAX)
	_p_life_max.resize(PUFF_MAX)
	_p_size.resize(PUFF_MAX)
	_p_kind.resize(PUFF_MAX)
	_fire.name = &"BodyFire"
	add_child(_fire)


## From the player once per physics tick: melt and frost 0..1, fire 0..1 (0 when not burning), and the facing side.
func set_state(melt: float, frost: float, fire: float, facing: float) -> void:
	_melt = melt
	_frost = frost
	_fire.set_fire(fire)
	_facing = facing


func clear() -> void:
	_p_count = 0
	_melt = 0.0
	_frost = 0.0
	_fire.clear()
	queue_redraw()


## A few frames of every look at almost no opacity, behind the loading cover.
func warm_up() -> void:
	_fire.warm_up()
	_frost = 1.0
	_melt = 1.0
	for kind: int in [Puff.BREATH, Puff.STEAM]:
		_emit(kind, Vector2.ZERO, Vector2.UP * 10.0, 4.0, 0.3)
	queue_redraw()
	await get_tree().process_frame
	await get_tree().process_frame
	clear()


func _process(delta: float) -> void:
	_time += delta
	_step_puffs(delta)
	var r := _body_radius()
	if r > 1.0:
		_spawn(delta, r)
	# The melt only spawns steam puffs; _draw reads the puffs and the frost.
	if _frost > 0.01 or _p_count > 0 or _drawn:
		queue_redraw()


func _spawn(delta: float, r: float) -> void:
	var size := r / maxf(Tuning.radius_full, 1.0)
	if _frost > 0.3:
		_breath_wait -= delta
		if _breath_wait <= 0.0:
			_breath_wait = _rng.randf_range(0.5, 0.9)
			var mouth: Vector2 = body.call(&"surface_point", Vector2(_facing, -0.1))
			for k: int in 2:
				_emit(Puff.BREATH, mouth, Vector2(_facing * _rng.randf_range(20.0, 45.0), _rng.randf_range(-12.0, -2.0)), _rng.randf_range(4.0, 7.0) * size * Tuning.character_scale, _rng.randf_range(0.8, 1.3))
	if _melt > 0.1 and not _fire.is_burning():
		_steam_wait -= delta
		if _steam_wait <= 0.0:
			_steam_wait = lerpf(0.4, 0.12, _melt)
			var at: Vector2 = body.call(&"surface_point", Vector2(_rng.randf_range(-1.0, 1.0), -1.0))
			_emit(Puff.STEAM, at, Vector2(_rng.randf_range(-10.0, 10.0), -_rng.randf_range(40.0, 70.0)), _rng.randf_range(3.0, 5.0) * size * Tuning.character_scale, _rng.randf_range(0.6, 1.0))


func _emit(kind: int, at: Vector2, vel: Vector2, size: float, life: float) -> void:
	if _p_count >= PUFF_MAX:
		return
	var i := _p_count
	_p_count += 1
	_p_pos[i] = at
	_p_vel[i] = vel
	_p_life[i] = life
	_p_life_max[i] = life
	_p_size[i] = size
	_p_kind[i] = kind


## Puffs live in the player's local space but must not follow it, so each one moves back by the player's motion.
func _step_puffs(delta: float) -> void:
	var player := get_parent() as Node2D
	var drift := Vector2.ZERO
	if player != null:
		var velocity: Variant = player.get(&"velocity")
		if velocity is Vector2:
			drift = -(velocity as Vector2) * delta
	var i := 0
	while i < _p_count:
		_p_life[i] -= delta
		if _p_life[i] <= 0.0:
			_p_count -= 1
			_p_pos[i] = _p_pos[_p_count]
			_p_vel[i] = _p_vel[_p_count]
			_p_life[i] = _p_life[_p_count]
			_p_life_max[i] = _p_life_max[_p_count]
			_p_size[i] = _p_size[_p_count]
			_p_kind[i] = _p_kind[_p_count]
			continue
		_p_vel[i] *= maxf(1.0 - 1.2 * delta, 0.0)
		_p_pos[i] += _p_vel[i] * delta + drift
		i += 1


func _body_radius() -> float:
	if not is_instance_valid(body) or not body.has_method(&"radius"):
		return 0.0
	return float(body.call(&"radius"))


func _draw() -> void:
	_batch.clear()
	var r := _body_radius()
	_draw_puffs()
	if r > 1.0 and _frost > 0.01:
		_draw_frost(r)
	_drawn = not _batch_is_empty()
	_batch.commit(get_canvas_item())


func _batch_is_empty() -> bool:
	return _p_count == 0 and _frost <= 0.01


func _draw_puffs() -> void:
	for i: int in _p_count:
		var share := 1.0 - _p_life[i] / maxf(_p_life_max[i], 0.001)
		var grow := lerpf(0.6, 1.6, share)
		var fade := sin(PI * minf(share * 1.3, 1.0))
		match _p_kind[i]:
			Puff.BREATH:
				var c := Tuning.frost_breath_color
				_batch.disc(_p_pos[i], _p_size[i] * grow, Color(c, c.a * fade))
			Puff.STEAM:
				var c := Tuning.heat_steam_color
				_batch.disc(_p_pos[i], _p_size[i] * grow, Color(c, c.a * 2.0 * fade))


func _contour(r: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for k: int in EDGE_POINTS:
		points.append(body.call(&"surface_point", Vector2.from_angle(TAU * k / EDGE_POINTS)))
	return points


func _draw_frost(r: float) -> void:
	var f := _frost
	var crust := Tuning.frost_crust_color
	_batch.stroke(_contour(r), maxf(2.5 * Tuning.character_scale * f, 1.0), Color(crust, crust.a * f), true)
	if f > 0.35:
		var crack_alpha := smoothstep(0.35, 1.0, f)
		for line: Array in CRACKS:
			var points := PackedVector2Array()
			for p: Vector2 in line:
				points.append(body.call(&"deform_point", p * r * 0.85))
			_batch.stroke(points, maxf(1.2 * Tuning.character_scale, 1.0), Color(Tuning.frost_crack_color, Tuning.frost_crack_color.a * crack_alpha), false, false)
		# A pale highlight band across the upper face of the ice.
		var a: Vector2 = body.call(&"surface_point", Vector2(-1.0, -0.55))
		var b: Vector2 = body.call(&"surface_point", Vector2(-0.35, -1.0))
		_batch.stroke(PackedVector2Array([a.lerp(b, 0.15) + (b - a).orthogonal().normalized() * -6.0, a.lerp(b, 0.85) + (b - a).orthogonal().normalized() * -6.0]), 3.0 * Tuning.character_scale, Color(1.0, 1.0, 1.0, 0.45 * crack_alpha), false)
	for k: int in CORNERS.size():
		var cycle := 1.4 + 0.37 * k
		var share := fposmod(_time / cycle + 0.29 * k, 1.0)
		if share > 0.3:
			continue
		var flare := sin(PI * share / 0.3) * f
		var at: Vector2 = body.call(&"surface_point", CORNERS[k])
		var s := 7.0 * Tuning.character_scale * flare
		var c := Color(Tuning.frost_glint_color, flare)
		_batch.stroke(PackedVector2Array([at - Vector2(s, 0.0), at + Vector2(s, 0.0)]), maxf(s * 0.2, 1.0), c, false, false)
		_batch.stroke(PackedVector2Array([at - Vector2(0.0, s), at + Vector2(0.0, s)]), maxf(s * 0.2, 1.0), c, false, false)
