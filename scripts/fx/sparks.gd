extends Node2D
## Cosmetic impact effects with no gameplay effect: additive sparks, rings and glints, plus solid debris (shards, spores)
## that bounce on solid ground. Everything draws in two canvas items, one per blend mode.

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

enum Kind { SPARK, RING, GLINT, SHARD, BLOB }

const RNG_SEED := 5150
const SHARD_SPIN := 14.0
const SETTLE_SPEED := 40.0

var _pos := PackedVector2Array()
var _prev := PackedVector2Array()
var _vel := PackedVector2Array()
var _life := PackedFloat32Array()
var _life_max := PackedFloat32Array()
var _size := PackedFloat32Array()
var _angle := PackedFloat32Array()
var _spin := PackedFloat32Array()
var _kind := PackedByteArray()
var _color := PackedColorArray()
var _count := 0
var _dirty := false
var _query := PhysicsPointQueryParameters2D.new()
var _rng := RandomNumberGenerator.new()
var _debris: Node2D
var _spark_batch := ShapeBatch.new()
var _debris_batch := ShapeBatch.new()


func _ready() -> void:
	var cap: int = maxi(Tuning.sparks_max, 1)
	_pos.resize(cap)
	_prev.resize(cap)
	_vel.resize(cap)
	_life.resize(cap)
	_life_max.resize(cap)
	_size.resize(cap)
	_angle.resize(cap)
	_spin.resize(cap)
	_kind.resize(cap)
	_color.resize(cap)
	_query.collision_mask = Tuning.LAYER_WORLD
	_query.collide_with_areas = false
	_query.collide_with_bodies = true
	_rng.seed = RNG_SEED
	z_index = Tuning.over_goo_z_index
	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = additive
	_debris = Node2D.new()
	_debris.name = "Debris"
	add_child(_debris)
	_debris.draw.connect(_draw_debris)
	Juice.sparks = self


func _exit_tree() -> void:
	if Juice.sparks == self:
		Juice.sparks = null


## Hot streaks thrown off a hit along normal. speed and size are (min, max).
func sparks(at: Vector2, normal: Vector2, count: int, speed: Vector2, spread_deg: float, color: Color, size := Vector2(1.5, 3.0)) -> void:
	var base := normal.angle() if normal != Vector2.ZERO else -PI * 0.5
	for i: int in maxi(count, 0):
		var a := base + deg_to_rad(_rng.randf_range(-spread_deg, spread_deg))
		var v := Vector2.from_angle(a) * _rng.randf_range(speed.x, speed.y)
		_add(Kind.SPARK, at, v, _rng.randf_range(Tuning.spark_life.x, Tuning.spark_life.y), _rng.randf_range(size.x, size.y), color)


## Solid pieces that fly, bounce on the ground and fade: triangle shards or round blobs, colors picked from the list.
func debris(at: Vector2, dir: Vector2, count: int, speed: Vector2, spread_deg: float, size: Vector2, colors: PackedColorArray, round_shape := false) -> void:
	if colors.is_empty():
		return
	var base := dir.angle() if dir != Vector2.ZERO else -PI * 0.5
	var kind := Kind.BLOB if round_shape else Kind.SHARD
	for i: int in maxi(count, 0):
		var a := base + deg_to_rad(_rng.randf_range(-spread_deg, spread_deg))
		var v := Vector2.from_angle(a) * _rng.randf_range(speed.x, speed.y)
		var idx := _add(kind, at, v, _rng.randf_range(Tuning.debris_life.x, Tuning.debris_life.y), _rng.randf_range(size.x, size.y), colors[i % colors.size()])
		if idx >= 0:
			_angle[idx] = _rng.randf_range(0.0, TAU)
			_spin[idx] = _rng.randf_range(-SHARD_SPIN, SHARD_SPIN)


## Expanding shock ring that fades out.
func ring(at: Vector2, radius: float, color: Color, seconds: float) -> void:
	if _far_from_view(at, radius):
		_skip_add(seconds, radius)
		return
	_add(Kind.RING, at, Vector2.ZERO, seconds, radius, color)


## Four-point star that flares and fades.
func glint(at: Vector2, size: float, color: Color, seconds: float) -> void:
	if _far_from_view(at, size):
		if _skip_add(seconds, size):
			_rng.randf_range(0.0, PI * 0.5)
		return
	var idx := _add(Kind.GLINT, at, Vector2.ZERO, seconds, size, color)
	if idx >= 0:
		_angle[idx] = _rng.randf_range(0.0, PI * 0.5)


## A ring or glint that starts this far out of view stays out of sight for its short life.
func _far_from_view(at: Vector2, size: float) -> bool:
	return not _view_rect(Tuning.tile_size * 4.0 + size).has_point(at)


## Takes the random numbers that _add would take for an effect that is skipped, so later effects stay the same.
func _skip_add(life: float, size: float) -> bool:
	if life <= 0.0 or size <= 0.0:
		return false
	if _count >= _pos.size():
		_rng.randi()
	return true


func _view_rect(margin: float) -> Rect2:
	var viewport := get_viewport()
	return (viewport.get_canvas_transform().affine_inverse() * viewport.get_visible_rect()).grow(margin)


func clear() -> void:
	_count = 0
	_dirty = true


func count() -> int:
	return _count


func _add(kind: Kind, p: Vector2, v: Vector2, life: float, size: float, color: Color) -> int:
	if life <= 0.0 or size <= 0.0:
		return -1
	var i := _count
	if _count >= _pos.size():
		i = _rng.randi() % _pos.size()
	else:
		_count += 1
	_pos[i] = p
	_prev[i] = p
	_vel[i] = v
	_life[i] = life
	_life_max[i] = life
	_size[i] = size
	_angle[i] = 0.0
	_spin[i] = 0.0
	_kind[i] = kind
	_color[i] = color
	_dirty = true
	return i


func _remove(i: int) -> void:
	_count -= 1
	_pos[i] = _pos[_count]
	_prev[i] = _prev[_count]
	_vel[i] = _vel[_count]
	_life[i] = _life[_count]
	_life_max[i] = _life_max[_count]
	_size[i] = _size[_count]
	_angle[i] = _angle[_count]
	_spin[i] = _spin[_count]
	_kind[i] = _kind[_count]
	_color[i] = _color[_count]


func _physics_process(delta: float) -> void:
	if _count == 0:
		return
	var space := get_world_2d().direct_space_state
	var i := 0
	while i < _count:
		_life[i] -= delta
		if _life[i] <= 0.0:
			_remove(i)
			continue
		_prev[i] = _pos[i]
		match _kind[i]:
			Kind.SPARK:
				var v := _vel[i]
				v.y += Tuning.spark_gravity * delta
				v *= maxf(1.0 - Tuning.spark_drag * delta, 0.0)
				_vel[i] = v
				_pos[i] += v * delta
				if _solid(space, _pos[i]):
					_life[i] = minf(_life[i], delta)
			Kind.SHARD, Kind.BLOB:
				_step_debris(i, space, delta)
		i += 1
	_dirty = true


func _step_debris(i: int, space: PhysicsDirectSpaceState2D, delta: float) -> void:
	var v := _vel[i]
	if v == Vector2.ZERO:
		return
	v.y += Tuning.debris_gravity * delta
	var p := _pos[i]
	var next := p + v * delta
	if _solid(space, next):
		if _solid(space, Vector2(next.x, p.y)):
			v.x = -v.x * Tuning.debris_bounce
		else:
			v.y = -v.y * Tuning.debris_bounce
			v.x *= 0.7
		_spin[i] *= 0.5
		if v.length() < SETTLE_SPEED:
			v = Vector2.ZERO
		next = p
	_vel[i] = v
	_pos[i] = next
	_angle[i] += _spin[i] * delta


func _solid(space: PhysicsDirectSpaceState2D, at: Vector2) -> bool:
	_query.position = at
	return not space.intersect_point(_query, 1).is_empty()


func _process(_delta: float) -> void:
	visible = Tuning.fx_sparks
	if _dirty:
		_dirty = _count > 0
		queue_redraw()
		_debris.queue_redraw()


func _draw() -> void:
	var batch := _spark_batch
	batch.clear()
	var f := Engine.get_physics_interpolation_fraction()
	var view := _view_rect(Tuning.tile_size)
	for i: int in _count:
		var kind := _kind[i]
		if kind == Kind.SHARD or kind == Kind.BLOB:
			continue
		var p := _prev[i].lerp(_pos[i], f)
		if not view.grow(_size[i] + 12.0).has_point(p):
			if kind != Kind.SPARK or not view.grow(_size[i] + _vel[i].length() * Tuning.spark_stretch + 4.0).has_point(p):
				continue
		var t := clampf(_life[i] / maxf(_life_max[i], 0.001), 0.0, 1.0)
		var c := _color[i]
		match kind:
			Kind.SPARK:
				var tail := _vel[i] * Tuning.spark_stretch
				batch.stroke(PackedVector2Array([p - tail, p]), _size[i] * (0.5 + 0.5 * t), Color(c, c.a * t), false, false)
			Kind.RING:
				var grow := 1.0 - t
				batch.ring(p, _size[i] * (0.25 + 0.75 * (1.0 - (1.0 - grow) * (1.0 - grow))), 2.0 + 8.0 * t, Color(c, c.a * t))
			Kind.GLINT:
				var flare := sin(PI * (1.0 - t))
				var s := _size[i] * flare
				var ax := Vector2.from_angle(_angle[i])
				var ay := ax.orthogonal()
				var col := Color(c, c.a * flare)
				batch.stroke(PackedVector2Array([p - ax * s, p + ax * s]), maxf(s * 0.18, 1.0), col, false, false)
				batch.stroke(PackedVector2Array([p - ay * s * 0.7, p + ay * s * 0.7]), maxf(s * 0.14, 1.0), col, false, false)
	batch.commit(get_canvas_item())


func _draw_debris() -> void:
	var batch := _debris_batch
	batch.clear()
	var f := Engine.get_physics_interpolation_fraction()
	var view := _view_rect(Tuning.tile_size)
	for i: int in _count:
		var kind := _kind[i]
		if kind != Kind.SHARD and kind != Kind.BLOB:
			continue
		var p := _prev[i].lerp(_pos[i], f)
		if not view.grow(_size[i] + 4.0).has_point(p):
			continue
		var alpha := clampf(_life[i] / Tuning.debris_fade_time, 0.0, 1.0)
		var c := Color(_color[i], _color[i].a * alpha)
		var s := _size[i]
		if kind == Kind.BLOB:
			batch.feather = ShapeBatch.SOFT_EDGE
			batch.disc(p, s * (0.6 + 0.4 * alpha), c)
			continue
		var ax := Vector2.from_angle(_angle[i])
		var ay := ax.orthogonal()
		batch.feather = 0.0
		batch.polygon(PackedVector2Array([p + ax * s, p + ay * s * 0.35 - ax * s * 0.4, p - ay * s * 0.35 - ax * s * 0.4]), c)
	batch.commit(_debris.get_canvas_item())
