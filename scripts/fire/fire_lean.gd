extends RefCounted
## How the air bends a moving fire. The flames rise and stream against the motion: they trail behind a run,
## stream down and back in a jump and stretch up in a fall. A soft spring follows the motion, so they stand
## straight again a moment after a stop, with a small sway.

## The lean: a vector in flame heights that adds to the straight-up flame, against the motion.
var lean := Vector2.ZERO
var _lean_vel := Vector2.ZERO


func reset() -> void:
	lean = Vector2.ZERO
	_lean_vel = Vector2.ZERO


## True when the flames stand straight and still; reset() then snaps the last trace of the spring to zero.
func is_settled() -> bool:
	return lean.length_squared() < 1.0e-6 and _lean_vel.length_squared() < 1.0e-6


func update(delta: float, velocity: Vector2) -> void:
	var target := (-velocity * Tuning.fire_lean_per_speed).limit_length(Tuning.fire_lean_max)
	var k := Tuning.fire_lean_stiffness
	var damping := 2.0 * sqrt(k) * Tuning.fire_lean_damping
	var dt := minf(delta, 1.0 / 30.0)
	_lean_vel += ((target - lean) * k - _lean_vel * damping) * dt
	lean += _lean_vel * dt


## Offset from the root to the tip of a flame of the given height: up plus the lean, longer when the air streams
## up along it and shorter when it pushes it down.
func tip(height: float) -> Vector2:
	var dir := Vector2.UP + lean
	var length := dir.length()
	if length < 0.05:
		dir = lean.normalized() if lean.length_squared() > 0.0 else Vector2.UP
	else:
		dir /= length
	var stretch := clampf(1.0 - lean.y * Tuning.fire_lean_stretch, Tuning.fire_lean_length_range.x, Tuning.fire_lean_length_range.y)
	return dir * height * stretch
