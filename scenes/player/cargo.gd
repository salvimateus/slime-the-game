extends Node2D
## Props floating inside the slime. Positions live in body radii around the body centre and go through the
## SlimeBody deformation, so the props squash, lean and wobble with the jelly. Drawn under the translucent goo
## surface (GooField has a higher z_index), so the gelatin itself covers them with its colour. Each prop drifts and turns on its own slow path and now and then lets small
## bubbles go; hard jolts shake out more. Part of the Player: only player.gd calls it.
## Everything here is visual: which prop a shot takes reads the fixed slot layout, and the RNG is this node's own.
## The geometry of each prop is built one time (cargo_mesh.gd); cargo.gdshader places, turns, sizes and tints it.
## The motion steps once per physics tick and writes its data to the shader, which blends the last two steps and
## applies the body deformation in each frame. No geometry is built in a frame.

const PropArt := preload("res://scripts/props/prop_art.gd")
const CargoMesh := preload("res://scenes/player/cargo_mesh.gd")
const CARGO_SHADER := preload("res://scenes/player/cargo.gdshader")
const SlimeBody := preload("res://scenes/player/slime_body.gd")
## Indices of SlimeBody.deform_state(), the only body data the cargo reads.
const D := SlimeBody.DeformState
const ENTRY_DISTANCE := 1.15
const GOLDEN_ANGLE := 2.39996323
const RNG_SEED := 31337
const BUBBLE_TEXTURE_SIZE := 32
## Slots of the shader data arrays (cargo.gdshader); props past this count are not drawn.
const MAX_SLOTS := 32
## Half size of the cull rect of the cargo items, in pixels around the body centre.
const CULL_HALF := 400.0
## Slot offsets from the zone centre, in body radii, for one to four props.
const SLOT_LAYOUTS := [
	[Vector2(0.0, 0.0)],
	[Vector2(-0.3, 0.0), Vector2(0.3, 0.0)],
	[Vector2(-0.36, 0.1), Vector2(0.0, -0.08), Vector2(0.36, 0.1)],
	[Vector2(-0.3, -0.1), Vector2(0.3, -0.1), Vector2(-0.3, 0.27), Vector2(0.3, 0.27)],
]

var body: Node2D

var _items: Array[Dictionary] = []
var _pos := PackedVector2Array()
var _prev_pos := PackedVector2Array()
var _vel := PackedVector2Array()
var _angle := PackedFloat32Array()
var _prev_angle := PackedFloat32Array()
var _spin := PackedFloat32Array()
var _swallow := PackedFloat32Array()
var _prop_radius := PackedFloat32Array()
# Per-prop float: drift frequencies (x, y) and phases, base turn speed, time to the next bubble.
var _drift_hz := PackedVector2Array()
var _drift_phase := PackedVector2Array()
var _turn := PackedFloat32Array()
var _bubble_wait := PackedFloat32Array()
var _layout := PackedVector2Array()
var _impulse := Vector2.ZERO
var _jolt := 0.0
var _last_velocity := Vector2.ZERO
var _time := 0.0
var _tick := 1.0 / 60.0
var _aim_active := false
var _aim_dir := Vector2.RIGHT
var _front := -1
## Prop the next shot takes (nearest the mouth side); drawn larger and on top so it reads at a glance.
var _next := -1
var _rng := RandomNumberGenerator.new()

# Bubble pool, in body radii like the props.
var _b_pos := PackedVector2Array()
var _b_prev := PackedVector2Array()
var _b_vel := PackedVector2Array()
var _b_life := PackedFloat32Array()
var _b_life_max := PackedFloat32Array()
var _b_age_prev := PackedFloat32Array()
var _b_size := PackedFloat32Array()
var _b_phase := PackedFloat32Array()
var _b_count := 0
var _bubble_texture: ImageTexture
var _bubble_geo: Array
var _warm_frames := 0
# Temperature of the body, smoothed per tick: frost locks the props in the ice, ember heats them before the shot,
# melt lets them sink to the bottom of the puddle.
var _frost := 0.0
var _frost_target := 0.0
var _ember := 0.0
var _ember_target := 0.0
var _melt := 0.0
var _melt_target := 0.0

# Two canvas items under this node: the load in item order, then the front item with the next prop and the bubbles.
var _material := ShaderMaterial.new()
var _material_rid := RID()
var _back_item := RID()
var _front_item := RID()
var _shapes_dirty := true
var _front_dirty := true
var _data_dirty := true
# Positions and turns in the last shader write; a load that stays near them writes nothing new.
var _written_pos := PackedVector2Array()
var _written_angle := PackedFloat32Array()
var _still := false
var _still_written := false
var _drawn_front := -1
var _active := false
# Shader data, double buffered so that a write never copies an array the renderer still holds.
var _buf := 0
var _frame_index := 0
var _bubbles_written := PackedInt32Array([0, 0])
var _item_pos_buf: Array[PackedVector4Array] = []
var _item_data_buf: Array[PackedVector4Array] = []
var _bubble_pos_buf: Array[PackedVector4Array] = []
var _bubble_data_buf: Array[PackedVector4Array] = []
var _frame_buf: Array[PackedVector4Array] = []


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_INHERIT
	_rng.seed = RNG_SEED
	_tick = 1.0 / float(Engine.physics_ticks_per_second)
	var cap := clampi(Tuning.carry_bubble_max, 1, MAX_SLOTS)
	_b_pos.resize(cap)
	_b_prev.resize(cap)
	_b_vel.resize(cap)
	_b_life.resize(cap)
	_b_life_max.resize(cap)
	_b_age_prev.resize(cap)
	_b_size.resize(cap)
	_b_phase.resize(cap)
	for k: int in 2:
		for list: Array[PackedVector4Array] in [_item_pos_buf, _item_data_buf, _bubble_pos_buf, _bubble_data_buf]:
			var arr := PackedVector4Array()
			arr.resize(MAX_SLOTS)
			list.append(arr)
		var frame := PackedVector4Array()
		frame.resize(7)
		_frame_buf.append(frame)
	_bubble_texture = _make_bubble_texture()
	_bubble_geo = CargoMesh.bubbles(cap)
	_setup_material()
	_material_rid = _material.get_rid()
	_back_item = RenderingServer.canvas_item_create()
	_front_item = RenderingServer.canvas_item_create()
	for item: RID in [_back_item, _front_item]:
		RenderingServer.canvas_item_set_parent(item, get_canvas_item())
		RenderingServer.canvas_item_set_material(item, _material_rid)
		# The vertices are unit shapes that the shader moves out, so the cull rect must cover the whole body.
		RenderingServer.canvas_item_set_custom_rect(item, true, Rect2(-Vector2.ONE * CULL_HALF, Vector2.ONE * CULL_HALF * 2.0))
	_set_active(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for item: RID in [_back_item, _front_item]:
			if item.is_valid():
				RenderingServer.free_rid(item)


func count() -> int:
	return _items.size()


## Draws a few bubbles at almost zero opacity for some frames, so the shader and the first real bubbles do not hitch.
func warm_up() -> void:
	_warm_frames = 4
	for kind: StringName in [&"rock", &"crystal"]:
		CargoMesh.prop(kind, 0, PropArt.radius_of(kind) * Tuning.carry_item_scale)
	for i: int in 3:
		_emit_bubble(Tuning.carry_zone_center, 1.0)
	_set_active(true)


## Adds a swallowed prop; it enters at the global point where it touched the slime and sinks to its slot through
## the gelatin, faster and deeper the harder it came in (strength 0 to 1).
func add(identity: Dictionary, from_global: Vector2, strength := 0.0) -> void:
	var r := _radius()
	var entry := Vector2(0.0, -1.0)
	var parent := get_parent() as Node2D
	if parent != null:
		var offset := from_global - parent.global_position
		if offset.length_squared() > 0.01:
			entry = offset.normalized()
	var kind: StringName = identity.get("kind", &"rock")
	_items.append(identity)
	var start := entry * ENTRY_DISTANCE if r > 0.0 else Tuning.carry_zone_center
	_pos.append(start)
	_prev_pos.append(start)
	_vel.append(-entry * lerpf(Tuning.carry_sink_speed.x, Tuning.carry_sink_speed.y, clampf(strength, 0.0, 1.0)))
	var angle := float(int(identity.get("seed", 0)) % 628) * 0.01
	_angle.append(angle)
	_prev_angle.append(angle)
	_spin.append(0.0)
	_swallow.append(0.0)
	_prop_radius.append(PropArt.radius_of(kind))
	_drift_hz.append(Vector2(_rng.randf_range(Tuning.carry_drift_hz.x, Tuning.carry_drift_hz.y), _rng.randf_range(Tuning.carry_drift_hz.x, Tuning.carry_drift_hz.y)))
	_drift_phase.append(Vector2(_rng.randf_range(0.0, TAU), _rng.randf_range(0.0, TAU)))
	_turn.append(_rng.randf_range(Tuning.carry_turn_speed.x, Tuning.carry_turn_speed.y) * (1.0 if _rng.randf() < 0.5 else -1.0))
	_bubble_wait.append(0.0)
	_load_changed()
	for _k: int in Tuning.carry_bubble_on_swallow:
		_emit_bubble(_pos[_pos.size() - 1] * 0.8, 1.0)
	_set_active(true)


## Removes the prop whose slot is nearest the side `dir` points at (the mouth of a shot) and returns its identity.
## The choice reads the fixed slot layout, not the per-frame float, so it is the same at any frame rate.
func take_toward(dir: Vector2) -> Dictionary:
	if _items.is_empty():
		return {}
	return _remove(_pick_toward(dir))


## Kind of the prop that take_toward(dir) would hand out, without removing it.
func peek_toward(dir: Vector2) -> StringName:
	if _items.is_empty():
		return &"rock"
	return _items[_pick_toward(dir)].get("kind", &"rock")


## While the aim is open the prop that will fly next floats to the front of the body, toward the target.
func set_aim(dir: Vector2, active: bool) -> void:
	_aim_active = active and not _items.is_empty()
	if dir != Vector2.ZERO:
		_aim_dir = dir.normalized()
	_front = _pick_toward(_aim_dir) if _aim_active else -1


## Removes the most recently swallowed prop and returns its identity.
func take_last() -> Dictionary:
	if _items.is_empty():
		return {}
	return _remove(_items.size() - 1)


## Call once per physics tick: velocity changes push the props the other way, so they lag behind the body,
## and a hard change (landing, hit, recoil) shakes bubbles loose.
func set_motion(velocity: Vector2) -> void:
	var dv := velocity - _last_velocity
	_last_velocity = velocity
	_impulse += -dv * Tuning.carry_inertia
	if dv.length() > Tuning.carry_bubble_jolt_speed:
		_jolt = maxf(_jolt, clampf(dv.length() / Tuning.carry_bubble_jolt_ref, 0.0, 1.0))


## Temperature from the player, once per physics tick: frost, ember (burning) and melt, each 0..1.
func set_temperature(frost: float, ember: float, melt := 0.0) -> void:
	_frost_target = clampf(frost, 0.0, 1.0)
	_ember_target = clampf(ember, 0.0, 1.0)
	_melt_target = clampf(melt, 0.0, 1.0)


## Respawn keeps the cargo; the props settle again in the new body.
func reset_motion() -> void:
	_impulse = Vector2.ZERO
	_jolt = 0.0
	_last_velocity = Vector2.ZERO
	_b_count = 0
	for i: int in _items.size():
		_vel[i] = Vector2.ZERO
		_pos[i] = _slot(i)
		_prev_pos[i] = _pos[i]
	_still = false
	_data_dirty = true


## Call once per physics tick with the direction of the next shot.
func set_next(dir: Vector2) -> void:
	var next := _pick_toward(dir) if not _items.is_empty() and dir != Vector2.ZERO else -1
	if next != _next:
		_next = next
		_front_dirty = true
		_data_dirty = true


func _pick_toward(dir: Vector2) -> int:
	var best := 0
	var best_dot := -INF
	for i: int in _items.size():
		var d := _layout_slot(i).dot(dir)
		if d > best_dot:
			best_dot = d
			best = i
	return best


func _remove(i: int) -> Dictionary:
	_front = -1
	_next = -1
	var data := _items[i].duplicate()
	_items.remove_at(i)
	_pos.remove_at(i)
	_prev_pos.remove_at(i)
	_vel.remove_at(i)
	_drift_hz.remove_at(i)
	_drift_phase.remove_at(i)
	_angle.remove_at(i)
	_prev_angle.remove_at(i)
	_spin.remove_at(i)
	_swallow.remove_at(i)
	_prop_radius.remove_at(i)
	_turn.remove_at(i)
	_bubble_wait.remove_at(i)
	_load_changed()
	return data


## The load changed: new slot layout, new geometry for the back item, new data.
func _load_changed() -> void:
	var n := _items.size()
	_layout.resize(n)
	for i: int in n:
		_layout[i] = _layout_slot(i)
	_shapes_dirty = true
	_front_dirty = true
	_data_dirty = true


func _set_active(on: bool) -> void:
	if on and not _active:
		# Asleep, the temperature did not follow its target; it catches up here.
		_frost = _frost_target
		_ember = _ember_target
		_melt = _melt_target
	_active = on
	set_process(on)
	set_physics_process(on)
	RenderingServer.canvas_item_set_visible(_back_item, on)
	RenderingServer.canvas_item_set_visible(_front_item, on)
	if not on:
		_shapes_dirty = true
		_front_dirty = true


func _physics_process(delta: float) -> void:
	_time += delta
	var temp_k := 1.0 - exp(-delta * Tuning.temp_body_smooth)
	_frost = lerpf(_frost, _frost_target, temp_k)
	_ember = lerpf(_ember, _ember_target, temp_k)
	_melt = lerpf(_melt, _melt_target, temp_k)
	var impulse := _impulse.limit_length(Tuning.carry_inertia_max) * (1.0 - _frost)
	_impulse = Vector2.ZERO
	if impulse != Vector2.ZERO:
		for i: int in _items.size():
			_vel[i] += impulse
		var share := impulse * Tuning.carry_bubble_inertia_share
		for b: int in _b_count:
			_b_vel[b] += share
	if _jolt > 0.0 and _frost < 0.5:
		_shake_out_bubbles(_jolt)
		_jolt = 0.0
	_step(delta)
	_still = _is_still()
	if not (_still and _still_written):
		_data_dirty = true
	if _items.is_empty() and _b_count == 0 and _warm_frames == 0:
		_set_active(false)


func _process(_delta: float) -> void:
	if _warm_frames > 0:
		_warm_frames -= 1
		if _warm_frames == 0:
			_b_count = 0
			_data_dirty = true
	if _shapes_dirty:
		_build_back()
	if _front_dirty:
		_build_front()
	if _data_dirty:
		_write_data()
	_write_frame()


func _step(dt: float) -> void:
	var n := _items.size()
	var separation := Tuning.carry_separation * _crowd_scale() / maxf(Tuning.carry_item_scale_crowded, 0.01)
	var separation_sq := separation * separation
	var separation_k := Tuning.carry_separation_stiffness
	var bubble_share := maxf(float(n) / 4.0, 1.0) / (1.0 + Tuning.carry_ember_bubble_boost * _ember)
	var sink_rate := dt / maxf(Tuning.carry_sink_time, 0.01)
	var spring := Tuning.carry_spring
	var sink_spring := Tuning.carry_sink_spring
	var damping := Tuning.carry_damping
	var sink_drag := Tuning.carry_sink_drag
	var wall := Tuning.carry_wall
	var wall_k := Tuning.carry_wall_stiffness
	var spin_from_swing := Tuning.carry_spin_from_swing
	var spin_k := minf(Tuning.carry_spin_drag * dt, 1.0)
	# Ice slows every motion inside it to a stop; the props keep the pose they froze in.
	var live_dt := dt * (1.0 - _frost)
	for i: int in n:
		var p := _pos[i]
		var v := _vel[i]
		_prev_pos[i] = p
		_prev_angle[i] = _angle[i]
		var sinking := _swallow[i] < 1.0
		_swallow[i] = minf(_swallow[i] + sink_rate, 1.0)
		var stiffness := spring * (sink_spring if sinking else 1.0)
		var drag := damping * (1.0 + sink_drag * (1.0 - _swallow[i]))
		var force := (_slot(i) - p) * stiffness - v * drag
		# Soft push from near props, in item order: a prop feels the props before it at their new places, so a load
		# swallowed at one point spreads the same way at any step rate.
		for j: int in n:
			if j == i:
				continue
			var away := p - _pos[j]
			var d_sq := away.length_squared()
			if d_sq < separation_sq and d_sq > 0.00000001:
				var d := sqrt(d_sq)
				force += away * ((separation - d) * separation_k / d)
		var dist := p.length()
		if dist > wall and _swallow[i] >= 1.0:
			force -= p / dist * (dist - wall) * wall_k
		v += force * live_dt
		_vel[i] = v
		_pos[i] = p + v * live_dt
		# Each prop turns at its own slow pace; a sideways swing adds a little roll that the jelly then damps.
		var target_spin := _turn[i] + v.x * spin_from_swing
		_spin[i] += (target_spin - _spin[i]) * spin_k
		_angle[i] += _spin[i] * live_dt
		_bubble_wait[i] -= dt
		if _frost > 0.5:
			continue
		if sinking and _bubble_wait[i] <= 0.0:
			# A sinking prop leaves a trail of small bubbles through the gelatin.
			_bubble_wait[i] = Tuning.carry_sink_bubble_interval
			_emit_bubble(_pos[i], 0.6)
		elif _bubble_wait[i] <= 0.0:
			_bubble_wait[i] = _rng.randf_range(Tuning.carry_bubble_interval.x, Tuning.carry_bubble_interval.y) * bubble_share
			for _k: int in _rng.randi_range(Tuning.carry_bubble_per_release.x, Tuning.carry_bubble_per_release.y):
				_emit_bubble(_pos[i], 1.0)
	_step_bubbles(live_dt)


## True when no bubble lives and every prop is fully inside and still near its last written place and turn.
func _is_still() -> bool:
	var n := mini(_items.size(), MAX_SLOTS)
	if _b_count > 0 or _written_pos.size() != n:
		return false
	var move_sq := Tuning.carry_still_move * Tuning.carry_still_move
	var turn := Tuning.carry_still_turn
	for i: int in n:
		if _swallow[i] < 1.0 or _pos[i].distance_squared_to(_written_pos[i]) > move_sq or absf(_angle[i] - _written_angle[i]) > turn:
			return false
	return true


func _step_bubbles(dt: float) -> void:
	if _b_count == 0:
		return
	var rise := Tuning.carry_bubble_rise * (1.0 + Tuning.carry_ember_rise_boost * _ember)
	var ceiling := Tuning.carry_bubble_ceiling
	var limit_sq := Tuning.carry_bubble_limit * Tuning.carry_bubble_limit
	var keep := maxf(1.0 - Tuning.carry_damping * dt, 0.0)
	var wobble_step := dt * Tuning.carry_bubble_wobble_hz * TAU
	var wobble := Tuning.carry_bubble_wobble * dt
	var b := 0
	while b < _b_count:
		_b_life[b] -= dt
		var p := _b_pos[b]
		if _b_life[b] <= 0.0 or p.y < ceiling or p.length_squared() > limit_sq:
			_remove_bubble(b)
			continue
		var v := _b_vel[b]
		v.y = move_toward(v.y, -rise, rise * 2.0 * dt)
		v.x *= keep
		_b_vel[b] = v
		_b_phase[b] += wobble_step
		_b_prev[b] = p
		_b_age_prev[b] = _bubble_age(b, dt)
		_b_pos[b] = p + v * dt + Vector2(cos(_b_phase[b]) * wobble, 0.0)
		b += 1


## Share of its life a bubble has lived, `ago` seconds before now.
func _bubble_age(b: int, ago: float) -> float:
	return 1.0 - (_b_life[b] + ago) / maxf(_b_life_max[b], 0.001)


func _emit_bubble(from: Vector2, strength: float) -> void:
	if _b_count >= _b_pos.size():
		return
	var b := _b_count
	_b_count += 1
	_b_pos[b] = from + Vector2(_rng.randf_range(-0.08, 0.08), _rng.randf_range(-0.12, -0.04))
	_b_prev[b] = _b_pos[b]
	_b_vel[b] = Vector2(_rng.randf_range(-0.1, 0.1), -Tuning.carry_bubble_rise * _rng.randf_range(0.3, 0.8)) * strength
	var life := _rng.randf_range(Tuning.carry_bubble_life.x, Tuning.carry_bubble_life.y)
	_b_life[b] = life
	_b_life_max[b] = life
	_b_age_prev[b] = 0.0
	_b_size[b] = _rng.randf_range(Tuning.carry_bubble_size.x, Tuning.carry_bubble_size.y)
	_b_phase[b] = _rng.randf_range(0.0, TAU)
	_data_dirty = true


func _remove_bubble(b: int) -> void:
	_b_count -= 1
	_b_pos[b] = _b_pos[_b_count]
	_b_prev[b] = _b_prev[_b_count]
	_b_vel[b] = _b_vel[_b_count]
	_b_life[b] = _b_life[_b_count]
	_b_life_max[b] = _b_life_max[_b_count]
	_b_age_prev[b] = _b_age_prev[_b_count]
	_b_size[b] = _b_size[_b_count]
	_b_phase[b] = _b_phase[_b_count]


func _shake_out_bubbles(strength: float) -> void:
	if _items.is_empty():
		return
	var total := int(round(Tuning.carry_bubble_jolt_max * strength))
	for k: int in total:
		_emit_bubble(_pos[k % _items.size()], 1.0 + strength)


## Resting spot of item i: a fixed layout for the current load around the zone centre, plus a slow drift of its own.
func _slot(i: int) -> Vector2:
	if i == _front:
		return _aim_dir * Tuning.aim_cargo_front
	var hz := _drift_hz[i]
	var phase := _drift_phase[i]
	var drift := Vector2(sin(_time * TAU * hz.x + phase.x), sin(_time * TAU * hz.y + phase.y)) * Tuning.carry_drift * (1.0 - _frost)
	var slot := Tuning.carry_zone_center + _layout[i]
	if _melt > 0.0:
		# In a puddle the props lie side by side on the bottom.
		slot = slot.lerp(Vector2(slot.x * Tuning.carry_melt_spread, Tuning.carry_melt_floor), _melt)
	return slot + drift


## Up to four props use the hand-made layouts; a larger load fills an ellipse below the face on a sunflower spiral.
func _layout_slot(i: int) -> Vector2:
	var count := maxi(_items.size(), 1)
	if count <= SLOT_LAYOUTS.size():
		var layout: Array = SLOT_LAYOUTS[count - 1]
		return layout[mini(i, layout.size() - 1)]
	var t := sqrt((float(i) + 0.5) / float(count))
	var a := float(i) * GOLDEN_ANGLE
	return Vector2(cos(a) * Tuning.carry_zone_half.x, sin(a) * Tuning.carry_zone_half.y) * t


## Item scale for the current load: the props shrink as more of them share the body.
func _crowd_scale() -> float:
	var count := _items.size()
	if count < 3:
		return Tuning.carry_item_scale
	return maxf(Tuning.carry_item_scale_crowded * sqrt(minf(Tuning.carry_crowd_ref / float(count), 1.0)), Tuning.carry_item_scale_min)


func _radius() -> float:
	if not is_instance_valid(body) or not body.has_method(&"radius"):
		return 0.0
	return float(body.call(&"radius"))


func _setup_material() -> void:
	_material.shader = CARGO_SHADER
	var params := _shader_params()
	for key: StringName in params:
		_material.set_shader_parameter(key, params[key])


## The fixed uniforms of cargo.gdshader.
static func _shader_params() -> Dictionary:
	return {
		&"radius_full": Tuning.radius_full,
		&"soft_edge": PropArt.ShapeBatch.SOFT_EDGE,
		&"edge_width": Tuning.carry_edge_width,
		&"edge_alpha": Tuning.carry_edge_alpha,
		&"next_edge_alpha": Tuning.carry_next_edge_alpha,
		&"lighten": Tuning.carry_lighten,
		&"next_lighten": Tuning.carry_next_lighten,
		&"next_scale": Tuning.carry_next_scale,
		&"next_pulse": Tuning.carry_next_pulse,
		&"next_pulse_hz": Tuning.carry_next_pulse_hz,
		&"gloss_alpha": Tuning.carry_gloss_alpha,
		&"ember_glow": Tuning.carry_ember_glow,
		&"ember_tint": Tuning.carry_ember_tint,
		&"ember_pulse_hz": Tuning.ember_pulse_hz,
		&"frost_tint": Tuning.carry_frost_tint,
		&"carry_alpha": Tuning.carry_alpha,
		&"bubble_alpha": Tuning.carry_bubble_alpha,
		&"ember_hot": Vector3(Tuning.ember_hot.r, Tuning.ember_hot.g, Tuning.ember_hot.b),
		&"ember_core": Vector3(Tuning.ember_core.r, Tuning.ember_core.g, Tuning.ember_core.b),
		&"frost_color": Vector3(Tuning.frost_body_color.r, Tuning.frost_body_color.g, Tuning.frost_body_color.b),
		&"light_shift": PropArt.LIGHT_OFFSET,
		&"press_narrow": Tuning.body_press_narrow,
		&"press_tall": Tuning.body_press_tall,
		&"ceiling_depth": Tuning.body_ceiling_depth,
		&"ceiling_bulge": Tuning.body_ceiling_bulge,
		&"aim_stretch": Tuning.body_aim_stretch,
		&"aim_shift": Tuning.body_aim_shift,
	}


## Back item: every prop of the load in item order; the shader hides the one the front item draws.
func _build_back() -> void:
	_shapes_dirty = false
	RenderingServer.canvas_item_clear(_back_item)
	var n := mini(_items.size(), MAX_SLOTS)
	if n == 0:
		return
	var points := PackedVector2Array()
	var colors := PackedColorArray()
	var codes := PackedVector2Array()
	var size_scale := _size_scale()
	for i: int in n:
		_append_shape(i, 0, _prop_radius[i] * size_scale, points, colors, codes)
	RenderingServer.canvas_item_add_triangle_array(_back_item, PackedInt32Array(), points, colors, codes)


## Front item: the next prop on top of the others, then the bubbles over every prop.
func _build_front() -> void:
	_front_dirty = false
	RenderingServer.canvas_item_clear(_front_item)
	_drawn_front = _next if _next >= 0 and _next < mini(_items.size(), MAX_SLOTS) else -1
	if _drawn_front >= 0:
		var points := PackedVector2Array()
		var colors := PackedColorArray()
		var codes := PackedVector2Array()
		var radius := _prop_radius[_drawn_front] * _size_scale()
		if _items.size() > 1:
			radius *= Tuning.carry_next_scale * (1.0 + Tuning.carry_next_pulse * 0.5)
		_append_shape(_drawn_front, CargoMesh.FRONT, radius, points, colors, codes)
		RenderingServer.canvas_item_add_triangle_array(_front_item, PackedInt32Array(), points, colors, codes)
	RenderingServer.canvas_item_add_triangle_array(_front_item, PackedInt32Array(), _bubble_geo[0], _bubble_geo[1], _bubble_geo[2], PackedInt32Array(), PackedFloat32Array(), _bubble_texture.get_rid())


## Scale from the prop radius to pixels for the current load and body size, without the next-shot growth.
func _size_scale() -> float:
	var r := _radius()
	if r <= 1.0:
		r = Tuning.radius_full
	return clampf(r / maxf(Tuning.radius_full, 1.0), 0.55, 1.0) * _crowd_scale()


func _append_shape(i: int, layer_offset: int, radius: float, points: PackedVector2Array, colors: PackedColorArray, codes: PackedVector2Array) -> void:
	var shape := CargoMesh.prop(_items[i].get("kind", &"rock"), int(_items[i].get("seed", 0)), radius)
	points.append_array(shape[0])
	colors.append_array(shape[1])
	codes.append_array(Transform2D(0.0, Vector2(i * CargoMesh.SLOT + layer_offset, 0.0)) * (shape[2] as PackedVector2Array))


## Per-step data of every prop and bubble, after each step or change.
func _write_data() -> void:
	_data_dirty = false
	_buf = 1 - _buf
	var item_pos := _item_pos_buf[_buf]
	var item_data := _item_data_buf[_buf]
	var n := mini(_items.size(), MAX_SLOTS)
	var has_next := _next >= 0 and _items.size() > 1
	# A still load keeps the places it was written at, with no blend, so the shader shows it at rest.
	var still := _still and _written_pos.size() == n
	_written_pos.resize(n)
	_written_angle.resize(n)
	for i: int in n:
		var p := _prev_pos[i]
		var q := _pos[i]
		var a0 := _prev_angle[i]
		var a1 := _angle[i]
		if still:
			q = _written_pos[i]
			p = q
			a1 = _written_angle[i]
			a0 = a1
		item_pos[i] = Vector4(p.x, p.y, q.x, q.y)
		_written_pos[i] = q
		_written_angle[i] = a1
		var flags := _swallow[i] + (2.0 if i == _drawn_front else 0.0) + (4.0 if has_next and i == _next else 0.0)
		item_data[i] = Vector4(a0, a1, _prop_radius[i], flags)
	_still_written = still
	var bubble_pos := _bubble_pos_buf[_buf]
	var bubble_data := _bubble_data_buf[_buf]
	for b: int in _b_count:
		var p := _b_prev[b]
		var q := _b_pos[b]
		bubble_pos[b] = Vector4(p.x, p.y, q.x, q.y)
		bubble_data[b] = Vector4(_b_size[b], _b_age_prev[b], _bubble_age(b, 0.0), 1.0)
	# Slots that bubbles left since this buffer was last written are cleared; the rest are clear already.
	for b: int in range(_b_count, _bubbles_written[_buf]):
		bubble_data[b] = Vector4.ZERO
	_bubbles_written[_buf] = _b_count
	RenderingServer.material_set_param(_material_rid, &"item_pos", item_pos)
	RenderingServer.material_set_param(_material_rid, &"item_data", item_data)
	RenderingServer.material_set_param(_material_rid, &"bubble_pos", bubble_pos)
	RenderingServer.material_set_param(_material_rid, &"bubble_data", bubble_data)


## Per-frame data: the blend between the last two steps, the clocks, and the body deformation.
func _write_frame() -> void:
	_frame_index = 1 - _frame_index
	var frame := _frame_buf[_frame_index]
	var share := Engine.get_physics_interpolation_fraction()
	var crowd := _crowd_scale()
	var warm := 1.0 if _warm_frames > 0 else 0.0
	if is_instance_valid(body):
		_pack_frame(frame, body.call(&"deform_state"), share, _time - _tick + share * _tick, crowd, _ember, _frost, warm)
	else:
		frame[0] = Vector4(share, _time, 0.0, crowd)
		frame[1] = Vector4(_ember, _frost, warm, Tuning.radius_full)
		frame[2] = Vector4(1.0, 1.0, 1.0, 1.0)
		for k: int in range(3, 7):
			frame[k] = Vector4.ZERO
	RenderingServer.material_set_param(_material_rid, &"frame", frame)


## Shader frame data (the `frame` uniform of cargo.gdshader) from a SlimeBody.deform_state() array.
static func _pack_frame(frame: PackedVector4Array, s: PackedFloat32Array, share: float, time: float, crowd: float, ember: float, frost: float, warm: float) -> void:
	frame[0] = Vector4(share, time, s[D.RADIUS], crowd)
	frame[1] = Vector4(ember, frost, warm, s[D.R])
	frame[2] = Vector4(s[D.SX], s[D.SY], s[D.EX], s[D.EY])
	frame[3] = Vector4(s[D.CRAWL_DX], s[D.PRESS], s[D.PRESS_SIDE], s[D.FEET])
	frame[4] = Vector4(s[D.CEIL], s[D.LEAN], s[D.FROST], s[D.AIM_PULL])
	frame[5] = Vector4(s[D.AIM_X], s[D.AIM_Y], s[D.ROLL], 0.0)
	frame[6] = Vector4(s[D.PIVOT_X], s[D.PIVOT_Y], 0.0, 0.0)


## GDScript mirror of deform_point() in cargo.gdshader: the same math on the same frame data and uniforms.
## The source of the deformation is SlimeBody._shape_point() and _deform() (slime_body.gd); change all three together.
## check_deform() compares this mirror with the body at boot.
static func _shader_deform(p: Vector2, frame: PackedVector4Array, u: Dictionary) -> Vector2:
	var f1 := frame[1]
	var f2 := frame[2]
	var f3 := frame[3]
	var f4 := frame[4]
	var f5 := frame[5]
	var r := f1.w
	var q := Vector2(p.x * f2.x, p.y * f2.y + r * (1.0 - f2.y))
	q.x = q.x * f2.z + f3.x
	q.y = r - (r - q.y) * f2.w
	if f3.y > 0.001:
		var anchor := f3.z * f3.w
		q.x = anchor + (q.x - anchor) * (1.0 - float(u[&"press_narrow"]) * f3.y)
		q.y = r - (r - q.y) * (1.0 + float(u[&"press_tall"]) * f3.y)
	if absf(f4.x) > 0.001:
		var top := clampf(-q.y / maxf(r, 0.001), 0.0, 1.0)
		var mid := clampf(1.0 - absf(q.y) / maxf(r, 0.001), 0.0, 1.0)
		q.y += top * f4.x * float(u[&"ceiling_depth"]) * r
		q.x *= 1.0 + float(u[&"ceiling_bulge"]) * f4.x * mid
	var span := maxf(r * 2.0, 0.001)
	var h := clampf((r - q.y) / span, 0.0, 1.2)
	q.x += f4.y * span * h * (0.5 + 0.5 * h) * (1.0 - f4.z)
	if absf(f4.w) > 0.001:
		var back := -Vector2(f5.x, f5.y)
		var along := maxf(q.dot(back) / maxf(r, 0.001), 0.0)
		q += back * f4.w * r * (float(u[&"aim_stretch"]) * along + float(u[&"aim_shift"])) * (1.0 - f4.z)
	if f5.z != 0.0:
		var pivot := Vector2(frame[6].x, frame[6].y)
		q = pivot + (q - pivot).rotated(f5.z)
	return q


## Boot check (Harness, debug builds): places sample points with SlimeBody._deform() and with the shader mirror on
## sample deformation states, and prints an error when they differ by more than Tuning.carry_deform_check_limit px.
static func check_deform() -> float:
	var probe: Node2D = SlimeBody.new()
	var frame := PackedVector4Array()
	frame.resize(7)
	var uniforms := _shader_params()
	var worst := 0.0
	for state: PackedFloat32Array in Tuning.carry_deform_check_states:
		probe.call(&"set_deform_state", state)
		_pack_frame(frame, state, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0)
		for point: Vector2 in Tuning.carry_deform_check_points:
			var p := point * state[D.R]
			var gap := (probe.call(&"deform_point", p) as Vector2).distance_to(_shader_deform(p, frame, uniforms))
			worst = maxf(worst, gap)
	probe.free()
	if worst > Tuning.carry_deform_check_limit:
		push_error("Cargo: the cargo shader mirror of SlimeBody._deform is %.4f px off (limit %.4f); change slime_body.gd _shape_point, cargo.gdshader deform_point and cargo.gd _shader_deform together" % [worst, Tuning.carry_deform_check_limit])
	return worst


## A pale goo-green ring with a bright spot: reads as an air bubble in the jelly.
static func _make_bubble_texture() -> ImageTexture:
	var size := BUBBLE_TEXTURE_SIZE
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var half := size * 0.5
	var tint := Tuning.goo_body_color.lerp(Color.WHITE, 0.65)
	for y: int in size:
		for x: int in size:
			var offset := Vector2(x + 0.5 - half, y + 0.5 - half)
			var d := offset.length() / (half - 1.0)
			var ring := clampf(1.0 - absf(d - 0.82) * 6.0, 0.0, 1.0)
			var fill := 0.18 * clampf(1.0 - d, 0.0, 1.0)
			var spot := clampf(1.0 - (offset + Vector2(half * 0.32, half * 0.32)).length() / (half * 0.22), 0.0, 1.0)
			var a := clampf(ring + fill + spot, 0.0, 1.0) * (1.0 if d <= 1.0 else 0.0)
			img.set_pixel(x, y, Color(tint.lerp(Color.WHITE, spot), a))
	return ImageTexture.create_from_image(img)
