extends Node2D
## A small fire that a moving object carries (an ember shot, a burning mite): a coal glow from inside, one flame with
## a thread of smoke that streams against the motion (fire.gdshader, kinds glow and ember, one canvas item drawn one
## time), and a spark trail (engine particles). Add it as a child of the object and call carry() once per physics
## tick; the flame leans with the same air as the slime's fire (FireLean) by the node rotation and scale, and its heat
## goes through modulate, so nothing is built or drawn again in a frame.
## At most Tuning.ember_flame_max torches burn with a flame at one time; past that the oldest keeps the glow only.
## burn_out(seconds) lets a torch live on its own, fading where it is, then free itself.

const FireAssets := preload("res://scripts/fire/fire_assets.gd")
const FireQuad := preload("res://scripts/fire/fire_quad.gd")
const FireLean := preload("res://scripts/fire/fire_lean.gd")

## Heat and flame go to the shader in these steps, so a slow cooling changes the node only now and then.
const STEP := 1.0 / 32.0

## Torches with a flame, oldest first.
static var _flames: Array[Node] = []

var _lean := FireLean.new()
var _quad := FireQuad.new()
var _sparks: CPUParticles2D
var _heat := -1.0
var _fresh := -1.0
var _flare := 0.0
var _glow_only := false
var _burn_left := 0.0
var _burn_time := 0.0


## object_radius: radius of the burning object in px; seed_value 0..1 varies its flicker.
func _init(object_radius := 8.0, seed_value := 0.37) -> void:
	var r := object_radius * Tuning.fire_torch_core
	_quad.material = FireAssets.fire_material()
	_quad.add_glow(Vector2.ZERO, Vector2.ONE * object_radius * Tuning.fire_torch_glow_size, Tuning.fire_glow_color)
	# The ember quad: 7 radii wide, 12 tall, the coal at 82 % of its height, at this node's origin.
	_quad.add_piece(FireQuad.KIND_EMBER, Rect2(-3.5 * r, -9.84 * r, 7.0 * r, 12.0 * r), Color(1.0, 1.0, seed_value, 1.0))
	add_child(_quad)
	_sparks = FireAssets.make_sparks(Tuning.fire_torch_spark_amount, Vector2.ONE * object_radius * 0.5)
	_sparks.scale_amount_min *= Tuning.fire_torch_spark_scale
	_sparks.scale_amount_max *= Tuning.fire_torch_spark_scale
	add_child(_sparks)
	set_process(false)


func _enter_tree() -> void:
	_flames.append(self)
	while _flames.size() > maxi(Tuning.ember_flame_max, 0):
		var oldest: Node = _flames.pop_front()
		if is_instance_valid(oldest):
			oldest.call(&"_set_glow_only")


func _exit_tree() -> void:
	_flames.erase(self)


## Once per physics tick: the motion of the object, its heat 0..1 (0 hides the fire) and how much of it still burns
## with a flame 0..1 (0: only the glowing coal).
func carry(delta: float, velocity: Vector2, heat: float, flame := 1.0) -> void:
	_lean.update(delta, velocity)
	var tip := _lean.tip(1.0)
	_quad.rotation = tip.angle() + PI * 0.5
	_quad.scale = Vector2(1.0, tip.length())
	_flare = maxf(_flare - delta / Tuning.fire_torch_flare_time, 0.0)
	var boost := 1.0 + _flare * Tuning.fire_torch_flare
	_show(heat, 0.0 if _glow_only else flame * boost)


## A bounce or a hit: the flame flares up for a moment.
func flare() -> void:
	_flare = 1.0


## Leaves the object: the torch stays where it is and fades over seconds, then frees itself.
func burn_out(seconds: float) -> void:
	_burn_time = maxf(seconds, 0.01)
	_burn_left = _burn_time
	set_process(true)


func _process(delta: float) -> void:
	_burn_left -= delta
	if _burn_left <= 0.0:
		queue_free()
		return
	var k := _burn_left / _burn_time
	carry(delta, Vector2.ZERO, k, k)


func _set_glow_only() -> void:
	_glow_only = true
	_sparks.emitting = false
	_show(_heat, 0.0)


func _show(heat: float, fresh: float) -> void:
	var h := snappedf(clampf(heat, 0.0, 1.0), STEP)
	var f := snappedf(clampf(fresh, 0.0, 1.0 + Tuning.fire_torch_flare), STEP)
	if h == _heat and f == _fresh:
		return
	_heat = h
	_fresh = f
	visible = h > 0.0
	# The shader reads heat in red and the flame in green of the vertex colour, which modulate scales.
	_quad.modulate = Color(h, f, 1.0, 1.0)
	_sparks.emitting = f > Tuning.fire_spark_min_power and not _glow_only
