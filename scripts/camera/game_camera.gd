extends Camera2D
## Platformer camera: damped follow with look-ahead, trauma shake and zoom punch.

# Caps one spring step, so a long frame cannot blow up the punch spring.
const MAX_SPRING_STEP := 1.0 / 30.0
const PUNCH_MIN_ZOOM_FACTOR := 0.5

var target: Node2D
var _trauma := 0.0
var _noise := FastNoiseLite.new()
var _noise_t := 0.0
var _punch := 0.0
var _punch_vel := 0.0
var _focus := Vector2.ZERO
var _focus_vel := Vector2.ZERO
var _anchor_y := 0.0
var _look := Vector2.ZERO


## Interpolation goes off before the node enters the tree; otherwise Camera2D forces the physics callback.
func _init() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


func _ready() -> void:
	process_callback = Camera2D.CAMERA2D_PROCESS_IDLE
	position_smoothing_enabled = false
	ignore_rotation = false
	_noise.seed = 7
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	_noise.frequency = Tuning.shake_noise_frequency
	zoom = Vector2.ONE * Tuning.camera_zoom
	_focus = global_position
	Juice.camera = self
	make_current()


func _exit_tree() -> void:
	if Juice.camera == self:
		Juice.camera = null


func set_bounds(rect: Rect2) -> void:
	limit_left = int(rect.position.x)
	limit_top = int(rect.position.y)
	limit_right = int(rect.end.x)
	limit_bottom = int(rect.end.y)


func snap() -> void:
	if not _has_target():
		return
	var p := _target_position()
	_anchor_y = p.y
	_look = Vector2.ZERO
	_focus = Vector2(p.x, p.y + Tuning.camera_vertical_bias)
	_focus_vel = Vector2.ZERO
	global_position = _focus
	reset_smoothing()
	force_update_scroll()


func add_trauma(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


func punch(amount: float) -> void:
	_punch_vel += amount * Tuning.camera_punch_kick


func _process(delta: float) -> void:
	var real := Juice.real_delta(delta)
	if _has_target():
		_follow(delta)
	_update_shake(real)
	_update_punch(real)


func _follow(delta: float) -> void:
	var p := _target_position()
	var v := Vector2.ZERO
	var velocity_value: Variant = target.get(&"velocity")
	if velocity_value is Vector2:
		v = velocity_value
	var grounded := false
	if target.has_method(&"is_on_floor"):
		grounded = bool(target.call(&"is_on_floor"))
	if grounded:
		_anchor_y = p.y
	elif absf(p.y - _anchor_y) > Tuning.camera_deadzone_y:
		_anchor_y = p.y - signf(p.y - _anchor_y) * Tuning.camera_deadzone_y
	var look_x := clampf(v.x * Tuning.camera_look_ahead_time, -Tuning.camera_look_ahead_max, Tuning.camera_look_ahead_max)
	var look_y := 0.0
	if v.y > Tuning.camera_fall_look_speed:
		look_y = clampf((v.y - Tuning.camera_fall_look_speed) * Tuning.camera_fall_look_gain, 0.0, Tuning.camera_fall_look_max)
	_look = _look.lerp(Vector2(look_x, look_y), 1.0 - exp(-delta * Tuning.camera_look_response))
	var goal := Vector2(p.x, _anchor_y + Tuning.camera_vertical_bias) + _look
	var dx := _damp(_focus.x, goal.x, _focus_vel.x, Tuning.camera_smooth_x, delta)
	var dy := _damp(_focus.y, goal.y, _focus_vel.y, Tuning.camera_smooth_y, delta)
	_focus = Vector2(dx.x, dy.x)
	_focus_vel = Vector2(dx.y, dy.y)
	_keep_in_view(p, v)
	global_position = _focus


## Hard edge for the damped follow: a fast fall or dash never carries the target out of the safe band of the screen.
func _keep_in_view(p: Vector2, v: Vector2) -> void:
	var half := get_viewport_rect().size * 0.5 / maxf(Tuning.camera_zoom, 0.01)
	var reach := (half - Tuning.camera_edge_margin).max(Vector2.ZERO)
	var offset_from_focus := p - _focus
	if absf(offset_from_focus.x) > reach.x:
		_focus.x = p.x - signf(offset_from_focus.x) * reach.x
		_focus_vel.x = v.x
	if absf(offset_from_focus.y) > reach.y:
		_focus.y = p.y - signf(offset_from_focus.y) * reach.y
		_focus_vel.y = v.y


## Shake runs on real time, so a hitstop freezes the world but not the screen.
func _update_shake(real: float) -> void:
	_trauma = maxf(_trauma - Tuning.shake_decay * real, 0.0)
	_noise_t += real * Tuning.shake_speed
	var amount := _trauma * _trauma
	if amount <= 0.0:
		offset = Vector2.ZERO
		rotation = 0.0
		return
	var n := Vector2(_noise.get_noise_2d(_noise_t, 0.0), _noise.get_noise_2d(0.0, _noise_t))
	offset = n * Tuning.shake_max_offset * amount
	rotation = _noise.get_noise_2d(_noise_t, 100.0) * Tuning.shake_max_roll * amount


func _update_punch(real: float) -> void:
	var remaining := real
	while remaining > 0.0:
		var step := minf(remaining, MAX_SPRING_STEP)
		_punch_vel += (-_punch * Tuning.camera_punch_stiffness - _punch_vel * Tuning.camera_punch_damping) * step
		_punch += _punch_vel * step
		remaining -= step
	var factor := maxf(1.0 + _punch, PUNCH_MIN_ZOOM_FACTOR)
	zoom = Vector2.ONE * Tuning.camera_zoom * factor


func _has_target() -> bool:
	return is_instance_valid(target) and target.is_inside_tree()


func _target_position() -> Vector2:
	if target.has_method(&"visual_position"):
		return target.call(&"visual_position")
	return target.global_position


## Critically damped spring step. Returns (new value, new velocity).
static func _damp(current: float, goal: float, vel: float, smooth: float, dt: float) -> Vector2:
	var omega := 2.0 / maxf(smooth, 0.0001)
	var x := omega * dt
	var e := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var change := current - goal
	var temp := (vel + omega * change) * dt
	return Vector2(goal + (change + temp) * e, (vel - omega * temp) * e)
