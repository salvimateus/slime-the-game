extends Node2D
## Soft-body outline of the player, drawn as one deformed kernel fan into the goo field.

const GooMath := preload("res://scripts/goo/goo_math.gd")
const STEP := 1.0 / 120.0
const MIN_POINTS := 8
## Face height, in body radii, when the body is no larger than the face.
const FACE_HEIGHT_SMALL := 0.22
## Stable layout of deform_state(): radius is the body radius, r the radius with swell; the rest are the inputs of
## _shape_point() and _deform() (squash sx/sy, crawl stretch ex/ey and shift, wall press, ceiling dent, lean, frost,
## aim pull and direction, roll angle and pivot). Add new values at the end, before COUNT.
enum DeformState { RADIUS, R, SX, SY, EX, EY, CRAWL_DX, PRESS, PRESS_SIDE, FEET, CEIL, LEAN, FROST, AIM_PULL, AIM_X, AIM_Y, ROLL, PIVOT_X, PIVOT_Y, COUNT }

var _n := 32
var _dirs := PackedVector2Array()
var _points := PackedVector2Array()
var _radial := PackedFloat32Array()
var _radial_vel := PackedFloat32Array()
var _squash := 0.0
var _squash_vel := 0.0
var _lean := 0.0
var _lean_vel := 0.0
var _radius := 0.0
var _radius_vel := 0.0
var _target_radius := 0.0
var _velocity := Vector2.ZERO
var _on_floor := false
var _danger := 0.0
var _feet := 0.0
var _flash := 0.0
var _pulse := 0.0
var _dead := false
var _time := 0.0
var _acc := 0.0
var _step_side := 1.0
var _center := Vector2.ZERO
var _scale_xy := Vector2.ONE
var _fan_points := PackedVector2Array()
var _fan_uvs := PackedVector2Array()
var _fan_colors := PackedColorArray()
var _fan_indices := PackedInt32Array()
var _drawn := false

# Crawl input from the player (physics ticks) and its per-frame shape.
var _crawl_prev := 0.0
var _crawl_curr := 0.0
var _crawl_target := 0.0
var _crawl_amount := 0.0
var _crawl_dir := 1.0

# Aim pull: direction toward the target and a spring that is positive while pulled back, negative when it snaps forward.
var _aim_dir := Vector2.RIGHT
var _aim_target := 0.0
var _aim_pull := 0.0
var _aim_pull_vel := 0.0

# Per-frame deformation parameters, written by _rebuild and read by _deform.
var _r := 0.0
var _sx := 1.0
var _sy := 1.0
var _ex := 1.0
var _ey := 1.0
var _crawl_dx := 0.0
var _hump := 0.0
var _hump_at := 0.0

# Move poses from the player (physics ticks), smoothed per frame. Crouch rides a spring for a jelly settle.
var _run := 0.0
var _run_target := 0.0
var _crouch := 0.0
var _crouch_vel := 0.0
var _crouch_target := 0.0
var _skid := 0.0
var _skid_target := 0.0
var _skid_dir := 1.0
var _wall := 0.0
var _wall_target := 0.0
var _wall_side := 1.0
var _ball := 0.0
var _ball_target := 0.0
var _roll_prev := 0.0
var _roll_curr := 0.0
## Roll angle of this frame and the point it turns about (the centre before the turn).
var _roll := 0.0
var _pivot := Vector2.ZERO
## Seconds to the pop of a double jump, below zero when none is pending.
var _pop_timer := -1.0
## 0 for the heavy full-mass body, 1 for the light one: stiffer, faster springs.
var _agility := 0.0
# Contact squash: the head flattened by a ceiling hit, and the body pressed against a wall on the floor.
var _ceil := 0.0
var _ceil_vel := 0.0
var _press := 0.0
var _press_vel := 0.0
var _press_target := 0.0
var _press_side := 1.0
# Temperature from the player, smoothed per frame: melt flattens and loosens the body, frost stiffens it into a cube.
var _melt := 0.0
var _melt_target := 0.0
var _frost := 0.0
var _frost_target := 0.0
## Outline direction of each point on the ice cube (a superellipse), matched to _dirs by index.
var _cube_dirs := PackedVector2Array()
## Grow pulse after a swallow with mass: a radius overshoot on its own spring.
var _grow := 0.0
var _grow_vel := 0.0
## Seconds since the outline was last rebuilt while the body rests (only the breath moves it then).
var _rest_wait := 0.0
var _resting := false
var _deform_state := PackedFloat32Array()
## False while every radial offset and speed is exactly zero: the ring springs are skipped until the next kick.
var _radial_live := true


func _ready() -> void:
	_n = maxi(Tuning.body_points, MIN_POINTS)
	_dirs.resize(_n)
	_points.resize(_n)
	_radial.resize(_n)
	_radial_vel.resize(_n)
	_fan_points.resize(_n + 1)
	_fan_uvs.resize(_n + 1)
	_fan_colors.resize(_n + 1)
	_fan_indices.resize(_n * 3)
	_cube_dirs.resize(_n)
	_fan_uvs[0] = Vector2(0.5, 0.5)
	for i: int in _n:
		_dirs[i] = Vector2.from_angle(TAU * i / _n)
		_cube_dirs[i] = _cube_dir(_dirs[i])
		_fan_uvs[i + 1] = Vector2(0.5, 0.5) + _dirs[i] * 0.5
		_fan_indices[i * 3] = 0
		_fan_indices[i * 3 + 1] = i + 1
		_fan_indices[i * 3 + 2] = (i + 1) % _n + 1
	material = GooMath.additive_material()


func set_motion(velocity: Vector2, on_floor: bool, target_radius: float, danger: float, feet: float) -> void:
	var dvx := velocity.x - _velocity.x
	if absf(dvx) > Tuning.body_inertia_min_change and not _dead:
		_kick(Vector2(-signf(dvx), 0.0), absf(dvx) * Tuning.body_inertia_kick, 0.6)
		_lean_vel -= dvx * Tuning.body_lean_accel_impulse
	if not _dead and on_floor and absf(_velocity.x) > Tuning.body_turn_min_speed and signf(velocity.x) != signf(_velocity.x):
		# A turn sends a wave through the body: the old leading side bulges, then the ripple travels around.
		_kick(Vector2(signf(_velocity.x), -0.3), Tuning.body_turn_ripple, 0.5)
		_squash_vel += Tuning.body_turn_squash_kick
	_velocity = velocity
	_on_floor = on_floor
	_target_radius = 0.0 if _dead else target_radius
	_danger = danger
	_feet = feet


## Crawl state from the player, once per physics tick: an unbounded cycle counter (one unit per cycle), the gait strength and the walk direction.
func set_crawl(cycle: float, amount: float, dir: float) -> void:
	_crawl_prev = _crawl_curr
	_crawl_curr = cycle
	if absf(_crawl_curr - _crawl_prev) > 1.0:
		_crawl_prev = _crawl_curr
	_crawl_target = clampf(amount, 0.0, 1.0)
	if dir != 0.0:
		_crawl_dir = signf(dir)


## Move pose from the player, once per physics tick: run share 0..1, crouched, the skid travel direction (0 when no
## skid), the side of the held wall (0 when none), the roll angle and whether the body is a rolling ball.
## press is signed: the side of the wall the body is pushed against times the push share 0..1.
func set_pose(run: float, crouched: bool, skid_dir: float, wall_side: float, roll_angle: float, ball: bool, press: float, agility: float) -> void:
	_agility = clampf(agility, 0.0, 1.0)
	_press_target = clampf(absf(press), 0.0, 1.0) if not _dead else 0.0
	if press != 0.0:
		_press_side = signf(press)
	_run_target = clampf(run, 0.0, 1.0)
	_crouch_target = 1.0 if crouched and not _dead else 0.0
	_skid_target = 1.0 if skid_dir != 0.0 else 0.0
	if skid_dir != 0.0:
		_skid_dir = signf(skid_dir)
	_wall_target = 1.0 if wall_side != 0.0 else 0.0
	if wall_side != 0.0:
		_wall_side = signf(wall_side)
	_ball_target = 1.0 if ball else 0.0
	_roll_prev = _roll_curr
	_roll_curr = roll_angle
	if absf(_roll_curr - _roll_prev) > PI:
		_roll_prev = _roll_curr


## Temperature from the player, once per physics tick: melt and frost, each 0..1.
func set_temperature(melt: float, frost: float) -> void:
	_melt_target = clampf(melt, 0.0, 1.0)
	_frost_target = clampf(frost, 0.0, 1.0)


## A point on the drawn outline toward dir from the body centre, without the wobble: for effects on the surface.
func surface_point(dir: Vector2) -> Vector2:
	var d := dir.normalized()
	return _deform(d.lerp(_cube_dir(d), _frost) * _r)


## Second jump in the air: the body squeezes, then pops tall with a swell a moment later.
func double_jump() -> void:
	if _dead:
		return
	_squash_vel += Tuning.body_double_squeeze
	_pop_timer = Tuning.body_double_pop_delay


## Dodge or roll start toward dir: a flat squash, the front bulges, the back gathers and the top trails.
func dodge(dir: float, strength: float) -> void:
	if _dead or dir == 0.0:
		return
	_squash_vel += Tuning.body_dodge_squash * strength
	_kick(Vector2(dir, 0.2), Tuning.body_dodge_ripple * strength, 0.45)
	_kick(Vector2(-dir, 0.0), -Tuning.body_dodge_ripple * 0.6 * strength, 0.5)
	_lean_vel -= dir * Tuning.body_dodge_lean * strength


## One beat of the run cost: the side that loses the drop pinches in and the body twitches.
func drain_pulse(dir: Vector2, strength: float) -> void:
	if _dead:
		return
	_kick(dir, -Tuning.body_drain_pinch * strength, 0.35)
	_squash_vel += Tuning.body_drain_twitch * strength


## Something fell in from dir (body centre to the entry point): the entry dents in and rings round the body.
func splash_in(dir: Vector2, strength: float) -> void:
	if _dead or dir == Vector2.ZERO:
		return
	var s := clampf(strength, 0.0, 1.0)
	_kick(dir, -Tuning.body_splash_dent * s, Tuning.body_splash_width)
	_kick(-dir, Tuning.body_splash_dent * 0.35 * s, 0.5)
	_squash_vel += Tuning.body_splash_squash * s * maxf(-dir.y, 0.2)
	_radius_vel += Tuning.body_splash_swell * s


## Turn of the drawn body about its centre this frame (identity unless it rolls); the face applies it to itself.
func spin() -> Transform2D:
	return Transform2D(_roll, _pivot - _pivot.rotated(_roll))


func pop_in(radius: float) -> void:
	_radius = 0.0
	_radius_vel = radius * Tuning.body_pop_in_speed
	_target_radius = radius
	_squash = 0.0
	_squash_vel = 0.0
	_lean = 0.0
	_lean_vel = 0.0
	_crawl_amount = 0.0
	_crawl_target = 0.0
	_velocity = Vector2.ZERO
	_run = 0.0
	_run_target = 0.0
	_crouch = 0.0
	_crouch_vel = 0.0
	_crouch_target = 0.0
	_skid = 0.0
	_skid_target = 0.0
	_wall = 0.0
	_wall_target = 0.0
	_ball = 0.0
	_ball_target = 0.0
	_roll_prev = 0.0
	_roll_curr = 0.0
	_pop_timer = -1.0
	_melt = _melt_target
	_frost = _frost_target
	_ceil = 0.0
	_ceil_vel = 0.0
	_press = 0.0
	_press_vel = 0.0
	_press_target = 0.0
	_radial.fill(0.0)
	_radial_vel.fill(0.0)
	_grow = 0.0
	_grow_vel = 0.0


func land(impact: float) -> void:
	var s := clampf(impact * Tuning.body_land_squash, 0.0, Tuning.body_land_squash_max)
	_squash_vel += s * Tuning.body_land_kick
	_kick(Vector2.DOWN, -s * Tuning.body_land_ripple, 0.6)


func jump() -> void:
	_squash_vel -= Tuning.body_jump_kick


func hit(dir: Vector2, strength: float) -> void:
	_flash = 1.0
	_kick(-dir, -Tuning.body_hit_ripple * strength, 0.5)
	_squash_vel += Tuning.body_hit_squash * strength


## The body just took in mass: it swells past its new size and settles back with a jelly wobble.
func grow(strength: float) -> void:
	if _dead:
		return
	_grow_vel += Tuning.body_grow_kick * clampf(strength, 0.0, 1.0) * (1.0 - 0.9 * _frost)


func gulp(dir: Vector2, strength: float) -> void:
	_kick(dir, Tuning.body_gulp_ripple * strength, 0.45)
	_radius_vel += Tuning.body_gulp_swell * strength


func wall_splat(normal: Vector2, strength: float) -> void:
	_kick(-normal, -Tuning.body_wall_splat_ripple * strength, 0.5)
	if absf(normal.x) > 0.5 and not _dead:
		_press_side = -signf(normal.x)
		_press_vel += Tuning.body_splat_press_kick * strength


## One crawl pulse, called at the start of every gather phase: a small upward stretch plus a ripple that alternates sides of the base.
func step() -> void:
	if _dead:
		return
	_squash_vel -= Tuning.body_step_squash_kick
	_step_side = -_step_side
	_kick(Vector2(_step_side * 0.7, 0.7), Tuning.body_step_ripple, 0.5)
	_kick(Vector2(-_step_side * 0.4, -0.9), Tuning.body_step_ripple * 0.6, 0.5)


## Spitting a prop: the mouth side bulges toward dir, the back compresses and the top kicks back like a recoil.
func spit(dir: Vector2, strength: float) -> void:
	if _dead or dir == Vector2.ZERO:
		return
	_kick(dir, Tuning.body_spit_ripple * strength, 0.4)
	_kick(-dir, -Tuning.body_spit_back * strength, 0.5)
	_squash_vel += Tuning.body_spit_squash * strength
	_lean_vel -= dir.x * Tuning.body_spit_lean * strength


## Slingshot pull for the aim: dir points at the target, pull is 0..1 (0 when the aim is closed).
func set_aim(dir: Vector2, pull: float) -> void:
	if dir != Vector2.ZERO:
		_aim_dir = dir.normalized()
	_aim_target = 0.0 if _dead else clampf(pull, 0.0, 1.0)


## The pulled body lets go: the spring overshoots so the body snaps toward the target.
func release_aim(strength: float) -> void:
	_aim_target = 0.0
	_aim_pull_vel += Tuning.body_aim_release_kick * clampf(strength, 0.0, 1.0) * Tuning.body_aim_stiffness * 0.05


func bonk(strength: float) -> void:
	_squash_vel += Tuning.body_bonk_squash * strength


## Head hit on a ceiling: the top flattens as deep as the hit was fast, the sides bulge, then it wobbles back.
func ceiling_hit(strength: float) -> void:
	if _dead:
		return
	# The dent is there at once, as deep as the hit was fast; the spring then lets it go with a wobble.
	_ceil = maxf(_ceil, clampf(strength, 0.0, 1.0) * Tuning.body_ceiling_kick)
	_ceil_vel = 0.0
	_kick(Vector2.UP, -Tuning.body_ceiling_ripple * strength, 0.6)


func pulse() -> void:
	_pulse = 1.0


func set_dead(dead: bool) -> void:
	_dead = dead
	if dead:
		_radius = 0.0
		_radius_vel = 0.0
		_target_radius = 0.0
		_crawl_amount = 0.0
		_crawl_target = 0.0


func radius() -> float:
	return _radius


## Centre of the face: the upper centre of a large body; on a body no larger than the face it sits lower to fit.
func face_anchor() -> Vector2:
	var room := clampf((_r - Tuning.face_radius) / maxf(Tuning.face_radius, 1.0), 0.0, 1.0)
	var shift := Vector2(-_press_side * maxf(_press, 0.0) * Tuning.body_press_face_shift * _r, 0.0)
	return _shape_point(Vector2(0.0, -_r * lerpf(FACE_HEIGHT_SMALL, Tuning.body_face_height, room))) + shift


## Maps a body-local point of the round body (centre at the origin) to where it sits on the drawn, deformed body.
func deform_point(p: Vector2) -> Vector2:
	return _deform(p)


## Deformation state of this frame, in the layout of DeformState: every input of deform_point(). Other nodes that
## follow the outline (the cargo shader) read only this. cargo.gd mirrors _deform() for its shader and checks it.
func deform_state() -> PackedFloat32Array:
	if _deform_state.size() != DeformState.COUNT:
		_deform_state.resize(DeformState.COUNT)
	_deform_state[DeformState.RADIUS] = _radius
	_deform_state[DeformState.R] = _r
	_deform_state[DeformState.SX] = _sx
	_deform_state[DeformState.SY] = _sy
	_deform_state[DeformState.EX] = _ex
	_deform_state[DeformState.EY] = _ey
	_deform_state[DeformState.CRAWL_DX] = _crawl_dx
	_deform_state[DeformState.PRESS] = _press
	_deform_state[DeformState.PRESS_SIDE] = _press_side
	_deform_state[DeformState.FEET] = _feet
	_deform_state[DeformState.CEIL] = _ceil
	_deform_state[DeformState.LEAN] = _lean
	_deform_state[DeformState.FROST] = _frost
	_deform_state[DeformState.AIM_PULL] = _aim_pull
	_deform_state[DeformState.AIM_X] = _aim_dir.x
	_deform_state[DeformState.AIM_Y] = _aim_dir.y
	_deform_state[DeformState.ROLL] = _roll
	_deform_state[DeformState.PIVOT_X] = _pivot.x
	_deform_state[DeformState.PIVOT_Y] = _pivot.y
	return _deform_state


## Sets the deformation inputs from a DeformState array, until the next frame builds them again. For checks only.
func set_deform_state(s: PackedFloat32Array) -> void:
	_radius = s[DeformState.RADIUS]
	_r = s[DeformState.R]
	_sx = s[DeformState.SX]
	_sy = s[DeformState.SY]
	_ex = s[DeformState.EX]
	_ey = s[DeformState.EY]
	_crawl_dx = s[DeformState.CRAWL_DX]
	_press = s[DeformState.PRESS]
	_press_side = s[DeformState.PRESS_SIDE]
	_feet = s[DeformState.FEET]
	_ceil = s[DeformState.CEIL]
	_lean = s[DeformState.LEAN]
	_frost = s[DeformState.FROST]
	_aim_pull = s[DeformState.AIM_PULL]
	_aim_dir = Vector2(s[DeformState.AIM_X], s[DeformState.AIM_Y])
	_roll = s[DeformState.ROLL]
	_pivot = Vector2(s[DeformState.PIVOT_X], s[DeformState.PIVOT_Y])


func face_scale() -> Vector2:
	return _scale_xy * (_radius / maxf(Tuning.radius_full, 1.0))


func _kick(dir: Vector2, amount: float, width: float) -> void:
	if dir == Vector2.ZERO:
		return
	var d := dir.normalized()
	var exponent := 1.0 / maxf(width, 0.05)
	# Ice barely gives: a frozen body takes only a tenth of a kick.
	var give := 1.0 - 0.9 * _frost
	_radial_live = true
	for i: int in _n:
		var w := pow(maxf(_dirs[i].dot(d), 0.0), exponent)
		_radial_vel[i] += amount * w * Tuning.body_kick_scale * give


func _process(delta: float) -> void:
	_time += delta
	_acc = minf(_acc + delta, 0.1)
	while _acc >= STEP:
		_step(STEP)
		_acc -= STEP
	_flash = maxf(_flash - delta * Tuning.body_flash_decay, 0.0)
	_pulse = maxf(_pulse - delta * Tuning.body_pulse_decay, 0.0)
	var crawl_goal := _crawl_target if _on_floor and not _dead else 0.0
	_crawl_amount = lerpf(_crawl_amount, crawl_goal, 1.0 - exp(-delta * Tuning.crawl_smooth))
	var pose_k := 1.0 - exp(-delta * Tuning.body_pose_smooth)
	_run = lerpf(_run, _run_target, pose_k)
	_skid = lerpf(_skid, _skid_target, pose_k)
	_wall = lerpf(_wall, _wall_target, pose_k)
	_ball = lerpf(_ball, _ball_target, pose_k)
	var temp_k := 1.0 - exp(-delta * Tuning.temp_body_smooth)
	_melt = lerpf(_melt, _melt_target, temp_k)
	_frost = lerpf(_frost, _frost_target, temp_k)
	if _pop_timer >= 0.0:
		_pop_timer -= delta
		if _pop_timer < 0.0 and not _dead:
			_squash_vel -= Tuning.body_double_pop
			_radius_vel += Tuning.body_double_pop_swell
			_kick(Vector2.DOWN, -Tuning.body_double_pop_ripple, 0.5)
			_kick(Vector2.UP, Tuning.body_double_pop_ripple, 0.6)
	if _radius <= 0.5 and not _drawn:
		return
	# A body at rest only breathes: its outline is rebuilt at body_rest_redraw_hz, not in every frame.
	_resting = _at_rest()
	if _resting:
		_rest_wait += delta
		if _rest_wait < 1.0 / maxf(Tuning.body_rest_redraw_hz, 1.0):
			return
	_rest_wait = 0.0
	_rebuild()
	queue_redraw()


## Nothing moves the body but the breath: no motion, no pose blend in progress and every spring settled.
func _at_rest() -> bool:
	const EPS := 0.002
	if _dead or _velocity.length_squared() > 1.0 or _pop_timer >= 0.0 or _crawl_amount > EPS or _ball > EPS:
		return false
	if absf(_radius - _target_radius) > 0.05 or absf(_radius_vel) > 0.5 or absf(_lean_vel) > 0.01 or absf(_lean) > EPS:
		return false
	if absf(_squash_vel) > 0.4 or absf(_crouch_vel) > EPS or absf(_crouch - _crouch_target) > EPS:
		return false
	if absf(_grow) > EPS or absf(_grow_vel) > 0.01 or _pulse > 0.0 or _flash > 0.0 or absf(_aim_pull) > EPS or absf(_aim_pull_vel) > 0.01:
		return false
	if absf(_ceil) > EPS or absf(_press) > EPS or absf(_press_target) > 0.0 or absf(_run - _run_target) > EPS or absf(_skid - _skid_target) > EPS:
		return false
	if absf(_wall - _wall_target) > EPS or absf(_melt - _melt_target) > EPS or absf(_frost - _frost_target) > EPS:
		return false
	if _radial_live:
		for i: int in _n:
			if absf(_radial_vel[i]) > 0.01 or absf(_radial[i]) > EPS:
				return false
		# Below the visible threshold: snap the ring to rest, so its springs stop running.
		_radial.fill(0.0)
		_radial_vel.fill(0.0)
		_radial_live = false
	return true


func _step(dt: float) -> void:
	# A light body has stiffer springs; damping grows with the square root, so it settles quicker.
	var ks := (1.0 + Tuning.agility_body * _agility) * lerpf(1.0, Tuning.melt_wobble_stiffness, _melt)
	var kd := sqrt(ks)
	_radius_vel += ((_target_radius - _radius) * Tuning.body_radius_stiffness - _radius_vel * Tuning.body_radius_damping) * dt
	_radius = maxf(_radius + _radius_vel * dt, 0.0)
	var target_squash := 0.0
	if _on_floor:
		target_squash = sin(_time * TAU * Tuning.body_breath_hz) * Tuning.body_breath_amp
	else:
		target_squash = -clampf(absf(_velocity.y) * Tuning.body_air_stretch, 0.0, Tuning.body_air_stretch_max)
	target_squash *= 1.0 - _ball
	_squash_vel += ((target_squash - _squash) * Tuning.body_squash_stiffness * ks - _squash_vel * Tuning.body_squash_damping * kd) * dt
	_squash = clampf(_squash + _squash_vel * dt, -0.45, 0.6)
	# The top leans forward into the motion, more while running; the skid brakes, so its top leans back.
	var lean_max := maxf(lerpf(Tuning.body_lean_max, Tuning.body_run_lean_max, _run), Tuning.body_skid_lean * _skid)
	var target_lean := clampf(_velocity.x * Tuning.body_lean * lerpf(1.0, Tuning.body_run_lean, _run), -lean_max, lean_max)
	target_lean = lerpf(target_lean, -_skid_dir * Tuning.body_skid_lean, _skid)
	target_lean *= 1.0 - _ball
	_lean_vel += ((target_lean - _lean) * Tuning.body_lean_stiffness * ks - _lean_vel * Tuning.body_lean_damping * kd) * dt
	_lean = clampf(_lean + _lean_vel * dt, -lean_max, lean_max)
	_crouch_vel += ((_crouch_target - _crouch) * Tuning.body_crouch_stiffness * ks - _crouch_vel * Tuning.body_crouch_damping * kd) * dt
	_crouch = clampf(_crouch + _crouch_vel * dt, -0.2, 1.25)
	_ceil_vel += (-_ceil * Tuning.body_ceiling_stiffness * ks - _ceil_vel * Tuning.body_ceiling_damping * kd) * dt
	_ceil = clampf(_ceil + _ceil_vel * dt, -0.35, 1.0)
	var press_goal := _press_target * (1.0 + Tuning.body_press_breath * sin(_time * TAU * Tuning.body_press_breath_hz))
	_press_vel += ((press_goal - _press) * Tuning.body_press_stiffness * ks - _press_vel * Tuning.body_press_damping * kd) * dt
	_press = clampf(_press + _press_vel * dt, -0.3, 1.3)
	_aim_pull_vel += ((_aim_target - _aim_pull) * Tuning.body_aim_stiffness - _aim_pull_vel * Tuning.body_aim_damping) * dt
	_grow_vel += (-_grow * Tuning.body_grow_stiffness * ks - _grow_vel * Tuning.body_grow_damping * kd) * dt
	_grow = clampf(_grow + _grow_vel * dt, -0.12, 0.3)
	_aim_pull = clampf(_aim_pull + _aim_pull_vel * dt, -0.6, 1.2)
	if not _radial_live:
		return
	var stiff := Tuning.body_wobble_stiffness * ks
	var couple := Tuning.body_wobble_coupling * ks
	var damp := Tuning.body_wobble_damping * kd
	var last := _n - 1
	# Neighbours wrap round the ring; the two end points are handled out of the loop, so no modulo runs in it.
	_radial_vel[0] += (-_radial[0] * stiff + ((_radial[last] + _radial[1]) * 0.5 - _radial[0]) * couple - _radial_vel[0] * damp) * dt
	for i: int in range(1, last):
		var here := _radial[i]
		_radial_vel[i] += (-here * stiff + ((_radial[i - 1] + _radial[i + 1]) * 0.5 - here) * couple - _radial_vel[i] * damp) * dt
	_radial_vel[last] += (-_radial[last] * stiff + ((_radial[last - 1] + _radial[0]) * 0.5 - _radial[last]) * couple - _radial_vel[last] * damp) * dt
	for i: int in _n:
		_radial[i] = clampf(_radial[i] + _radial_vel[i] * dt, -0.5, 0.6)


func _rebuild() -> void:
	_r = _radius * (1.0 + _pulse * Tuning.body_pulse_swell + _grow)
	_roll = lerpf(_roll_prev, _roll_curr, Engine.get_physics_interpolation_fraction())
	_sy = 1.0 - _squash
	_sx = 1.0 / maxf(_sy, 0.3)
	_sx *= lerpf(1.0, Tuning.body_crouch_sx, _crouch) * (1.0 + Tuning.body_skid_stretch * _skid)
	_sy *= lerpf(1.0, Tuning.body_crouch_sy, _crouch) * (1.0 - Tuning.body_skid_stretch * _skid)
	_sx *= lerpf(1.0, Tuning.melt_body_sx, _melt)
	_sy *= lerpf(1.0, Tuning.melt_body_sy, _melt)
	# Frozen: the squash, skid and crawl stop; only the crouch slab a body froze in stays.
	_sx = lerpf(_sx, lerpf(1.0, Tuning.body_crouch_sx, _crouch), _frost)
	_sy = lerpf(_sy, lerpf(1.0, Tuning.body_crouch_sy, _crouch), _frost)
	_update_crawl()
	if _frost > 0.0:
		_ex = lerpf(_ex, 1.0, _frost)
		_ey = 1.0 / _ex
		_crawl_dx *= 1.0 - _frost
		_hump *= 1.0 - _frost
	_scale_xy = Vector2(_sx * _ex, _sy * _ey)
	_pivot = _shape_point(Vector2.ZERO)
	_center = _pivot
	var foot_y := _feet + Tuning.body_floor_sink
	var base_x := _deform(Vector2(0.0, _r)).x + _skid_dir * Tuning.body_skid_foot_shift * _r * _skid
	var sag := Tuning.body_foot_sag * lerpf(1.0, Tuning.body_ball_sag, _ball) * (1.0 - _frost)
	var wobble := 1.0 - _frost
	var hump_angle := -PI * 0.5 + _hump_at * _crawl_dir
	var hump_width := maxf(Tuning.crawl_hump_width, 0.05)
	for i: int in _n:
		var radial := 1.0 + _radial[i] * wobble
		if _hump > 0.0:
			var off := absf(angle_difference(hump_angle, TAU * i / _n))
			if off < hump_width:
				radial += _hump * (0.5 + 0.5 * cos(PI * off / hump_width))
		var local := _dirs[i].lerp(_cube_dirs[i], _frost) * _r * radial
		if _on_floor and _dirs[i].y > 0.0:
			local.y += sag * _r * _dirs[i].y * _dirs[i].y
		var p := _deform(local)
		if maxf(_wall, _press) > 0.01:
			p = _settle_wall(p)
		if _ceil > 0.01:
			p = _settle_ceiling(p)
		if _on_floor:
			p = _settle_foot(p, foot_y, base_x)
		_points[i] = p


## Slug foot: points near the floor flare outward, then a soft minimum flattens them onto the floor with round corners.
func _settle_foot(p: Vector2, foot_y: float, base_x: float) -> Vector2:
	var flare_top := foot_y - Tuning.body_foot_flare_height * _r
	var f := smoothstep(flare_top, foot_y, p.y)
	f *= f
	var flare := Tuning.body_foot_flare * lerpf(1.0, Tuning.body_ball_flare, _ball) * (1.0 - _frost)
	if (p.x - base_x) * _skid_dir > 0.0:
		flare *= 1.0 + Tuning.body_skid_flare * _skid
	p.x = base_x + (p.x - base_x) * (1.0 + flare * f)
	var k := maxf(Tuning.body_foot_round * _r, 0.01)
	var gap := (foot_y - p.y) / k
	# Soft minimum of p.y and foot_y; written so that large gaps do not overflow exp().
	if gap > 0.0:
		p.y = p.y - k * log(1.0 + exp(-gap))
	else:
		p.y = foot_y - k * log(1.0 + exp(gap))
	return p


## Crawl shape for this frame. sin > 0 is the reach half, sin < 0 the gather half; ex * ey = 1 keeps the area.
func _update_crawl() -> void:
	var cycle := lerpf(_crawl_prev, _crawl_curr, Engine.get_physics_interpolation_fraction())
	var wave := sin(TAU * cycle)
	var gait := _crawl_amount * (1.0 - _ball)
	var stretch := Tuning.crawl_stretch * lerpf(1.0, Tuning.body_run_stretch, _run)
	var depth := stretch * gait * (1.0 if wave >= 0.0 else Tuning.crawl_gather_share)
	_ex = 1.0 + depth * wave
	_ey = 1.0 / _ex
	# Reach keeps the rear in place and pushes the front out; gather keeps the front and pulls the rear in.
	# The mean of |sin| is 2 / PI, so the drawn body stays centred on the collider over a full cycle.
	var lead := absf(_ex - 1.0) - stretch * gait * (1.0 + Tuning.crawl_gather_share) / PI
	_crawl_dx = lead * _r * _crawl_dir
	if wave < 0.0:
		_hump = Tuning.crawl_hump * lerpf(1.0, Tuning.body_run_hump, _run) * gait * -wave
		_hump_at = lerpf(-0.8, 0.8, fposmod(cycle, 1.0) * 2.0 - 1.0)
	else:
		_hump = 0.0


## Wall foot: points past the wall plane flatten onto it with a round corner, and the wall side spreads along it.
func _settle_wall(p: Vector2) -> Vector2:
	var pressing := _press > _wall
	var side := _press_side if pressing else _wall_side
	var amount := clampf(maxf(_wall, _press * 4.0), 0.0, 1.0)
	var wall_x := side * (_feet + Tuning.body_floor_sink)
	var start := wall_x - side * Tuning.body_wall_flare_width * _r
	var f := smoothstep(start * side, wall_x * side, p.x * side)
	f *= f * amount
	p.y = _center.y + (p.y - _center.y) * (1.0 + Tuning.body_wall_flare * f)
	var k := maxf(Tuning.body_foot_round * _r, 0.01)
	var gap := (wall_x - p.x) * side / k
	var settled: float
	if gap > 0.0:
		settled = p.x - side * k * log(1.0 + exp(-gap))
	else:
		settled = wall_x - side * k * log(1.0 + exp(gap))
	p.x = lerpf(p.x, settled, amount)
	return p


## Flat head: points above the collider top (lowered by the dent) flatten onto it with round corners.
func _settle_ceiling(p: Vector2) -> Vector2:
	var amount := clampf(_ceil * 4.0, 0.0, 1.0)
	var plane := -_feet - Tuning.body_floor_sink + _ceil * Tuning.body_ceiling_depth * _r
	var k := maxf(Tuning.body_foot_round * _r, 0.01)
	var gap := (p.y - plane) / k
	var settled: float
	if gap > 0.0:
		settled = p.y + k * log(1.0 + exp(-gap))
	else:
		settled = plane + k * log(1.0 + exp(gap))
	p.y = lerpf(p.y, settled, amount)
	return p


## Maps a point of the round body (local, centre at the origin) to the drawn outline, including the roll turn.
func _deform(p: Vector2) -> Vector2:
	var q := _shape_point(p)
	if _roll != 0.0:
		q = _pivot + (q - _pivot).rotated(_roll)
	return q


## The drawn outline before the roll turn: squash, crawl, then the gelatin shear.
## The source of the deformation: cargo.gdshader deform_point copies it with _deform and _shear_at, and cargo.gd
## _shader_deform mirrors that copy for the boot check (cargo.gd check_deform). Change them together.
func _shape_point(p: Vector2) -> Vector2:
	var q := Vector2(p.x * _sx, p.y * _sy + _r * (1.0 - _sy))
	q.x = q.x * _ex + _crawl_dx
	q.y = _r - (_r - q.y) * _ey
	if _press > 0.001:
		# Pressed against glass: narrower toward the wall and taller, the base stays on the floor.
		var anchor := _press_side * _feet
		q.x = anchor + (q.x - anchor) * (1.0 - Tuning.body_press_narrow * _press)
		q.y = _r - (_r - q.y) * (1.0 + Tuning.body_press_tall * _press)
	if absf(_ceil) > 0.001:
		# The head pushes down and the sides bulge out at mid height.
		var top := clampf(-q.y / maxf(_r, 0.001), 0.0, 1.0)
		var mid := clampf(1.0 - absf(q.y) / maxf(_r, 0.001), 0.0, 1.0)
		q.y += top * _ceil * Tuning.body_ceiling_depth * _r
		q.x *= 1.0 + Tuning.body_ceiling_bulge * _ceil * mid
	q.x += _shear_at(q.y) * (1.0 - _frost)
	if absf(_aim_pull) > 0.001:
		# The back half stretches away from the target and the whole body leans back, like a pulled slingshot.
		var back := -_aim_dir
		var along := maxf(q.dot(back) / maxf(_r, 0.001), 0.0)
		q += back * _aim_pull * _r * (Tuning.body_aim_stretch * along + Tuning.body_aim_shift) * (1.0 - _frost)
	return q


## Horizontal offset at local height y: zero at the base, largest at the top (a positive lean moves the top to +x).
func _shear_at(y: float) -> float:
	var span := maxf(_r * 2.0, 0.001)
	var h := clampf((_r - y) / span, 0.0, 1.2)
	return _lean * span * h * (0.5 + 0.5 * h)


## The cube outline toward d: a superellipse of half size Tuning.cube_half_size (in body radii).
static func _cube_dir(d: Vector2) -> Vector2:
	var e := 2.0 / maxf(Tuning.cube_superellipse, 2.0)
	return Vector2(signf(d.x) * pow(absf(d.x), e), signf(d.y) * pow(absf(d.y), e)) * Tuning.cube_half_size


func _draw() -> void:
	_drawn = _radius > 0.5
	if not _drawn:
		return
	var ks := GooMath.kernel_scale()
	var color := GooMath.field_color(_flash, _danger * (Tuning.body_danger_tint_base + Tuning.body_danger_tint_pulse * _pulse))
	_fan_points[0] = _center
	_fan_colors.fill(color)
	for i: int in _n:
		_fan_points[i + 1] = _center + (_points[i] - _center) * ks
	RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), _fan_indices, _fan_points, _fan_colors, _fan_uvs, PackedInt32Array(), PackedFloat32Array(), GooMath.kernel_texture().get_rid())
