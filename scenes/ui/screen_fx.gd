extends CanvasLayer
## Full-screen feedback layers: danger vignette, flash, goo iris transition and the boot cover.

## Emitted when an iris transition ends, or when a new one replaces it, so no caller waits forever.
signal iris_finished

const IRIS_OPEN_RADIUS := 1.5
# Below zero, so the wobbling edge closes the hole completely.
const IRIS_CLOSED_RADIUS := -0.05
const IRIS_WARM_RADIUS := 0.7
const IRIS_CORNER_MARGIN := 0.08
const WARM_UP_FRAMES := 4
## Segments of the ring meshes that draw the vignette and the iris without their clear centre.
const RING_SEGMENTS := 64

@onready var _vignette: ColorRect = $Vignette
@onready var _flash: ColorRect = $Flash
@onready var _iris: ColorRect = $Iris
@onready var _cover: ColorRect = $Cover

var _vignette_material: ShaderMaterial
var _iris_material: ShaderMaterial
var _flash_tween: Tween
var _iris_tween: Tween
var _cover_tween: Tween
var _danger_target := 0.0
var _heartbeat_level := 0.0
var _danger := 0.0
var _beat_phase := 0.0
var _applied_danger := NAN
var _warming := false
var _ring_points := PackedVector2Array()
var _ring_colors := PackedColorArray()
var _ring_indices := PackedInt32Array()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_vignette_material = _vignette.material as ShaderMaterial
	_iris_material = _iris.material as ShaderMaterial
	_flash.color.a = 0.0
	_flash.visible = false
	_iris_material.set_shader_parameter(&"center", Vector2(0.5, 0.5))
	_iris_material.set_shader_parameter(&"rim_color", Tuning.goo_lime_color)
	_iris_material.set_shader_parameter(&"rim_dark", Tuning.goo_deep_color)
	_set_iris_radius(IRIS_OPEN_RADIUS)
	_iris.visible = false
	_cover.visible = true
	_cover.modulate.a = 1.0
	_apply_danger(0.0)
	_add_ring(_vignette)
	_add_ring(_iris)
	get_viewport().size_changed.connect(_on_size_changed)
	_on_size_changed()
	Juice.screen_fx = self
	Game.mass_changed.connect(_on_mass_changed)


## The rect keeps its node, visibility and material, but draws nothing itself: a child ring mesh with the same
## material covers only the part of the screen that the shader changes (the fragments of the clear centre cost fill).
func _add_ring(rect: ColorRect) -> void:
	var material := rect.material as ShaderMaterial
	material.set_shader_parameter(&"ring_mesh", true)
	rect.set_anchors_preset(Control.PRESET_TOP_LEFT)
	rect.size = Vector2.ZERO
	var ring := Node2D.new()
	ring.name = &"Ring"
	ring.use_parent_material = true
	rect.add_child(ring)
	# The shader places every vertex, so the item must never be culled by its placeholder points.
	RenderingServer.canvas_item_set_custom_rect(ring.get_canvas_item(), true, Rect2(-1.0e6, -1.0e6, 2.0e6, 2.0e6))
	if _ring_indices.is_empty():
		_build_ring_mesh()
	# A canvas item drops its commands on each redraw (a visibility change), so the mesh goes in from the draw signal.
	ring.draw.connect(func() -> void:
		RenderingServer.canvas_item_add_triangle_array(ring.get_canvas_item(), _ring_indices, _ring_points, _ring_colors, _ring_points))
	ring.queue_redraw()


## One vertex pair per angle step: UV.x is the angle in turns, UV.y is 0 inside and 1 outside (the shaders place them).
func _build_ring_mesh() -> void:
	for i in RING_SEGMENTS + 1:
		var t := float(i) / RING_SEGMENTS
		for outer in 2:
			_ring_points.append(Vector2(t, outer))
			_ring_colors.append(Color.WHITE)
	for i in RING_SEGMENTS:
		var a := i * 2
		_ring_indices.append_array([a, a + 1, a + 3, a, a + 3, a + 2])


func _on_size_changed() -> void:
	var size := get_viewport().get_visible_rect().size
	_vignette_material.set_shader_parameter(&"screen_size", size)
	_iris_material.set_shader_parameter(&"screen_size", size)


func _exit_tree() -> void:
	if Juice.screen_fx == self:
		Juice.screen_fx = null


func flash(color: Color, seconds: float) -> void:
	if seconds <= 0.0 or color.a <= 0.0:
		return
	# A weaker flash never cuts a stronger one short.
	if _flash.visible and _flash.color.a > color.a:
		return
	_kill(_flash_tween)
	_flash.color = color
	_flash.visible = true
	_flash_tween = _new_tween()
	_flash_tween.tween_property(_flash, ^"color:a", 0.0, seconds).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_flash_tween.tween_callback(_flash.hide)


func set_danger(level: float) -> void:
	_set_danger_levels(level, level)


func iris_close(screen_pos: Vector2, seconds: float) -> Signal:
	_iris_material.set_shader_parameter(&"center", _to_uv(screen_pos))
	return _tween_iris(_iris_radius(), IRIS_CLOSED_RADIUS, seconds, Tween.TRANS_BACK, Tween.EASE_IN, false)


func iris_open(screen_pos: Vector2, seconds: float) -> Signal:
	var center := _to_uv(screen_pos)
	_iris_material.set_shader_parameter(&"center", center)
	return _tween_iris(IRIS_CLOSED_RADIUS, _open_radius_for(center), seconds, Tween.TRANS_ELASTIC, Tween.EASE_OUT, true)


func hide_cover(seconds: float) -> void:
	_kill(_cover_tween)
	if seconds <= 0.0:
		_cover.modulate.a = 0.0
		_cover.visible = false
		return
	_cover_tween = _new_tween()
	_cover_tween.tween_property(_cover, ^"modulate:a", 0.0, seconds)
	_cover_tween.tween_callback(_cover.hide)


## Renders every layer and shader once behind the cover, so their first real use does not hitch.
func warm_up() -> void:
	_warming = true
	_apply_danger(1.0)
	_flash.color = Color(1.0, 1.0, 1.0, 0.01)
	_flash.visible = true
	if not _iris_busy():
		_set_iris_radius(IRIS_WARM_RADIUS)
		_iris.visible = true
	for i in WARM_UP_FRAMES:
		await get_tree().process_frame
	_warming = false
	_apply_danger(_danger)
	if not _flash_busy():
		_flash.color.a = 0.0
		_flash.visible = false
	if not _iris_busy():
		_set_iris_radius(IRIS_OPEN_RADIUS)
		_iris.visible = false


func _process(delta: float) -> void:
	if _vignette.visible != Tuning.fx_vignette:
		_vignette.visible = Tuning.fx_vignette
	if _warming:
		return
	var real := Juice.real_delta(delta)
	_danger = move_toward(_danger, _danger_target, real * Tuning.vignette_danger_response)
	if _danger <= 0.0:
		_beat_phase = 0.0
		_apply_danger(0.0)
		return
	var interval := lerpf(Tuning.player_heartbeat_interval.x, Tuning.player_heartbeat_interval.y, _heartbeat_level)
	_beat_phase = fmod(_beat_phase + real / interval, 1.0)
	_apply_danger(_danger * (1.0 - Tuning.vignette_heartbeat_dip + Tuning.vignette_heartbeat_dip * _heartbeat(_beat_phase)))


## Two-beat pulse (lub, then a softer dub) in 0..1 over one heartbeat period.
func _heartbeat(phase: float) -> float:
	var lub := exp(-pow((phase - 0.08) / 0.06, 2.0))
	var dub := 0.7 * exp(-pow((phase - 0.3) / 0.07, 2.0))
	return clampf(lub + dub, 0.0, 1.0)


func _on_mass_changed(mass: float, _ratio: float) -> void:
	if mass >= Tuning.mass_danger or mass <= 0.0:
		_set_danger_levels(0.0, 0.0)
		return
	var t := clampf(inverse_lerp(Tuning.mass_danger, Tuning.mass_death, mass), 0.0, 1.0)
	_set_danger_levels(lerpf(Tuning.vignette_danger_floor, 1.0, t), t)


func _set_danger_levels(visual: float, heartbeat: float) -> void:
	_danger_target = clampf(visual, 0.0, 1.0)
	_heartbeat_level = clampf(heartbeat, 0.0, 1.0)


func _tween_iris(from: float, to: float, seconds: float, trans: Tween.TransitionType, ease_type: Tween.EaseType, hide_at_end: bool) -> Signal:
	if _iris_busy():
		_iris_tween.kill()
		iris_finished.emit()
	_iris.visible = true
	_set_iris_radius(from)
	_iris_tween = _new_tween()
	_iris_tween.tween_method(_set_iris_radius, from, to, maxf(seconds, 0.001)).set_trans(trans).set_ease(ease_type)
	if hide_at_end:
		_iris_tween.tween_callback(_iris.hide)
	_iris_tween.tween_callback(iris_finished.emit)
	return iris_finished


func _set_iris_radius(value: float) -> void:
	_iris_material.set_shader_parameter(&"radius", value)


func _iris_radius() -> float:
	if not _iris.visible:
		return _open_radius_for(_iris_material.get_shader_parameter(&"center"))
	return float(_iris_material.get_shader_parameter(&"radius"))


## Radius that clears the farthest screen corner from the center, in the shader's aspect space.
func _open_radius_for(center: Vector2) -> float:
	var size := get_viewport().get_visible_rect().size
	var aspect := size.x / maxf(size.y, 1.0)
	var far := Vector2(maxf(center.x, 1.0 - center.x) * aspect, maxf(center.y, 1.0 - center.y))
	return maxf(far.length() + IRIS_CORNER_MARGIN, IRIS_OPEN_RADIUS)


func _to_uv(screen_pos: Vector2) -> Vector2:
	var size := get_viewport().get_visible_rect().size
	if size.x <= 0.0 or size.y <= 0.0:
		return Vector2(0.5, 0.5)
	return (screen_pos / size).clamp(Vector2.ZERO, Vector2.ONE)


func _apply_danger(value: float) -> void:
	if value == _applied_danger:
		return
	_applied_danger = value
	_vignette_material.set_shader_parameter(&"danger", value)


func _iris_busy() -> bool:
	return _iris_tween != null and _iris_tween.is_valid() and _iris_tween.is_running()


func _flash_busy() -> bool:
	return _flash_tween != null and _flash_tween.is_valid() and _flash_tween.is_running()


func _new_tween() -> Tween:
	var tween := create_tween()
	tween.set_ignore_time_scale(true)
	return tween


func _kill(tween: Tween) -> void:
	if tween != null and tween.is_valid():
		tween.kill()
