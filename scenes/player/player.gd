extends CharacterBody2D
## Slime controller: movement, moves (run, skid, crouch, wall, double jump, dodge and roll), mass, damage intake,
## goo absorption, swallowed props, spit shots and death.

const GooMath := preload("res://scripts/goo/goo_math.gd")
const Temperature := preload("res://scenes/player/temperature.gd")
const GooPiece := preload("res://scenes/goo/goo_piece.gd")

enum State { SPAWNING, NORMAL, HURT, DEAD, GOAL }
## A move that drives the velocity on its own; crouch and run are flags that combine with NONE.
enum Move { NONE, SKID, DODGE, ROLL, WALL }

const CEILING_CLEARANCE := 0.5
const MIN_RADIUS_GROWTH := 0.05
## Aim vectors shorter than this keep the last aim (stick in the centre).
const AIM_MIN := 0.05
## Shape queries shrink the probe by this much, so a shape that only touches a surface still fits.
const FIT_INSET := 2.0
## Wall normals need at least this horizontal share.
const WALL_NORMAL_MIN := 0.7
## A timer start value that is longer than any window it is compared against.
const LONG_AGO := 99.0

var state: State = State.SPAWNING
var mass := 0.0
## Colour of the slime goo: the base green, mixed with the colours of goo it slurps; a respawn gives the green again.
var goo_color := Tuning.goo_body_color
var facing := 1.0
var body_visual: Node2D
var field: Node2D
var intent := {"move": 0.0, "jump_pressed": false, "jump_held": false, "restart": false, "shoot_pressed": false, "fire_pressed": false, "aim_held": false, "aim_vector": Vector2.ZERO, "aim_from_mouse": false, "run_held": false, "dodge_pressed": false, "down": 0.0}
## Trajectory preview node (scripts/props/aim_preview.gd), wired by main.
var aim_preview: Node2D

var _prev_pos := Vector2.ZERO
var _curr_pos := Vector2.ZERO
var _coyote := 0.0
var _jump_buffer := 0.0
var _jump_rising := false
var _was_on_floor := false
var _was_on_wall := false
## Feet height when the slime last stood on the floor (or jumped, or was knocked back, or held a wall).
var _takeoff_y := 0.0
var _invulnerable := 0.0
var _state_timer := 0.0
var _collision_radius := 0.0
var _ladder := 0
var _ladder_timer := 0.0
## Unbounded crawl cycle counter: the fraction 0 to 0.5 is the reach phase, 0.5 to 1 the gather phase.
var _crawl_cycle := 0.0
var _heartbeat_timer := 0.0
var _shot_cooldown := 0.0
var _shot_buffer := 0.0
var _buffered_aimed := false
var _aim_open := false
var _aim_dir := Vector2.ZERO
var _aim_force := 0.0

# Moves
var _move: Move = Move.NONE
var _move_time := 0.0
var _running := false
var _crouched := false
var _crouch_grace := 0.0
var _floor_is_plank := false
var _drop_timer := 0.0
var _air_jumps := 0
## Air deceleration is off while this runs (after a double jump), so the boost carries.
var _carry_timer := 0.0
## After a wall jump or kick, until the next landing or grab: strong air control, and a neutral stick keeps momentum.
var _wall_flight := false
var _wall_side := 1.0
var _wall_hold := 0.0
var _wall_release_time := 0.0
var _wall_coyote := 0.0
var _wall_coyote_side := 1.0
var _wall_lock := 0.0
var _wall_lock_dir := 0.0
var _wall_streak := 0.0
var _wall_sound_timer := 0.0
var _wall_drip_timer := 0.0
var _skid_dir := 1.0
var _skid_new_dir := -1.0
var _skid_speed := 0.0
var _skid_phase := 0
var _skid_spray_timer := 0.0
var _evade_dir := 1.0
## Evade time runs this much faster for a light slime (same distance, shorter move).
var _evade_rate := 1.0
var _evade_clock := LONG_AGO
var _iframe_clock := LONG_AGO
var _roll_angle := 0.0
var _roll_trail := 0.0
## Run cost that is not yet a piece on the ground; it leaves the mass only when a step drops it.
var _run_debt := 0.0
## The run stopped at the minimum mass; it waits for a new press of the run button.
var _run_tired := false
var _was_running := false
var _run_pulse := 0.0
var _overflow_dir := Vector2.UP
var _press_time := 0.0
var _press_side := 1.0
var _overflow_timer := 0.0
# Goo magnet: per piece (instance id) the tick of its next path test while blocked, and the last refusal logged.
var _pull_blocked := {}
var _pull_refused := {}
## Per piece: whether its goo has the colour of the body (valid while the body colour is _same_color_of).
var _same_color := {}
var _same_color_of := Color(0.0, 0.0, 0.0, 0.0)
var _pull_ray := PhysicsRayQueryParameters2D.new()
## Pieces near the slime come from this area (the physics broadphase), so no loop runs over far goo.
var _goo_sense: Area2D
var _goo_sense_circle := CircleShape2D.new()
var _pull_clear := PackedFloat32Array()
var _pull_clear_at := Vector2.INF
var _pull_clear_len := 0.0
var _pull_clear_tick := -1000
var _full_sound_wait := 0.0
var _sip_wait := 0.0
var _sip_step := 0
## Entry schedule of pulled pieces: the clock, the earliest time of the next entry, and the length of this chain.
var _pull_clock := 0.0
var _entry_next := 0.0
var _entry_chain := 0

# Temperature (scenes/player/temperature.gd): melt, ice cube and fire
var temperature := Temperature.new()
## The puddle collider is on; it lags the liquid flag while the solid body would not fit (under a grate or a ceiling).
var _liquid_shape := false
var _burn_pulse := 0.0
## Melt trail cost that is not yet a piece on the ground, like _run_debt.
var _melt_debt := 0.0
var _melt_pulse := 0.0
var _melt_drip := 0.0
var _lock_wait := 0.0
var _refuse_wait := 0.0
var _immune_wait := 0.0
## Hazard that gave the last cube shrug; contact with the same hazard does not repeat it.
var _shrug_area_id := 0
var _aim_was_held := false
var _floor_surface: StringName = &""
var _cube_slide_sound := 0.0
var _harness_temperature_used := false
## Last status sent to GooField.set_body_status, so it is sent only on a change.
var _status_sent := Color(0.0, 0.0, 0.0, -1.0)
## Last temperature state sent to the body, cargo and effects; they are called again only on a change.
var _temp_visual_key := []
# Pipe flow: the pipe, the path from the drain, the distance along it and the phase time.
var _flow_pipe: Node2D
var _flow_path := PackedVector2Array()
var _flow_from := Vector2.ZERO
var _flow_dist := 0.0
var _flow_length := 0.0
var _flow_time := 0.0
var _flow_cooldown := 0.0
var _flow_drip := 0.0

var _circle := CircleShape2D.new()
var _capsule := CapsuleShape2D.new()
var _hurt_circle := CircleShape2D.new()
var _hurt_capsule := CapsuleShape2D.new()
var _absorb_circle := CircleShape2D.new()
var _absorb_capsule := CapsuleShape2D.new()
var _probe_circle := CircleShape2D.new()
var _probe_capsule := CapsuleShape2D.new()
var _shape_query := PhysicsShapeQueryParameters2D.new()
var _ray_query := PhysicsRayQueryParameters2D.new()
var _point_query := PhysicsPointQueryParameters2D.new()

@onready var _shape: CollisionShape2D = $CollisionShape2D
@onready var _hurtbox: Area2D = $Hurtbox
@onready var _hurtbox_shape: CollisionShape2D = $Hurtbox/CollisionShape2D
@onready var _absorber: Area2D = $Absorber
@onready var _absorber_shape: CollisionShape2D = $Absorber/CollisionShape2D
@onready var face: Node2D = $Face
@onready var cargo: Node2D = $Cargo
@onready var _temp_fx: Node2D = $TemperatureFx


func _ready() -> void:
	_shape.shape = _circle
	_hurtbox_shape.shape = _hurt_circle
	_absorber_shape.shape = _absorb_circle
	# A grate blocks the solid body, so a fit test of the solid shape counts it.
	_shape_query.collision_mask = Tuning.LAYER_WORLD | Tuning.LAYER_GRATES
	_ray_query.collision_mask = Tuning.LAYER_WORLD
	_point_query.collision_mask = Tuning.LAYER_WORLD
	_pull_ray.collision_mask = Tuning.LAYER_WORLD
	_pull_clear.resize(maxi(Tuning.goo_pull_rays, 0))
	_goo_sense = Area2D.new()
	_goo_sense.name = &"GooSense"
	_goo_sense.collision_layer = 0
	_goo_sense.collision_mask = Tuning.LAYER_PIECES
	_goo_sense.monitorable = false
	var sense_shape := CollisionShape2D.new()
	sense_shape.shape = _goo_sense_circle
	_goo_sense.add_child(sense_shape)
	add_child(_goo_sense)
	# Shed goo that leaves the sense area is out of reach: the slime may take it when it comes back.
	_goo_sense.body_exited.connect(func(body: Node2D) -> void:
		if body.get(&"shed") == true:
			body.set(&"left_range", true))
	Game.player = self


func spawn_at(at: Vector2, start_mass: float) -> void:
	velocity = Vector2.ZERO
	var before := mass
	mass = maxf(start_mass, 0.0)
	goo_color = GooMath.base_color()
	if state != State.SPAWNING:
		if mass > before:
			Game.report_gained(mass - before, &"respawn")
		elif mass < before:
			Game.report_lost(before - mass, &"respawn")
	_reset_moves()
	_reset_temperature()
	_collision_radius = 0.0
	_set_collision_radius(GooMath.visual_radius(mass) * Tuning.collision_radius_ratio, false)
	global_position = Vector2(at.x, at.y + Tuning.tile_size * 0.5 - _collision_radius)
	_prev_pos = global_position
	_curr_pos = global_position
	reset_physics_interpolation()
	if _has_body():
		body_visual.global_position = global_position
		body_visual.reset_physics_interpolation()
		body_visual.call("set_dead", false)
		body_visual.call("pop_in", GooMath.visual_radius(mass))
	_set_face(&"normal", 0.0)
	state = State.SPAWNING
	_state_timer = Tuning.spawn_freeze_time
	_invulnerable = Tuning.spawn_invulnerable_time
	_coyote = 0.0
	_jump_buffer = 0.0
	_jump_rising = false
	_ladder = 0
	_ladder_timer = 0.0
	_shot_cooldown = 0.0
	_shot_buffer = 0.0
	_pull_blocked.clear()
	_pull_refused.clear()
	cargo.call(&"reset_motion")
	_takeoff_y = _feet_y()
	_was_on_floor = false
	Sfx.play(&"respawn", global_position)
	Game.report_mass(mass)


func visual_position() -> Vector2:
	return _prev_pos.lerp(_curr_pos, Engine.get_physics_interpolation_fraction())


func state_name() -> String:
	return State.keys()[state]


func move_name() -> String:
	return Move.keys()[_move]


func is_crouched() -> bool:
	return _crouched


func is_running() -> bool:
	return _running


func air_jumps_left() -> int:
	return _air_jumps


func can_trigger() -> bool:
	return state == State.NORMAL or state == State.HURT


## Props the slime can carry at its current mass: from carry_capacity_min at carry_capacity_min_mass to carry_capacity_max at full mass.
func capacity() -> int:
	if mass < Tuning.carry_capacity_min_mass:
		return 0
	var t := clampf(inverse_lerp(Tuning.carry_capacity_min_mass, Tuning.mass_max, mass), 0.0, 1.0)
	return int(floorf(lerpf(float(Tuning.carry_capacity_min), float(Tuning.carry_capacity_max), pow(t, Tuning.carry_capacity_curve)) + 0.0001))


func load_count() -> int:
	return int(cargo.call(&"count"))


func _physics_process(delta: float) -> void:
	_prev_pos = global_position
	_read_intent()
	_tick_timers(delta)
	_update_aim()
	if state == State.DEAD or state == State.GOAL:
		_curr_pos = global_position
		_push_visual()
		return
	if _flowing():
		_step_flow(delta)
		_curr_pos = global_position
		_push_visual()
		return
	if bool(intent.restart) and state != State.SPAWNING:
		Game.request_respawn()
	_update_crouch(delta)
	if _move != Move.WALL:
		_apply_gravity(delta)
	if state != State.HURT:
		_apply_run(delta)
	_apply_move(delta)
	_apply_jump()
	_apply_evade()
	_apply_shoot()
	var pre_velocity := velocity
	move_and_slide()
	_after_move(pre_velocity, delta)
	_update_collision_radius()
	_check_hazards()
	_update_temperature(delta)
	_check_absorb()
	_check_props()
	if global_position.y > Game.kill_y:
		die(&"pit")
	_curr_pos = global_position
	_push_visual()


func _read_intent() -> void:
	var source: Dictionary
	if Harness.has_scripted_input():
		source = Harness.intent_at(Game.input_tick)
	else:
		source = {
			"move": Input.get_axis(&"move_left", &"move_right"),
			"jump_pressed": Input.is_action_just_pressed(&"jump"),
			"jump_held": Input.is_action_pressed(&"jump"),
			"restart": Input.is_action_just_pressed(&"restart"),
			"shoot_pressed": Input.is_action_just_pressed(&"shoot"),
			"fire_pressed": Game.trigger_just_pressed(&"fire"),
			"aim_held": Game.trigger_held(&"aim"),
			"aim_vector": _device_aim_vector(),
			"aim_from_mouse": _mouse_aims(),
			"run_held": Input.is_action_pressed(&"run"),
			"dodge_pressed": Input.is_action_just_pressed(&"dodge"),
			"down": Input.get_action_raw_strength(&"crouch"),
		}
	# Written in place: no new dictionary in each tick.
	intent.move = clampf(float(source.get("move", 0.0)), -1.0, 1.0)
	intent.jump_pressed = bool(source.get("jump_pressed", false))
	intent.jump_held = bool(source.get("jump_held", false))
	intent.restart = bool(source.get("restart", false))
	intent.shoot_pressed = bool(source.get("shoot_pressed", false))
	intent.fire_pressed = bool(source.get("fire_pressed", false))
	intent.aim_held = bool(source.get("aim_held", false))
	intent.aim_vector = source.get("aim_vector", Vector2.ZERO) as Vector2
	intent.aim_from_mouse = bool(source.get("aim_from_mouse", false))
	intent.run_held = bool(source.get("run_held", false))
	intent.dodge_pressed = bool(source.get("dodge_pressed", false))
	intent.down = clampf(float(source.get("down", 0.0)), 0.0, 1.0)
	if state != State.NORMAL:
		intent.move = 0.0
		intent.jump_pressed = false
		intent.shoot_pressed = false
		intent.fire_pressed = false
		intent.aim_held = false
		intent.run_held = false
		intent.dodge_pressed = false
		intent.down = 0.0
		intent.jump_held = state == State.HURT and bool(intent.jump_held)
	if temperature.cube:
		# Ice does not drip, so a cube cannot run.
		intent.run_held = false


func _tick_timers(delta: float) -> void:
	_coyote = maxf(_coyote - delta, 0.0)
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	_invulnerable = maxf(_invulnerable - delta, 0.0)
	_shot_cooldown = maxf(_shot_cooldown - delta, 0.0)
	_shot_buffer = maxf(_shot_buffer - delta, 0.0)
	_carry_timer = maxf(_carry_timer - delta, 0.0)
	_wall_coyote = maxf(_wall_coyote - delta, 0.0)
	_wall_lock = maxf(_wall_lock - delta, 0.0)
	_full_sound_wait = maxf(_full_sound_wait - delta, 0.0)
	_sip_wait = maxf(_sip_wait - delta, 0.0)
	_pull_clock += delta
	_evade_clock += delta
	_iframe_clock += delta
	if _overflow_timer > 0.0:
		_overflow_timer -= delta
		if _overflow_timer <= 0.0 and load_count() > capacity() and state != State.DEAD:
			_drop_one_overflow()
			_overflow_timer = Tuning.carry_drop_interval
	if _drop_timer > 0.0:
		_drop_timer -= delta
		if _drop_timer <= 0.0:
			collision_mask |= Tuning.LAYER_PLATFORMS
	if _move != Move.ROLL and _roll_angle != 0.0:
		# A roll cut short spins on to the nearest whole turn, so the face and the cargo never snap back.
		var rest := roundf(_roll_angle / TAU) * TAU
		_roll_angle = move_toward(_roll_angle, rest, Tuning.roll_unwind_speed * delta)
		if is_equal_approx(_roll_angle, rest):
			_roll_angle = 0.0
	_ladder_timer -= delta
	if _ladder_timer <= 0.0:
		_ladder = 0
	if _state_timer > 0.0:
		_state_timer -= delta
		if _state_timer <= 0.0:
			match state:
				State.SPAWNING, State.HURT:
					state = State.NORMAL
				State.DEAD:
					Game.request_respawn()
	var danger := _danger_level()
	if danger > 0.0 and (state == State.NORMAL or state == State.HURT):
		_heartbeat_timer -= delta
		if _heartbeat_timer <= 0.0:
			_heartbeat_timer = lerpf(Tuning.player_heartbeat_interval.x, Tuning.player_heartbeat_interval.y, danger)
			Sfx.play(&"heartbeat", null, 1.0, lerpf(Tuning.player_heartbeat_volume_db.x, Tuning.player_heartbeat_volume_db.y, danger), 0.0)
			if _has_body():
				body_visual.call("pulse")


func _apply_gravity(delta: float) -> void:
	var g: float = Tuning.gravity_up * _agile(Tuning.agility_rise) if velocity.y < 0.0 else Tuning.gravity_down
	if not is_on_floor() and absf(velocity.y) < Tuning.apex_threshold and bool(intent.jump_held):
		g = Tuning.gravity_apex
	velocity.y = minf(velocity.y + g * delta, Tuning.max_fall_speed)


func _apply_run(delta: float) -> void:
	if _move != Move.NONE:
		return
	var move: float = intent.move
	var on_floor := is_on_floor()
	_running = false
	if _wall_lock > 0.0 and signf(move) == _wall_lock_dir:
		# Input back toward the wall just left is ignored for a moment; the jump keeps its momentum.
		return
	if _crouched:
		_apply_crawl(move, delta)
		return
	if temperature.cube and _floor_surface == &"ice" and on_floor:
		_apply_ice_slide(move, delta)
		return
	var moving := absf(move) > 0.01
	if not bool(intent.run_held):
		_run_tired = false
	_running = moving and bool(intent.run_held) and not _run_tired
	var top: float = Tuning.sprint_speed if _running else Tuning.run_speed
	var target := move * top * _speed_factor()
	var reversing := moving and absf(velocity.x) > 10.0 and signf(move) != signf(velocity.x)
	var fast := absf(velocity.x) >= Tuning.skid_min_speed
	if on_floor and reversing and _running and fast and state == State.NORMAL:
		_start_skid(signf(move))
		return
	var accel: float
	if moving:
		accel = Tuning.accel_ground if on_floor else Tuning.accel_air
		if _wall_flight and not on_floor:
			accel = Tuning.wall_flight_accel
		if reversing:
			accel *= Tuning.turn_multiplier
		elif _running and absf(velocity.x) >= Tuning.run_speed:
			accel *= Tuning.sprint_accel_share
		if not on_floor and not reversing and absf(velocity.x) > maxf(absf(target), Tuning.run_speed):
			return
		if not (on_floor and reversing and fast):
			facing = signf(move)
	else:
		if not on_floor and (_carry_timer > 0.0 or _wall_flight):
			return
		accel = Tuning.decel_ground if on_floor else Tuning.decel_air
	velocity.x = move_toward(velocity.x, target, accel * _agile(Tuning.agility_accel) * _temp_accel() * delta)


func _apply_crawl(move: float, delta: float) -> void:
	var target := move * Tuning.crawl_speed * _speed_factor()
	var speeding_up := absf(move) > 0.01 and (signf(move) == signf(velocity.x) or absf(velocity.x) < 1.0) and absf(target) > absf(velocity.x)
	var accel: float = Tuning.crawl_accel if speeding_up else Tuning.decel_ground
	if absf(move) > 0.01:
		facing = signf(move)
	velocity.x = move_toward(velocity.x, target, accel * _agile(Tuning.agility_accel) * delta)


func _apply_move(delta: float) -> void:
	match _move:
		Move.SKID:
			_step_skid(delta)
		Move.DODGE, Move.ROLL:
			_step_evade(delta)
		Move.WALL:
			_step_wall(delta)


func _apply_jump() -> void:
	if bool(intent.jump_pressed):
		_jump_buffer = Tuning.jump_buffer
	if _jump_buffer > 0.0 and state == State.NORMAL and not _jump_locked():
		_try_jump()
	if _jump_rising and not bool(intent.jump_held) and velocity.y < 0.0:
		velocity.y *= Tuning.jump_cut
		_jump_rising = false
	if velocity.y >= 0.0:
		_jump_rising = false


## The slide of a skid and the motion of an evade keep the jump in its buffer until they end.
func _jump_locked() -> bool:
	match _move:
		Move.SKID:
			return _move_time < Tuning.skid_slide_time
		Move.DODGE:
			return _move_time < Tuning.dodge_motion_time
		Move.ROLL:
			return _move_time < Tuning.roll_time * Tuning.roll_jump_cancel
	return false


## Priority: drop through a plank, ground or coyote jump, wall jump, double jump.
func _try_jump() -> void:
	var on_floor := is_on_floor()
	if _crouched and on_floor and _floor_is_plank:
		_drop_through()
		return
	if (on_floor or _coyote > 0.0) and _move != Move.WALL:
		if _crouched:
			if not _can_stand():
				_jump_buffer = 0.0
				return
			_set_crouched(false)
		_end_move()
		_ground_jump()
		return
	if _move == Move.WALL:
		_wall_jump(_wall_side)
		return
	if _temp_rigid_or_runny():
		# Ice slips off walls and a puddle cannot push off them or the air.
		return
	if _wall_coyote > 0.0:
		_wall_jump(_wall_coyote_side)
		return
	if on_floor:
		return
	var side := _touching_wall_side()
	if side != 0.0:
		_wall_jump(side)
		return
	if _air_jumps > 0 and not _landing_soon():
		_end_move()
		_double_jump()


## A press just before touchdown stays in the jump buffer for a ground jump instead of spending the air jump.
func _landing_soon() -> bool:
	if velocity.y <= 0.0:
		return false
	return test_move(global_transform, Vector2(0.0, velocity.y * Tuning.jump_buffer + CEILING_CLEARANCE))


func _ground_jump() -> void:
	velocity.y = -Tuning.jump_velocity * _agile(Tuning.agility_jump) * _temp_jump()
	_jump_buffer = 0.0
	_coyote = 0.0
	_jump_rising = true
	_takeoff_y = _feet_y()
	_on_jump()


## Fixed height: a release does not cut it. A held direction keeps at least the boost speed that way.
func _double_jump() -> void:
	var rise := maxf(-velocity.y, 0.0)
	velocity.y = -maxf(Tuning.double_jump_velocity * _agile(Tuning.agility_jump), rise + Tuning.double_jump_min_add)
	var dir := signf(float(intent.move))
	if dir != 0.0:
		var kept := absf(velocity.x) if signf(velocity.x) == dir else 0.0
		velocity.x = dir * maxf(kept, Tuning.double_jump_boost)
		facing = dir
	else:
		velocity.x *= Tuning.double_jump_neutral_keep
	_air_jumps -= 1
	_carry_timer = Tuning.double_jump_carry_time
	_jump_buffer = 0.0
	_jump_rising = false
	_wall_flight = false
	_takeoff_y = _feet_y()
	var feet := global_position + Vector2(0.0, _collision_radius)
	Sfx.play(&"double_jump", global_position, _voice())
	_haptic(&"double_jump")
	if _has_body():
		body_visual.call("double_jump")
	if _has_field():
		field.call("spray", feet, Vector2.DOWN, Tuning.double_jump_puff_count, Tuning.double_jump_puff_speed, Tuning.double_jump_puff_spread, Tuning.double_jump_puff_radius, velocity * -0.15)
	if is_instance_valid(Juice.sparks):
		Juice.sparks.call("ring", feet, Tuning.double_jump_ring_radius * _size_scale(), Tuning.double_jump_ring_color, Tuning.double_jump_ring_time)
	Juice.punch(Tuning.double_jump_punch, &"double_jump")
	_set_face(&"happy", Tuning.double_jump_face_time)
	_report_move(&"double_jump", {"air_jumps": _air_jumps})


## Stick away from the wall: a wall jump that turns away. Toward it or neutral: a wall kick that climbs the same wall.
func _wall_jump(side: float) -> void:
	var away := -side
	var jumping_away := signf(float(intent.move)) == away
	var v: Vector2 = (Tuning.wall_jump_velocity if jumping_away else Tuning.wall_kick_velocity) * _agile(Tuning.agility_wall)
	velocity = Vector2(away * v.x, -v.y)
	facing = away if jumping_away else side
	_wall_lock = Tuning.wall_jump_lock if jumping_away else Tuning.wall_kick_lock
	_wall_lock_dir = side
	if _move == Move.WALL:
		_move = Move.NONE
	_wall_coyote = 0.0
	_jump_buffer = 0.0
	_coyote = 0.0
	_jump_rising = false
	_wall_flight = true
	_carry_timer = 0.0
	_takeoff_y = _feet_y()
	var contact := global_position + Vector2(side * _collision_radius, 0.0)
	Sfx.play(&"jump", global_position, 1.15 * _voice())
	_haptic(&"jump", 0.8)
	Sfx.play(&"wall_splat", contact, 1.4, Tuning.wall_grab_volume_db - 3.0)
	if _has_body():
		body_visual.call("jump")
		body_visual.call("wall_splat", Vector2(away, 0.0), 0.7)
	if _has_field():
		field.call("spray", contact, Vector2(away, 0.6).normalized(), Tuning.wall_grab_spray_count, Tuning.wall_grab_spray_speed, Tuning.wall_grab_spray_spread, Tuning.wall_grab_spray_radius)
	_set_face(&"spit" if jumping_away else &"happy", 0.25)
	_report_move(&"wall_jump" if jumping_away else &"wall_kick", {"side": side})


func _drop_through() -> void:
	_jump_buffer = 0.0
	collision_mask &= ~Tuning.LAYER_PLATFORMS
	_drop_timer = Tuning.drop_through_time
	velocity.y = Tuning.drop_through_speed
	_takeoff_y = _feet_y()
	Sfx.play(&"drip", global_position, 0.8)
	if _has_body():
		body_visual.call("bonk", Tuning.player_bonk_strength_min)
	_report_move(&"drop_through", {})


func _apply_evade() -> void:
	if not bool(intent.dodge_pressed) or state != State.NORMAL:
		return
	if temperature.cube:
		_ice_lock(&"dodge")
		return
	if _liquid_shape:
		_slosh()
		return
	if not is_on_floor() or _move == Move.SKID or _move == Move.WALL:
		return
	if _evade_clock < Tuning.evade_chain_after / _agile(Tuning.agility_evade):
		return
	if _crouched:
		if not _can_stand():
			return
		_set_crouched(false)
	_end_move()
	_start_evade(signf(float(intent.move)))


## No direction: a dodge backward. A direction: a roll that way. Each gets i-frames unless the last ones were too recent.
func _start_evade(dir: float) -> void:
	var rolling := dir != 0.0
	_move = Move.ROLL if rolling else Move.DODGE
	_move_time = 0.0
	_evade_dir = dir if rolling else -facing
	if rolling:
		facing = dir
	_evade_clock = 0.0
	_evade_rate = _agile(Tuning.agility_evade)
	_roll_trail = 0.0
	var granted := _iframe_clock >= Tuning.evade_iframe_rearm
	if granted:
		_iframe_clock = 0.0
		_invulnerable = maxf(_invulnerable, Tuning.roll_iframes if rolling else Tuning.dodge_iframes)
	var feet := global_position + Vector2(0.0, _collision_radius)
	if rolling:
		velocity.x = _evade_dir * Tuning.roll_distance * 1.5 * _evade_rate / Tuning.roll_time
		Sfx.play(&"roll", global_position, _voice(), Tuning.roll_volume_db)
		_haptic(&"roll")
		if _has_body():
			body_visual.call("dodge", _evade_dir, 0.5)
		if _has_field():
			field.call("spray", feet - Vector2(_evade_dir * _collision_radius * 0.5, 0.0), Vector2(-_evade_dir, -0.8).normalized(), Tuning.dodge_spray_count, Tuning.dodge_spray_speed, Tuning.dodge_spray_spread, Tuning.dodge_spray_radius)
	else:
		velocity.x = _evade_dir * Tuning.dodge_distance * 3.0 * _evade_rate / Tuning.dodge_motion_time
		Sfx.play(&"dodge", global_position, _voice(), Tuning.dodge_volume_db)
		_haptic(&"dodge")
		if _has_body():
			body_visual.call("dodge", _evade_dir, 1.0)
		if _has_field():
			field.call("spray", feet + Vector2(_evade_dir * _collision_radius * 0.6, -2.0), Vector2(_evade_dir, -0.35).normalized(), Tuning.dodge_spray_count, Tuning.dodge_spray_speed, Tuning.dodge_spray_spread, Tuning.dodge_spray_radius)
	_set_face(&"normal", 0.0)
	_report_move(&"roll" if rolling else &"dodge", {"dir": _evade_dir, "iframes": granted})


func _step_evade(delta: float) -> void:
	_move_time += delta * _evade_rate
	var rolling := _move == Move.ROLL
	if rolling:
		var s := clampf(_move_time / Tuning.roll_time, 0.0, 1.0)
		velocity.x = _evade_dir * Tuning.roll_distance * (1.5 - s) * _evade_rate / Tuning.roll_time
		_roll_angle = _evade_dir * TAU * s * (2.0 - s)
		if is_on_wall() and get_wall_normal().x * _evade_dir < -WALL_NORMAL_MIN:
			_end_roll(&"wall")
			return
		if is_on_floor():
			_roll_trail += absf(velocity.x) * delta
			if _roll_trail >= Tuning.roll_trail_step:
				_roll_trail = 0.0
				_drip_at_feet(0.0)
	elif _move_time < Tuning.dodge_motion_time:
		var s := _move_time / Tuning.dodge_motion_time
		velocity.x = _evade_dir * Tuning.dodge_distance * 3.0 * (1.0 - s) * (1.0 - s) * _evade_rate / Tuning.dodge_motion_time
	else:
		velocity.x = move_toward(velocity.x, 0.0, Tuning.decel_ground * delta)
	if _move_time >= (Tuning.roll_time if rolling else Tuning.dodge_time):
		if rolling:
			_end_roll(&"done")
		else:
			_end_move()
			_report_move(&"dodge_end", {})


func _end_roll(reason: StringName) -> void:
	_end_move()
	if _has_body():
		body_visual.call("land", Tuning.roll_exit_squash)
	if is_on_floor():
		Sfx.play(&"land_soft", global_position, 1.1 * _voice())
	_report_move(&"roll_end", {"reason": reason})


func _start_skid(new_dir: float) -> void:
	_move = Move.SKID
	_move_time = 0.0
	_skid_dir = signf(velocity.x)
	_skid_speed = absf(velocity.x)
	_skid_new_dir = new_dir
	_skid_phase = 0
	_skid_spray_timer = 0.0
	Sfx.play(&"skid", global_position, lerpf(0.9, 1.1, clampf(_skid_speed / Tuning.sprint_speed, 0.0, 1.0)) * _voice(), Tuning.skid_volume_db)
	_haptic(&"skid", clampf(_skid_speed / Tuning.sprint_speed, 0.0, 1.0))
	_report_move(&"skid", {"speed": _skid_speed, "dir": _skid_dir})


## Slide with an eased stop, a short hold where the slime flips, then a launch the other way.
func _step_skid(delta: float) -> void:
	_move_time += delta
	if not is_on_floor():
		_end_move()
		_report_move(&"skid_end", {"reason": &"air"})
		return
	var slide := Tuning.skid_slide_time
	var hold := Tuning.skid_hold_time
	var t := _move_time
	if t < slide:
		velocity.x = _skid_dir * _skid_speed * pow(1.0 - t / slide, Tuning.skid_slide_curve)
		_skid_spray_timer -= delta
		if _skid_spray_timer <= 0.0:
			_skid_spray_timer = Tuning.skid_spray_interval
			_skid_spray(1.0 - t / slide)
	elif t < slide + hold:
		if _skid_phase == 0:
			_skid_stop()
		velocity.x = 0.0
		if t >= slide + hold * 0.5:
			facing = _skid_new_dir
	elif t < slide + hold + Tuning.skid_launch_time:
		if _skid_phase < 2:
			_skid_phase = 2
			facing = _skid_new_dir
		var s := (t - slide - hold) / Tuning.skid_launch_time
		velocity.x = _skid_new_dir * Tuning.run_speed * _speed_factor() * s * (2.0 - s)
	else:
		_end_move()
		_report_move(&"skid_end", {"reason": &"done"})


func _skid_spray(share: float) -> void:
	_drip_at_feet(_skid_dir * 0.2)
	if not _has_field():
		return
	var front := global_position + Vector2(_skid_dir * _collision_radius * 0.75, _collision_radius - 2.0)
	var speed := Tuning.skid_spray_speed * lerpf(0.4, 1.0, share)
	field.call("spray", front, Vector2(_skid_dir, -0.45).normalized(), Tuning.skid_spray_count, speed, Tuning.skid_spray_spread, Tuning.skid_spray_radius)


func _skid_stop() -> void:
	_skid_phase = 1
	if _has_body():
		body_visual.call("bonk", Tuning.skid_stop_squash)
	if _has_field():
		var front := global_position + Vector2(_skid_dir * _collision_radius * 0.8, _collision_radius - 2.0)
		field.call("spray", front, Vector2(_skid_dir * 0.6, -1.0).normalized(), Tuning.skid_stop_spray_count, Tuning.skid_stop_spray_speed, 50.0, Tuning.skid_spray_radius)
	Sfx.play(&"land_soft", global_position, 0.85)
	Juice.shake(Tuning.skid_stop_shake, &"skid_stop")
	_report_move(&"skid_stop", {})


func _step_wall(delta: float) -> void:
	var side := _wall_side
	velocity.x = side * Tuning.wall_contact_push
	if velocity.y < 0.0:
		velocity.y = move_toward(velocity.y, 0.0, Tuning.wall_upward_damp * delta)
	elif _wall_hold > 0.0 and float(intent.down) < Tuning.wall_fast_down:
		velocity.y = 0.0
		_wall_hold -= delta
		if _wall_hold <= 0.0:
			_report_move(&"wall_slide", {})
	else:
		var fast := float(intent.down) >= Tuning.wall_fast_down
		var cap: float = Tuning.wall_slide_fast_speed if fast else Tuning.wall_slide_speed
		var g: float = Tuning.gravity_down * (1.0 if fast else Tuning.wall_slide_gravity_scale)
		if velocity.y > cap:
			velocity.y = move_toward(velocity.y, cap, Tuning.wall_upward_damp * delta)
		else:
			velocity.y = minf(velocity.y + g * delta, cap)
	if signf(float(intent.move)) == -side:
		_wall_release_time += delta
		if _wall_release_time >= Tuning.wall_release_delay / _agile(Tuning.agility_wall):
			_leave_wall(&"release")
			velocity.x = -side * Tuning.wall_release_push
	else:
		_wall_release_time = 0.0


## In the air, pushing into a wall that reaches above the head and down to mid body grabs it, unless the rise clears it.
func _try_wall_grab() -> void:
	if is_on_floor() or _crouched or _move != Move.NONE or state != State.NORMAL or _temp_rigid_or_runny():
		return
	var side := signf(float(intent.move))
	if side == 0.0 or (_wall_lock > 0.0 and side == _wall_lock_dir):
		return
	if not is_on_wall() or get_wall_normal().x * side > -WALL_NORMAL_MIN:
		return
	var wall_x: Variant = _wall_contact(side)
	if wall_x == null:
		return
	if velocity.y < 0.0 and _would_clear_wall(side, float(wall_x)):
		return
	_grab_wall(side, float(wall_x))


func _grab_wall(side: float, wall_x: float) -> void:
	_move = Move.WALL
	_move_time = 0.0
	_wall_side = side
	facing = side
	_air_jumps = Tuning.air_jumps
	_wall_flight = false
	_carry_timer = 0.0
	_jump_rising = false
	_wall_hold = Tuning.wall_cling_time
	_wall_release_time = 0.0
	_wall_streak = 0.0
	_wall_sound_timer = Tuning.wall_slide_sound_interval
	_wall_drip_timer = Tuning.wall_drip_interval
	velocity.x = 0.0
	var contact := Vector2(wall_x, global_position.y)
	Sfx.play(&"wall_splat", contact, 1.25, Tuning.wall_grab_volume_db)
	_haptic(&"wall_cling")
	if _has_body():
		body_visual.call("wall_splat", Vector2(-side, 0.0), 0.8)
	if _has_field():
		field.call("spray", contact, Vector2(-side, -0.4).normalized(), Tuning.wall_grab_spray_count, Tuning.wall_grab_spray_speed, Tuning.wall_grab_spray_spread, Tuning.wall_grab_spray_radius)
	_report_move(&"wall_grab", {"side": side})


func _leave_wall(reason: StringName) -> void:
	var side := _wall_side
	_end_move()
	if reason != &"floor":
		_wall_coyote = Tuning.wall_coyote_time
		_wall_coyote_side = side
	_report_move(&"wall_leave", {"reason": reason, "side": side})


## Wet streak, slide sound and falling drips while the slime holds or slides on the wall.
func _wall_fx(delta: float) -> void:
	var side := _wall_side
	var contact := global_position + Vector2(side * (_collision_radius + 1.0), 0.0)
	_wall_streak += maxf(velocity.y, 0.0) * delta
	if _wall_streak >= Tuning.wall_streak_step and _has_field():
		_wall_streak = 0.0
		var at := contact + Vector2(0.0, Game.rng.randf_range(-0.3, 0.3) * _collision_radius)
		field.call("drip", at, Game.rng.randf_range(Tuning.wall_streak_radius.x, Tuning.wall_streak_radius.y), Tuning.wall_streak_life, Vector2(-side, 0.0))
	_wall_sound_timer -= delta
	if _wall_sound_timer <= 0.0 and velocity.y > 20.0:
		_wall_sound_timer = Tuning.wall_slide_sound_interval
		var share := clampf(velocity.y / Tuning.wall_slide_fast_speed, 0.0, 1.0)
		Sfx.play(&"wall_slide", contact, lerpf(0.85, 1.25, share), lerpf(Tuning.wall_slide_volume_db.x, Tuning.wall_slide_volume_db.y, share))
	_wall_drip_timer -= delta
	if _wall_drip_timer <= 0.0 and _has_field():
		_wall_drip_timer = Tuning.wall_drip_interval
		field.call("spray", contact + Vector2(-side * 4.0, _collision_radius * 0.6), Vector2.DOWN, 1, Vector2(20.0, 60.0), 20.0, Tuning.wall_streak_radius)


## The wall on that side, if it spans the head and the middle of the body: its x, else null.
func _wall_contact(side: float) -> Variant:
	var space := get_world_2d().direct_space_state
	var reach := _collision_radius + Tuning.wall_probe
	var wall_x: Variant = null
	for height: float in [-Tuning.wall_probe_head, 0.0]:
		var from := global_position + Vector2(0.0, height * _collision_radius)
		_ray_query.from = from
		_ray_query.to = from + Vector2(side * reach, 0.0)
		var hit := space.intersect_ray(_ray_query)
		if hit.is_empty() or absf((hit.normal as Vector2).x) < WALL_NORMAL_MIN:
			return null
		wall_x = (hit.position as Vector2).x
	return wall_x


## True when the current rise lifts the feet above the top of the wall, so the slime hops onto it instead of sticking.
func _would_clear_wall(side: float, wall_x: float) -> bool:
	var rise := velocity.y * velocity.y / (2.0 * Tuning.gravity_up)
	_point_query.position = Vector2(wall_x + side * 4.0, _feet_y() - rise - 2.0)
	return get_world_2d().direct_space_state.intersect_point(_point_query, 1).is_empty()


func _touching_wall_side() -> float:
	for side: float in [facing, -facing]:
		if _wall_contact(side) != null:
			return side
	return 0.0


func _update_crouch(delta: float) -> void:
	var want := state == State.NORMAL and _crouch_wanted() and _can_squish()
	if want:
		_crouch_grace = Tuning.crouch_release_grace
	else:
		_crouch_grace = maxf(_crouch_grace - delta, 0.0)
	var on_floor := is_on_floor()
	if not _crouched:
		if on_floor and _move == Move.NONE and state == State.NORMAL and (want or _auto_crouch()):
			_crouch_grace = Tuning.crouch_release_grace
			_set_crouched(true)
	elif (not on_floor or (not want and _crouch_grace <= 0.0)) and _can_stand():
		if on_floor and state == State.NORMAL and _auto_crouch():
			_crouch_grace = Tuning.crouch_release_grace
		else:
			_set_crouched(false)


## Stick within the crouch cone of straight down; once crouched, any push down past crouch_keep holds it.
func _crouch_wanted() -> bool:
	var down: float = intent.down
	if _crouched:
		return down >= Tuning.crouch_keep
	var v := Vector2(float(intent.move), down)
	return down > 0.0 and v.length() >= Tuning.crouch_enter and absf(rad_to_deg(v.angle_to(Vector2.DOWN))) <= Tuning.crouch_cone_deg


## Moving into a gap where the standing body does not fit but the crouched one does.
func _auto_crouch() -> bool:
	if not _can_squish():
		return false
	var dir := signf(float(intent.move))
	if dir == 0.0 and absf(velocity.x) > Tuning.crouch_auto_min_speed:
		dir = signf(velocity.x)
	if dir == 0.0:
		return false
	var ahead := Vector2(dir * (Tuning.crouch_auto_probe + absf(velocity.x) / float(Engine.physics_ticks_per_second)), 0.0)
	return not _standing_fits(global_position + ahead) and _crouched_fits(global_position + ahead)


func _can_stand() -> bool:
	return _standing_fits(global_position)


func _standing_fits(at: Vector2) -> bool:
	_probe_circle.radius = maxf(_collision_radius - FIT_INSET, 1.0)
	return _fits(_probe_circle, Transform2D(0.0, at))


func _crouched_fits(at: Vector2) -> bool:
	var size := _crouch_size()
	_probe_capsule.radius = maxf(size.y * 0.5 - FIT_INSET, 1.0)
	_probe_capsule.height = maxf(size.x - FIT_INSET * 2.0, _probe_capsule.radius * 2.0)
	return _fits(_probe_capsule, Transform2D(PI * 0.5, at + Vector2(0.0, _collision_radius - size.y * 0.5)))


func _fits(shape: Shape2D, at: Transform2D) -> bool:
	_shape_query.shape = shape
	_shape_query.transform = at
	return get_world_2d().direct_space_state.intersect_shape(_shape_query, 1).is_empty()


## Width and height of the crouched collider.
func _crouch_size() -> Vector2:
	var h := 2.0 * _collision_radius * Tuning.crouch_height_ratio
	return Vector2(maxf(2.0 * _collision_radius * Tuning.crouch_width_ratio, h), h)


func _set_crouched(on: bool, quiet := false) -> void:
	if on == _crouched:
		return
	_crouched = on
	_apply_shapes()
	if quiet:
		return
	if on:
		Sfx.play(&"land_soft", global_position, 0.7 * _voice(), -6.0)
		_haptic(&"crouch")
		_report_move(&"crouch", {})
	else:
		Sfx.play(&"step", global_position, 0.75 * _voice(), Tuning.player_step_volume_db + 4.0)
		_report_move(&"stand", {})


## The right mouse button holds the aim; a scripted run hears no real mouse.
func _mouse_aims() -> bool:
	return not Harness.blocks_real_input and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)


## Device right stick, or the mouse while its right button holds the aim. Length is the deflection, 0 to 1.
func _device_aim_vector() -> Vector2:
	if _mouse_aims():
		return ((get_global_mouse_position() - visual_position()) / maxf(Tuning.aim_mouse_range, 1.0)).limit_length(1.0)
	return Input.get_vector(&"aim_left", &"aim_right", &"aim_up", &"aim_down", Tuning.aim_stick_deadzone)


## Direction the eyes follow while the aim is open, else zero.
func aim_look() -> Vector2:
	return _aim_dir if _aim_open else Vector2.ZERO


func is_aiming() -> bool:
	return _aim_open


## Expression the current move or pose asks for, or an empty name.
func pose_expression() -> StringName:
	match _move:
		Move.WALL:
			return &"grit"
		Move.SKID:
			return &"alarm" if _skid_phase < 2 else &"grit"
		Move.ROLL:
			return &"dizzy"
		Move.DODGE:
			return &"strain"
	if _press_time > 0.0:
		return &"strain"
	if _crouched:
		return &"squish"
	if _run_amount() > 0.5:
		return &"grit"
	return &""


## Direction the eyes follow during a move, else zero.
func move_look() -> Vector2:
	match _move:
		Move.WALL:
			return Vector2(-_wall_side * 0.7, -0.3)
		Move.SKID:
			return Vector2(_skid_dir, 0.15)
		Move.DODGE:
			return Vector2(-_evade_dir, 0.0)
	if _press_time > 0.0:
		return Vector2(_press_side, 0.1)
	if _crouched:
		return Vector2(facing * 0.85, 0.25)
	return Vector2.ZERO


func _update_aim() -> void:
	var pressed := bool(intent.aim_held) and not _aim_was_held
	_aim_was_held = bool(intent.aim_held)
	if pressed and temperature.cube:
		_ice_lock(&"aim")
	var held := bool(intent.aim_held) and not temperature.cube and not _flowing()
	if held != _aim_open:
		_aim_open = held
		Juice.aim_slowmo(held)
		if held:
			_haptic(&"aim_open")
		if held and _aim_dir == Vector2.ZERO:
			_aim_dir = Vector2(facing, 0.0).rotated(-facing * deg_to_rad(Tuning.aim_default_angle_deg))
			_aim_force = Tuning.aim_default_force
		if not held:
			_close_aim_visuals()
	if not _aim_open:
		return
	var aim: Vector2 = intent.aim_vector
	if aim.length() >= AIM_MIN:
		var from_mouse := bool(intent.aim_from_mouse)
		_aim_dir = aim.normalized()
		if Tuning.aim_invert_slingshot and not from_mouse:
			_aim_dir = -_aim_dir
		_aim_force = clampf(aim.length(), 0.0, 1.0) if from_mouse else pow(clampf(aim.length(), 0.0, 1.0), Tuning.aim_force_curve)
	if absf(_aim_dir.x) > 0.01 and _move != Move.WALL and _move != Move.ROLL:
		facing = signf(_aim_dir.x)
	if _has_body():
		body_visual.call("set_aim", _aim_dir, _aim_force)
	cargo.call(&"set_aim", _aim_dir, true)
	if is_instance_valid(aim_preview):
		var kind := _next_kind(_aim_dir)
		aim_preview.call(&"show_aim", kind, global_position, _aim_dir, _spawn_distance(), _shot_velocity(_aim_dir, _aim_force), load_count() > 0)


func _close_aim_visuals() -> void:
	if _has_body():
		body_visual.call("set_aim", _aim_dir, 0.0)
	cargo.call(&"set_aim", _aim_dir, false)
	if is_instance_valid(aim_preview):
		aim_preview.call(&"hide_aim")


## A rolling ball keeps its mouth shut: a shot pressed during the roll waits in the buffer.
func _apply_shoot() -> void:
	if bool(intent.fire_pressed):
		_shot_buffer = Tuning.shot_buffer
		_buffered_aimed = _aim_open
	if bool(intent.shoot_pressed):
		_shot_buffer = Tuning.shot_buffer
		_buffered_aimed = false
	if temperature.cube and _shot_buffer > 0.0:
		_shot_buffer = 0.0
		_ice_lock(&"shoot")
		return
	if _shot_buffer <= 0.0 or _shot_cooldown > 0.0 or state != State.NORMAL or _move == Move.ROLL:
		return
	_shot_buffer = 0.0
	if _buffered_aimed and _aim_open:
		_fire(_aim_dir, _aim_force)
	else:
		_fire(_quick_dir(), 1.0)


## Quick shot: full force where the slime faces, a little above the horizon.
func _quick_dir() -> Vector2:
	return Vector2(facing, 0.0).rotated(-facing * deg_to_rad(Tuning.quick_shot_angle_deg))


func _shot_velocity(dir: Vector2, force: float) -> Vector2:
	return dir * lerpf(Tuning.shot_speed.x, Tuning.shot_speed.y, force) + velocity * Tuning.shot_inherit


func _spawn_distance() -> float:
	return _collision_radius * Tuning.shot_spawn_offset


func _next_kind(dir: Vector2) -> StringName:
	return cargo.call(&"peek_toward", dir) if load_count() > 0 else &"rock"


func _fire(dir: Vector2, force: float) -> void:
	if load_count() == 0 or not is_instance_valid(Game.props):
		_dry_spit(dir)
		return
	var shot_velocity := _shot_velocity(dir, force)
	var kind := _next_kind(dir)
	var predicted: Variant = null
	if is_instance_valid(aim_preview):
		predicted = (aim_preview.call(&"predict", kind, global_position, dir, _spawn_distance(), shot_velocity) as Dictionary).get("impact")
	var data: Dictionary = cargo.call(&"take_toward", dir)
	var identity := {"kind": data.get("kind", &"rock"), "seed": data.get("seed", 0), "home": data.get("home", global_position), "ember": temperature.burning()}
	Game.props.call(&"launch", identity, global_position, dir, _spawn_distance(), shot_velocity)
	if temperature.burning():
		_ember_spit(global_position + dir * _collision_radius, dir)
	_shot_cooldown = Tuning.shot_cooldown
	var feedback := lerpf(Tuning.shot_force_feedback_min, 1.0, force)
	if is_on_floor():
		velocity.x -= dir.x * Tuning.shot_recoil_ground * feedback
	else:
		velocity -= dir * Tuning.shot_recoil_air * feedback
		velocity.y = maxf(velocity.y, -Tuning.shot_recoil_up_max)
	var mouth := global_position + dir * _collision_radius
	if _has_body():
		body_visual.call("release_aim", force if _aim_open else 0.0)
		body_visual.call("spit", dir, Tuning.shot_squash * feedback)
	if _has_field():
		field.call("spray", mouth, dir, int(Tuning.shot_spray_count * feedback) + 2, Tuning.shot_spray_speed * feedback, Tuning.shot_spray_spread, Tuning.shot_spray_radius, velocity * Tuning.shot_spray_inherit)
	_set_face(&"spit", Tuning.shot_face_time)
	Sfx.play(&"spit", mouth, lerpf(Tuning.shot_pitch.x, Tuning.shot_pitch.y, force), Tuning.shot_volume_db)
	Juice.shake(Tuning.shot_shake * feedback, &"shot")
	Juice.punch(Tuning.shot_punch * feedback, &"shot")
	Game.report_prop_shot(identity.kind, mouth, dir, load_count(), force, predicted)


## A spit with nothing inside: a wet cough, so the button never feels dead.
func _dry_spit(dir: Vector2) -> void:
	_shot_cooldown = Tuning.shot_dry_cooldown
	var mouth := global_position + dir * _collision_radius
	if _has_body():
		body_visual.call("spit", dir, Tuning.shot_squash * 0.35)
	if _has_field():
		field.call("spray", mouth, dir, Tuning.shot_dry_spray_count, Tuning.shot_spray_speed * 0.5, Tuning.shot_spray_spread * 1.5, Tuning.shot_spray_radius * 0.6)
	_set_face(&"spit", Tuning.shot_face_time * 0.6)
	Sfx.play(&"spit_dry", mouth, 1.0, Tuning.shot_dry_volume_db)


func _after_move(pre_velocity: Vector2, delta: float) -> void:
	var on_floor := is_on_floor()
	if on_floor:
		_coyote = Tuning.coyote_time
		_air_jumps = Tuning.air_jumps
		_wall_flight = false
		_carry_timer = 0.0
		if not _was_on_floor:
			_on_land(pre_velocity)
		_takeoff_y = _feet_y()
	_floor_is_plank = false
	if not on_floor:
		_floor_surface = &""
	var splatted := false
	for i: int in get_slide_collision_count():
		var collision := get_slide_collision(i)
		var n := collision.get_normal()
		if absf(n.x) > 0.7 and absf(pre_velocity.x) > Tuning.wall_splat_speed and not splatted and not _was_on_wall:
			splatted = true
			_on_wall_splat(n, absf(pre_velocity.x))
		elif n.y > 0.7 and pre_velocity.y < -Tuning.ceiling_touch_speed:
			_on_bonk(-pre_velocity.y)
		elif n.y < -0.7:
			var floor_body := collision.get_collider() as CollisionObject2D
			if floor_body != null and floor_body.collision_layer & Tuning.LAYER_PLATFORMS:
				_floor_is_plank = true
			if floor_body != null:
				_floor_surface = floor_body.get_meta(&"surface", &"")
		if temperature.cube:
			_try_cube_smash(collision, pre_velocity)
	_was_on_floor = on_floor
	_was_on_wall = is_on_wall()
	if _move == Move.WALL:
		if on_floor:
			_leave_wall(&"floor")
		elif _wall_contact(_wall_side) == null:
			_leave_wall(&"edge")
		else:
			_takeoff_y = _feet_y()
			_wall_fx(delta)
	else:
		_try_wall_grab()
	_pay_run_cost(delta)
	_update_press(delta)
	if on_floor and absf(velocity.x) > Tuning.crawl_min_speed and state == State.NORMAL and _move == Move.NONE:
		var before := _crawl_cycle
		_crawl_cycle += absf(velocity.x) * delta / _crawl_stride()
		if floorf(_crawl_cycle - 0.5) > floorf(before - 0.5):
			_on_step()


func _on_jump() -> void:
	Sfx.play(&"jump", global_position, _voice())
	_haptic(&"jump")
	if _has_body():
		body_visual.call("jump")
	if _has_field():
		field.call("spray", global_position + Vector2(0.0, _collision_radius), Vector2.DOWN, Tuning.player_jump_spray_count, Tuning.player_jump_spray_speed, Tuning.player_jump_spray_spread, Tuning.player_jump_spray_radius)


func _on_land(pre_velocity: Vector2) -> void:
	if temperature.cube:
		_on_cube_land(pre_velocity)
		return
	var impact := pre_velocity.y
	var drop := _feet_y() - _takeoff_y
	var heavy := drop > Tuning.heavy_land_height or impact > Tuning.heavy_land_speed
	if _has_body():
		body_visual.call("land", impact)
	if impact > Tuning.player_land_soft_speed:
		_haptic(&"land", clampf(impact / Tuning.max_fall_speed, 0.0, 1.0))
	if heavy:
		Sfx.play(&"land_heavy", global_position, _voice(), lerpf(Tuning.player_land_heavy_volume_db.x, Tuning.player_land_heavy_volume_db.y, clampf(impact / Tuning.max_fall_speed, 0.0, 1.0)))
		Juice.shake(clampf(impact / Tuning.max_fall_speed, Tuning.player_land_heavy_shake.x, Tuning.player_land_heavy_shake.y), &"land")
		if _has_field():
			field.call("spray", global_position + Vector2(0.0, _collision_radius), Vector2.UP, Tuning.player_land_heavy_spray_count, Tuning.player_land_heavy_spray_speed, Tuning.player_land_heavy_spray_spread, Tuning.player_land_heavy_spray_radius, velocity * Tuning.player_land_heavy_spray_inherit)
	elif impact > Tuning.player_land_soft_speed:
		Sfx.play(&"land_soft", global_position, _voice(), lerpf(Tuning.player_land_soft_volume_db.x, Tuning.player_land_soft_volume_db.y, clampf(impact / Tuning.player_land_soft_speed_ref, 0.0, 1.0)))
	if drop > Tuning.fall_safe_height and state != State.DEAD:
		var tiles := (drop - Tuning.fall_safe_height) / Tuning.tile_size
		var loss := minf(Tuning.fall_loss_max, tiles * Tuning.fall_loss_per_tile)
		take_damage(loss, Vector2.UP, &"fall", Vector2.ZERO, true)


func _on_step() -> void:
	if temperature.cube:
		_on_cube_step()
		return
	if _liquid_shape:
		Sfx.play(&"drip", global_position, 0.7 * _voice(), Tuning.melt_step_volume_db)
	var run := _run_amount()
	Sfx.play(&"step", global_position, (1.0 + 0.15 * run) * _voice(), lerpf(Tuning.player_step_volume_db, Tuning.sprint_step_volume_db, run))
	if _has_body():
		body_visual.call("step")
	if not _has_field():
		return
	_drip_at_feet(-signf(velocity.x) * 0.5)
	if run <= 0.0:
		return
	for k: int in Tuning.sprint_step_drips - 1:
		_drip_at_feet(-signf(velocity.x) * Game.rng.randf_range(0.2, 0.8))
	var back := global_position + Vector2(-signf(velocity.x) * _collision_radius * 0.6, _collision_radius - 2.0)
	field.call("spray", back, Vector2(-signf(velocity.x), -1.0).normalized(), Tuning.sprint_step_spray_count, Tuning.sprint_step_spray_speed, Tuning.sprint_step_spray_spread, Tuning.sprint_step_spray_radius)


## Pushing into a wall on the floor squashes the body against it, more the longer the push lasts.
func _update_press(delta: float) -> void:
	var side := signf(float(intent.move))
	var pressing := is_on_floor() and _move == Move.NONE and side != 0.0 and is_on_wall() and get_wall_normal().x * side < -WALL_NORMAL_MIN
	if not pressing:
		if _press_time > 0.0:
			_report_move(&"press_end", {"time": _press_time})
		_press_time = 0.0
		return
	if _press_time == 0.0:
		_report_move(&"press", {"side": side})
	_press_side = side
	_press_time += delta


func _press_amount() -> float:
	return clampf(_press_time / maxf(Tuning.press_build_time, 0.01), 0.0, 1.0)


## Running costs goo: the cost collects every tick and leaves in pulses, one drop per beat (see _drop_run_piece).
func _pay_run_cost(delta: float) -> void:
	if _running and not _was_running and is_on_floor():
		_haptic(&"run_start")
		_report_move(&"run", {})
	_was_running = _running
	if _run_amount() <= 0.0:
		_run_pulse = Tuning.run_pulse_interval
		return
	_run_debt += Tuning.run_cost_per_second * delta
	if mass - _run_debt - _melt_debt <= Tuning.run_min_mass:
		_run_debt = maxf(mass - _melt_debt - Tuning.run_min_mass, 0.0)
		_drop_run_piece()
		_tire()
		return
	_run_pulse -= delta
	if _run_pulse <= 0.0:
		_run_pulse += Tuning.run_pulse_interval
		_drop_run_piece()


## True when the run cannot start: the slime is at its minimum mass or tired until the button is pressed again.
func run_blocked() -> bool:
	return _run_tired or mass <= Tuning.run_min_mass


func _tire() -> void:
	_run_tired = true
	_running = false
	_set_face(&"tired", Tuning.run_tired_face_time)
	Sfx.play(&"spit_dry", global_position, 0.6, Tuning.shot_dry_volume_db)
	_haptic(&"run_tired")
	if _has_body():
		body_visual.call("bonk", Tuning.player_bonk_strength_min * 2.0)
	_report_move(&"run_tired", {})


## The run cost leaves the body as a real goo piece behind the slime, so the balance always holds.
func _drop_run_piece() -> void:
	if _run_debt <= 0.0 or not _has_field():
		return
	var back := -signf(velocity.x)
	var at := global_position + Vector2(back * _collision_radius * 0.9, _collision_radius * 0.55)
	var piece_mass := _run_debt
	_run_debt = 0.0
	mass -= piece_mass
	var piece: Node2D = field.call("spawn_piece", at, piece_mass, Vector2(back * Tuning.run_piece_speed.x, -Tuning.run_piece_speed.y), false)
	if piece != null:
		piece.set(&"shed", true)
	if _has_body():
		body_visual.call("drain_pulse", Vector2(back, 0.5).normalized(), clampf(piece_mass / Tuning.run_pulse_mass_ref, 0.2, 1.0))
	_haptic(&"drain", clampf(piece_mass / Tuning.run_pulse_mass_ref, 0.2, 1.0))
	Game.report_mass(mass)
	_report_move(&"run_cost", {"piece": piece_mass})


## A trail drop under the body; offset is in collision radii along x.
func _drip_at_feet(offset: float) -> void:
	if not _has_field():
		return
	var feet := global_position + Vector2(offset * _collision_radius + Game.rng.randf_range(-Tuning.player_step_drip_jitter, Tuning.player_step_drip_jitter), _collision_radius + 1.0)
	field.call("drip", feet, Game.rng.randf_range(Tuning.trail_radius.x, Tuning.trail_radius.y), Tuning.trail_life)


## A fast hit on a wall: a flat splat with goo that sticks to the wall, a sound and a camera kick.
func _on_wall_splat(normal: Vector2, speed: float) -> void:
	if not is_on_floor() and signf(float(intent.move)) * normal.x < 0.0 and _wall_contact(-signf(normal.x)) != null:
		return
	var strength := clampf(speed / Tuning.run_speed, Tuning.player_wall_splat_strength_min, 1.0)
	var contact := global_position - normal * _collision_radius
	Sfx.play(&"wall_splat", contact, 1.0, lerpf(Tuning.player_wall_splat_volume_db.x, Tuning.player_wall_splat_volume_db.y, strength))
	if _has_body():
		body_visual.call("wall_splat", normal, strength)
	if _has_field():
		field.call("spray", contact, normal, Tuning.player_wall_splat_spray_count, Tuning.player_wall_splat_spray_speed, Tuning.player_wall_splat_spray_spread, Tuning.player_wall_splat_spray_radius)
		for k: int in int(roundf(Tuning.wall_splat_drip_count * strength)):
			var at := contact + Vector2(0.0, Game.rng.randf_range(-0.6, 0.6) * _collision_radius)
			field.call("drip", at, Game.rng.randf_range(Tuning.wall_streak_radius.x, Tuning.wall_streak_radius.y), Tuning.wall_streak_life, normal)
	Juice.punch(Tuning.wall_splat_punch * strength, &"wall_splat")
	Juice.shake(Tuning.wall_splat_shake * strength, &"wall_splat")
	_haptic(&"wall_splat", strength)
	if _move == Move.NONE and is_on_floor():
		_set_face(&"hurt" if strength > 0.8 else &"surprise", 0.25)
	_report_move(&"wall_splat", {"strength": strength})


## The head hits a ceiling: the top flattens as deep as the hit was fast. A real hit adds sound, stuck drips,
## a camera kick and a face reaction; a light touch only flattens.
func _on_bonk(speed: float) -> void:
	var strength := clampf(speed / Tuning.ceiling_hit_speed_ref, 0.0, 1.0)
	if _has_body():
		body_visual.call("ceiling_hit", strength)
	if speed < Tuning.bonk_speed:
		return
	var top := global_position + Vector2(0.0, -_collision_radius - 1.0)
	Sfx.play(&"bonk", top, lerpf(1.1, 0.85, strength))
	if _has_body():
		body_visual.call("bonk", clampf(speed / Tuning.jump_velocity, Tuning.player_bonk_strength_min, 1.0))
	if _has_field():
		for k: int in int(roundf(Tuning.ceiling_drip_count * maxf(strength, 0.4))):
			var at := top + Vector2(Game.rng.randf_range(-0.5, 0.5) * _collision_radius, 0.0)
			field.call("drip", at, Game.rng.randf_range(Tuning.wall_streak_radius.x, Tuning.wall_streak_radius.y), Tuning.ceiling_drip_life, Vector2.DOWN)
	Juice.punch(Tuning.ceiling_punch * strength, &"bonk")
	Juice.shake(Tuning.ceiling_shake * strength, &"bonk")
	_haptic(&"bonk", strength)
	_set_face(&"strain" if strength > 0.5 else &"surprise", Tuning.ceiling_face_time)
	_report_move(&"bonk", {"strength": strength})


func take_damage(amount: float, dir: Vector2, source: StringName, knockback := Vector2.ZERO, ignore_invulnerable := false) -> void:
	if state == State.DEAD or state == State.GOAL:
		return
	if not ignore_invulnerable and _invulnerable > 0.0:
		return
	var loss := minf(amount, mass)
	if loss <= 0.0:
		return
	if dir == Vector2.ZERO:
		dir = Vector2.UP
	dir = dir.normalized()
	mass -= loss
	var strength := clampf(loss / Tuning.player_hurt_strength_ref, Tuning.player_hurt_strength_min, 1.0)
	_spawn_pieces(loss, dir)
	if _has_field():
		field.call("spray", global_position, dir, int(Tuning.player_hurt_spray_count + loss * Tuning.player_hurt_spray_per_mass), Tuning.player_hurt_spray_speed, Tuning.player_hurt_spray_spread, Tuning.player_hurt_spray_radius, velocity * Tuning.player_hurt_spray_inherit)
	if _has_body():
		body_visual.call("hit", dir, strength)
	_set_face(&"hurt", Tuning.player_hurt_face_time)
	Juice.impact(strength)
	Sfx.play(&"splash", global_position, lerpf(Tuning.player_hurt_splash_pitch.x, Tuning.player_hurt_splash_pitch.y, strength))
	if source != &"fall":
		Sfx.play(&"hurt", global_position)
	Game.report_damage(loss, source, global_position)
	Game.report_mass(mass)
	if mass < Tuning.mass_death:
		die(source)
		return
	_drop_overflow(dir)
	if knockback != Vector2.ZERO:
		if _move != Move.NONE:
			_report_move(&"interrupted", {"move": move_name()})
		_end_move()
		velocity = knockback
		_takeoff_y = _feet_y()
		_jump_rising = false
		state = State.HURT
		_state_timer = Tuning.hurt_stun_time
	_invulnerable = Tuning.invulnerable_time


func die(source: StringName) -> void:
	if state == State.DEAD:
		return
	_end_temperature(&"death")
	state = State.DEAD
	_state_timer = Tuning.death_sequence_time
	velocity = Vector2.ZERO
	_end_move()
	_running = false
	var rest := mass
	mass = 0.0
	if rest > 0.0:
		Game.report_lost(rest, &"death")
		if _has_field():
			for m: float in GooMath.split_mass(rest, Game.rng):
				var a := -PI * 0.5 + Game.rng.randf_range(-Tuning.player_death_piece_spread, Tuning.player_death_piece_spread)
				field.call("spawn_piece", global_position, m, Vector2.from_angle(a) * Game.rng.randf_range(Tuning.player_death_piece_speed.x, Tuning.player_death_piece_speed.y), true)
	_scatter_cargo()
	if _has_field():
		field.call("burst", global_position, Tuning.player_death_burst_count, Tuning.player_death_burst_speed, Tuning.player_death_burst_radius)
	if _has_body():
		body_visual.call("set_dead", true)
	_set_face(&"dead", 999.0)
	Juice.death()
	Sfx.play(&"death", global_position)
	Game.report_death(source, global_position)
	Game.report_mass(0.0)


## color: colour of the goo; a clear colour (the default) means goo of the slime's own colour.
func receive_goo(amount: float, from: Vector2, color := Color(0.0, 0.0, 0.0, 0.0)) -> void:
	if amount <= 0.0:
		return
	if state == State.DEAD or state == State.GOAL:
		Game.report_lost(amount, &"late")
		return
	if color.a > 0.0 and GooMath.differs(color, goo_color):
		var mixed := GooMath.mix_goo(goo_color, mass, color, amount)
		if _has_field():
			field.call("mix_body_color", from, mixed)
		goo_color = mixed
		Game.report_color_absorb(amount, color, goo_color)
	var taken := clampf(Tuning.mass_max - mass, 0.0, amount)
	mass += taken
	if amount > taken:
		Game.report_lost(amount - taken, &"overflow")
	_ladder = mini(_ladder + 1, Tuning.absorb_ladder_max)
	_ladder_timer = Tuning.absorb_ladder_window
	# The feedback grows with the amount: a tick for a run drop, a strong gulp for a large piece.
	var share := clampf(amount / maxf(Tuning.goo_feedback_mass_ref, 0.001), 0.0, 1.0)
	var soft := sqrt(share)
	Sfx.play(&"absorb", global_position, pow(2.0, float(_ladder - 1) / 12.0), lerpf(Tuning.goo_feedback_volume_db.x, Tuning.goo_feedback_volume_db.y, soft), 0.0)
	var dir := (from - global_position).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.UP
	var gulp := clampf(amount / Tuning.player_gulp_mass_ref, Tuning.player_gulp_strength_min, 1.0)
	if _has_body():
		body_visual.call("gulp", dir, gulp)
		body_visual.call("splash_in", dir, lerpf(Tuning.goo_feedback_dent.x, Tuning.goo_feedback_dent.y, soft))
		body_visual.call("grow", lerpf(Tuning.body_grow_min, 1.0, soft) if taken > 0.0 else Tuning.body_grow_min * 0.5)
	_set_face(&"happy", Tuning.player_absorb_face_time)
	if _has_field():
		var count := int(roundf(lerpf(float(Tuning.goo_feedback_spray.x), float(Tuning.goo_feedback_spray.y), soft)))
		field.call("spray", from, dir, count, Tuning.goo_feedback_spray_speed * lerpf(0.6, 1.0, soft), Tuning.absorb_splash_spray_spread, Tuning.player_absorb_spray_radius)
	if share >= Tuning.goo_feedback_strong:
		Sfx.play(&"swallow", global_position, Tuning.goo_feedback_gulp_pitch * _voice(), Tuning.goo_feedback_gulp_volume_db)
		Juice.punch(Tuning.goo_feedback_punch * share, &"goo_gulp")
	if _has_field():
		field.call("gulp_wave", from, lerpf(Tuning.goo_gulp_wave_strength.x, Tuning.goo_gulp_wave_strength.y, soft))
	Harness.log_event("goo_absorb", {"amount": snappedf(amount, 0.001), "taken": snappedf(taken, 0.001), "share": snappedf(share, 0.001), "mass": snappedf(mass, 0.001)})
	Game.report_absorb(taken, from)
	Game.report_mass(mass)


## Visual goo with no mass reached the body: a small sip dent and a drip tick, no mass and no grow pulse.
func swallow_droplets(count: int, size: float, at: Vector2) -> void:
	if count <= 0 or state == State.DEAD:
		return
	var dir := (at - global_position).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.UP
	var share := clampf(size / maxf(Tuning.radius_full * 0.5, 1.0), 0.0, 1.0)
	if _has_body():
		body_visual.call("splash_in", dir, Tuning.droplet_sip_dent * lerpf(0.6, 1.6, share))
	if _sip_wait <= 0.0:
		_sip_wait = Tuning.droplet_sip_interval
		# A stepped pitch, so a run of sips ripples up and down without a random source.
		_sip_step += 1
		Sfx.play(&"drip", at, lerpf(Tuning.droplet_sip_pitch.x, Tuning.droplet_sip_pitch.y, fposmod(float(_sip_step) * 0.37, 1.0)), Tuning.droplet_sip_volume_db)
	Harness.log_event("droplet_swallow", {"n": count})


## Depth inside the body where pulled goo ends its flight.
func goo_entry_radius() -> float:
	return GooMath.visual_radius(mass) * Tuning.goo_pull_entry_depth


func refill(target_mass: float) -> void:
	target_mass = minf(target_mass, Tuning.mass_max)
	if state == State.DEAD or mass >= target_mass:
		return
	var added := target_mass - mass
	mass = target_mass
	Game.report_gained(added, &"checkpoint")
	Sfx.play(&"absorb", global_position, Tuning.player_refill_pitch, 0.0, 0.0)
	if _has_body():
		body_visual.call("gulp", Vector2.UP, 1.0)
	_set_face(&"happy", Tuning.player_refill_face_time)
	Game.report_mass(mass)


func enter_goal(_center: Vector2) -> void:
	if state == State.DEAD or state == State.GOAL:
		return
	_end_temperature(&"goal")
	state = State.GOAL
	velocity = Vector2.ZERO
	_end_move()
	_running = false
	_set_face(&"happy", 999.0)
	Game.report_goal()


func _spawn_pieces(total: float, dir: Vector2) -> void:
	if not _has_field():
		Game.report_lost(total, &"no_field")
		return
	var spread := deg_to_rad(Tuning.piece_eject_spread_deg)
	for m: float in GooMath.split_mass(total, Game.rng):
		var a := dir.angle() + Game.rng.randf_range(-spread, spread)
		var speed := Game.rng.randf_range(Tuning.piece_eject_speed.x, Tuning.piece_eject_speed.y)
		speed *= lerpf(Tuning.piece_eject_size_speed.x, Tuning.piece_eject_size_speed.y, clampf(m / Tuning.piece_eject_size_ref, 0.0, 1.0))
		var v := Vector2.from_angle(a) * speed + velocity * Tuning.piece_inherit_velocity
		field.call("spawn_piece", global_position, m, v, false)


func _check_hazards() -> void:
	if _hurtbox.has_overlapping_areas():
		for area: Area2D in _hurtbox.get_overlapping_areas():
			if not area.has_method("hazard_hit"):
				continue
			var hit: Dictionary = area.call("hazard_hit", self)
			var source: StringName = hit.get("source", &"hazard")
			if temperature.cube and source in Tuning.cube_immune_sources:
				_cube_shrug(area, source)
				continue
			if bool(hit.get("kills", false)):
				die(source)
				return
			if _invulnerable <= 0.0:
				var loss: float = hit.get("loss", 0.0)
				var dir: Vector2 = hit.get("dir", Vector2.UP)
				var knockback: Vector2 = hit.get("knockback", Vector2.ZERO)
				take_damage(loss, dir, source, knockback)
			return


## Goo magnet: goo within goo_pull_reach of the body edge, with a free path to the centre, flies into the slime.
## Pieces with mass use one exact ray each (retested every goo_pull_block_retest ticks while blocked); droplets use the
## shared fan of goo_pull_rays rays. A frozen cube and a dead slime pull nothing.
func _check_absorb() -> void:
	if state != State.NORMAL and state != State.HURT:
		return
	if temperature.cube:
		if state == State.NORMAL:
			_refuse_goo()
		return
	if not _has_field():
		return
	var center := _pull_center()
	var half := _pull_half()
	var body_r := _pull_radius()
	var reach: float = Tuning.goo_pull_reach
	if _goo_sense.position != _absorber_shape.position:
		_goo_sense.position = _absorber_shape.position
	var sense_r := half + body_r + reach + Tuning.goo_sense_reach + GooMath.visual_radius(Tuning.piece_eject_size_ref)
	if absf(_goo_sense_circle.radius - sense_r) > 1.0:
		_goo_sense_circle.radius = sense_r
	_pull_pieces(center, half, body_r, reach)
	var droplets: Node = field.get(&"droplets")
	if droplets == null:
		return
	var arrived: Vector4 = droplets.call(&"take_arrivals")
	if arrived.x > 0.0:
		swallow_droplets(int(arrived.x), arrived.y, Vector2(arrived.z, arrived.w))
	if int(droplets.call(&"count")) == 0:
		return
	droplets.call(&"follow", center, goo_entry_radius())
	# Droplets are visual: the pull scan runs every few ticks, and casts its ray fan only when a droplet needs it.
	if Game.tick % maxi(Tuning.droplet_pull_interval, 1) != 0:
		return
	if bool(droplets.call(&"near", center, half + body_r + reach + Tuning.goo_pull_ray_tolerance)):
		if int(droplets.call(&"attract", center, half, body_r, reach, goo_entry_radius(), _pull_clear, false)) < 0:
			_update_pull_clearance(center, body_r + reach)
			droplets.call(&"attract", center, half, body_r, reach, goo_entry_radius(), _pull_clear, true)


func _pull_pieces(center: Vector2, half: float, body_r: float, reach: float) -> void:
	# A full slime still takes goo of another colour, for the colour; the extra mass is lost as overflow.
	var full := mass >= Tuning.mass_max - 0.01
	if _goo_sense.has_overlapping_bodies():
		var sense: float = Tuning.goo_sense_reach
		for node: Node2D in _goo_sense.get_overlapping_bodies():
			# Typed access: this loop runs in each tick while goo lies near the slime.
			var piece := node as GooPiece
			if piece == null or piece.absorbing or piece.is_queued_for_deletion():
				continue
			var id := piece.get_instance_id()
			if full and _pull_refused.get(id, &"") == &"full":
				# Refused for room: nothing changes for it until the slime has room again.
				continue
			var piece_mass := piece.mass
			var edge := GooMath.edge_distance(piece.global_position, center, half, body_r) - GooMath.visual_radius(piece_mass)
			if edge > reach:
				if piece.shed:
					piece.left_range = true
				if edge < reach + sense and piece.pull_ready():
					piece.sense(center, 1.0 - (edge - reach) / maxf(sense, 1.0))
				if _pull_refused.has(id):
					_pull_refused.erase(id)
					_pull_blocked.erase(id)
				continue
			if not piece.pull_ready():
				continue
			var decorative := piece.decorative
			if full and not decorative and _same_goo_color(piece, id):
				_refuse_piece(piece, id, &"full", piece_mass)
				continue
			if edge > 0.0 and not _pull_path_clear(center, piece, id):
				_refuse_piece(piece, id, &"blocked", piece_mass)
				continue
			_pull_refused.erase(id)
			_pull_blocked.erase(id)
			var min_total := 0.0
			if not decorative:
				if _pull_clock > _entry_next + Tuning.goo_entry_chain_break:
					_entry_chain = 0
				min_total = maxf(_entry_next - _pull_clock, 0.0)
			var total := piece.start_absorb(self, min_total)
			if not decorative and total >= 0.0:
				var chain := clampf(float(_entry_chain) / float(maxi(Tuning.goo_entry_chain_max - 1, 1)), 0.0, 1.0)
				_entry_next = _pull_clock + total + lerpf(Tuning.goo_entry_gap.x, Tuning.goo_entry_gap.y, chain)
				_entry_chain += 1
			Harness.log_event("goo_pull", {"mass": snappedf(piece_mass, 0.001), "edge": snappedf(maxf(edge, 0.0), 0.1), "decorative": decorative, "move": move_name(), "state": state_name(), "entry_in": snappedf(total, 0.001)})


## The colour test turns hues, so its result is kept for each piece until the body colour changes.
func _same_goo_color(piece: Node2D, id: int) -> bool:
	if _same_color_of != goo_color or _same_color.size() > Tuning.piece_cap * 2:
		_same_color_of = goo_color
		_same_color.clear()
	if not _same_color.has(id):
		_same_color[id] = not GooMath.differs(piece.get(&"goo_color"), goo_color)
	return _same_color[id]


func _pull_path_clear(center: Vector2, piece: Node2D, id: int) -> bool:
	if Game.tick < int(_pull_blocked.get(id, -1)):
		return false
	_pull_ray.from = center
	_pull_ray.to = piece.global_position
	if get_world_2d().direct_space_state.intersect_ray(_pull_ray).is_empty():
		return true
	_pull_blocked[id] = Game.tick + Tuning.goo_pull_block_retest
	return false


## Logs a refusal once per piece and reason; a full slime makes the goo shiver toward it with a soft bonk.
## Returns true for a new refusal.
func _refuse_piece(piece: Node2D, id: int, reason: StringName, piece_mass: float) -> bool:
	if _pull_refused.get(id, &"") == reason:
		return false
	_pull_refused[id] = reason
	if _pull_refused.size() > Tuning.piece_cap * 2:
		_pull_refused.clear()
		_pull_blocked.clear()
		_pull_refused[id] = reason
	if reason == &"full":
		piece.call(&"shiver")
		if _full_sound_wait <= 0.0:
			_full_sound_wait = Tuning.goo_full_sound_interval
			Sfx.play(&"bonk", piece.global_position, Tuning.goo_full_pitch, Tuning.goo_full_volume_db)
	Harness.log_event("goo_refuse", {"reason": String(reason), "mass": snappedf(piece_mass, 0.001)})
	return true


## Free distance along each ray of the fan from the body centre, for the droplet path test.
func _update_pull_clearance(center: Vector2, length: float) -> void:
	# A still slime keeps its fan for a while: the level changes rarely (a broken barrier), so a short reuse is safe.
	if center.distance_squared_to(_pull_clear_at) < 1.0 and absf(length - _pull_clear_len) < 1.0 and Game.tick - _pull_clear_tick < Tuning.goo_pull_ray_reuse:
		return
	_pull_clear_at = center
	_pull_clear_len = length
	_pull_clear_tick = Game.tick
	var rays := _pull_clear.size()
	var space := get_world_2d().direct_space_state
	for i: int in rays:
		_pull_ray.from = center
		_pull_ray.to = center + Vector2.from_angle(TAU * float(i) / float(rays)) * length
		var hit := space.intersect_ray(_pull_ray)
		_pull_clear[i] = center.distance_to(hit.position) if not hit.is_empty() else length


## Centre, half length and radius of the body core, from the absorber shape (a circle, or a capsule when crouched or melted).
func _pull_center() -> Vector2:
	return global_position + _absorber_shape.position


func _pull_half() -> float:
	if _absorber_shape.shape == _absorb_capsule:
		return maxf(_absorb_capsule.height * 0.5 - _absorb_capsule.radius, 0.0)
	return 0.0


func _pull_radius() -> float:
	var margin: float = Tuning.piece_absorb_margin
	if _absorber_shape.shape == _absorb_capsule:
		return maxf(_absorb_capsule.radius - margin, 0.0)
	return maxf(_absorb_circle.radius - margin, 0.0)


## Swallows touched props while there is room; a full slime bumps them away.
func _check_props() -> void:
	if state != State.NORMAL:
		return
	if temperature.cube:
		_refuse_props()
		return
	if _absorber.has_overlapping_bodies():
		for prop: Node2D in _absorber.get_overlapping_bodies():
			if not prop.has_method("take") or not bool(prop.call("can_be_absorbed")):
				continue
			if load_count() >= capacity():
				if bool(prop.call("reject", global_position)):
					Sfx.play(&"bonk", prop.global_position, 1.4, Tuning.carry_full_volume_db)
					if _has_body():
						body_visual.call("bonk", Tuning.player_bonk_strength_min)
				continue
			_swallow_prop(prop)


func _swallow_prop(prop: Node2D) -> void:
	var at := prop.global_position
	var prop_velocity: Variant = prop.get("velocity")
	var entry_speed := (prop_velocity as Vector2).length() if prop_velocity is Vector2 else 0.0
	var strength := _splash_strength(entry_speed)
	var data: Dictionary = prop.call("take")
	cargo.call(&"add", data, at, strength)
	var carried := load_count()
	var dir := (at - global_position).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.UP
	if _has_body():
		body_visual.call("gulp", dir, Tuning.carry_gulp_strength)
	_splash_in(at, dir, strength)
	if strength < Tuning.absorb_splash_strong:
		_set_face(&"happy", Tuning.player_absorb_face_time)
	Sfx.play(&"swallow", global_position, 1.0 + Tuning.carry_swallow_pitch_step * float(mini(carried, 12) - 1), Tuning.carry_swallow_volume_db)
	Juice.punch(Tuning.carry_swallow_punch, &"swallow_prop")
	_haptic(&"absorb_object", strength)
	Game.report_prop_absorbed(data.get("kind", &"rock"), at, carried)


## 0 to 1 from the entry speed; a prop the slime only walks over still gives the minimum.
func _splash_strength(entry_speed: float) -> float:
	var t := clampf(inverse_lerp(Tuning.absorb_splash_speed.x, Tuning.absorb_splash_speed.y, entry_speed), 0.0, 1.0)
	return lerpf(Tuning.absorb_splash_min, 1.0, t)


## Something fell into the slime: the surface dents at the entry and rings, goo splashes out of that point, and a
## strong entry adds a hitstop, a camera kick and a surprised face.
func _splash_in(at: Vector2, dir: Vector2, strength: float) -> void:
	if _has_body():
		body_visual.call("splash_in", dir, strength)
	if _has_field():
		var count := int(roundf(lerpf(float(Tuning.absorb_splash_spray_count.x), float(Tuning.absorb_splash_spray_count.y), strength)))
		field.call("spray", at, dir, count, Tuning.absorb_splash_spray_speed * lerpf(0.4, 1.0, strength), Tuning.absorb_splash_spray_spread, Tuning.absorb_splash_spray_radius)
	if strength >= Tuning.absorb_splash_strong:
		Sfx.play(&"splash", at, 1.35, -8.0)
		Juice.hitstop(Tuning.absorb_splash_hitstop * strength)
		Juice.punch(Tuning.absorb_splash_punch * strength, &"absorb_splash")
		_set_face(&"surprise", Tuning.absorb_splash_face_time)
	_report_move(&"splash_in", {"strength": strength})


func _haptic(preset: StringName, strength := 1.0) -> void:
	Juice.haptic(preset, clampf(strength, 0.0, 1.0))


## Damage that shrinks the slime below its load spits the extra props out with the splash: a few at once, the rest
## one by one over the next moments, so a large load does not burst out in a single frame.
func _drop_overflow(dir: Vector2) -> void:
	_overflow_dir = dir
	var dropped := 0
	while load_count() > capacity() and dropped < Tuning.carry_drop_max_per_hit:
		_drop_one_overflow()
		dropped += 1
	_overflow_timer = Tuning.carry_drop_interval


func _drop_one_overflow() -> void:
	var spread := deg_to_rad(Tuning.carry_drop_spread_deg)
	var data: Dictionary = cargo.call(&"take_last")
	var a := _overflow_dir.angle() + Game.rng.randf_range(-spread, spread)
	var v := Vector2.from_angle(a) * Game.rng.randf_range(Tuning.carry_drop_speed.x, Tuning.carry_drop_speed.y) + velocity * Tuning.piece_inherit_velocity
	_drop_prop(data, v, &"shrink")


func _scatter_cargo() -> void:
	while load_count() > 0:
		var data: Dictionary = cargo.call(&"take_last")
		var a := -PI * 0.5 + Game.rng.randf_range(-Tuning.player_death_piece_spread, Tuning.player_death_piece_spread)
		_drop_prop(data, Vector2.from_angle(a) * Game.rng.randf_range(Tuning.carry_scatter_speed.x, Tuning.carry_scatter_speed.y), &"death")


## The prop leaves half a radius out along its flight, or from the slime centre when that spot is inside a wall.
func _drop_prop(data: Dictionary, drop_velocity: Vector2, reason: StringName) -> void:
	var at := global_position + drop_velocity.normalized() * _collision_radius * 0.5
	var query := PhysicsPointQueryParameters2D.new()
	query.position = at
	query.collision_mask = Tuning.LAYER_WORLD
	if not get_world_2d().direct_space_state.intersect_point(query, 1).is_empty():
		at = global_position
	var identity := {"kind": data.get("kind", &"rock"), "seed": data.get("seed", 0), "home": data.get("home", at)}
	if is_instance_valid(Game.props):
		Game.props.call(&"drop", identity, at, drop_velocity)
	Game.report_prop_dropped(identity.kind, at, reason)


func _update_collision_radius() -> void:
	var target := GooMath.visual_radius(mass) * Tuning.collision_radius_ratio
	if absf(target - _collision_radius) < 0.2:
		return
	var step := clampf(target - _collision_radius, -Tuning.radius_step_max, Tuning.radius_step_max)
	_set_collision_radius(_collision_radius + step, true)


func _set_collision_radius(r: float, keep_feet: bool) -> void:
	var dr := r - _collision_radius
	if keep_feet and is_on_floor():
		if dr > 0.0:
			# With the feet fixed, the top of the collider rises by twice the radius change (scaled by the crouch height).
			var top_share := Tuning.crouch_height_ratio if _crouched else (Tuning.melt_collider_height if _liquid_shape else 1.0)
			var collision := KinematicCollision2D.new()
			if test_move(global_transform, Vector2(0.0, -2.0 * dr * top_share), collision):
				dr = maxf(collision.get_travel().length() - CEILING_CLEARANCE, 0.0) * 0.5 / top_share
				if dr < MIN_RADIUS_GROWTH:
					return
				r = _collision_radius + dr
		global_position += Vector2(0.0, -dr)
	_collision_radius = r
	_apply_shapes()


## Circles while standing; lying capsules anchored at the feet while crouched.
func _apply_shapes() -> void:
	var r := _collision_radius
	var margin: float = Tuning.piece_absorb_margin
	if _liquid_shape:
		var puddle := _puddle_size()
		var low := Vector2(0.0, r - puddle.y * 0.5)
		_set_capsule(_shape, _capsule, puddle.y * 0.5, puddle.x, low)
		_set_capsule(_hurtbox_shape, _hurt_capsule, puddle.y * 0.5 * Tuning.hurtbox_ratio, puddle.x * Tuning.hurtbox_ratio, low)
		_set_capsule(_absorber_shape, _absorb_capsule, puddle.y * 0.5 + margin, puddle.x + margin * 2.0, low)
	elif _crouched:
		var size := _crouch_size()
		var offset := Vector2(0.0, r - size.y * 0.5)
		_set_capsule(_shape, _capsule, size.y * 0.5, size.x, offset)
		_set_capsule(_hurtbox_shape, _hurt_capsule, size.y * 0.5 * Tuning.hurtbox_ratio, size.x * Tuning.hurtbox_ratio, offset)
		_set_capsule(_absorber_shape, _absorb_capsule, size.y * 0.5 + margin, size.x + margin * 2.0, offset)
	else:
		_set_circle(_shape, _circle, r)
		_set_circle(_hurtbox_shape, _hurt_circle, r * Tuning.hurtbox_ratio)
		_set_circle(_absorber_shape, _absorb_circle, r + margin)


func _set_circle(node: CollisionShape2D, shape: CircleShape2D, radius: float) -> void:
	shape.radius = radius
	if node.shape != shape:
		node.shape = shape
		node.rotation = 0.0
		node.position = Vector2.ZERO


func _set_capsule(node: CollisionShape2D, shape: CapsuleShape2D, radius: float, length: float, offset: Vector2) -> void:
	shape.radius = radius
	shape.height = maxf(length, radius * 2.0)
	if node.shape != shape:
		node.shape = shape
		node.rotation = PI * 0.5
	node.position = offset


func _reset_moves() -> void:
	_end_move()
	_crouched = false
	_crouch_grace = 0.0
	_running = false
	_air_jumps = Tuning.air_jumps
	_carry_timer = 0.0
	_wall_flight = false
	_wall_coyote = 0.0
	_wall_lock = 0.0
	_evade_clock = LONG_AGO
	_iframe_clock = LONG_AGO
	_roll_angle = 0.0
	_drop_timer = 0.0
	_floor_is_plank = false
	_run_debt = 0.0
	_run_tired = false
	_was_running = false
	_run_pulse = 0.0
	_overflow_timer = 0.0
	_press_time = 0.0
	collision_mask |= Tuning.LAYER_PLATFORMS


## Stops the current move with no feedback (hurt, death, goal, respawn, or a new move).
func _end_move() -> void:
	_move = Move.NONE
	_move_time = 0.0
	_skid_phase = 0


func _report_move(move: StringName, data: Dictionary) -> void:
	var info := {"at": global_position, "vel": velocity, "mass": mass}
	info.merge(data, true)
	Game.report_move(move, info)


func _push_visual() -> void:
	if not _has_body():
		return
	body_visual.global_position = global_position
	var on_floor := is_on_floor()
	var shown_radius := GooMath.visual_radius(mass)
	var feet := _collision_radius
	if _flowing():
		# A small round lump centred in the tube, with no floor under it.
		shown_radius = minf(shown_radius, Tuning.pipe_body_radius)
		feet = shown_radius
		on_floor = false
	body_visual.call("set_motion", velocity, on_floor, shown_radius, _danger_level(), feet)
	var crawl := 0.0
	if on_floor and state != State.DEAD and _move == Move.NONE:
		var full_speed: float = Tuning.crawl_speed if _crouched else Tuning.run_speed
		crawl = clampf(absf(velocity.x) / maxf(full_speed * Tuning.crawl_full_speed_share, 1.0), 0.0, 1.0)
	var dir := signf(velocity.x) if absf(velocity.x) > 1.0 else facing
	body_visual.call("set_crawl", _crawl_cycle, crawl, dir)
	var skid_dir := _skid_dir if _move == Move.SKID and _skid_phase == 0 else 0.0
	var wall_side := _wall_side if _move == Move.WALL else 0.0
	body_visual.call("set_pose", _run_amount(), _crouched, skid_dir, wall_side, _roll_angle, _move == Move.ROLL, _press_side * _press_amount(), _agility())
	cargo.call(&"set_motion", velocity)
	cargo.call(&"set_next", _aim_dir if _aim_open else _quick_dir())
	cargo.visible = not _flowing()
	_send_temperature_visuals()


## 0 at the walk speed, 1 at full run, on the floor only.
func _run_amount() -> float:
	if not _running or not is_on_floor():
		return 0.0
	return clampf(inverse_lerp(Tuning.run_speed * 0.85, Tuning.sprint_speed, absf(velocity.x)), 0.0, 1.0)


func _crawl_stride() -> float:
	var ratio: float = Tuning.crawl_stride_ratio
	if _crouched:
		ratio = Tuning.crouch_stride_ratio
	else:
		ratio = lerpf(ratio, Tuning.sprint_stride_ratio, _run_amount())
	return ratio * maxf(GooMath.visual_radius(mass), Tuning.radius_min_visual) / _agile(Tuning.agility_crawl)


func _feet_y() -> float:
	return global_position.y + _collision_radius


func _has_body() -> bool:
	return is_instance_valid(body_visual)


func _has_field() -> bool:
	return is_instance_valid(field)


func _set_face(expression: StringName, seconds: float) -> void:
	if is_instance_valid(face):
		face.call("set_expression", expression, seconds)


func _danger_level() -> float:
	if mass >= Tuning.mass_danger or mass <= 0.0:
		return 0.0
	return clampf(inverse_lerp(Tuning.mass_danger, Tuning.mass_death, mass), 0.0, 1.0)


## 0 at full mass, 1 at the death mass, on the agility curve: less goo, a lighter and faster slime.
func _agility() -> float:
	return pow(clampf(inverse_lerp(Tuning.mass_max, Tuning.mass_death, mass), 0.0, 1.0), Tuning.agility_curve)


## Multiplier for one agility gain from Tuning.
func _agile(gain: float) -> float:
	return 1.0 + gain * _agility()


## Body size against the full-mass body, for effects that scale with the slime.
func _size_scale() -> float:
	return clampf(GooMath.visual_radius(mass) / maxf(Tuning.radius_full, 1.0), 0.3, 1.0)


func _speed_factor() -> float:
	return _agile(Tuning.agility_speed) * _temp_speed()


## Sound pitch for the body size: lower for the heavy slime, higher for the light one.
func _voice() -> float:
	return _agile(Tuning.agility_pitch)


# --- Temperature: melt, ice cube, fire and pipes (model in scenes/player/temperature.gd) ---

## Temperature fields of the Harness STATE line.
func temperature_state() -> Dictionary:
	return {
		"temperature": temperature.value,
		"temp_state": StringName(temperature.phase_name()),
		"burning": temperature.burning(),
		"fire_left": temperature.fuel,
		"flowing": _flowing(),
		"puddle": _liquid_shape,
	}


## Face of the temperature: panic while burning, frozen as an ice cube, melty as a puddle; else empty.
func temperature_expression() -> StringName:
	if temperature.burning():
		return &"panic"
	if temperature.cube:
		return &"frozen"
	if _liquid_shape:
		return &"melty"
	return &""


## Tint the temperature puts on the body, with its share in alpha; the face ink follows it.
func status_tint() -> Color:
	if temperature.burning():
		return Color(Tuning.fire_body_color, Tuning.fire_body_tint)
	if temperature.frost() > 0.0:
		return Color(Tuning.frost_body_color, Tuning.frost_body_tint * temperature.frost())
	return Color(0.0, 0.0, 0.0, 0.0)


func is_flowing() -> bool:
	return _flowing()


## Visuals of every temperature look, drawn once behind the loading cover.
func warm_up_temperature() -> void:
	_temp_fx.set("body", body_visual)
	_temp_fx.call(&"warm_up")


func _flowing() -> bool:
	return _flow_pipe != null


func _reset_temperature() -> void:
	var start := 0.0
	var burning := false
	if not _harness_temperature_used:
		# The first spawn of a run takes the --temp and --burn overrides of the Harness.
		_harness_temperature_used = true
		start = Harness.temperature_override
		burning = Harness.burn_override
	if temperature.burning():
		_report_temperature(&"fire_end", {"reason": &"respawn", "burned": temperature.burned})
	if temperature.phase != Temperature.Phase.SOLID:
		_report_temperature(&"temp_state", {"from": StringName(temperature.phase_name()), "to": &"SOLID", "temperature": 0.0, "reason": &"respawn"})
	_abort_flow()
	temperature.reset(start, burning)
	_liquid_shape = temperature.liquid
	_burn_pulse = Tuning.fire_pulse_interval
	_melt_debt = 0.0
	_melt_pulse = Tuning.melt_trail_interval
	_melt_drip = 0.0
	_lock_wait = 0.0
	_refuse_wait = 0.0
	_immune_wait = 0.0
	_shrug_area_id = 0
	_flow_cooldown = 0.0
	_floor_surface = &""
	_update_grate_mask()
	_temp_fx.set("body", body_visual)
	_temp_fx.call(&"clear")
	if burning:
		_report_temperature(&"fire_start", {})


## Death and the goal end the fire and any flow; death also clears the temperature.
func _end_temperature(reason: StringName) -> void:
	if temperature.burning():
		temperature.put_out()
		_report_temperature(&"fire_end", {"reason": reason, "burned": temperature.burned})
	_abort_flow()
	if reason == &"death" and temperature.phase != Temperature.Phase.SOLID:
		_report_temperature(&"temp_state", {"from": StringName(temperature.phase_name()), "to": &"SOLID", "temperature": 0.0, "reason": reason})
		temperature.reset()
		_liquid_shape = false
		_update_grate_mask()
		_apply_shapes()


func _update_temperature(delta: float) -> void:
	if state == State.DEAD or state == State.GOAL:
		return
	_lock_wait = maxf(_lock_wait - delta, 0.0)
	_refuse_wait = maxf(_refuse_wait - delta, 0.0)
	_immune_wait = maxf(_immune_wait - delta, 0.0)
	_flow_cooldown = maxf(_flow_cooldown - delta, 0.0)
	if _hurtbox.has_overlapping_areas():
		for area: Area2D in _hurtbox.get_overlapping_areas():
			if area.has_method(&"temperature_push"):
				var push: Dictionary = area.call(&"temperature_push")
				temperature.push(float(push.get("heat", 0.0)), float(push.get("thaw", 0.0)), bool(push.get("ignite", false)), bool(push.get("extinguish", false)))
	for event: Dictionary in temperature.step(delta):
		_on_temperature_event(event.name, event.data)
	_burn(delta)
	if state == State.DEAD:
		return
	_pay_melt_trail(delta)
	_melt_drips(delta)
	_update_liquid_shape()
	if (temperature.cube or _liquid_shape) and _move != Move.NONE:
		if _move == Move.WALL:
			_leave_wall(&"frozen" if temperature.cube else &"melted")
		else:
			_report_move(&"interrupted", {"move": move_name()})
			_end_move()
	_try_enter_pipe()


func _on_temperature_event(event: StringName, data: Dictionary) -> void:
	match event:
		&"temp_state":
			_on_phase_change(data.from, data.to)
		&"fire_start":
			_on_ignite()
		&"fire_end":
			_on_fire_out()
	_report_temperature(event, data)


func _on_phase_change(from: StringName, to: StringName) -> void:
	var feet := global_position + Vector2(0.0, _collision_radius)
	match to:
		&"LIQUID":
			Sfx.play(&"melt", global_position, 0.85 * _voice())
			_haptic(&"melt")
			if _has_body():
				body_visual.call("splash_in", Vector2.UP, 0.6)
			if _has_field():
				field.call("spray", feet, Vector2.UP, 10, Vector2(80.0, 200.0), 70.0, Tuning.melt_drip_radius)
			_set_face(&"normal", 0.0)
		&"MELTING":
			if from == &"LIQUID":
				# Back from a puddle: the goo pulls itself up into a body again.
				Sfx.play(&"swallow", global_position, 1.2 * _voice(), -4.0)
				if _has_body():
					body_visual.call("gulp", Vector2.UP, 0.8)
			else:
				Sfx.play(&"melt", global_position, 1.1 * _voice(), -8.0)
		&"CUBE":
			Sfx.play(&"freeze", global_position, 0.9)
			Sfx.play(&"ice_clink", global_position, 0.8, -3.0)
			_haptic(&"freeze")
			Juice.shake(Tuning.cube_freeze_shake, &"freeze")
			Juice.punch(Tuning.cube_freeze_punch, &"freeze")
			if is_instance_valid(Juice.sparks):
				Juice.sparks.call(&"ring", global_position, _collision_radius * 2.4, Tuning.frost_glint_color, 0.35)
				Juice.sparks.call(&"glint", global_position + Vector2(-0.6, -0.6) * _collision_radius, 16.0, Color.WHITE, 0.4)
			if _has_body():
				body_visual.call("bonk", 0.6)
		&"FREEZING":
			if from == &"CUBE":
				# The cube cracks open: ice shards fly and the gelatin wobbles free.
				Sfx.play(&"crack", global_position, 1.5, -2.0)
				Sfx.play(&"ice_clink", global_position, 0.6, -4.0)
				_haptic(&"freeze", 0.6)
				if is_instance_valid(Juice.sparks):
					Juice.sparks.call(&"debris", global_position, Vector2.UP, 10, Vector2(140.0, 380.0), 80.0, Vector2(4.0, 8.0), PackedColorArray(Tuning.frost_shard_colors), false)
				if _has_body():
					body_visual.call("gulp", Vector2.UP, 1.0)
			else:
				Sfx.play(&"freeze", global_position, 1.3, -10.0)
		&"SOLID":
			if from == &"FREEZING" and _has_body():
				body_visual.call("splash_in", Vector2.UP, 0.4)


func _on_ignite() -> void:
	_burn_pulse = Tuning.fire_pulse_interval
	Sfx.play(&"ignite", global_position)
	_haptic(&"ignite")
	Juice.flash(Tuning.fire_ignite_flash, 0.25)
	Juice.shake(Tuning.fire_ignite_shake, &"ignite")
	Juice.punch(Tuning.fire_ignite_punch, &"ignite")
	if is_instance_valid(Juice.sparks):
		Juice.sparks.call(&"sparks", global_position, Vector2.UP, 26, Vector2(200.0, 600.0), 80.0, Tuning.ember_hot, Vector2(2.0, 4.5))
		Juice.sparks.call(&"ring", global_position, _collision_radius * 2.6, Tuning.ember_hot, 0.35)
	if _has_body():
		body_visual.call("hit", Vector2.UP, 0.6)


func _on_fire_out() -> void:
	Sfx.play(&"fire_out", global_position, 1.0, Tuning.fire_out_volume_db)
	_haptic(&"fire_out")
	if is_instance_valid(Juice.sparks):
		Juice.sparks.call(&"ring", global_position, _collision_radius * 2.2, Color(1.0, 1.0, 1.0, 0.6), 0.4)
		Juice.sparks.call(&"sparks", global_position + Vector2(0.0, -_collision_radius), Vector2.UP, 10, Vector2(60.0, 180.0), 50.0, Color(0.9, 0.9, 0.95, 0.7), Vector2(3.0, 6.0))


## The fire eats goo in pulses; the burned goo evaporates and leaves no piece.
func _burn(delta: float) -> void:
	if not temperature.burning():
		return
	_burn_pulse -= delta
	if _burn_pulse > 0.0:
		return
	_burn_pulse += Tuning.fire_pulse_interval
	var amount := minf(temperature.burn(Tuning.fire_fuel / Tuning.fire_duration * Tuning.fire_pulse_interval), mass)
	mass -= amount
	Game.report_lost(amount, &"burned")
	Game.report_mass(mass)
	_haptic(&"drain", Tuning.fire_haptic_strength)
	Sfx.play(&"sizzle", global_position, lerpf(0.9, 1.2, Game.rng.randf()), -3.0)
	if _has_body():
		body_visual.call("drain_pulse", Vector2.UP, 0.9)
		body_visual.call("pulse")
	if is_instance_valid(Juice.sparks):
		Juice.sparks.call(&"sparks", global_position + Vector2(0.0, -_collision_radius * 0.6), Vector2.UP, 8, Vector2(160.0, 420.0), 60.0, Tuning.ember_hot)
	if mass < Tuning.mass_death:
		die(&"fire")
		return
	if not temperature.burning():
		_report_temperature(&"fire_end", {"reason": &"burned_out", "burned": temperature.burned})
		_on_fire_out()


## The melt trail costs goo every tick and leaves in pulses as real pieces behind the slime (see _drop_melt_piece).
func _pay_melt_trail(delta: float) -> void:
	var melt := temperature.melt()
	if melt < Tuning.melt_trail_start or state != State.NORMAL or not is_on_floor():
		_melt_pulse = minf(_melt_pulse, Tuning.melt_trail_interval)
		return
	var room := mass - _run_debt - Tuning.melt_trail_min_mass
	_melt_debt = clampf(_melt_debt + Tuning.melt_trail_per_second * melt * delta, 0.0, maxf(room, 0.0))
	_melt_pulse -= delta
	if _melt_pulse <= 0.0:
		_melt_pulse += Tuning.melt_trail_interval
		_drop_melt_piece()


func _drop_melt_piece() -> void:
	if _melt_debt <= 0.0 or not _has_field():
		return
	var back := -signf(velocity.x) if absf(velocity.x) > 1.0 else -facing
	var at := global_position + Vector2(back * _collision_radius * 0.8, _collision_radius * 0.7)
	var piece_mass := _melt_debt
	_melt_debt = 0.0
	mass -= piece_mass
	var piece: Node2D = field.call("spawn_piece", at, piece_mass, Vector2(back * Tuning.melt_trail_piece_speed.x, -Tuning.melt_trail_piece_speed.y), false)
	if piece != null:
		piece.set(&"shed", true)
	if _has_body():
		body_visual.call("drain_pulse", Vector2(back, 0.6).normalized(), clampf(piece_mass / Tuning.melt_trail_pulse_ref, 0.2, 0.8))
	Game.report_mass(mass)
	_report_move(&"melt_trail", {"piece": piece_mass})


## Drops that run off a melting body: real goo droplets, more the more it melts.
func _melt_drips(delta: float) -> void:
	var melt := temperature.melt()
	if melt < 0.15 or not _has_field():
		return
	_melt_drip -= delta * melt
	if _melt_drip > 0.0:
		return
	_melt_drip = Tuning.melt_drip_interval
	var side := Game.rng.randf_range(-1.0, 1.0)
	var at := global_position + Vector2(side * _collision_radius * lerpf(0.8, 1.6, melt), _collision_radius * 0.8)
	field.call("drip", at, Game.rng.randf_range(Tuning.melt_drip_radius.x, Tuning.melt_drip_radius.y), Tuning.melt_drip_life)


## The puddle collider follows the liquid flag; it stays on while the solid body would not fit where the puddle is.
func _update_liquid_shape() -> void:
	if temperature.liquid == _liquid_shape:
		return
	if temperature.liquid:
		_set_crouched(false, true)
		_liquid_shape = true
	elif _standing_fits(global_position):
		_liquid_shape = false
	elif _crouched_fits(global_position):
		_liquid_shape = false
		_set_crouched(true, true)
	else:
		return
	_update_grate_mask()
	_apply_shapes()


func _update_grate_mask() -> void:
	if _liquid_shape:
		collision_mask &= ~Tuning.LAYER_GRATES
	else:
		collision_mask |= Tuning.LAYER_GRATES


## Width and height of the puddle collider.
func _puddle_size() -> Vector2:
	var h := 2.0 * _collision_radius * Tuning.melt_collider_height
	return Vector2(maxf(2.0 * _collision_radius * Tuning.melt_collider_width, h), h)


func _puddle_fits(at: Vector2) -> bool:
	var size := _puddle_size()
	_probe_capsule.radius = maxf(size.y * 0.5 - FIT_INSET, 1.0)
	_probe_capsule.height = maxf(size.x - FIT_INSET * 2.0, _probe_capsule.radius * 2.0)
	_shape_query.collision_mask = Tuning.LAYER_WORLD
	var fits := _fits(_probe_capsule, Transform2D(PI * 0.5, at + Vector2(0.0, _collision_radius - size.y * 0.5)))
	_shape_query.collision_mask = Tuning.LAYER_WORLD | Tuning.LAYER_GRATES
	return fits


func _can_squish() -> bool:
	return not temperature.cube and not _liquid_shape


func _temp_rigid_or_runny() -> bool:
	return temperature.cube or _liquid_shape


func _temp_speed() -> float:
	return lerpf(1.0, Tuning.melt_speed_share, temperature.melt()) * lerpf(1.0, Tuning.cube_speed_share, temperature.frost())


func _temp_jump() -> float:
	return lerpf(1.0, Tuning.melt_jump_share, temperature.melt()) * lerpf(1.0, Tuning.cube_jump_share, temperature.frost())


func _temp_accel() -> float:
	return lerpf(1.0, Tuning.cube_accel_share, temperature.frost())


## A cube on ice: slow to start, fast at the top, and it hardly stops by itself.
func _apply_ice_slide(move: float, delta: float) -> void:
	if absf(move) > 0.01:
		facing = signf(move)
		velocity.x = move_toward(velocity.x, move * Tuning.cube_ice_top_speed, Tuning.cube_ice_accel * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, Tuning.cube_ice_decel * delta)
	_cube_slide_sound -= delta
	if _cube_slide_sound <= 0.0 and absf(velocity.x) > 80.0:
		_cube_slide_sound = Tuning.cube_slide_sound_interval
		var share := clampf(absf(velocity.x) / Tuning.cube_ice_top_speed, 0.0, 1.0)
		var feet := global_position + Vector2(-signf(velocity.x) * _collision_radius * 0.6, _collision_radius)
		Sfx.play(&"skid", feet, lerpf(1.4, 1.9, share), lerpf(-16.0, -8.0, share))
		if is_instance_valid(Juice.sparks):
			Juice.sparks.call(&"sparks", feet, Vector2(-signf(velocity.x), -0.4), 3, Vector2(80.0, 220.0) * share, 25.0, Tuning.frost_glint_color, Vector2(1.5, 2.5))


## A fast cube that meets crystal (a wall in a slide, a plug in a fall) smashes through it and keeps going.
func _try_cube_smash(collision: KinematicCollision2D, pre_velocity: Vector2) -> void:
	var target := collision.get_collider()
	if target == null or not target.has_method(&"shot_hit"):
		return
	var n := collision.get_normal()
	var impact := -pre_velocity.dot(n)
	var pound := n.y < -0.7
	if impact < (Tuning.cube_pound_speed if pound else Tuning.cube_break_speed):
		return
	var at := collision.get_position()
	var result: Dictionary = target.call(&"shot_hit", {"at": at, "dir": -n, "speed": impact, "kind": &"ice_cube", "prop": null, "damage": 1})
	if not bool(result.get("pierce", false)):
		return
	velocity = pre_velocity * Tuning.cube_break_keep
	Sfx.play(&"ice_clink", at, 0.7, 0.0)
	_haptic(&"cube_smash")
	if _has_body():
		body_visual.call("bonk", 1.0)
	_report_temperature(&"cube_smash", {"how": &"pound" if pound else &"slide", "speed": impact, "at": at})


## A cube lands like a block of ice: a hard knock, a shake and ice chips, and no fall damage.
func _on_cube_land(pre_velocity: Vector2) -> void:
	var impact := pre_velocity.y
	if impact < Tuning.player_land_soft_speed:
		return
	var share := clampf(impact / Tuning.max_fall_speed, 0.0, 1.0)
	var feet := global_position + Vector2(0.0, _collision_radius)
	if _has_body():
		body_visual.call("land", impact * 0.2)
	Sfx.play(&"ice_clink", feet, lerpf(1.0, 0.65, share), Tuning.cube_land_volume_db)
	Sfx.play(&"land_heavy", feet, 1.3, lerpf(-12.0, -4.0, share))
	Juice.shake(Tuning.cube_land_shake * share, &"cube_land")
	Juice.punch(Tuning.cube_land_punch * share, &"cube_land")
	_haptic(&"land", share)
	if is_instance_valid(Juice.sparks):
		Juice.sparks.call(&"debris", feet, Vector2.UP, int(lerpf(3.0, 10.0, share)), Vector2(120.0, 320.0), 70.0, Vector2(3.0, 6.0), PackedColorArray(Tuning.frost_shard_colors), false)


func _on_cube_step() -> void:
	Sfx.play(&"ice_clink", global_position + Vector2(0.0, _collision_radius), 0.55, -14.0)


## A cube cannot shoot, aim or dodge: the press gives a frosty knock so the lock is clear. A refusal never moves the camera.
func _ice_lock(action: StringName) -> void:
	if _lock_wait > 0.0:
		return
	_lock_wait = Tuning.cube_lock_feedback_interval
	var mouth := global_position + Vector2(facing * _collision_radius, -_collision_radius * 0.2)
	Sfx.play(&"ice_clink", mouth, 1.35)
	_haptic(&"ice_lock")
	if _has_body():
		body_visual.call("bonk", 0.5)
	if is_instance_valid(Juice.sparks):
		Juice.sparks.call(&"glint", mouth, 18.0, Color.WHITE, 0.3)
		Juice.sparks.call(&"ring", mouth, _collision_radius * 0.9, Tuning.frost_glint_color, 0.25)
		Juice.sparks.call(&"debris", mouth, Vector2(facing, -0.5), 4, Vector2(80.0, 220.0), 50.0, Vector2(2.5, 4.5), PackedColorArray(Tuning.frost_shard_colors), false)
	_report_temperature(&"ice_lock", {"action": action})


## Loose goo that touches the cube stays outside: a soft sign for a piece that was not refused before.
func _refuse_goo() -> void:
	if _absorber.has_overlapping_bodies():
		for body: Node2D in _absorber.get_overlapping_bodies():
			if body.has_method("start_absorb") and bool(body.call("can_be_absorbed")):
				if _refuse_piece(body, body.get_instance_id(), &"cube", float(body.get(&"mass"))):
					_ice_refuse(&"absorb_goo")
				return


## Props that touch the cube bounce off it.
func _refuse_props() -> void:
	if _absorber.has_overlapping_bodies():
		for prop: Node2D in _absorber.get_overlapping_bodies():
			if prop.has_method("take") and bool(prop.call("can_be_absorbed")) and bool(prop.call("reject", global_position)):
				_ice_refuse(&"absorb_prop")
				return


## The player did not ask for this contact: one small glint and a soft clink, with a long cooldown, no vibration and no camera.
func _ice_refuse(action: StringName) -> void:
	if _refuse_wait > 0.0:
		return
	_refuse_wait = Tuning.cube_refuse_feedback_interval
	var mouth := global_position + Vector2(facing * _collision_radius, -_collision_radius * 0.2)
	Sfx.play(&"ice_clink", mouth, 1.5, Tuning.cube_refuse_volume_db)
	if is_instance_valid(Juice.sparks):
		Juice.sparks.call(&"glint", mouth, 12.0, Color.WHITE, 0.25)
	_report_temperature(&"ice_lock", {"action": action})


## Spikes cannot pierce the ice: a clink and a spray of ice dust instead of damage.
func _cube_shrug(area: Area2D, source: StringName) -> void:
	var id := area.get_instance_id()
	if _immune_wait > 0.0:
		if id == _shrug_area_id:
			# Still on the same hazard: hold the wait, so a resting cube clinks once.
			_immune_wait = Tuning.cube_immune_feedback_interval
		return
	_shrug_area_id = id
	_immune_wait = Tuning.cube_immune_feedback_interval
	var feet := global_position + Vector2(0.0, _collision_radius)
	Sfx.play(&"ice_clink", feet, 1.6, -6.0)
	if is_instance_valid(Juice.sparks):
		Juice.sparks.call(&"sparks", feet, Vector2.UP, 6, Vector2(100.0, 260.0), 70.0, Tuning.frost_glint_color, Vector2(1.5, 3.0))
	_report_temperature(&"cube_immune", {"source": source, "hazard": area.name})


## A puddle cannot dodge or roll: it only sloshes.
func _slosh() -> void:
	if _lock_wait > 0.0:
		return
	_lock_wait = Tuning.cube_lock_feedback_interval
	Sfx.play(&"drip", global_position, 0.8, -6.0)
	if _has_body():
		body_visual.call("splash_in", Vector2(facing, -0.4), 0.5)
	if _has_field():
		field.call("spray", global_position + Vector2(facing * _collision_radius, _collision_radius * 0.5), Vector2(facing, -1.0).normalized(), 6, Vector2(80.0, 200.0), 40.0, Tuning.melt_drip_radius)
	_report_temperature(&"puddle_lock", {"action": &"dodge"})


## Extra heat on an ember spit: a hot puff at the mouth and a hiss.
func _ember_spit(mouth: Vector2, dir: Vector2) -> void:
	Sfx.play(&"sizzle", mouth, 1.3, -2.0)
	if is_instance_valid(Juice.sparks):
		Juice.sparks.call(&"sparks", mouth, dir, 14, Vector2(200.0, 520.0), 30.0, Tuning.ember_hot, Vector2(2.0, 4.0))
		Juice.sparks.call(&"ring", mouth, _collision_radius * 0.8, Tuning.ember_hot, 0.2)


func _try_enter_pipe() -> void:
	if not _liquid_shape or state != State.NORMAL or _flow_cooldown > 0.0 or _flowing():
		return
	if _hurtbox.has_overlapping_areas():
		for area: Area2D in _hurtbox.get_overlapping_areas():
			if area.has_method(&"flow_path"):
				_start_flow(area)
				return


func _start_flow(pipe: Node2D) -> void:
	var path: PackedVector2Array = pipe.call(&"flow_path")
	if path.size() < 2:
		return
	if _move != Move.NONE:
		_end_move()
	_running = false
	if _aim_open:
		_aim_open = false
		Juice.aim_slowmo(false)
		_close_aim_visuals()
	_flow_pipe = pipe
	_flow_path = path
	_flow_from = global_position
	_flow_dist = 0.0
	_flow_time = 0.0
	_flow_drip = 0.0
	_flow_length = 0.0
	for i: int in range(1, path.size()):
		_flow_length += path[i - 1].distance_to(path[i])
	velocity = Vector2.ZERO
	pipe.call(&"begin_flow")
	Sfx.play(&"gurgle", global_position, 0.9)
	Sfx.play(&"swallow", path[0], 0.7, -4.0)
	_haptic(&"pipe_flow")
	if _has_body():
		body_visual.call("splash_in", Vector2.DOWN, 0.8)
	if _has_field():
		field.call("spray", path[0], Vector2.UP, 8, Vector2(80.0, 220.0), 50.0, Tuning.melt_drip_radius)
	_report_temperature(&"flow_start", {"pipe": pipe.name, "length": _flow_length})


## Runs the slime along the pipe: a short slurp into the drain, then the flow at a steady speed to the outlet.
func _step_flow(delta: float) -> void:
	_flow_time += delta
	var before := global_position
	if _flow_time < Tuning.pipe_enter_time:
		var s := _flow_time / Tuning.pipe_enter_time
		global_position = _flow_from.lerp(_flow_path[0], s * s)
	else:
		_flow_dist += Tuning.pipe_flow_speed * delta
		if _flow_dist >= _flow_length:
			_finish_flow()
			return
		global_position = _point_on_flow(_flow_dist)
	velocity = (global_position - before) / maxf(delta, 0.0001)
	if absf(velocity.x) > 1.0:
		facing = signf(velocity.x)
	_flow_pipe.call(&"flow_at", global_position)
	_flow_drip -= delta
	if _flow_drip <= 0.0:
		_flow_drip = Tuning.pipe_drip_interval * 5.0
		Sfx.play(&"gurgle", global_position, Game.rng.randf_range(0.8, 1.2), -10.0)


func _point_on_flow(dist: float) -> Vector2:
	var left := dist
	for i: int in range(1, _flow_path.size()):
		var a := _flow_path[i - 1]
		var b := _flow_path[i]
		var length := a.distance_to(b)
		if left <= length:
			return a.lerp(b, left / maxf(length, 0.001))
		left -= length
	return _flow_path[_flow_path.size() - 1]


## Out of the outlet: the slime splashes out along the pipe, still liquid, and the pipe will not take it back at once.
func _finish_flow() -> void:
	var pipe := _flow_pipe
	var dir: Vector2 = pipe.call(&"exit_direction")
	var face_point: Vector2 = pipe.call(&"exit_point")
	_flow_pipe = null
	pipe.call(&"end_flow")
	_set_collision_radius(GooMath.visual_radius(mass) * Tuning.collision_radius_ratio, false)
	var reach := _puddle_size().x * 0.5 if _liquid_shape and absf(dir.x) > 0.5 else _collision_radius
	var at := face_point + dir * (reach + 2.0)
	for k: int in 4:
		if _puddle_fits(at) if _liquid_shape else _standing_fits(at):
			break
		at += dir * _collision_radius * 0.5
	global_position = at
	_prev_pos = at
	_curr_pos = at
	reset_physics_interpolation()
	velocity = dir * Tuning.pipe_exit_speed
	_flow_cooldown = Tuning.pipe_exit_cooldown
	_takeoff_y = _feet_y()
	_was_on_floor = false
	Sfx.play(&"splash", face_point, 1.3, -4.0)
	_haptic(&"land", 0.5)
	Juice.punch(Tuning.pipe_exit_punch, &"pipe_exit")
	if _has_body():
		body_visual.call("splash_in", -dir, 1.0)
	if _has_field():
		field.call("spray", face_point, dir, 14, Vector2(150.0, 380.0), 35.0, Tuning.melt_drip_radius)
	_report_temperature(&"flow_end", {"time": _flow_time})


func _abort_flow() -> void:
	if _flowing():
		_flow_pipe.call(&"end_flow")
		_flow_pipe = null


## Body shape, effects and body tint of the temperature, once per physics tick.
func _send_temperature_visuals() -> void:
	var melt := temperature.melt()
	var frost := temperature.frost()
	var fire := temperature.fire_share() if temperature.burning() else 0.0
	var visual_key := [0.0 if _flowing() else melt, frost, fire, facing, temperature.burning()]
	if visual_key != _temp_visual_key:
		_temp_visual_key = visual_key
		body_visual.call("set_temperature", 0.0 if _flowing() else melt, frost)
		cargo.call(&"set_temperature", frost, 1.0 if temperature.burning() else 0.0, melt)
		_temp_fx.call(&"set_state", melt, frost, fire, facing)
	var status := Color(0.0, 0.0, 0.0, 0.0)
	var glow := 0.0
	if temperature.burning():
		var flicker := 0.5 + 0.5 * sin(Game.sim_time * TAU * Tuning.ember_pulse_hz)
		var pulse_share := clampf(1.0 - _burn_pulse / Tuning.fire_pulse_interval, 0.0, 1.0)
		status = Color(Tuning.fire_body_color, Tuning.fire_body_tint)
		glow = Tuning.fire_body_glow * lerpf(0.6, 1.0, flicker) - Tuning.fire_pulse_glow * pulse_share
	elif frost > 0.0:
		status = Color(Tuning.frost_body_color, Tuning.frost_body_tint * frost)
		glow = Tuning.frost_body_glow * frost
	elif melt > 0.0:
		status = Color(Tuning.melt_body_color, Tuning.melt_body_tint * melt)
		glow = Tuning.melt_body_glow * melt
	var sent := Color(status.r, status.g, status.b, status.a + glow * 10.0)
	if sent.is_equal_approx(_status_sent) or not _has_field() or not field.has_method(&"set_body_status"):
		return
	_status_sent = sent
	field.call(&"set_body_status", Color(status, 1.0), status.a, glow)


func _report_temperature(event: StringName, data: Dictionary) -> void:
	var info := {"at": global_position, "mass": mass}
	info.merge(data, true)
	Game.report_temperature(event, info)
