extends CharacterBody2D
## Detached goo blob: flies, sticks to surfaces, drips, sinks into the soil when its time ends, and can be slurped back.

const GooMath := preload("res://scripts/goo/goo_math.gd")

enum State { FLYING, CLINGING, SLIDING, RESTING, ABSORBING }

const FLOOR_NORMAL_Y := -0.65
const CEILING_NORMAL_Y := 0.65
const MIN_COLLISION_RADIUS := 2.0
const DRY_REMOVE_MASS := 0.25
const WOBBLE_EPSILON := 0.002

var mass := 1.0
var decorative := false
## Colour of this goo; the slime takes it in when it slurps the piece.
var goo_color := Color(0.0, 0.0, 0.0, 0.0)
var _code := Color(0.7, 0.0, 0.0, 1.0)
var state: State = State.FLYING
var age := 0.0
var absorbing: bool:
	get:
		return state == State.ABSORBING
var soaking: bool:
	get:
		return _soak >= 0.0
## Goo the slime shed as a cost (run, melt trail): the pull takes it only after it was once out of reach.
var shed := false
var left_range := false

var _normal := Vector2.UP
var _cling_timer := 0.0
var _cling_total := 1.0
var _sag := 0.0
var _trail_dist := 0.0
var _wobble := 0.0
var _wobble_vel := 0.0
var _absorb_target: Node2D
var _absorb_from := Vector2.ZERO
var _absorb_t := 0.0
var _pull_flight := 0.1
var _pull_lifted := Vector2.ZERO
var _pull_arc := 0.0
var _pull_head := Vector2.ZERO
## Magnet sense: the goo leans and trembles toward a near slime (0 to 1), toward _lean_dir; it fades when not renewed.
var _lean := 0.0
var _lean_target := 0.0
var _lean_dir := Vector2.UP
var _sense_ticks := 0
var _tremble_step := 0
var _life := 0.0
var _dries := true
## Seconds since the sink started; below zero while the piece has not started to sink.
var _soak := -1.0
var _soak_mass := 0.0
var _soaked := 0.0
var _redraw := true
var _rng := RandomNumberGenerator.new()

@onready var _shape: CollisionShape2D = $CollisionShape2D


func setup(at: Vector2, piece_mass: float, initial_velocity: Vector2, is_decorative: bool, color := Color(0.0, 0.0, 0.0, 0.0)) -> void:
	goo_color = color if color.a > 0.0 else GooMath.base_color()
	_code = GooMath.source_color(goo_color)
	mass = maxf(piece_mass, 0.0)
	decorative = is_decorative
	velocity = initial_velocity
	global_position = at
	reset_physics_interpolation()
	_rng.seed = Game.rng.randi()
	_shape.shape = CircleShape2D.new()
	_update_shape()
	if decorative:
		_life = Tuning.goo_ground_life * _rng.randf_range(Tuning.goo_ground_life_jitter.x, Tuning.goo_ground_life_jitter.y)
		collision_layer = 0
	else:
		_life = Tuning.piece_lifetime
	_dries = decorative or Tuning.piece_lifetime > 0.0
	_wake()


func can_be_absorbed() -> bool:
	return not decorative and pull_ready()


## The magnet may take this piece now: old enough to let the splash read, and not shed goo that never left reach.
func pull_ready() -> bool:
	if state == State.ABSORBING or is_queued_for_deletion() or mass <= 0.0:
		return false
	if age < Tuning.piece_absorb_delay:
		return false
	if state == State.FLYING and age < Tuning.piece_absorb_delay_flying:
		return false
	return not shed or left_range


## The slime is near: the goo leans and trembles toward it, as iron does before a magnet takes it.
func sense(toward: Vector2, strength: float) -> void:
	var d := toward - global_position
	if d != Vector2.ZERO:
		_lean_dir = d.normalized()
	_lean_target = maxf(_lean_target, clampf(strength, 0.0, 1.0))
	_sense_ticks = 2
	set_process(true)


## The pull: the piece holds and trembles toward the target (at least until min_total seconds before its entry, so
## entries come one by one), stretches on the spot, lets go, and flies in faster and faster on a short arc. A sinking
## piece comes out of the soil with the mass it still has. Returns the seconds to the entry.
func start_absorb(target: Node2D, min_total := 0.0) -> float:
	if not pull_ready() or not is_instance_valid(target):
		return -1.0
	if soaking:
		if not decorative and _soaked > 0.0:
			Game.goo_lost.emit(_soaked, &"soaked")
		_soak = -1.0
		_soaked = 0.0
		_update_shape()
	state = State.ABSORBING
	_absorb_target = target
	_absorb_from = global_position
	_absorb_t = 0.0
	_sag = 0.0
	var r := GooMath.visual_radius(mass)
	var lift_dir := _normal if _normal != Vector2.ZERO else Vector2.UP
	_pull_lifted = _absorb_from + lift_dir * r * Tuning.goo_pull_lift
	var length := _pull_lifted.distance_to(_pull_entry())
	_pull_flight = clampf(length / maxf(Tuning.goo_pull_speed, 1.0), Tuning.goo_pull_flight_time.x, Tuning.goo_pull_flight_time.y)
	_pull_arc = GooMath.pull_arc(length)
	_pull_head = (_pull_entry() - _absorb_from).normalized()
	var natural := Tuning.goo_pull_stretch_time + _pull_flight
	var hold := maxf(min_total - natural, 0.0)
	_absorb_t = -hold
	_lean_dir = _pull_head
	_lean_target = 1.0
	velocity = Vector2.ZERO
	collision_layer = 0
	collision_mask = 0
	_wake()
	return hold + natural


## A full slime has no room: the goo shivers toward it and settles back.
func shiver() -> void:
	_wobble_vel += Tuning.goo_full_shiver
	_wake()


## The soil starts to take the piece: it flattens, darkens and drains over piece_soak_time, and leaves a damp stain.
func start_soak() -> void:
	if soaking or state == State.ABSORBING or is_queued_for_deletion() or mass <= 0.0:
		return
	_soak = 0.0
	_soak_mass = mass
	_wobble_vel += Tuning.piece_soak_kick
	_wake()
	if state != State.FLYING and is_instance_valid(Game.field):
		var r := GooMath.visual_radius(mass)
		var contact := global_position - _normal * (_shape.shape as CircleShape2D).radius
		Game.field.call(&"stain", contact, r * Tuning.goo_stain_size, _normal, Tuning.piece_soak_time)


func shred() -> void:
	if state == State.ABSORBING or is_queued_for_deletion():
		return
	if not decorative:
		Game.report_lost(mass, &"shredded")
	if is_instance_valid(Game.field):
		Game.field.call(&"burst", global_position, Tuning.piece_shred_burst_count, Tuning.piece_shred_burst_speed, Tuning.piece_shred_burst_radius, goo_color)
	Sfx.play(&"shred", global_position)
	mass = 0.0
	queue_free()


func _physics_process(delta: float) -> void:
	age += delta
	if _sense_ticks > 0:
		_sense_ticks -= 1
		if _sense_ticks == 0:
			_lean_target = 0.0
	match state:
		State.FLYING:
			velocity.y += Tuning.piece_gravity * delta
			velocity *= maxf(1.0 - Tuning.piece_air_drag * delta, 0.0)
			var hit := move_and_collide(velocity * delta)
			if hit:
				_on_hit(hit)
			_wake()
		State.CLINGING:
			_cling_timer -= delta
			_sag = clampf(1.0 - _cling_timer / _cling_total, 0.0, 1.0)
			_wake()
			if _cling_timer <= 0.0:
				if _normal.y > CEILING_NORMAL_Y:
					_release()
				else:
					state = State.SLIDING
		State.SLIDING:
			_sag = move_toward(_sag, Tuning.piece_slide_sag, delta * Tuning.piece_slide_sag_rate)
			var step := Tuning.piece_drip_speed * delta
			var hit := move_and_collide(Vector2(0.0, step))
			if hit and hit.get_normal().y < FLOOR_NORMAL_Y:
				_normal = hit.get_normal()
				state = State.RESTING
				_sag = 0.0
				_wobble_vel += Tuning.piece_splat_wobble * Tuning.piece_rest_wobble_share
			elif not test_move(global_transform, -_normal * 2.0):
				_release()
			else:
				_leave_trail(step)
			_wake()
		State.ABSORBING:
			if not _absorb_step(delta):
				return
	_update_life(delta)
	if global_position.y > Game.kill_y:
		if not decorative:
			Game.report_lost(mass, &"fell")
		mass = 0.0
		queue_free()


## Where the flight ends: inside the body, on the side the piece comes from.
func _pull_entry() -> Vector2:
	var center := _absorb_target.global_position
	var depth := 0.0
	if _absorb_target.has_method(&"goo_entry_radius"):
		depth = float(_absorb_target.call(&"goo_entry_radius"))
	var side := (_absorb_from - center).normalized()
	if side == Vector2.ZERO:
		side = Vector2.UP
	return center + side * depth


## Returns false when the piece handed its mass over and is gone.
func _absorb_step(delta: float) -> bool:
	if not is_instance_valid(_absorb_target) or _absorb_target.is_queued_for_deletion() or not _absorb_target.has_method(&"receive_goo"):
		_cancel_absorb()
		return true
	_absorb_t += delta
	if _absorb_t < 0.0:
		_lean_target = 1.0
		_sense_ticks = 2
		_wake()
		return true
	var stretch := Tuning.goo_pull_stretch_time
	var before := global_position
	var entry := _pull_entry()
	if _absorb_t < stretch:
		var k := _absorb_t / maxf(stretch, 0.001)
		global_position = _absorb_from.lerp(_pull_lifted, k * k)
		_pull_head = (entry - global_position).normalized()
	else:
		var u := clampf((_absorb_t - stretch) / maxf(_pull_flight, 0.001), 0.0, 1.0)
		global_position = GooMath.pull_point(_pull_lifted, entry, _pull_arc, pow(u, Tuning.goo_pull_accel_power))
		if u >= 1.0:
			var amount := mass
			mass = 0.0
			if decorative:
				if _absorb_target.has_method(&"swallow_droplets"):
					_absorb_target.call(&"swallow_droplets", 1, GooMath.visual_radius(amount), global_position)
			else:
				_absorb_target.call(&"receive_goo", amount, global_position, goo_color)
			queue_free()
			return false
	velocity = (global_position - before) / maxf(delta, 0.0001)
	_wake()
	return true


func _cancel_absorb() -> void:
	_absorb_target = null
	collision_layer = 0 if decorative else Tuning.LAYER_PIECES
	collision_mask = Tuning.LAYER_WORLD | Tuning.LAYER_PLATFORMS
	_release()


func _release() -> void:
	state = State.FLYING
	velocity = Vector2.ZERO
	_sag = 0.0
	_wake()


func _leave_trail(step: float) -> void:
	_trail_dist += step
	if _trail_dist < Tuning.piece_trail_step or not is_instance_valid(Game.field):
		return
	_trail_dist = 0.0
	var r := GooMath.visual_radius(mass)
	var at := global_position - _normal * r * 0.3 + Vector2(0.0, -r * 0.5)
	Game.field.call(&"drip", at, maxf(r * Tuning.piece_trail_radius_ratio, Tuning.piece_trail_min_radius) * _rng.randf_range(Tuning.piece_trail_radius_jitter.x, Tuning.piece_trail_radius_jitter.y), Tuning.goo_ground_life, _normal, goo_color)


func _update_life(delta: float) -> void:
	if state == State.ABSORBING or not _dries:
		return
	if not soaking:
		_life -= delta
		if _life <= 0.0:
			start_soak()
		return
	_soak += delta
	var t := clampf(_soak / maxf(Tuning.piece_soak_time, 0.01), 0.0, 1.0)
	var loss := mass - _soak_mass * (1.0 - t)
	if loss > 0.0:
		mass -= loss
		_drain(loss)
	_update_shape()
	_wake()
	if t >= 1.0 or mass <= DRY_REMOVE_MASS:
		_drain(mass)
		mass = 0.0
		if not decorative and _soaked > 0.0:
			# One event per piece with the whole sunk mass; each tick already booked its share silently.
			Game.goo_lost.emit(_soaked, &"soaked")
		queue_free()


func _drain(amount: float) -> void:
	if decorative or amount <= 0.0:
		return
	_soaked += amount
	Game.report_lost(amount, &"soaked", false)


func _on_hit(hit: KinematicCollision2D) -> void:
	var impact := velocity.length()
	_normal = hit.get_normal()
	velocity = Vector2.ZERO
	_wobble_vel = Tuning.piece_splat_wobble * clampf(impact / Tuning.piece_splat_speed_ref, Tuning.piece_splat_wobble_range.x, Tuning.piece_splat_wobble_range.y)
	_trail_dist = 0.0
	if _normal.y < FLOOR_NORMAL_Y:
		state = State.RESTING
		_sag = 0.0
	else:
		state = State.CLINGING
		_cling_total = maxf(_rng.randf_range(Tuning.piece_cling_time.x, Tuning.piece_cling_time.y), 0.01)
		_cling_timer = _cling_total
		_sag = 0.0
	var size := clampf(mass / Tuning.piece_drip_size_ref, 0.0, 1.0)
	Sfx.play(&"drip", global_position, lerpf(Tuning.piece_drip_pitch.x, Tuning.piece_drip_pitch.y, size), lerpf(Tuning.piece_drip_volume_db.x, Tuning.piece_drip_volume_db.y, size))
	if is_instance_valid(Game.field) and mass > Tuning.piece_splat_spray_mass:
		Game.field.call(&"spray", global_position, _normal, Tuning.piece_splat_spray_count, Tuning.piece_splat_spray_speed, Tuning.piece_splat_spray_spread, Tuning.piece_splat_spray_radius, Vector2.ZERO, goo_color)


func _update_shape() -> void:
	var circle := _shape.shape as CircleShape2D
	if circle:
		circle.radius = maxf(GooMath.visual_radius(mass) * Tuning.piece_collision_ratio, MIN_COLLISION_RADIUS)


func _process(delta: float) -> void:
	if _lean > 0.0 or _lean_target > 0.0:
		# The tremble redraws at goo_sense_redraw_hz, not in every frame.
		_lean = move_toward(_lean, _lean_target, delta * Tuning.goo_sense_rate)
		var step := int(age * Tuning.goo_sense_redraw_hz)
		if step != _tremble_step or _lean <= 0.0:
			_tremble_step = step
			_wake()
	if absf(_wobble) > WOBBLE_EPSILON or absf(_wobble_vel) > WOBBLE_EPSILON:
		_wobble_vel += (-_wobble * Tuning.piece_wobble_stiffness - _wobble_vel * Tuning.piece_wobble_damping) * delta
		_wobble += _wobble_vel * delta
		_wake()
	if _redraw:
		_redraw = false
		queue_redraw()
	elif _lean <= 0.0 and _lean_target <= 0.0 and absf(_wobble) <= WOBBLE_EPSILON and absf(_wobble_vel) <= WOBBLE_EPSILON:
		# Settled: nothing to animate until the next change wakes the piece.
		set_process(false)


## Something visible changed: redraw on the next frame.
func _wake() -> void:
	_redraw = true
	if not is_processing():
		set_process(true)


func _draw() -> void:
	var r := GooMath.visual_radius(mass)
	if r <= 0.0:
		return
	var ks := GooMath.kernel_scale()
	var kr := r * ks
	var tex := GooMath.kernel_texture()
	# Fast at first, so the sink reads from its first frames.
	var sink := 0.0
	var strength := 1.0
	if soaking and state != State.ABSORBING:
		var t := clampf(_soak / maxf(Tuning.piece_soak_time, 0.01), 0.0, 1.0)
		sink = 1.0 - (1.0 - t) * (1.0 - t)
		strength = GooMath.soak_strength(t)
	var color := Color(_code.r * strength, _code.g * strength, _code.b * strength, 1.0)
	var rot := 0.0
	var scale_v := Vector2.ONE
	var offset := Vector2.ZERO
	match state:
		State.ABSORBING when _absorb_t < 0.0:
			_draw_rest(tex, ks, r, color, 0.0)
			return
		State.ABSORBING:
			if _absorb_t < Tuning.goo_pull_stretch_time:
				_draw_stretch(tex, ks, r, color)
				return
			_draw_string(tex, ks, r, color)
			rot = velocity.angle()
			var s := 1.0 + Tuning.piece_absorb_stretch + clampf(velocity.length() * Tuning.piece_fly_stretch, 0.0, Tuning.piece_fly_stretch_max)
			scale_v = Vector2(s, 1.0 / s)
		State.FLYING:
			var s := 1.0 + clampf(velocity.length() * Tuning.piece_fly_stretch, 0.0, Tuning.piece_fly_stretch_max)
			rot = velocity.angle()
			s += _wobble * Tuning.piece_wobble_squash * 0.5
			scale_v = Vector2(s, 1.0 / s)
		_:
			if _lean > 0.01 and _sag <= 0.0:
				_draw_rest(tex, ks, r, color, sink)
				return
			rot = _normal.angle()
			var flat := lerpf(Tuning.piece_rest_flat, Tuning.piece_soak_flat, sink) - _wobble * Tuning.piece_wobble_squash
			scale_v = Vector2(flat, 1.0 / flat)
			offset = -_normal * r * (0.25 + Tuning.piece_soak_sink * sink)
	draw_set_transform(offset, rot, scale_v)
	draw_texture_rect(tex, Rect2(-kr, -kr, kr * 2.0, kr * 2.0), false, color)
	if _sag > 0.0:
		# A drop that gathers below the blob and hangs on a goo neck before it lets go.
		var drop_r := r * (0.3 + 0.25 * _sag) * ks
		var drop_at := offset + Vector2(0.0, r * (0.45 + 0.65 * _sag))
		draw_set_transform(drop_at, 0.0, Vector2(1.0 - 0.15 * _sag, 1.0 + 0.25 * _sag))
		draw_texture_rect(tex, Rect2(-drop_r, -drop_r, drop_r * 2.0, drop_r * 2.0), false, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## The first phase of a pull: the base still holds the ground while a head reaches toward the body; the field joins
## the two into one stretched neck of goo.
func _draw_stretch(tex: Texture2D, ks: float, r: float, color: Color) -> void:
	var k := clampf(_absorb_t / maxf(Tuning.goo_pull_stretch_time, 0.001), 0.0, 1.0)
	var base := to_local(_absorb_from)
	var base_r := r * lerpf(1.0, 0.6, k) * ks
	draw_set_transform(base, _normal.angle(), Vector2(Tuning.piece_rest_flat, 1.0 / Tuning.piece_rest_flat))
	draw_texture_rect(tex, Rect2(-base_r, -base_r, base_r * 2.0, base_r * 2.0), false, color)
	var head := _pull_head * r * Tuning.goo_pull_head_stretch * k
	var s := 1.0 + Tuning.piece_absorb_stretch * k
	var head_r := r * lerpf(0.75, 0.85, k) * ks
	draw_set_transform(head, _pull_head.angle(), Vector2(s, 1.0 / s))
	draw_texture_rect(tex, Rect2(-head_r, -head_r, head_r * 2.0, head_r * 2.0), false, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Goo at rest that senses the slime: it trembles and a bump of it leans toward the body; the field joins the two.
func _draw_rest(tex: Texture2D, ks: float, r: float, color: Color, sink: float) -> void:
	var lean := clampf(_lean, 0.0, 1.0)
	var shake := sin(floorf(age * Tuning.goo_sense_redraw_hz) / Tuning.goo_sense_redraw_hz * Tuning.goo_sense_tremble_hz * TAU) * r * Tuning.goo_sense_tremble * lean
	var along := Vector2(-_normal.y, _normal.x)
	var base := (to_local(_absorb_from) if state == State.ABSORBING else Vector2.ZERO) - _normal * r * (0.25 + Tuning.piece_soak_sink * sink) + along * shake
	var flat := lerpf(Tuning.piece_rest_flat, Tuning.piece_soak_flat, sink) - _wobble * Tuning.piece_wobble_squash
	var kr := r * ks * lerpf(1.0, 0.85, lean)
	draw_set_transform(base, _normal.angle(), Vector2(flat, 1.0 / flat))
	draw_texture_rect(tex, Rect2(-kr, -kr, kr * 2.0, kr * 2.0), false, color)
	var head := base + _lean_dir * r * Tuning.goo_sense_lean * lean
	var head_r := r * ks * lerpf(0.4, 0.62, lean)
	draw_set_transform(head, _lean_dir.angle(), Vector2(1.0 + 0.3 * lean, 1.0 / (1.0 + 0.3 * lean)))
	draw_texture_rect(tex, Rect2(-head_r, -head_r, head_r * 2.0, head_r * 2.0), false, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## In flight a thin string of goo still joins the piece to the body; it thins out and snaps in with the piece.
func _draw_string(tex: Texture2D, ks: float, r: float, color: Color) -> void:
	if not is_instance_valid(_absorb_target):
		return
	var to := to_local(_pull_entry())
	var length := to.length()
	var bead := Tuning.goo_string_radius
	if length <= bead * 2.0:
		return
	var u := clampf((_absorb_t - Tuning.goo_pull_stretch_time) / maxf(_pull_flight, 0.001), 0.0, 1.0)
	var count := mini(int(length / (bead * Tuning.goo_string_spacing)), Tuning.goo_string_beads)
	var kr := bead * lerpf(1.0, 0.7, u) * ks
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	for i: int in count:
		var at := to * (float(i + 1) / float(count + 1))
		draw_texture_rect(tex, Rect2(at.x - kr, at.y - kr, kr * 2.0, kr * 2.0), false, color)
