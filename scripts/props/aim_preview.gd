extends Node2D
## Trajectory preview of the aimed shot: goo dots that shrink along the arc, a splat ring at the first impact and a
## short trail of the first ricochet. It steps the same flight as Throwable (spawn point, exact parabola, body motion
## test with the same shape and mask), so the real first bounce lands on the predicted point.
## All dots draw in one triangle array; the arrays are allocated once and rebuilt only when the aim or the slime moves.

const Throwable := preload("res://scenes/props/throwable.gd")
const PropArt := preload("res://scripts/props/prop_art.gd")

const MAX_QUADS := 320
const DISC_SIZE := 32
const RIM_GROW := 1.45
const SAME_EPSILON := 0.25
const STEP := 1.0 / 60.0
const QUAD_ORDER: Array[int] = [0, 1, 2, 0, 2, 3]

## Node2D whose interpolated draw position the dots follow (the player); its visual_position() is read each frame.
var anchor: Node2D

var _probe: CharacterBody2D
var _probe_shape := CircleShape2D.new()
var _collision := KinematicCollision2D.new()
var _hazard_query := PhysicsShapeQueryParameters2D.new()
var _disc: ImageTexture
var _points := PackedVector2Array()
var _uvs := PackedVector2Array()
var _colors := PackedColorArray()
var _indices := PackedInt32Array()
var _quads := 0
var _shown := false
var _last_key := PackedFloat32Array()
var _built_tick := 0
var _arc := PackedVector2Array()
var _bounce_arc := PackedVector2Array()


func _ready() -> void:
	top_level = true
	z_index = Tuning.over_goo_z_index
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_probe = CharacterBody2D.new()
	_probe.name = "Probe"
	_probe.motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	_probe.collision_layer = 0
	_probe.collision_mask = Tuning.LAYER_WORLD | Tuning.LAYER_PLATFORMS | Tuning.LAYER_ENEMIES | Tuning.LAYER_GRATES
	var shape := CollisionShape2D.new()
	shape.shape = _probe_shape
	_probe.add_child(shape)
	add_child(_probe)
	_hazard_query.shape = _probe_shape
	_hazard_query.collision_mask = Tuning.LAYER_HAZARDS
	_hazard_query.collide_with_areas = true
	_hazard_query.collide_with_bodies = false
	_disc = _make_disc()
	_points.resize(MAX_QUADS * 4)
	_uvs.resize(MAX_QUADS * 4)
	_colors.resize(MAX_QUADS * 4)
	_indices.resize(MAX_QUADS * 6)
	for q: int in MAX_QUADS:
		_uvs[q * 4] = Vector2(0.0, 0.0)
		_uvs[q * 4 + 1] = Vector2(1.0, 0.0)
		_uvs[q * 4 + 2] = Vector2(1.0, 1.0)
		_uvs[q * 4 + 3] = Vector2(0.0, 1.0)
		for k: int in 6:
			_indices[q * 6 + k] = q * 4 + QUAD_ORDER[k]
	_colors.fill(Color(1.0, 1.0, 1.0, 0.0))
	_last_key.resize(9)
	visible = false


## Steps the flight of a shot and returns {"impact": Vector2 or null, "normal", "surface", "target", "shatter"}.
## "shatter" is the number of pieces the shot breaks into at the impact, 0 when it stays whole.
## Fills the arc and the first ricochet as a side effect, for the dots.
func predict(kind: StringName, center: Vector2, dir: Vector2, spawn_dist: float, velocity: Vector2) -> Dictionary:
	_arc.clear()
	_bounce_arc.clear()
	var radius := PropArt.radius_of(kind)
	_probe_shape.radius = radius
	var space := get_world_2d().direct_space_state
	var start := Throwable.spawn_point(space, center, dir, spawn_dist, radius)
	var pos: Vector2 = start.at
	_arc.append(pos)
	if bool(start.contact):
		return _result(start.point, start.normal, start.collider, velocity, pos)
	var v := velocity
	var steps := int(Tuning.aim_preview_time / STEP)
	for i: int in steps:
		var step := Throwable.flight_step(v, Tuning.shot_gravity, STEP)
		var motion := step[0]
		v = step[1]
		if _probe.test_move(Transform2D(0.0, pos), motion, _collision):
			pos += _collision.get_travel()
			_arc.append(pos)
			return _result(_collision.get_position(), _collision.get_normal(), _collision.get_collider(), v, pos)
		pos += motion
		_arc.append(pos)
		var hazard := _hazard_at(space, pos)
		if hazard != null:
			var pieces := PropArt.shatter_pieces(kind) if hazard.has_method(&"breaks_props") and bool(hazard.call(&"breaks_props")) else 0
			return {"impact": pos, "normal": Vector2.ZERO, "surface": StringName(hazard.get(&"source")), "target": false, "shatter": pieces}
	return {"impact": null, "normal": Vector2.ZERO, "surface": &"", "target": false, "shatter": 0}


## Shows the preview for this aim; it rebuilds only when an input changed since the last call.
## A burning slime shows the arc in the colours of fire: the next shot is an ember.
func show_aim(kind: StringName, center: Vector2, dir: Vector2, spawn_dist: float, velocity: Vector2, has_ammo: bool) -> void:
	var key := PackedFloat32Array([center.x, center.y, velocity.x, velocity.y, spawn_dist, 1.0 if has_ammo else 0.0, PropArt.radius_of(kind), float(PropArt.size_of(kind)), 1.0 if _anchor_burning() else 0.0])
	# Traps move while the aim holds still, so an unchanged aim still predicts again every few ticks.
	var tick := Engine.get_physics_frames()
	if _shown and _same(key) and tick - _built_tick < Tuning.aim_preview_refresh_ticks:
		return
	_built_tick = tick
	_last_key = key
	_shown = true
	visible = true
	var hit := predict(kind, center, dir, spawn_dist, velocity)
	_rebuild(hit, has_ammo, key[8] > 0.5)
	queue_redraw()


func hide_aim() -> void:
	if not _shown:
		return
	_shown = false
	visible = false


func _process(_delta: float) -> void:
	if _shown and is_instance_valid(anchor) and anchor.has_method(&"visual_position"):
		var visual: Vector2 = anchor.call(&"visual_position")
		position = visual - anchor.global_position


func _result(point: Vector2, normal: Vector2, collider: Object, v: Vector2, pos: Vector2) -> Dictionary:
	var is_target := collider != null and (collider.has_method(&"shot_hit") or (collider is Node and (collider as Node).get_parent() != null and (collider as Node).get_parent().has_method(&"shot_hit")))
	if not is_target and v.dot(normal) < 0.0:
		_trace_bounce(pos, Throwable.hot_bounce(v, normal))
	var surface := &"floor" if normal.y < -0.65 else (&"ceiling" if normal.y > 0.65 else &"wall")
	return {"impact": point, "normal": normal, "surface": &"target" if is_target else surface, "target": is_target, "shatter": 0}


func _trace_bounce(pos: Vector2, v: Vector2) -> void:
	_bounce_arc.append(pos)
	for i: int in int(Tuning.aim_preview_bounce_time / STEP):
		var step := Throwable.flight_step(v, Tuning.shot_gravity, STEP)
		var motion := step[0]
		v = step[1]
		if _probe.test_move(Transform2D(0.0, pos), motion, _collision):
			_bounce_arc.append(pos + _collision.get_travel())
			return
		pos += motion
		_bounce_arc.append(pos)


func _hazard_at(space: PhysicsDirectSpaceState2D, pos: Vector2) -> Object:
	_hazard_query.transform = Transform2D(0.0, pos)
	for hit: Dictionary in space.intersect_shape(_hazard_query, 4):
		var area: Object = hit.collider
		if area != null and area.has_method(&"deflects_props") and bool(area.call(&"deflects_props")):
			return area
	return null


func _anchor_burning() -> bool:
	if not is_instance_valid(anchor):
		return false
	var temperature: Variant = anchor.get(&"temperature")
	return temperature is Object and bool((temperature as Object).call(&"burning"))


func _same(key: PackedFloat32Array) -> bool:
	for i: int in key.size():
		if absf(key[i] - _last_key[i]) > SAME_EPSILON:
			return false
	return true


func _rebuild(hit: Dictionary, has_ammo: bool, hot := false) -> void:
	_quads = 0
	var alpha := Tuning.aim_preview_alpha if has_ammo else Tuning.aim_preview_empty_alpha
	var rim := Color(Tuning.aim_preview_hot_rim if hot else Tuning.goo_rim_color, alpha)
	var fill := Color(Tuning.aim_preview_hot_fill if hot else Tuning.goo_body_color, alpha)
	var arc_length := minf(_length_of(_arc), Tuning.aim_preview_max_length)
	_dots_along(_arc, arc_length, Tuning.aim_preview_dot_radius, rim, fill)
	var marker_color := Tuning.aim_preview_hot_marker if hot else Tuning.aim_preview_marker_color
	var bounce_fill := Color(marker_color, alpha * 0.75)
	var bounce_rim := Color(rim, alpha * 0.75)
	var bounce_radius := Vector2.ONE * Tuning.aim_preview_bounce_dot_radius
	_dots_along(_bounce_arc, _length_of(_bounce_arc), bounce_radius, bounce_rim, bounce_fill)
	if hit.impact is Vector2:
		var pieces := int(hit.get("shatter", 0))
		if pieces > 0:
			_shatter_marker(hit.impact, pieces, rim, Color(Tuning.aim_preview_shatter_color, alpha))
		else:
			var at: Vector2 = hit.impact
			var marker := Color(marker_color, alpha)
			for k: int in Tuning.aim_preview_marker_dots:
				var a := TAU * float(k) / float(Tuning.aim_preview_marker_dots)
				_add_dot(at + Vector2.from_angle(a) * Tuning.aim_preview_marker_radius, 2.2, rim, marker)
			_add_dot(at, 3.5, rim, marker)
	for q: int in range(_quads, MAX_QUADS):
		var base := q * 4
		if _colors[base].a == 0.0:
			break
		for k: int in 4:
			_points[base + k] = Vector2.ZERO
			_colors[base + k] = Color(1.0, 1.0, 1.0, 0.0)


## A break marker: a jagged burst of rays around the impact and one pip per piece above it, so the player reads
## "this shot breaks into N" before firing.
func _shatter_marker(at: Vector2, pieces: int, rim: Color, color: Color) -> void:
	var rays := Tuning.aim_preview_shatter_rays
	var radius := Tuning.aim_preview_shatter_radius
	for k: int in rays:
		var dir := Vector2.from_angle(TAU * (float(k) + 0.25) / float(rays))
		var long_ray := k % 2 == 0
		var reach := radius * (1.0 if long_ray else 0.62)
		_add_dot(at + dir * reach * 0.5, 3.0, rim, color)
		_add_dot(at + dir * reach, 2.6 if long_ray else 2.0, rim, color)
	_add_dot(at, 5.0, rim, color)
	var pip_gap := Tuning.aim_preview_shatter_pip_gap
	var pip_y := at.y - radius - pip_gap
	for i: int in pieces:
		var x := at.x + (float(i) - float(pieces - 1) * 0.5) * pip_gap
		_add_dot(Vector2(x, pip_y), Tuning.aim_preview_shatter_pip_radius, rim, color)


## Dots at an even arc-length spacing along a polyline, up to max_length; radius goes from x at the start to y at the end.
func _dots_along(line: PackedVector2Array, max_length: float, radius: Vector2, rim: Color, fill: Color) -> void:
	var spacing := maxf(Tuning.aim_preview_dot_spacing, 1.0)
	var next := spacing
	var walked := 0.0
	for i: int in range(1, line.size()):
		var a := line[i - 1]
		var seg := a.distance_to(line[i])
		while next <= walked + seg and next <= max_length:
			var t := next / maxf(max_length, 1.0)
			_add_dot(a.lerp(line[i], (next - walked) / maxf(seg, 0.0001)), lerpf(radius.x, radius.y, t), rim, fill)
			next += spacing
		walked += seg
		if walked >= max_length:
			return


static func _length_of(line: PackedVector2Array) -> float:
	var total := 0.0
	for i: int in range(1, line.size()):
		total += line[i - 1].distance_to(line[i])
	return total


## A dot is two quads in the one array: a dark rim behind a goo-coloured fill.
func _add_dot(at: Vector2, radius: float, rim: Color, fill: Color) -> void:
	_add_quad(at, radius * RIM_GROW, rim)
	_add_quad(at, radius, fill)


func _add_quad(at: Vector2, radius: float, color: Color) -> void:
	if _quads >= MAX_QUADS:
		return
	var base := _quads * 4
	_points[base] = at + Vector2(-radius, -radius)
	_points[base + 1] = at + Vector2(radius, -radius)
	_points[base + 2] = at + Vector2(radius, radius)
	_points[base + 3] = at + Vector2(-radius, radius)
	for k: int in 4:
		_colors[base + k] = color
	_quads += 1


func _draw() -> void:
	if not _shown:
		return
	RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), _indices, _points, _colors, _uvs, PackedInt32Array(), PackedFloat32Array(), _disc.get_rid())


static func _make_disc() -> ImageTexture:
	var img := Image.create_empty(DISC_SIZE, DISC_SIZE, false, Image.FORMAT_RGBA8)
	var half := DISC_SIZE * 0.5
	for y: int in DISC_SIZE:
		for x: int in DISC_SIZE:
			var d := Vector2(x + 0.5 - half, y + 0.5 - half).length()
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(half - 1.0 - d + 0.5, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)
