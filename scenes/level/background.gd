extends Node2D
## Parallax cave backdrop: gradient sky, painted far layer, silhouette mid layer and drifting glow spores.

const FAR_TEXTURE := "res://art/textures/bg_far.png"
const MID_TEXTURE := "res://art/textures/bg_mid.png"
## Camera2D limits wider than this are the engine defaults, not level bounds.
const LIMIT_SENTINEL := 1000000
const COVER_MARGIN := 32.0
const SPORE_COUNT := 40
const SPORE_PARALLAX := 0.7
const SPORE_PAD := Vector2(96.0, 96.0)
const SPORE_SEED := 4127
const SPORE_COLOR := Color(0.74, 0.78, 1.0)
const SPORE_ALPHA := 0.4
const SPORE_GLOW_SCALE := 3.0
const SPORE_RISE_SPEED := Vector2(6.0, 16.0)
const SPORE_SIZE := Vector2(1.6, 4.5)
const SPORE_SWAY := 18.0
## The spores move on the GPU: a fixed mesh of one quad per spore, placed each frame by this vertex shader from a few
## uniforms, with the same layout math the CPU used (screen-space wrap, own parallax, sway, rise and twinkle).
const SPORE_SHADER := """
shader_type canvas_item;
render_mode blend_add;

uniform vec2 spore_base[%d];
uniform float spore_speed[%d];
uniform float spore_size[%d];
uniform float spore_phase[%d];
uniform float time;
uniform vec2 period;
uniform vec2 scroll;
uniform vec2 pad;
uniform float sway;
uniform float glow_scale;
uniform vec4 spore_color;
uniform vec2 to_local_x;
uniform vec2 to_local_y;
uniform vec2 to_local_origin;

void vertex() {
	int i = int(VERTEX.x + 0.5);
	float phase = spore_phase[i];
	vec2 drift = vec2(sin(time * 0.4 + phase) * sway, -time * spore_speed[i]);
	vec2 p = spore_base[i] * period + drift - scroll;
	p = p - period * floor(p / period) - pad;
	float twinkle = 0.55 + 0.45 * sin(time * 1.7 + phase * 3.0);
	vec2 s = p + (UV * 2.0 - 1.0) * spore_size[i] * glow_scale;
	VERTEX = to_local_x * s.x + to_local_y * s.y + to_local_origin;
	COLOR *= vec4(spore_color.rgb, spore_color.a * twinkle);
}
"""

## World y range (top, bottom) the camera can show. The camera limits replace it when the level starts.
@export var view_span := Vector2(0.0, 2304.0)

var _spore_base := PackedVector2Array()
var _spore_speed := PackedFloat32Array()
var _spore_size := PackedFloat32Array()
var _spore_phase := PackedFloat32Array()
var _spore_texture: Texture2D
var _spore_material: ShaderMaterial
var _spore_points := PackedVector2Array()
var _spore_uvs := PackedVector2Array()
var _spore_colors := PackedColorArray()
var _spore_indices := PackedInt32Array()
var _time := 0.0
var _shown := -1
var _sent_view := Vector2.INF
var _sent_canvas := Transform2D()
var _sent_local := Transform2D()
var _detail := -1
## Lower band of the mid layer when its clear middle rows are cut out (the top band is the scene sprite).
var _mid_low: Sprite2D

@onready var _far: Parallax2D = $Far
@onready var _far_sprite: Sprite2D = $Far/Sprite
@onready var _mid: Parallax2D = $Mid
@onready var _mid_sprite: Sprite2D = $Mid/Sprite
@onready var _spores: Node2D = $Spores


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var missing := PackedStringArray()
	if not _apply_texture(_far, _far_sprite, FAR_TEXTURE):
		missing.append(FAR_TEXTURE)
	if not _apply_texture(_mid, _mid_sprite, MID_TEXTURE):
		missing.append(MID_TEXTURE)
	_split_mid()
	if not missing.is_empty():
		push_warning("Background: texture missing (%s); that layer is hidden." % ", ".join(missing))
	_build_spores()
	_spores.material = _spore_material
	# The mesh points hold spore indices, not positions, so the item gets a rect that is never culled.
	RenderingServer.canvas_item_set_custom_rect(_spores.get_canvas_item(), true, Rect2(-1.0e7, -1.0e7, 2.0e7, 2.0e7))
	_spores.draw.connect(_draw_spores)
	RenderingServer.frame_pre_draw.connect(_place_spores)
	get_viewport().size_changed.connect(_layout)
	Game.level_started.connect(_on_level_started)
	_layout()


func _process(delta: float) -> void:
	_time += delta
	var shown := int(Tuning.fx_background)
	var detail := int(Tuning.fx_bg_detail)
	if shown == _shown and detail == _detail:
		return
	_shown = shown
	_detail = detail
	_far.visible = Tuning.fx_background and _far_sprite.texture != null
	_mid.visible = Tuning.fx_background and Tuning.fx_bg_detail and _mid_sprite.texture != null
	_spores.visible = Tuning.fx_background and Tuning.fx_bg_detail


func _apply_texture(layer: Parallax2D, sprite: Sprite2D, path: String) -> bool:
	var texture: Texture2D = null
	if ResourceLoader.exists(path):
		texture = load(path) as Texture2D
	if texture == null or texture.get_width() <= 0 or texture.get_height() <= 0:
		layer.visible = false
		return false
	sprite.texture = texture
	return true


func _on_level_started() -> void:
	var camera := get_viewport().get_camera_2d()
	if camera == null or camera.limit_bottom - camera.limit_top >= LIMIT_SENTINEL:
		return
	view_span = Vector2(camera.limit_top, camera.limit_bottom)
	_layout()


func _layout() -> void:
	var view_size := get_viewport_rect().size / maxf(Tuning.camera_zoom, 0.01)
	var travel := maxf(view_span.y - view_span.x - view_size.y, 0.0)
	_fit_layer(_far, _far_sprite, view_size, travel)
	_fit_layer(_mid, _mid_sprite, view_size, travel)


## The mid layer is clear between Tuning.bg_mid_clear_rows; it draws as two bands, so those rows cost no fill.
func _split_mid() -> void:
	var texture := _mid_sprite.texture
	var rows := Tuning.bg_mid_clear_rows
	if texture == null or rows.x <= 0 or rows.y <= rows.x or rows.y >= texture.get_height():
		return
	_mid_sprite.region_enabled = true
	_mid_sprite.region_rect = Rect2(0.0, 0.0, texture.get_width(), rows.x)
	_mid_low = Sprite2D.new()
	_mid_low.name = &"SpriteLow"
	_mid_low.texture = texture
	_mid_low.centered = false
	_mid_low.modulate = _mid_sprite.modulate
	_mid_low.region_enabled = true
	_mid_low.region_rect = Rect2(0.0, rows.y, texture.get_width(), texture.get_height() - rows.y)
	_mid.add_child(_mid_low)


## Scales and places a layer so that it covers the view at every camera height inside view_span.
func _fit_layer(layer: Parallax2D, sprite: Sprite2D, view_size: Vector2, travel: float) -> void:
	if sprite.texture == null:
		return
	var texture_size := sprite.texture.get_size()
	var depth := layer.scroll_scale.y
	var needed_height := view_size.y + depth * travel + COVER_MARGIN * 2.0
	var k := maxf(1.0, needed_height / texture_size.y)
	sprite.scale = Vector2(k, k)
	var width := texture_size.x * k
	layer.repeat_size = Vector2(width, 0.0)
	layer.repeat_times = ceili(view_size.x / width) + 2
	# On screen, the layer top sits at sprite.position.y - depth * camera_top.
	var top_max := depth * view_span.x - COVER_MARGIN
	var top_min := view_size.y + COVER_MARGIN - texture_size.y * k + depth * (view_span.x + travel)
	sprite.position = Vector2(0.0, (top_min + top_max) * 0.5)
	if sprite == _mid_sprite and is_instance_valid(_mid_low):
		_mid_low.scale = sprite.scale
		_mid_low.position = sprite.position + Vector2(0.0, Tuning.bg_mid_clear_rows.y * k)


func _build_spores() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SPORE_SEED
	for i in SPORE_COUNT:
		_spore_base.append(Vector2(rng.randf(), rng.randf()))
		_spore_speed.append(rng.randf_range(SPORE_RISE_SPEED.x, SPORE_RISE_SPEED.y))
		_spore_size.append(rng.randf_range(SPORE_SIZE.x, SPORE_SIZE.y))
		_spore_phase.append(rng.randf_range(0.0, TAU))
		for corner: Vector2 in [Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0)]:
			_spore_points.append(Vector2(i, 0.0))
			_spore_uvs.append(corner)
			_spore_colors.append(Color.WHITE)
		for k: int in [0, 1, 2, 0, 2, 3]:
			_spore_indices.append(i * 4 + k)
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	gradient.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	gradient.add_point(0.18, Color(1.0, 1.0, 1.0, 0.7))
	var glow := GradientTexture2D.new()
	glow.gradient = gradient
	glow.fill = GradientTexture2D.FILL_RADIAL
	glow.fill_from = Vector2(0.5, 0.5)
	glow.fill_to = Vector2(1.0, 0.5)
	glow.width = 32
	glow.height = 32
	_spore_texture = glow
	var shader := Shader.new()
	shader.code = SPORE_SHADER % [SPORE_COUNT, SPORE_COUNT, SPORE_COUNT, SPORE_COUNT]
	_spore_material = ShaderMaterial.new()
	_spore_material.shader = shader
	_spore_material.set_shader_parameter(&"spore_base", _spore_base)
	_spore_material.set_shader_parameter(&"spore_speed", _spore_speed)
	_spore_material.set_shader_parameter(&"spore_size", _spore_size)
	_spore_material.set_shader_parameter(&"spore_phase", _spore_phase)
	_spore_material.set_shader_parameter(&"pad", SPORE_PAD)
	_spore_material.set_shader_parameter(&"sway", SPORE_SWAY)
	_spore_material.set_shader_parameter(&"glow_scale", SPORE_GLOW_SCALE)
	_spore_material.set_shader_parameter(&"spore_color", Color(SPORE_COLOR, SPORE_ALPHA))


## Spores are laid out in screen space on a wrapping period larger than the view, with their own parallax.
## Runs just before the frame renders, after the camera has moved, as the old per-frame _draw did.
func _place_spores() -> void:
	if not is_inside_tree() or not _spores.visible:
		return
	var view := get_viewport_rect().size
	var canvas := get_viewport().get_canvas_transform()
	var camera_top := canvas.affine_inverse() * Vector2.ZERO
	var to_local := _spores.get_global_transform_with_canvas().affine_inverse()
	_spore_material.set_shader_parameter(&"time", _time)
	# The other values change only when the camera or the window moves.
	if view == _sent_view and canvas == _sent_canvas and to_local == _sent_local:
		return
	_sent_view = view
	_sent_canvas = canvas
	_sent_local = to_local
	_spore_material.set_shader_parameter(&"period", view + SPORE_PAD * 2.0)
	_spore_material.set_shader_parameter(&"scroll", camera_top * SPORE_PARALLAX * canvas.get_scale().x)
	_spore_material.set_shader_parameter(&"to_local_x", to_local.x)
	_spore_material.set_shader_parameter(&"to_local_y", to_local.y)
	_spore_material.set_shader_parameter(&"to_local_origin", to_local.origin)


## The spore mesh is drawn once; _place_spores moves it.
func _draw_spores() -> void:
	RenderingServer.canvas_item_add_triangle_array(_spores.get_canvas_item(), _spore_indices, _spore_points, _spore_colors, _spore_uvs, PackedInt32Array(), PackedFloat32Array(), _spore_texture.get_rid())
