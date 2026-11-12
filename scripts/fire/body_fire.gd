extends Node2D
## The fire on a burning slime: flames that rise from the upper body and stream with the air, a glow inside the
## gelatin, a thin smoke over the tips, sparks, warm light on what is near, heat shimmer above and a crackling roar.
## It starts at the point where the slime touched the flames and runs over the body; its size follows the fuel; it
## dies with a last flicker, goes out in a burst of steam in the cold, and puffs out with a death.
## Every piece is made one time: the flames are one quad of fire.gdshader (kind body) that the shader animates; the
## script only moves nodes and sets a few uniforms when they change. Sparks and puffs are engine particle nodes.
## It runs only while the slime burns or its fire ends. Child of TemperatureFx, which passes the fuel share every
## physics tick (set_fire). Visual and audio only: it uses its own seeded RNG and never touches gameplay state.

const FireAssets := preload("res://scripts/fire/fire_assets.gd")
const FireQuad := preload("res://scripts/fire/fire_quad.gd")
const FireLean := preload("res://scripts/fire/fire_lean.gd")
const FireShimmer := preload("res://scripts/fire/fire_shimmer.gd")

const RNG_SEED := 7919
const WARM_UP_FRAMES := 4
const FIRE_GROUP := &"fire_zones"
## No front: every side of the body is caught.
const SPREAD_DONE := -2.0
## The body shape is read every this many frames; it changes slowly.
const SHAPE_EVERY := 2
## Uniforms and node values change only past these steps, so a still fire sets nothing.
const POWER_STEP := 1.0 / 64.0
const LEAN_STEP := 0.01
const SHAPE_STEP := 0.5
const SOUND_EVERY := 4

enum End { NONE, BURNED_OUT, QUENCHED, DEATH, FADE }

var body: Node2D

var _player: Node2D
var _share := 0.0
var _burning := false
## Visual strength 0..1 of the fire now, eased toward the fuel share.
var _power := 0.0
## Seconds since the fire started; it spreads over the body in Tuning.fire_spread_time.
var _since_start := 999.0
## Direction from the body centre toward the point that caught fire.
var _touch := Vector2.DOWN
var _end := End.NONE
var _end_left := 0.0
var _end_time := 1.0
var _end_power := 0.0
var _time := 0.0
var _frame := 0
## Seconds since the flames went out.
var _idle := 0.0
var _crackle_wait := 0.0
var _warm_frames := 0
var _rng := RandomNumberGenerator.new()
var _lean := FireLean.new()
var _material: ShaderMaterial
var _flames := FireQuad.new()
var _light := FireQuad.new()
var _sparks: CPUParticles2D
var _puffs: CPUParticles2D
var _shimmer := FireShimmer.new()
var _roar: AudioStreamPlayer2D
## Body frame of the last read (offset of the centre from the player, radii) and the values last sent.
var _center_offset := Vector2.ZERO
var _radii := Vector2.ONE
var _sent_power := -1.0
var _sent_lean := Vector2(INF, INF)
var _sent_radii := Vector2.ZERO
var _sent_height := -1.0
var _sent_light := -1.0
var _sent_floor := false
var _sent_rich := true


func _ready() -> void:
	_player = get_parent().get_parent() as Node2D
	_rng.seed = RNG_SEED
	_material = FireAssets.new_fire_material()
	_sent_rich = Tuning.fx_fire_rich
	# The flames quad spans -1..1 and is placed in global space by position and scale.
	_flames.name = &"Flames"
	_flames.top_level = true
	_flames.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_flames.material = _material
	_flames.add_piece(FireQuad.KIND_BODY, Rect2(-1.0, -1.0, 2.0, 2.0), Color.WHITE)
	_flames.visible = false
	add_child(_flames)
	# The light: a warm wash around the fire and a pool on the floor, a unit-radius pair scaled by the body radius.
	_light.name = &"Light"
	_light.material = FireAssets.fire_material()
	_light.visible = false
	add_child(_light)
	_sparks = FireAssets.make_sparks(Tuning.fire_body_spark_amount, Vector2(Tuning.radius_full, Tuning.radius_full * 0.4))
	_sparks.name = &"Sparks"
	_sparks.visible = false
	add_child(_sparks)
	_puffs = FireAssets.make_puffs(Tuning.fire_quench_steam)
	_puffs.name = &"Puffs"
	# Hidden between bursts: an idle particle node still costs a draw call.
	_puffs.visible = false
	_puffs.finished.connect(_puffs.hide)
	add_child(_puffs)
	_shimmer.name = &"Shimmer"
	add_child(_shimmer)
	var loop := Sfx.stream(&"fire_roar")
	if loop != null:
		_roar = AudioStreamPlayer2D.new()
		_roar.stream = loop
		_roar.bus = &"SFX"
		_roar.max_distance = Tuning.fire_roar_distance
		add_child(_roar)
	_build_light(true)
	Game.temperature_event.connect(_on_temperature_event)
	set_process(false)


# A looping voice still in the audio server at shutdown leaks its stream.
func _exit_tree() -> void:
	if _roar != null:
		_roar.stop()
		_roar.stream = null


## From TemperatureFx every physics tick: the fuel share, 0 when the slime does not burn.
func set_fire(share: float) -> void:
	var burning := share > 0.0
	if burning and not _burning:
		_end = End.NONE
		if _since_start > Tuning.fire_spread_time and _power <= 0.01:
			# No fire_start event came with it: the whole body burns at once.
			_since_start = Tuning.fire_spread_time
		set_process(true)
	_burning = burning
	_share = share


func is_burning() -> bool:
	return _burning


func clear() -> void:
	_share = 0.0
	_burning = false
	_power = 0.0
	_end = End.NONE
	_end_left = 0.0
	_since_start = 999.0
	_lean.reset()
	_apply_hidden()
	if _roar != null:
		_roar.stop()


## A few frames of every piece of the fire at almost no strength, behind the loading cover, so the shaders and the
## particle nodes are ready before the first fire.
func warm_up() -> void:
	_warm_frames = WARM_UP_FRAMES
	_flames.visible = true
	_light.visible = true
	_material.set_shader_parameter(&"body_power", 0.004)
	_flames.position = _player_position()
	_flames.scale = Vector2(8.0, 8.0)
	_light.modulate.a = 0.004
	_sparks.emitting = true
	_sparks.visible = true
	_puffs.modulate = Color(1.0, 1.0, 1.0, 0.004)
	_puffs.visible = true
	_puffs.restart()
	_puffs.emitting = true
	_shimmer.scale = Vector2(8.0, 8.0)
	_shimmer.set_strength(0.02)
	set_process(true)


func _on_temperature_event(event: StringName, data: Dictionary) -> void:
	match event:
		&"fire_start":
			_start()
		&"fire_end":
			_finish(StringName(data.get("reason", &"")))


func _start() -> void:
	_since_start = 0.0
	_end = End.NONE
	_touch = _touch_direction()
	_material.set_shader_parameter(&"body_touch", _touch)
	set_process(true)


func _finish(reason: StringName) -> void:
	_end_power = _power
	match reason:
		&"cold":
			_end = End.QUENCHED
			_end_time = Tuning.fire_quench_time
			# The cold kills the flames at once and boils the goo surface into white steam.
			_puff(Tuning.fire_steam_color, 1.0)
			Sfx.play(&"sizzle", _player_position(), 0.65, -4.0)
		&"burned_out":
			_end = End.BURNED_OUT
			_end_time = Tuning.fire_die_time
		&"death":
			_end = End.DEATH
			_end_time = Tuning.fire_quench_time
			_puff(Tuning.fire_death_smoke_color, 0.6)
		_:
			_end = End.FADE
			_end_time = Tuning.fire_quench_time
	_end_left = _end_time
	_burning = false
	set_process(true)


## One burst of the puff emitter over the upper body: white steam or dark smoke.
func _puff(color: Color, speed_scale: float) -> void:
	var r := maxf(_radius(), 8.0)
	_puffs.position = _center_offset + Vector2(0.0, -_radii.y * 0.4)
	_puffs.emission_rect_extents = Vector2(_radii.x * 0.8, _radii.y * 0.4)
	_puffs.scale_amount_min = r * Tuning.fire_puff_size.x / FireAssets.DOT_SIZE
	_puffs.scale_amount_max = r * Tuning.fire_puff_size.y / FireAssets.DOT_SIZE
	_puffs.speed_scale = speed_scale
	_puffs.modulate = color
	_puffs.visible = true
	_puffs.restart()
	_puffs.emitting = true


## The side of the body nearest to the flames it touched; straight down when no flames are near (--burn).
func _touch_direction() -> Vector2:
	var center := _player_position()
	var best := Vector2.DOWN
	var best_distance := _radius() * 2.5
	for zone: Node in get_tree().get_nodes_in_group(FIRE_GROUP):
		var rect: Rect2 = zone.call(&"global_rect")
		var nearest := center.clamp(rect.position, rect.end)
		var distance := nearest.distance_to(center)
		if distance < best_distance:
			best_distance = distance
			var offset := nearest - center
			best = offset.normalized() if offset.length_squared() > 1.0 else Vector2.DOWN
	return best


func _process(delta: float) -> void:
	_frame += 1
	_time += delta
	_since_start += delta
	if _warm_frames > 0:
		_warm_frames -= 1
		if _warm_frames == 0:
			_puffs.emitting = false
			_puffs.visible = false
			_sparks.emitting = false
			_apply_hidden()
		return
	var velocity := _velocity()
	_lean.update(delta, velocity)
	_update_power(delta)
	var r := _radius()
	if _power <= 0.0 or r <= 1.0:
		_apply_hidden()
		_idle += delta
		# The last sparks live out their life, then the idle emitter hides (it would still cost a draw call).
		if _idle >= Tuning.fire_spark_life:
			_sparks.visible = false
			if not _burning and _end == End.NONE:
				set_process(false)
		return
	_idle = 0.0
	_sparks.visible = true
	if _frame % SHAPE_EVERY == 0 or not _flames.visible:
		_read_shape()
	_apply(r)
	if _frame % SOUND_EVERY == 0:
		_update_sound(delta * SOUND_EVERY, velocity)


func _update_power(delta: float) -> void:
	if _end != End.NONE:
		_end_left = maxf(_end_left - delta, 0.0)
		var k := _end_left / maxf(_end_time, 0.001)
		if _end == End.BURNED_OUT:
			# The last flicker: a short flare a moment after the end, then the flames sink into nothing.
			var flare := Tuning.fire_die_flare * maxf(0.0, sin(PI * clampf((1.0 - k) / 0.35, 0.0, 1.0)))
			_power = _end_power * k * (1.0 + flare)
		else:
			_power = _end_power * k * k
		if _end_left <= 0.0:
			_end = End.NONE
			_power = 0.0
		return
	var target := lerpf(Tuning.fire_min_power, 1.0, _share) if _burning else 0.0
	if _burning and _player_flowing():
		target *= Tuning.fire_flow_power
	var rate := Tuning.fire_power_rise if target > _power else Tuning.fire_power_fall
	_power = move_toward(_power, target, rate * delta)


## Reads the drawn body as an ellipse: its centre offset from the player and its radii.
func _read_shape() -> void:
	if not is_instance_valid(body) or not body.has_method(&"surface_point"):
		return
	var left: Vector2 = body.call(&"surface_point", Vector2.LEFT)
	var right: Vector2 = body.call(&"surface_point", Vector2.RIGHT)
	var top: Vector2 = body.call(&"surface_point", Vector2.UP)
	var bottom: Vector2 = body.call(&"surface_point", Vector2.DOWN)
	_center_offset = Vector2((left.x + right.x) * 0.5, (top.y + bottom.y) * 0.5)
	_radii = Vector2(maxf((right.x - left.x) * 0.5, 1.0), maxf((bottom.y - top.y) * 0.5, 1.0))


## Moves the pieces and sends the uniforms that changed.
func _apply(r: float) -> void:
	var power := snappedf(_power, POWER_STEP)
	var height := _flame_height(r) * power
	var stretch := _lean.tip(1.0).length()
	var center := _player_position() + _center_offset
	_flames.visible = true
	if not _sent_radii.is_equal_approx(_radii.snappedf(SHAPE_STEP)):
		_sent_radii = _radii.snappedf(SHAPE_STEP)
		_material.set_shader_parameter(&"body_radii", _sent_radii)
	var lean := _lean.lean.snappedf(LEAN_STEP)
	if not lean.is_equal_approx(_sent_lean):
		_sent_lean = lean
		_material.set_shader_parameter(&"body_lean", lean)
	var flame_height := snappedf(maxf(height * stretch, 1.0), SHAPE_STEP)
	if flame_height != _sent_height:
		_sent_height = flame_height
		_material.set_shader_parameter(&"body_flame_height", flame_height)
	if Tuning.fx_fire_rich != _sent_rich:
		# The performance panel switched the fire: the inner flame and the heat follow at once.
		_sent_rich = Tuning.fx_fire_rich
		_material.set_shader_parameter(&"inner_layer", 1.0 if _sent_rich else 0.0)
		_sent_power = -1.0
	if power != _sent_power:
		_sent_power = power
		_material.set_shader_parameter(&"body_power", power)
		_material.set_shader_parameter(&"body_wild", lerpf(Tuning.fire_flicker_calm, Tuning.fire_flicker_wild, _share if _burning else 0.0))
		_material.set_shader_parameter(&"body_heat", lerpf(Tuning.fire_outer_heat.x, Tuning.fire_outer_heat.y, power) * (1.0 if Tuning.fx_fire_rich else Tuning.fire_single_layer_heat))
		_light.modulate.a = power
		_sparks.emitting = power > Tuning.fire_spark_min_power
		_sparks.modulate.a = clampf(power * 1.4, 0.0, 1.0)
	if _since_start <= Tuning.fire_spread_time + 0.1:
		var front := _since_start / maxf(Tuning.fire_spread_time, 0.001) * (PI + Tuning.fire_spread_soft)
		_material.set_shader_parameter(&"body_spread_cos", cos(front) if front < PI else SPREAD_DONE)
		var flash := 1.0 - clampf(_since_start / Tuning.fire_spread_time, 0.0, 1.0)
		_material.set_shader_parameter(&"body_flash", flash * flash)
	# The quad: the body, the flames over it bent by the lean and the smoke over their tips.
	var reach := height * Tuning.fire_lean_length_range.y
	var bend := absf(lean.x) * reach * 1.2
	var side := _radii.x * 0.2 + height * 0.7
	var area := Rect2(center - _radii, _radii * 2.0).grow_individual(side + (bend if lean.x < 0.0 else 0.0), reach * Tuning.fire_smoke_reach + 4.0, side + (bend if lean.x > 0.0 else 0.0), 4.0)
	_flames.position = area.get_center()
	_flames.scale = area.size * 0.5
	_material.set_shader_parameter(&"body_center", center)
	# The light grows with the body and leans a little with the flames; the floor pool only on the floor.
	var light_scale := snappedf(r, SHAPE_STEP)
	if light_scale != _sent_light:
		_sent_light = light_scale
		_light.scale = Vector2.ONE * light_scale
		_sparks.emission_rect_extents = Vector2(_radii.x * 0.8, _radii.y * 0.35)
	_light.position = _center_offset + _lean.lean * r * 0.3
	_light.visible = true
	_sparks.position = _center_offset + Vector2(0.0, -_radii.y * 0.6) + _lean.tip(height * 0.3)
	var on_floor := _player_on_floor()
	if on_floor != _sent_floor:
		_sent_floor = on_floor
		_build_light(on_floor)
	_shimmer.position = _center_offset + Vector2(0.0, -_radii.y) + _lean.lean * height * 0.5
	_shimmer.scale = Vector2(_radii.x * 2.6, _radii.y * Tuning.fire_haze_height)
	_shimmer.set_strength(power * Tuning.fire_haze_strength)


func _apply_hidden() -> void:
	_flames.visible = false
	_light.visible = false
	_sparks.emitting = false
	_shimmer.set_strength(0.0)
	_sent_power = -1.0


## The light pieces in unit body radii: a warm wash and, on the floor, a flat pool under the body.
func _build_light(on_floor: bool) -> void:
	_light.clear_pieces()
	_light.add_glow(Vector2(0.0, -0.4), Vector2.ONE * Tuning.fire_body_light_radius, Tuning.fire_glow_color)
	if on_floor:
		_light.add_glow(Vector2(0.0, 1.0), Vector2(Tuning.fire_body_light_radius * 0.9, 0.5), Tuning.fire_floor_light_color)
	_light.redraw()


func _update_sound(delta: float, velocity: Vector2) -> void:
	var audible := _power > 0.02
	if _roar != null:
		if audible and not _roar.playing:
			_roar.play(_rng.randf() * 0.3)
		elif not audible and _roar.playing:
			_roar.stop()
		if audible:
			var rush := clampf(velocity.length() / Tuning.fire_roar_rush_speed, 0.0, 1.0)
			_roar.volume_db = lerpf(Tuning.fire_roar_db.x, Tuning.fire_roar_db.y, _power) + Tuning.fire_roar_rush_db * rush
			_roar.pitch_scale = lerpf(Tuning.fire_roar_pitch.x, Tuning.fire_roar_pitch.y, _power) * (1.0 + 0.15 * rush) * lerpf(0.97, 1.03, FireAssets.flicker(_time * 0.7, 0.3))
	if not audible:
		return
	_crackle_wait -= delta * _power
	if _crackle_wait <= 0.0:
		_crackle_wait = _rng.randf_range(Tuning.fire_crackle_interval.x, Tuning.fire_crackle_interval.y)
		Sfx.play(&"fire_crackle", _player_position(), _rng.randf_range(0.75, 1.45), lerpf(Tuning.fire_crackle_db.x, Tuning.fire_crackle_db.y, _power))


func _flame_height(r: float) -> float:
	return Tuning.fire_body_flame_height * clampf(r / maxf(Tuning.radius_full, 1.0), Tuning.fire_body_size_range.x, Tuning.fire_body_size_range.y)


func _player_position() -> Vector2:
	if _player != null and _player.has_method(&"visual_position"):
		return _player.call(&"visual_position")
	return global_position


func _radius() -> float:
	if not is_instance_valid(body) or not body.has_method(&"radius"):
		return 0.0
	return float(body.call(&"radius"))


func _velocity() -> Vector2:
	if _player == null:
		return Vector2.ZERO
	var v: Variant = _player.get(&"velocity")
	return v if v is Vector2 else Vector2.ZERO


func _player_on_floor() -> bool:
	return _player != null and _player.has_method(&"is_on_floor") and bool(_player.call(&"is_on_floor"))


func _player_flowing() -> bool:
	return _player != null and _player.has_method(&"is_flowing") and bool(_player.call(&"is_flowing"))
