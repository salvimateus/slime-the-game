extends Node2D
## Heat shimmer over a fire: a quad that bends the screen behind it with a rising noise (fire_haze.gdshader).
## It costs a copy of the screen (BackBufferCopy) and a screen read, so it exists only with the rich fire
## (Tuning.fx_fire_rich, which the quality level sets). The owner places it with the transform: the quad spans x -0.5..0.5
## and y -1..0 (its base at the origin), so position is the middle of its base and scale its size in px.
## Strength 0..1 goes through modulate alpha. It draws after the goo, so the goo's own screen read is untouched.

const FireAssets := preload("res://scripts/fire/fire_assets.gd")
const FireQuad := preload("res://scripts/fire/fire_quad.gd")

var _copy := BackBufferCopy.new()
var _quad := FireQuad.new()


func _init() -> void:
	z_index = Tuning.fire_haze_z_index
	z_as_relative = false
	_copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	add_child(_copy)
	_quad.material = FireAssets.haze_material()
	_quad.add_piece(FireQuad.KIND_PLAIN, Rect2(-0.5, -1.0, 1.0, 1.0), Color.WHITE)
	add_child(_quad)
	visible = false


## Shows the shimmer at this strength, or hides it (no copy, no draw) at 0 or without the rich fire.
func set_strength(strength: float) -> void:
	var on := strength > 0.01 and Tuning.fx_fire_rich
	if visible != on:
		visible = on
	if on:
		var alpha := snappedf(clampf(strength, 0.0, 1.0), 1.0 / 32.0)
		if not is_equal_approx(_quad.modulate.a, alpha):
			_quad.modulate.a = alpha
