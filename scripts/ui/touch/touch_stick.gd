extends RefCounted
## Floating move stick of the touch controls: state, output math, goo spring and drawing.
## It rests as a ghost at home, appears under the finger, drags its base along past the rim and eases home on release.

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

const SPRING_MAX_STEP := 1.0 / 120.0

var home := Vector2.ZERO
var base := Vector2.ZERO
var radius := 100.0
var knob_radius := 44.0
var shown := true
var active := false
## Finger offset from the base, never longer than the radius.
var knob := Vector2.ZERO
var appear := 0.0
## 0..1: how much the slime sits under the idle stick; the idle look fades by it.
var veil := 0.0

var _drawn_knob := Vector2.ZERO
var _drawn_vel := Vector2.ZERO
var _return_from := Vector2.ZERO
var _return_t := 1.0
var _active_blend := 0.0
var _pop := 0.0
var _run_on := false
var _crouch_on := false
var _run_lit := 0.0
## The slime cannot run now (minimum mass or tired): the rim never turns to the run colour.
var run_blocked := false
var _edge := 0.0
var _run_pop := 1.0
var _crouch_lit := 0.0
var _veil_shown := 0.0


func place(p_home: Vector2, p_radius: float, p_knob_radius: float) -> void:
	home = p_home
	radius = p_radius
	knob_radius = p_knob_radius
	if not active and _return_t >= 1.0:
		base = home


func press(p: Vector2) -> void:
	active = true
	base = p
	knob = Vector2.ZERO
	_drawn_knob = Vector2.ZERO
	_drawn_vel = Vector2.ZERO
	_return_t = 1.0
	_pop = 1.0


func drag(p: Vector2) -> void:
	if not active:
		return
	var off := p - base
	if off.length() > radius:
		# Past the rim the base follows the finger instead of locking it.
		base = p - off.normalized() * radius
		off = off.normalized() * radius
	knob = off


func release() -> void:
	if not active:
		return
	active = false
	_run_on = false
	_crouch_on = false
	knob = Vector2.ZERO
	_return_from = base
	_return_t = 0.0


## Signed move strength from the horizontal deflection, after the dead zone and with full speed before the rim.
func move_output() -> float:
	if not active or radius <= 0.0:
		return 0.0
	var x := knob.x / radius
	var amount := clampf(inverse_lerp(Tuning.touch_stick_deadzone, Tuning.touch_stick_full_at, absf(x)), 0.0, 1.0)
	return signf(x) * amount


## True while the knob sits at the rim: the stick at full deflection runs. It lets go a little inside the rim.
func run_output() -> bool:
	if not active or radius <= 0.0:
		_run_on = false
		return false
	var share := knob.length() / radius
	var was := _run_on
	_run_on = share >= (Tuning.touch_run_release if _run_on else Tuning.touch_run_at) and absf(move_output()) > 0.0
	if _run_on and not was and not run_blocked:
		_run_pop = 0.0
	return _run_on


## Down strength for the crouch: the knob within the crouch cone of down to start, any push down to keep.
func crouch_output() -> float:
	if not active or radius <= 0.0:
		_crouch_on = false
		return 0.0
	var v := knob / radius
	if _crouch_on:
		_crouch_on = v.y >= Tuning.crouch_keep
	else:
		_crouch_on = v.y > 0.0 and v.length() >= Tuning.crouch_enter and absf(rad_to_deg(v.angle_to(Vector2.DOWN))) <= Tuning.crouch_cone_deg
	return clampf(v.y, 0.0, 1.0) if _crouch_on else 0.0


func update(delta: float) -> void:
	_run_lit = move_toward(_run_lit, 1.0 if _run_on and not run_blocked else 0.0, delta * 12.0)
	_edge = clampf(inverse_lerp(Tuning.touch_run_hint_from, Tuning.touch_run_at, knob.length() / maxf(radius, 1.0)), 0.0, 1.0) if active else 0.0
	_run_pop = minf(_run_pop + delta / maxf(Tuning.touch_run_pop_time, 0.001), 1.0)
	_crouch_lit = move_toward(_crouch_lit, 1.0 if _crouch_on else 0.0, delta * 8.0)
	appear = move_toward(appear, 1.0 if shown else 0.0, delta / maxf(Tuning.touch_appear_time, 0.001))
	_active_blend = move_toward(_active_blend, 1.0 if active else 0.0, delta / maxf(Tuning.touch_appear_time, 0.001))
	_pop = move_toward(_pop, 0.0, delta * 4.0)
	_veil_shown = move_toward(_veil_shown, veil, delta / maxf(Tuning.touch_appear_time, 0.001))
	if not active and _return_t < 1.0:
		_return_t = minf(_return_t + delta / maxf(Tuning.touch_stick_return_time, 0.001), 1.0)
		var t := 1.0 - pow(1.0 - _return_t, 3.0)
		base = _return_from.lerp(home, t)
	var remaining := delta
	while remaining > 0.0:
		var step := minf(remaining, SPRING_MAX_STEP)
		_drawn_vel += ((knob - _drawn_knob) * Tuning.touch_stick_knob_stiffness - _drawn_vel * Tuning.touch_stick_knob_damping) * step
		_drawn_knob += _drawn_vel * step
		remaining -= step


## Everything draw() reads, with the knob spring snapped below a visible step, so a caller can skip a redraw while
## the key stays the same.
func visual_key() -> Array:
	if appear <= 0.0:
		return []
	return [appear, _active_blend, _pop, snappedf(_veil_shown, 0.01), base, radius, knob_radius, _drawn_knob.snapped(Vector2(0.01, 0.01)), knob, _edge,
		_run_lit, _run_pop, _crouch_lit, run_blocked, active]


func draw(batch: ShapeBatch) -> void:
	if appear <= 0.0:
		return
	var ghost := Tuning.touch_stick_ghost_alpha * lerpf(1.0, Tuning.touch_stick_veil_alpha, _veil_shown)
	var a := ease(appear, 0.4) * lerpf(ghost, 1.0, _active_blend)
	var r := radius * (1.0 + 0.12 * _pop * _pop)
	var accent := Tuning.goo_body_color
	batch.disc(base + Vector2(0.0, r * 0.08), r, Color(0.0, 0.0, 0.0, a * 0.18))
	batch.disc(base, r, Color(Tuning.touch_fill_color, a * 0.45))
	batch.ring(base, r * Tuning.touch_stick_full_at, 2.0, Color(accent, a * 0.18))
	batch.ring(base, r, r * 0.05, Color(accent, a * 0.75))
	var output := move_output()
	for side: float in [-1.0, 1.0]:
		var lit := clampf(output * side, 0.0, 1.0)
		var tip := base + Vector2(side * r * 0.8, 0.0)
		var back := tip - Vector2(side * r * 0.13, 0.0)
		batch.polygon(PackedVector2Array([tip, back + Vector2(0.0, -r * 0.11), back + Vector2(0.0, r * 0.11)]), Color(accent.lightened(0.4 * lit), a * (0.35 + 0.65 * lit)))
	# The rim brightens as the knob nears the run limit, turns hot lime while running (with a pop ring at the start),
	# and stays dim when the slime is too small to run. The chevron under the base lights while it crouches.
	var rim := accent.lerp(Tuning.touch_run_tired_color if run_blocked else accent.lightened(0.45), _edge)
	rim = rim.lerp(Tuning.touch_run_color, _run_lit)
	batch.ring(base, r * 1.02, r * lerpf(0.03, 0.08, maxf(_edge * 0.6, _run_lit)), Color(rim, a * lerpf(0.25, 1.0, maxf(_edge, _run_lit))))
	if _run_pop < 1.0:
		var t := ease(_run_pop, 0.4)
		batch.ring(base, r * lerpf(1.0, 1.35, t), r * 0.06 * (1.0 - t) + 1.0, Color(Tuning.touch_run_color, a * (1.0 - _run_pop)))
	var down_lit := _crouch_lit
	var tip_d := base + Vector2(0.0, r * 0.8)
	var back_d := tip_d - Vector2(0.0, r * 0.13)
	batch.polygon(PackedVector2Array([tip_d, back_d + Vector2(r * 0.11, 0.0), back_d + Vector2(-r * 0.11, 0.0)]), Color(accent.lightened(0.4 * down_lit), a * (0.25 + 0.75 * down_lit)))
	var k := base + _drawn_knob
	if _drawn_knob.length() > 1.0:
		var side := _drawn_knob.normalized().orthogonal()
		var neck_base := knob_radius * 0.45
		var neck_tip := knob_radius * 0.72
		var neck_color := Color(Tuning.goo_deep_color, a * 0.7)
		batch.polygon(PackedVector2Array([base + side * neck_base, k + side * neck_tip, k - side * neck_tip, base - side * neck_base]), neck_color)
		batch.disc(base, neck_base, neck_color)
	var angle := _drawn_knob.angle() if _drawn_knob.length() > 1.0 else 0.0
	var stretch := 1.0 + Tuning.touch_stick_stretch * minf(_drawn_knob.length() / maxf(radius, 1.0), 1.0)
	var kr := knob_radius * (1.0 + 0.15 * _pop)
	var blob := ShapeBatch.circle_points(k, Vector2(stretch, 1.0 / stretch) * kr, angle)
	batch.polygon(blob, Color(accent.lerp(Tuning.touch_run_color, _run_lit), a * 0.92))
	batch.stroke(blob, kr * 0.12, Color(Tuning.goo_rim_color, a), true)
	batch.disc(k + Vector2(-0.32, -0.38) * kr, kr * 0.24, Color(1.0, 1.0, 1.0, a * 0.45))
	batch.disc(k + Vector2(-0.05, -0.58) * kr, kr * 0.09, Color(1.0, 1.0, 1.0, a * 0.5))
