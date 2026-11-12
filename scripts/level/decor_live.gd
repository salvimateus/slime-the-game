extends Node2D
## Drives the decoration that moves. The pieces live in the section meshes of the ground; decor.gdshader moves them
## from one time uniform, so an idle frame costs one uniform write here. When the slime or a shot touches a mushroom or
## a hanging piece, the piece takes one of the few react slots of the shader; a spring per slot runs only until it
## settles. It also draws the spores that a bumped mushroom puffs (only while some are alive).
## Nothing here has collision or reads Game.rng.

const GooMath := preload("res://scripts/goo/goo_math.gd")
const Painter := preload("res://scripts/level/decor_painter.gd")
const DecorArt := preload("res://scripts/level/decor_art.gd")

const SLOTS := 16
const FREE_SLOT := -1.0
const REACT_RANGE := 300.0
## Widest reach of a piece from its anchor along x, for the range search.
const SEARCH_PAD := 120.0
const SETTLE := 0.003
const STILL_SPEED := 4.0
const SHOT_STATE := 1
const SPORE_RISE := 40.0
const SPORE_DRAG := 2.2
const SPORE_SIZE := Vector2(2.0, 4.0)
const ALPHA_LEVELS := 4

var _material: ShaderMaterial
var _items: Array[Dictionary] = []
var _xs := PackedFloat32Array()
## Slot state: item index (-1 free), squash, squash speed, lean or angle, its speed.
var _slot_item := PackedInt32Array()
var _slot_s := PackedFloat32Array()
var _slot_sv := PackedFloat32Array()
var _slot_w := PackedFloat32Array()
var _slot_wv := PackedFloat32Array()
var _react := PackedVector4Array()
var _pivot := PackedVector2Array()
var _slots_dirty := false
var _touching := {}
var _shot_touch := {}
var _time := 0.0
var _motion := true
var _player_was_on_floor := true
var _player_prev_vy := 0.0

var _spore_pos := PackedVector2Array()
var _spore_vel := PackedVector2Array()
var _spore_life := PackedFloat32Array()
var _spore_size := PackedFloat32Array()
var _spore_color := PackedInt32Array()
var _spore_dots: Array = []
var _rng := RandomNumberGenerator.new()
var _points := PackedVector2Array()
var _colors := PackedColorArray()
var _sequence := PackedInt32Array()
var _had_spores := false
## Bounds of the live spores and of the spores in the last draw, for the view check.
var _spore_rect := Rect2()
var _drawn_rect := Rect2()
## Microseconds of the last _process, for the performance measurements.
var last_process_usec := 0


static func make_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = preload("res://scripts/level/decor.gdshader")
	var react := PackedVector4Array()
	react.resize(SLOTS)
	react.fill(Vector4(FREE_SLOT, 0.0, 0.0, 0.0))
	material.set_shader_parameter(&"react", react)
	material.set_shader_parameter(&"pulse_hz", Tuning.decor_glow_pulse_hz)
	material.set_shader_parameter(&"drop_period", Tuning.decor_drop_period)
	material.set_shader_parameter(&"drop_gravity", Tuning.decor_drop_gravity)
	material.set_shader_parameter(&"idle_sway", Tuning.decor_idle_sway)
	return material


func setup(material: ShaderMaterial, items: Array[Dictionary]) -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_material = material
	_items = items
	_xs.resize(_items.size())
	for i in _items.size():
		_xs[i] = float(_items[i].pos.x)
	_slot_item.resize(SLOTS)
	_slot_item.fill(-1)
	_slot_s.resize(SLOTS)
	_slot_sv.resize(SLOTS)
	_slot_w.resize(SLOTS)
	_slot_wv.resize(SLOTS)
	_react.resize(SLOTS)
	_react.fill(Vector4(FREE_SLOT, 0.0, 0.0, 0.0))
	_pivot.resize(SLOTS)
	_rng.seed = Tuning.decor_seed + 1
	_spore_dots.clear()
	var p := Painter.new()
	for color: Color in Tuning.decor_glow_colors:
		var levels := []
		for level in ALPHA_LEVELS:
			DecorArt.dot(p, Color(color.lightened(0.4), 0.9 * (1.0 - float(level) / ALPHA_LEVELS)), true)
			levels.append([p.points, p.colors])
			p.clear()
		_spore_dots.append(levels)


func warm_up() -> void:
	if is_instance_valid(Game.player):
		_emit_spores(Game.player.global_position, 3, 0)


func reactive_count() -> int:
	return _items.size()


func _process(delta: float) -> void:
	var start := Time.get_ticks_usec()
	_update(delta)
	last_process_usec = Time.get_ticks_usec() - start


func _update(delta: float) -> void:
	var motion := Tuning.fx_decor_motion
	if motion != _motion:
		_motion = motion
		_material.set_shader_parameter(&"motion", 1.0 if motion else 0.0)
		if not motion:
			_clear_slots()
	if not _motion:
		return
	_time += delta
	_material.set_shader_parameter(&"t", _time)
	_react_player()
	_react_shots()
	_step_slots(delta)
	if _slots_dirty:
		_slots_dirty = false
		_material.set_shader_parameter(&"react", _react)
		_material.set_shader_parameter(&"pivot", _pivot)
	if not _spore_life.is_empty():
		_step_spores(delta)
		# Spores off screen move on with no redraw; the old draw is redrawn too when it is in view.
		var view := _view_rect()
		if view.intersects(_spore_rect) or (_had_spores and view.intersects(_drawn_rect)):
			queue_redraw()
	elif _had_spores:
		queue_redraw()


## First index whose x is at least x (binary search over the sorted anchors).
func _lower_bound(x: float) -> int:
	var lo := 0
	var hi := _xs.size()
	while lo < hi:
		var mid := (lo + hi) >> 1
		if _xs[mid] < x:
			lo = mid + 1
		else:
			hi = mid
	return lo


func _react_player() -> void:
	var player := Game.player
	if not is_instance_valid(player):
		return
	var velocity: Vector2 = player.get("velocity") if player.get("velocity") != null else Vector2.ZERO
	var on_floor: bool = player.call("is_on_floor") if player.has_method("is_on_floor") else true
	var landed := on_floor and not _player_was_on_floor and _player_prev_vy > Tuning.decor_land_speed
	var prev_vy := _player_prev_vy
	_player_was_on_floor = on_floor
	_player_prev_vy = velocity.y
	# A slime at rest touches nothing new: skip the search.
	if not landed and velocity.length_squared() < STILL_SPEED * STILL_SPEED:
		return
	var center := player.global_position
	var mass_value: Variant = player.get("mass")
	var radius := GooMath.visual_radius(float(mass_value) if mass_value != null else Tuning.mass_max) * Tuning.collision_radius_ratio
	var land_strength := clampf(prev_vy / 900.0, 0.3, 1.0)
	for i in range(_lower_bound(center.x - REACT_RANGE - SEARCH_PAD), _lower_bound(center.x + REACT_RANGE + SEARCH_PAD)):
		var item := _items[i]
		var pos: Vector2 = item.pos
		if item.kind == &"mushroom":
			_react_mushroom(i, item, pos, center, velocity, radius)
			if landed and absf(pos.y - (center.y + radius)) < 48.0:
				var d := absf(pos.x - center.x)
				if d < Tuning.decor_land_radius:
					_kick(i, Tuning.decor_land_kick * land_strength * (1.0 - d / Tuning.decor_land_radius), signf(pos.x - center.x) * 0.1)
					if d < radius * 2.0:
						_emit_spores(pos + Vector2(0.0, -float(item.height) * 0.8), 3, int(item.spore))
		else:
			var inside := _in_hanging(item, pos, center, radius)
			if inside and not _touching.has(i):
				_kick(i, 0.0, clampf(velocity.x * Tuning.decor_sway_gain, -Tuning.decor_sway_max, Tuning.decor_sway_max))
			_set_touching(i, inside)


func _react_mushroom(i: int, item: Dictionary, pos: Vector2, center: Vector2, velocity: Vector2, radius: float) -> void:
	var half: float = item.half
	var height: float = item.height
	var dx := absf(center.x - pos.x)
	var vertical := center.y + radius > pos.y - height and center.y - radius < pos.y + 4.0
	var inside := vertical and dx < half + radius * 0.8
	var near := vertical and dx < half + radius + 70.0 and absf(velocity.x) > Tuning.decor_fast_speed
	if inside and not _touching.has(i):
		var speed := velocity.length()
		_kick(i, Tuning.decor_squash_touch + speed * Tuning.decor_squash_speed_gain, -velocity.x * Tuning.decor_sway_gain * 0.5)
		if speed > 150.0:
			_emit_spores(pos + Vector2(0.0, -height * 0.8), _rng.randi_range(Tuning.decor_spore_count.x, Tuning.decor_spore_count.y), int(item.spore))
	elif near and not _touching.has(i):
		_kick(i, 0.06, -velocity.x * Tuning.decor_sway_gain * 0.35)
	_set_touching(i, inside or near)


func _in_hanging(item: Dictionary, pos: Vector2, center: Vector2, radius: float) -> bool:
	var length: float = item.length
	return absf(center.x - pos.x) < radius + 16.0 and center.y + radius > pos.y and center.y - radius < pos.y + length


func _set_touching(i: int, inside: bool) -> void:
	if inside:
		_touching[i] = true
	else:
		_touching.erase(i)


## Shots in flight push the hanging pieces and mushrooms they pass through.
func _react_shots() -> void:
	var layer := Game.props
	if not is_instance_valid(layer) or (_shot_touch.is_empty() and layer.get_child_count() == 0):
		return
	var seen := {}
	for prop in layer.get_children():
		var body := prop as Node2D
		if body == null or body.get("state") != SHOT_STATE:
			continue
		var at := body.global_position
		var velocity: Vector2 = body.get("velocity") if body.get("velocity") != null else Vector2.ZERO
		for i in range(_lower_bound(at.x - SEARCH_PAD), _lower_bound(at.x + SEARCH_PAD)):
			var item := _items[i]
			var pos: Vector2 = item.pos
			var hit := false
			if item.kind == &"mushroom":
				hit = absf(at.x - pos.x) < float(item.half) and at.y > pos.y - float(item.height) and at.y < pos.y
				if hit and not _shot_touch.has(i):
					_kick(i, Tuning.decor_squash_touch, -velocity.x * Tuning.decor_sway_gain * 0.4)
			else:
				hit = _in_hanging(item, pos, at, 14.0)
				if hit and not _shot_touch.has(i):
					_kick(i, 0.0, clampf(velocity.x * Tuning.decor_sway_gain * 0.8, -Tuning.decor_sway_max, Tuning.decor_sway_max))
			if hit:
				seen[i] = true
	_shot_touch = seen


## Pushes an item: squash speed and lean (mushroom) or angle (hanging) speed. Takes a free slot, or the calmest one.
func _kick(i: int, squash: float, lean: float) -> void:
	var slot := _slot_item.find(i)
	if slot < 0:
		slot = _slot_item.find(-1)
		if slot < 0:
			slot = _calmest_slot()
		_slot_item[slot] = i
		_slot_s[slot] = 0.0
		_slot_sv[slot] = 0.0
		_slot_w[slot] = 0.0
		_slot_wv[slot] = 0.0
		_pivot[slot] = _items[i].pos
	_slot_sv[slot] += squash * Tuning.decor_squash_stiffness * 0.1
	_slot_wv[slot] += lean * 4.0
	_slots_dirty = true


func _calmest_slot() -> int:
	var best := 0
	var best_energy := INF
	for k in SLOTS:
		var energy := absf(_slot_s[k]) + absf(_slot_w[k]) + (absf(_slot_sv[k]) + absf(_slot_wv[k])) * 0.05
		if energy < best_energy:
			best_energy = energy
			best = k
	return best


func _step_slots(delta: float) -> void:
	var dt := minf(delta, 1.0 / 30.0)
	for k in SLOTS:
		var i := _slot_item[k]
		if i < 0:
			continue
		var hanging: bool = _items[i].kind != &"mushroom"
		var s := _slot_s[k]
		var sv := _slot_sv[k]
		sv += (-Tuning.decor_squash_stiffness * s - Tuning.decor_squash_damping * sv) * dt
		s = clampf(s + sv * dt, -Tuning.decor_squash_max, Tuning.decor_squash_max)
		var stiffness := Tuning.decor_sway_stiffness if hanging else Tuning.decor_squash_stiffness * 0.6
		var damping := Tuning.decor_sway_damping if hanging else Tuning.decor_squash_damping
		var w := _slot_w[k]
		var wv := _slot_wv[k]
		wv += (-stiffness * w - damping * wv) * dt
		w = clampf(w + wv * dt, -Tuning.decor_sway_max, Tuning.decor_sway_max)
		_slot_s[k] = s
		_slot_sv[k] = sv
		_slot_w[k] = w
		_slot_wv[k] = wv
		var item: Dictionary = _items[i]
		if absf(s) + absf(w) + (absf(sv) + absf(wv)) * 0.05 < SETTLE:
			_slot_item[k] = -1
			_react[k] = Vector4(FREE_SLOT, 0.0, 0.0, 0.0)
		else:
			_react[k] = Vector4(float(item.id), s, w, 0.0)
		_slots_dirty = true


func _clear_slots() -> void:
	_slot_item.fill(-1)
	_react.fill(Vector4(FREE_SLOT, 0.0, 0.0, 0.0))
	_material.set_shader_parameter(&"react", _react)
	_touching.clear()
	_shot_touch.clear()


func _emit_spores(at: Vector2, count: int, color_index: int) -> void:
	for k in count:
		if _spore_life.size() >= Tuning.decor_spore_max:
			return
		_spore_pos.append(at + Vector2(_rng.randf_range(-14.0, 14.0), _rng.randf_range(-6.0, 6.0)))
		_spore_vel.append(Vector2(_rng.randf_range(-70.0, 70.0), _rng.randf_range(-130.0, -40.0)))
		_spore_life.append(Tuning.decor_spore_life * _rng.randf_range(0.7, 1.0))
		_spore_size.append(_rng.randf_range(SPORE_SIZE.x, SPORE_SIZE.y))
		_spore_color.append(color_index)
	queue_redraw()


func _step_spores(delta: float) -> void:
	var i := _spore_life.size() - 1
	while i >= 0:
		var life := _spore_life[i] - delta
		if life <= 0.0:
			_spore_pos.remove_at(i)
			_spore_vel.remove_at(i)
			_spore_life.remove_at(i)
			_spore_size.remove_at(i)
			_spore_color.remove_at(i)
		else:
			var v := _spore_vel[i]
			v *= exp(-SPORE_DRAG * delta)
			v.y -= SPORE_RISE * delta
			v.x += sin(_time * 3.0 + i) * 20.0 * delta
			_spore_vel[i] = v
			_spore_pos[i] += v * delta
			_spore_life[i] = life
		i -= 1
	_spore_rect = Rect2()
	for k in _spore_pos.size():
		_spore_rect = Rect2(_spore_pos[k], Vector2.ZERO) if k == 0 else _spore_rect.expand(_spore_pos[k])
	_spore_rect = _spore_rect.grow(SPORE_SIZE.y * 2.0)


func _view_rect() -> Rect2:
	var viewport := get_viewport()
	if viewport == null:
		return Rect2()
	return (get_global_transform_with_canvas().affine_inverse() * viewport.get_visible_rect()).grow(Tuning.tile_size)


func _draw() -> void:
	_had_spores = not _spore_life.is_empty()
	_drawn_rect = _spore_rect
	if not _had_spores or _spore_dots.is_empty():
		return
	_points.clear()
	_colors.clear()
	for k in _spore_life.size():
		var u := 1.0 - _spore_life[k] / Tuning.decor_spore_life
		var levels: Array = _spore_dots[clampi(_spore_color[k], 0, _spore_dots.size() - 1)]
		var piece: Array = levels[clampi(int(u * ALPHA_LEVELS), 0, ALPHA_LEVELS - 1)]
		var pts: PackedVector2Array = piece[0]
		_points.append_array(Transform2D(0.0, Vector2.ONE * _spore_size[k], 0.0, _spore_pos[k]) * pts)
		_colors.append_array(piece[1])
	var count := _points.size()
	if _sequence.size() < count:
		var start := _sequence.size()
		_sequence.resize(count + 512)
		for k in range(start, _sequence.size()):
			_sequence[k] = k
	RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), _sequence.slice(0, count), _points, _colors)
