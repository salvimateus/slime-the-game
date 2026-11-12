extends Node2D
## The look of one patch of floor flames (child of its FireZone): a bed of glowing coals under flames of mixed
## height that merge and split, a thin smoke over them, warm light on the room, sparks, heat shimmer and a roar.
## The flames and the light are one canvas item drawn one time (fire.gdshader kinds band and glow); the shader moves
## them. Sparks are an engine particle node. Only the wake of the slime runs in a script, and only while the patch is
## near the screen: a VisibleOnScreenNotifier2D turns the patch on and off.
## Visual and audio only: it uses its own seeded RNG and never touches gameplay state.

const FireAssets := preload("res://scripts/fire/fire_assets.gd")
const FireQuad := preload("res://scripts/fire/fire_quad.gd")
const FireLean := preload("res://scripts/fire/fire_lean.gd")
const FireShimmer := preload("res://scripts/fire/fire_shimmer.gd")

const RNG_SEED := 6151
const LEAN_STEP := 0.01

var _size := Vector2.ZERO
var _rng := RandomNumberGenerator.new()
var _lean := FireLean.new()
var _material: ShaderMaterial
var _fire := FireQuad.new()
var _sparks: CPUParticles2D
var _shimmer := FireShimmer.new()
var _notifier := VisibleOnScreenNotifier2D.new()
var _roar: AudioStreamPlayer2D
var _crackle := Timer.new()
var _sent_lean := INF
var _sent_rich := true
var _warm := false


## size: the floor patch in px, its top-left corner at this node's origin.
func setup(size: Vector2) -> void:
	_size = size
	_rng.seed = RNG_SEED + int(global_position.x)
	z_index = Tuning.fire_bed_z_index
	var height := _bed_height()
	var floor_left := Vector2(0.0, size.y)
	var middle := Vector2(size.x * 0.5, size.y)
	var reach := size.x * 0.5 + Tuning.tile_size * Tuning.fire_bed_light_reach
	_material = FireAssets.new_fire_material()
	_sent_rich = Tuning.fx_fire_rich
	_fire.material = _material
	# Light in the air of the room, the light pool on the floor, then the bed.
	_fire.add_glow(middle - Vector2(0.0, height * 0.5), Vector2(reach, reach * 0.75), Color(Tuning.fire_glow_color, Tuning.fire_glow_color.a * Tuning.fire_bed_light))
	_fire.add_glow(middle, Vector2(reach * 0.8, height * 0.35), Tuning.fire_floor_light_color)
	_fire.add_band(floor_left, size.x, height, _rng.randf())
	add_child(_fire)
	_sparks = FireAssets.make_sparks(int(Tuning.fire_bed_sparks_per_tile * maxf(size.x / Tuning.tile_size, 1.0)), Vector2(size.x * 0.45, height * 0.15))
	_sparks.position = Vector2(size.x * 0.5, size.y - height * 0.45)
	add_child(_sparks)
	_shimmer.position = Vector2(size.x * 0.5, size.y - height * 0.55)
	_shimmer.scale = Vector2(size.x * 1.1, height * Tuning.fire_bed_haze_height)
	add_child(_shimmer)
	var loop := Sfx.stream(&"fire_roar")
	if loop != null:
		_roar = AudioStreamPlayer2D.new()
		_roar.stream = loop
		_roar.bus = &"SFX"
		_roar.max_distance = Tuning.fire_roar_distance
		_roar.volume_db = Tuning.fire_bed_roar_db
		_roar.pitch_scale = Tuning.fire_bed_roar_pitch
		_roar.position = middle
		add_child(_roar)
	_crackle.one_shot = true
	_crackle.timeout.connect(_on_crackle)
	add_child(_crackle)
	var near := Rect2(-reach, size.y - height * Tuning.fire_bed_haze_height * 1.2, size.x + reach * 2.0, height * Tuning.fire_bed_haze_height * 1.2 + height * 0.5)
	_notifier.rect = near.grow(Tuning.fire_bed_listen_margin)
	_notifier.screen_entered.connect(_set_on.bind(true))
	_notifier.screen_exited.connect(_set_on.bind(false))
	# A sibling, not a child: a hidden patch must still see the screen.
	get_parent().add_child(_notifier)
	_set_on(false)


## Draws everything once, on screen or not, behind the loading cover.
func warm_up() -> void:
	_warm = true
	_set_on(true)
	await get_tree().process_frame
	await get_tree().process_frame
	_warm = false
	_set_on(_notifier.is_on_screen())


# A looping voice still in the audio server at shutdown leaks its stream.
func _exit_tree() -> void:
	if _roar != null:
		_roar.stop()
		_roar.stream = null


func _set_on(on: bool) -> void:
	visible = on
	_sparks.emitting = on
	_shimmer.set_strength(Tuning.fire_haze_strength if on else 0.0)
	set_process(on and not _warm)
	if _roar != null:
		if on and not _roar.playing and not _warm:
			_roar.play(_rng.randf() * 0.3)
		elif not on:
			_roar.stop()
	if on and not _warm:
		_crackle.start(_rng.randf_range(Tuning.fire_crackle_interval.x, Tuning.fire_crackle_interval.y))
	else:
		_crackle.stop()


func _on_crackle() -> void:
	Sfx.play(&"fire_crackle", global_position + Vector2(_rng.randf_range(0.0, _size.x), _size.y), _rng.randf_range(0.7, 1.4), Tuning.fire_crackle_db.y)
	_crackle.start(_rng.randf_range(Tuning.fire_crackle_interval.x, Tuning.fire_crackle_interval.y))


## The wake of the slime: the air it drags bends the flames, which spring back when it is gone.
func _process(delta: float) -> void:
	var velocity := Vector2.ZERO
	var player := Game.player
	if is_instance_valid(player):
		var at: Vector2 = player.global_position - global_position
		var gap := Vector2(maxf(maxf(-at.x, at.x - _size.x), 0.0), maxf(maxf(-_bed_height() - at.y, at.y - _size.y), 0.0))
		var near := 1.0 - clampf(gap.length() / Tuning.fire_bed_wake_reach, 0.0, 1.0)
		if near > 0.0:
			var v: Variant = player.get(&"velocity")
			if v is Vector2:
				velocity = -(v as Vector2) * near * Tuning.fire_bed_wake
	if Tuning.fx_fire_rich != _sent_rich:
		# The performance panel switched the fire: the inner flame and the shimmer follow at once.
		_sent_rich = Tuning.fx_fire_rich
		_material.set_shader_parameter(&"inner_layer", 1.0 if _sent_rich else 0.0)
		_shimmer.set_strength(Tuning.fire_haze_strength)
	# With no slime near and the flames upright, nothing on screen changes.
	if velocity == Vector2.ZERO and _lean.is_settled():
		if _sent_lean == 0.0:
			return
		_lean.reset()
	else:
		_lean.update(delta, velocity)
	var lean := snappedf(_lean.lean.x, LEAN_STEP)
	if lean != _sent_lean:
		_sent_lean = lean
		_material.set_shader_parameter(&"band_lean", lean)


func _bed_height() -> float:
	return Tuning.tile_size * Tuning.fire_bed_height
