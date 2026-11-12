extends Node2D
## Burning embers shed by ember shots: they fall, lie on the ground for a short time and burn any enemy that touches
## them (never the slime). One pool, one draw. Enemies are found through their shell bodies on
## Tuning.LAYER_ENEMIES; a hit goes through the same shot_hit(hit) contract as a shot, with "source" &"ember_trail".
## Each ember looks like a real coal (fire.gdshader, kind ember): a glow core that pulses and cools from yellow to
## dark red, a tiny flame and a thin smoke while it is fresh. The embers are instances of one MultiMesh: a falling
## ember moves its instance each physics tick, a resting one only changes its heat a few times a second.

const FireAssets := preload("res://scripts/fire/fire_assets.gd")
const FireQuad := preload("res://scripts/fire/fire_quad.gd")

var _pos := PackedVector2Array()
var _vel := PackedVector2Array()
var _life := PackedFloat32Array()
var _life_max := PackedFloat32Array()
var _resting := PackedByteArray()
var _count := 0
var _tick := 0
var _warm_frames := 0
var _view := MultiMeshInstance2D.new()
var _seed := PackedFloat32Array()
## Target instance id -> physics frame of its last ember hit.
var _last_hit := {}
var _point := PhysicsPointQueryParameters2D.new()
var _shape_query := PhysicsShapeQueryParameters2D.new()
var _circle := CircleShape2D.new()


func _ready() -> void:
	var cap := maxi(Tuning.ember_max, 1)
	_pos.resize(cap)
	_vel.resize(cap)
	_life.resize(cap)
	_life_max.resize(cap)
	_resting.resize(cap)
	_point.collision_mask = Tuning.LAYER_WORLD | Tuning.LAYER_PLATFORMS | Tuning.LAYER_GRATES
	_circle.radius = Tuning.ember_hit_radius
	_shape_query.shape = _circle
	_shape_query.collision_mask = Tuning.LAYER_ENEMIES
	_shape_query.collide_with_bodies = true
	_shape_query.collide_with_areas = false
	_seed.resize(cap)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.use_colors = true
	multimesh.mesh = _ember_mesh()
	multimesh.instance_count = cap
	multimesh.visible_instance_count = 0
	_view.multimesh = multimesh
	_view.material = FireAssets.fire_material()
	add_child(_view)
	set_process(false)


## One ember from a flying ember shot at `at`, with a little of the shot speed.
func shed(at: Vector2, carry: Vector2) -> void:
	var i := _count
	if _count >= _pos.size():
		i = _oldest()
	else:
		_count += 1
	_pos[i] = at
	_vel[i] = carry * 0.15 + Vector2(Game.rng.randf_range(-1.0, 1.0) * Tuning.ember_shed_speed.x, -Game.rng.randf_range(0.0, Tuning.ember_shed_speed.y))
	var life := Game.rng.randf_range(Tuning.ember_ground_life.x, Tuning.ember_ground_life.y)
	_life[i] = life
	_life_max[i] = life
	_resting[i] = 0
	_seed[i] = fposmod(at.x * 0.0131 + at.y * 0.0071, 1.0)
	_view.multimesh.visible_instance_count = _count
	_show(i)


## Draws one ember for a few frames behind the loading cover, so the first real ones do not hitch.
func warm_up(at: Vector2) -> void:
	if _count > 0:
		return
	_warm_frames = 3
	_view.multimesh.set_instance_transform_2d(0, Transform2D(0.0, to_local(at)))
	_view.multimesh.set_instance_color(0, Color(0.0, 0.0, 0.0, 0.004))
	_view.multimesh.visible_instance_count = 1
	set_process(true)


func count() -> int:
	return _count


func clear() -> void:
	_count = 0
	_last_hit.clear()
	_view.multimesh.visible_instance_count = 0


func _oldest() -> int:
	var best := 0
	for i: int in _count:
		if _life[i] < _life[best]:
			best = i
	return best


func _physics_process(delta: float) -> void:
	if _count == 0:
		return
	_tick += 1
	var space := get_world_2d().direct_space_state
	var check := _tick % maxi(Tuning.ember_check_ticks, 1) == 0
	var i := 0
	while i < _count:
		_life[i] -= delta
		if _life[i] <= 0.0:
			_remove(i)
			continue
		if _resting[i] == 0:
			var v := _vel[i]
			v.y += Tuning.ember_gravity * delta
			var next := _pos[i] + v * delta
			_point.position = next
			if not space.intersect_point(_point, 1).is_empty():
				_resting[i] = 1
				v = Vector2.ZERO
				next = _pos[i]
			_vel[i] = v
			_pos[i] = next
		if check:
			_burn_enemies(space, _pos[i])
		if _resting[i] == 0 or _tick % Tuning.ember_view_ticks == 0:
			_show(i)
		i += 1


func _burn_enemies(space: PhysicsDirectSpaceState2D, at: Vector2) -> void:
	_shape_query.transform = Transform2D(0.0, at)
	var frame := Engine.get_physics_frames()
	var cooldown := int(Tuning.ember_hit_interval * Engine.physics_ticks_per_second)
	for hit: Dictionary in space.intersect_shape(_shape_query, 4):
		var target := _target_of(hit.collider)
		if target == null:
			continue
		var id := target.get_instance_id()
		if frame - int(_last_hit.get(id, -100000)) < cooldown:
			continue
		_last_hit[id] = frame
		var result: Dictionary = target.call(&"shot_hit", {"at": at, "dir": Vector2.UP, "speed": 0.0, "kind": &"ember", "prop": null, "damage": 1, "source": &"ember_trail"})
		if bool(result.get("hit", false)):
			if is_instance_valid(Juice.sparks):
				Juice.sparks.call(&"sparks", at, Vector2.UP, 10, Vector2(120.0, 360.0), 60.0, Tuning.ember_hot)
			Sfx.play(&"sizzle", at, 1.3, -6.0)
			Game.report_temperature(&"ember_hit", {"source": &"trail", "damage": 1, "at": at})


static func _target_of(collider: Object) -> Object:
	if collider == null:
		return null
	if collider.has_method(&"shot_hit"):
		return collider
	var parent := (collider as Node).get_parent() if collider is Node else null
	if parent != null and parent.has_method(&"shot_hit"):
		return parent
	return null


func _remove(i: int) -> void:
	_count -= 1
	_pos[i] = _pos[_count]
	_vel[i] = _vel[_count]
	_life[i] = _life[_count]
	_life_max[i] = _life_max[_count]
	_resting[i] = _resting[_count]
	_seed[i] = _seed[_count]
	_view.multimesh.visible_instance_count = _count
	if i < _count:
		_show(i)


## Ends the warm-up instance after a few frames.
func _process(_delta: float) -> void:
	_warm_frames -= 1
	if _warm_frames <= 0:
		_view.multimesh.visible_instance_count = _count
		set_process(false)


## Puts ember i into its instance: where it is, leaning against its flight while it falls, and how hot it is.
func _show(i: int) -> void:
	var share := clampf(_life[i] / maxf(_life_max[i], 0.001), 0.0, 1.0)
	var fresh := clampf((share - Tuning.ember_flame_share) / (1.0 - Tuning.ember_flame_share), 0.0, 1.0)
	var up := Vector2.UP
	if _resting[i] == 0:
		up = (Vector2.UP - _vel[i] * Tuning.fire_lean_per_speed).normalized()
	var size := lerpf(0.55, 1.0, share)
	_view.multimesh.set_instance_transform_2d(i, Transform2D(up.angle() + PI * 0.5, Vector2(size, size), 0.0, to_local(_pos[i])))
	_view.multimesh.set_instance_color(i, Color(share, fresh, _seed[i], 1.0))


## The quad of one ember, in units of the ember radius: 7 wide, 12 tall, the coal at 82 % of its height.
static func _ember_mesh() -> ArrayMesh:
	var r := Tuning.ember_radius
	var rect := Rect2(-3.5 * r, -9.84 * r, 7.0 * r, 12.0 * r)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
	var kind := FireQuad.KIND_EMBER
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(kind, 0.0), Vector2(kind + 1.0, 0.0), Vector2(kind + 1.0, 1.0), Vector2(kind, 1.0)])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
