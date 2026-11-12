extends RefCounted
## Shared resources of the fire look, built by code once and kept for the whole run: the noise texture (R slow
## turbulence, G fine detail, both seamless), the fire and heat haze materials, and the spark and puff textures for
## the engine particle nodes. Every fire shares one shader, so it compiles once; a fire with its own uniforms (a body,
## a patch of floor flames) gets its own material of the same shader. The shaders animate with TIME, so no script
## sets a clock in a frame.

const FireShader := preload("res://scripts/fire/fire.gdshader")
const HazeShader := preload("res://scripts/fire/fire_haze.gdshader")
const NOISE_SIZE := 128
const DOT_SIZE := 32

static var _noise: ImageTexture
static var _fire_material: ShaderMaterial
static var _haze_material: ShaderMaterial
static var _spark_texture: GradientTexture2D
static var _puff_texture: GradientTexture2D
static var _spark_ramp: Gradient
static var _additive: CanvasItemMaterial


## The material of fire pieces that need no uniform of their own (glows, embers, carried flames).
static func fire_material() -> ShaderMaterial:
	if _fire_material == null:
		_fire_material = new_fire_material()
	return _fire_material


## A material of its own (body or patch uniforms) on the shared shader: nothing compiles again.
static func new_fire_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = FireShader
	material.set_shader_parameter(&"noise_tex", noise_texture())
	material.set_shader_parameter(&"core_color", Tuning.fire_core_color)
	material.set_shader_parameter(&"yellow_color", Tuning.fire_yellow_color)
	material.set_shader_parameter(&"orange_color", Tuning.fire_orange_color)
	material.set_shader_parameter(&"red_color", Tuning.fire_red_color)
	material.set_shader_parameter(&"smoke_color", Tuning.fire_smoke_color)
	material.set_shader_parameter(&"rise_speed", Tuning.fire_rise_speed)
	material.set_shader_parameter(&"tongue_px", Tuning.fire_tongue_px)
	material.set_shader_parameter(&"swell_px", Tuning.fire_swell_px)
	material.set_shader_parameter(&"swell_speed", Tuning.fire_swell_speed)
	material.set_shader_parameter(&"inner_speed", Tuning.fire_inner_speed)
	material.set_shader_parameter(&"erosion", Tuning.fire_erosion)
	material.set_shader_parameter(&"flame_gain", Tuning.fire_flame_gain)
	material.set_shader_parameter(&"flame_cover", Tuning.fire_flame_cover)
	material.set_shader_parameter(&"glow_noise", Tuning.fire_glow_noise)
	material.set_shader_parameter(&"body_glow", Tuning.fire_body_glow_color)
	material.set_shader_parameter(&"body_halo", Tuning.fire_body_halo)
	material.set_shader_parameter(&"body_side_reach", Tuning.fire_body_side_reach)
	material.set_shader_parameter(&"inner_layer", 1.0 if Tuning.fx_fire_rich else 0.0)
	return material


static func haze_material() -> ShaderMaterial:
	if _haze_material == null:
		_haze_material = ShaderMaterial.new()
		_haze_material.shader = HazeShader
		_haze_material.set_shader_parameter(&"noise_tex", noise_texture())
		_haze_material.set_shader_parameter(&"bend_px", Tuning.fire_haze_bend_px)
		_haze_material.set_shader_parameter(&"rise_speed", Tuning.fire_haze_rise_speed)
	return _haze_material


static func noise_texture() -> Texture2D:
	if _noise == null:
		var coarse := _noise_layer(Tuning.fire_noise_seed, Tuning.fire_noise_coarse_frequency).get_data()
		var fine := _noise_layer(Tuning.fire_noise_seed + 1, Tuning.fire_noise_fine_frequency).get_data()
		var texels := NOISE_SIZE * NOISE_SIZE
		var rg := PackedByteArray()
		rg.resize(texels * 2)
		for i: int in texels:
			rg[i * 2] = coarse[i]
			rg[i * 2 + 1] = fine[i]
		_noise = ImageTexture.create_from_image(Image.create_from_data(NOISE_SIZE, NOISE_SIZE, false, Image.FORMAT_RG8, rg))
	return _noise


static func _noise_layer(seed_value: int, frequency: float) -> Image:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	var image := noise.get_seamless_image(NOISE_SIZE, NOISE_SIZE, false, false, 0.1, true)
	if image.get_format() != Image.FORMAT_L8:
		image.convert(Image.FORMAT_L8)
	return image


## A spark emitter that runs in native code: hot streaks that leave upward, rise on the hot air, slow down, swirl
## and cool from white-yellow to dark red. amount is its fixed pool (less in the cheap fire); rect_extents the half
## size of its source area.
static func make_sparks(amount: int, rect_extents: Vector2) -> CPUParticles2D:
	var sparks := CPUParticles2D.new()
	sparks.amount = maxi(int(amount * (1.0 if Tuning.fx_fire_rich else Tuning.fire_cheap_spark_share)), 1)
	sparks.lifetime = Tuning.fire_spark_life
	sparks.randomness = 0.6
	sparks.local_coords = false
	sparks.texture = spark_texture()
	sparks.material = additive_material()
	sparks.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	sparks.emission_rect_extents = rect_extents
	sparks.direction = Vector2.UP
	sparks.spread = Tuning.fire_spark_spread
	sparks.initial_velocity_min = Tuning.fire_spark_speed.x
	sparks.initial_velocity_max = Tuning.fire_spark_speed.y
	sparks.gravity = Vector2(0.0, -Tuning.fire_spark_lift)
	sparks.damping_min = Tuning.fire_spark_drag.x
	sparks.damping_max = Tuning.fire_spark_drag.y
	sparks.tangential_accel_min = -Tuning.fire_spark_swirl
	sparks.tangential_accel_max = Tuning.fire_spark_swirl
	sparks.particle_flag_align_y = true
	sparks.scale_amount_min = Tuning.fire_spark_scale.x
	sparks.scale_amount_max = Tuning.fire_spark_scale.y
	sparks.color_ramp = spark_ramp()
	sparks.emitting = false
	return sparks


## A one-shot puff emitter (the steam of a quenched fire, the smoke of a death): soft discs that rise, spread and fade.
static func make_puffs(amount: int) -> CPUParticles2D:
	var puffs := CPUParticles2D.new()
	puffs.amount = maxi(amount, 1)
	puffs.one_shot = true
	puffs.explosiveness = 0.85
	puffs.lifetime = Tuning.fire_puff_life
	puffs.randomness = 0.5
	puffs.local_coords = false
	puffs.texture = puff_texture()
	puffs.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	puffs.direction = Vector2.UP
	puffs.spread = 80.0
	puffs.angle_min = 0.0
	puffs.angle_max = 360.0
	puffs.initial_velocity_min = Tuning.fire_puff_speed.x
	puffs.initial_velocity_max = Tuning.fire_puff_speed.y
	puffs.gravity = Vector2(0.0, -Tuning.fire_puff_lift)
	puffs.damping_min = Tuning.fire_puff_drag
	puffs.damping_max = Tuning.fire_puff_drag
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.45))
	grow.add_point(Vector2(1.0, 1.0))
	puffs.scale_amount_curve = grow
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.15, 1.0])
	fade.colors = PackedColorArray([Color(1.0, 1.0, 1.0, 0.0), Color(1.0, 1.0, 1.0, 1.0), Color(1.0, 1.0, 1.0, 0.0)])
	puffs.color_ramp = fade
	puffs.emitting = false
	return puffs


static func additive_material() -> CanvasItemMaterial:
	if _additive == null:
		_additive = CanvasItemMaterial.new()
		_additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	return _additive


## A spark streak: a soft dot stretched along its flight (the particle aligns its Y axis to the velocity).
static func spark_texture() -> Texture2D:
	if _spark_texture == null:
		_spark_texture = _radial_texture(PackedFloat32Array([0.0, 0.35, 1.0]), PackedColorArray([Color.WHITE, Color(1.0, 1.0, 1.0, 0.55), Color(1.0, 1.0, 1.0, 0.0)]))
		_spark_texture.width = 6
		_spark_texture.height = 18
	return _spark_texture


static func puff_texture() -> Texture2D:
	if _puff_texture == null:
		_puff_texture = _radial_texture(PackedFloat32Array([0.0, 0.35, 1.0]), PackedColorArray([Color(1.0, 1.0, 1.0, 0.45), Color(1.0, 1.0, 1.0, 0.3), Color(1.0, 1.0, 1.0, 0.0)]))
	return _puff_texture


static func _radial_texture(offsets: PackedFloat32Array, colors: PackedColorArray) -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.offsets = offsets
	gradient.colors = colors
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = DOT_SIZE
	texture.height = DOT_SIZE
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	return texture


## Colour of a spark over its life: white-yellow, yellow, orange, dark red, gone.
static func spark_ramp() -> Gradient:
	if _spark_ramp == null:
		_spark_ramp = Gradient.new()
		_spark_ramp.offsets = PackedFloat32Array([0.0, 0.2, 0.5, 0.82, 1.0])
		_spark_ramp.colors = PackedColorArray([Tuning.fire_core_color, Tuning.fire_yellow_color, Tuning.fire_orange_color, Tuning.fire_red_color, Color(Tuning.fire_red_color, 0.0)])
	return _spark_ramp


## Smooth value noise in 0..1 with irregular timing, for the flicker of a light or a sound.
static func flicker(t: float, seed_value: float) -> float:
	return _value_noise(t + seed_value * 31.7) * 0.65 + _value_noise(t * 2.37 + seed_value * 7.3) * 0.35


static func _value_noise(t: float) -> float:
	var i := floorf(t)
	var f := t - i
	var a := _hash(i)
	var b := _hash(i + 1.0)
	return lerpf(a, b, f * f * (3.0 - 2.0 * f))


static func _hash(n: float) -> float:
	var s := sin(n * 12.9898) * 43758.5453
	return s - floorf(s)
