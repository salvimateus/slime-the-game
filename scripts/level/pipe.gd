extends Area2D
## A drain in the floor and the pipe behind it. The Area2D is the drain: a melted slime that touches it flows along
## flow_path() by itself and comes out at the far end. The tube draws under the goo, through the level's
## TemperatureArt, so the flowing slime shows in front of it; during a flow a glow over the goo follows it.
## Contract: flow_path() (global points from the drain to the outlet face), exit_direction(), exit_point(),
## begin_flow(), flow_at(point), end_flow().

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

const BOLT_SHARE := 0.32
const DRAIN_SLOTS := 4

var _path := PackedVector2Array()
var _exit_dir := Vector2.RIGHT
var _exit_point := Vector2.ZERO
var _flowing := false
var _flow_point := Vector2.ZERO
var _time := 0.0
var _front_batch := ShapeBatch.new()
var _front := Node2D.new()
var _shape := CollisionShape2D.new()


## cells: the air cell over the drain, the rock cells the pipe runs through, then the air cell it opens into.
func setup(cells: Array, tile: float) -> void:
	position = Vector2.ZERO
	collision_layer = Tuning.LAYER_ZONES
	collision_mask = 0
	monitoring = false
	monitorable = true
	var first: Vector2i = cells[0]
	var last: Vector2i = cells[cells.size() - 1]
	var before_last: Vector2i = cells[cells.size() - 2]
	var center := func(c: Vector2i) -> Vector2: return (Vector2(c) + Vector2(0.5, 0.5)) * tile
	var raw := PackedVector2Array([Vector2(center.call(first).x, (first.y + 1) * tile)])
	for i: int in range(1, cells.size() - 1):
		raw.append(center.call(cells[i]))
	var face: Vector2 = (center.call(before_last) + center.call(last)) * 0.5
	raw.append(face)
	_path = _simplify(raw)
	_exit_dir = (face - Vector2(center.call(before_last))).normalized()
	_exit_point = face
	var box := RectangleShape2D.new()
	box.size = Vector2(tile * 0.8, tile * 0.5)
	_shape.shape = box
	_shape.position = Vector2(center.call(first).x, (first.y + 1) * tile - tile * 0.25)
	if _shape.get_parent() == null:
		add_child(_shape)
	if _front.get_parent() == null:
		_front.name = "Glass"
		_front.z_index = Tuning.over_goo_z_index
		_front.z_as_relative = false
		_front.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(_front)
		_front.draw.connect(_draw_front)
	_front.queue_redraw()


func flow_path() -> PackedVector2Array:
	return _path


func exit_direction() -> Vector2:
	return _exit_dir


## The opening of the pipe on the wall or floor face it comes out of.
func exit_point() -> Vector2:
	return _exit_point


func begin_flow() -> void:
	_flowing = true
	_flow_point = _path[0]
	_place_glow()
	_front.queue_redraw()
	set_process(true)


## Where the flowing goo is now, for the glow inside the glass.
func flow_at(point: Vector2) -> void:
	_flow_point = point


func end_flow() -> void:
	_flowing = false
	_front.position = Vector2.ZERO
	_front.modulate.a = 1.0
	_front.queue_redraw()


func warm_up() -> void:
	begin_flow()
	_flow_point = _path[_path.size() / 2]
	await get_tree().process_frame
	end_flow()


func _ready() -> void:
	set_process(false)


func _process(delta: float) -> void:
	_time += delta
	if _flowing:
		_place_glow()
	else:
		set_process(false)


## The glow is drawn one time at the origin of the glass item; the flow moves it and pulses it by transform and modulate.
func _place_glow() -> void:
	_front.position = _flow_point
	_front.modulate.a = 0.75 + 0.25 * sin(_time * 18.0)


## TemperatureArt contract: the look never changes, so it is drawn one time.
func art_is_static() -> bool:
	return true


## TemperatureArt contract: the region the tube covers, in the level's space.
func art_rect() -> Rect2:
	var rect := Rect2(_path[0], Vector2.ZERO)
	for p: Vector2 in _path:
		rect = rect.expand(p)
	return rect.grow(Tuning.pipe_radius * 3.0)


## TemperatureArt contract: adds the tube, its drain and its outlet to the batch.
func draw_art(into: ShapeBatch, _t: float) -> void:
	var r := Tuning.pipe_radius
	var rim := Tuning.pipe_rim
	into.stroke(_path, (r + rim) * 2.0 + 3.0, Tuning.ground_outline_color, false, false)
	into.stroke(_path, (r + rim) * 2.0, Tuning.pipe_rim_color, false, false)
	into.stroke(_path, r * 2.0, Tuning.pipe_color, false, false)
	for i: int in range(1, _path.size() - 1):
		into.disc(_path[i], r + rim * 1.6, Tuning.ground_outline_color)
		into.disc(_path[i], r + rim * 1.2, Tuning.pipe_rim_color)
		into.disc(_path[i], r, Tuning.pipe_color)
		for k: int in 4:
			into.disc(_path[i] + Vector2.from_angle(PI * 0.25 + k * PI * 0.5) * (r + rim * 0.6), rim * BOLT_SHARE * 2.0, Tuning.ground_outline_color)
	var shine := PackedVector2Array()
	for i: int in _path.size():
		shine.append(_path[i] + _side_normal(i) * r * 0.55)
	into.stroke(shine, maxf(r * 0.22, 1.5), Tuning.pipe_glass_color, false, false)
	_draw_drain(into, _path[0], r, rim)
	_draw_outlet(into, _exit_point, _exit_dir, r, rim)


## The drain cap on the floor: a slotted plate wider than the pipe.
func _draw_drain(into: ShapeBatch, at: Vector2, r: float, rim: float) -> void:
	var half := r + rim * 2.0
	into.rect(Rect2(at.x - half - 2.0, at.y - 3.0, half * 2.0 + 4.0, rim * 2.0 + 4.0), Tuning.ground_outline_color)
	into.rect(Rect2(at.x - half, at.y - 1.0, half * 2.0, rim * 2.0), Tuning.pipe_rim_color)
	for k: int in DRAIN_SLOTS:
		var x := lerpf(at.x - half * 0.7, at.x + half * 0.7, float(k) / (DRAIN_SLOTS - 1))
		into.rect(Rect2(x - rim * 0.35, at.y, rim * 0.7, rim * 1.4), Tuning.pipe_color)


## The flange where the pipe opens on a face, across the exit direction.
func _draw_outlet(into: ShapeBatch, at: Vector2, dir: Vector2, r: float, rim: float) -> void:
	var across := dir.orthogonal()
	var half := r + rim * 2.0
	var a := at - across * half
	var b := at + across * half
	into.stroke(PackedVector2Array([a, b]), rim * 2.4 + 3.0, Tuning.ground_outline_color, false, false)
	into.stroke(PackedVector2Array([a, b]), rim * 2.4, Tuning.pipe_rim_color, false, false)
	into.stroke(PackedVector2Array([at - across * r, at + across * r]), rim, Tuning.pipe_color, false, false)


func _draw_front() -> void:
	_front_batch.clear()
	var r := Tuning.pipe_radius
	# Only a flow draws over the goo, so an idle pipe adds no draw call of its own.
	if _flowing:
		_front_batch.disc(Vector2.ZERO, r * 1.5, Color(Tuning.pipe_glow_color, Tuning.pipe_glow_color.a * 0.35))
		_front_batch.disc(Vector2.ZERO, r * 0.8, Tuning.pipe_glow_color)
	_front_batch.commit(_front.get_canvas_item())


## Upper side of the tube at point i, where the glass catches the light.
func _side_normal(i: int) -> Vector2:
	var a := _path[maxi(i - 1, 0)]
	var b := _path[mini(i + 1, _path.size() - 1)]
	var n := (b - a).normalized().orthogonal()
	return n if n.y < 0.0 or (is_zero_approx(n.y) and n.x < 0.0) else -n


static func _simplify(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i: int in points.size():
		if i > 0 and i < points.size() - 1:
			var d0 := (points[i] - points[i - 1]).normalized()
			var d1 := (points[i + 1] - points[i]).normalized()
			if d0.is_equal_approx(d1):
				continue
		out.append(points[i])
	return out
