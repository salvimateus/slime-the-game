extends Node2D
## World-space tutorial hint that bobs and fades with the distance to the slime. A key of scripts/ui/input_hints.gd
## shows input icons with a short label for the input mode in use; any other key shows its Strings text.

const Strings := preload("res://scripts/ui/strings.gd")
const InputGlyphs := preload("res://scripts/ui/input_glyphs.gd")
const InputHints := preload("res://scripts/ui/input_hints.gd")

## Canvas pixels past the screen edge where an icon hint still animates.
const ONSCREEN_MARGIN := 200.0
## One frame is enough: the font cache fills while the text is drawn.
const WARM_UP_FRAMES := 1
const WARM_UP_ALPHA := 0.01

var _key: StringName
var _base_y := 0.0
var _time := 0.0
var _popped := false
var _pop: Tween
## Icons of the hint, or null for a text hint.
var _glyphs: InputGlyphs
## One icon set per input style, drawn almost clear during the warm-up so no style rasterizes its text in play.
var _warm: Array[InputGlyphs] = []
var _warm_frames := 0
## Look key of the icons at the last redraw; a redraw happens only when it changes.
var _drawn_key: Variant = null
var _drawn_step := -1


func setup(key: StringName) -> void:
	_key = key
	if InputHints.HINTS.has(key):
		_glyphs = _new_glyphs()
		$Label.visible = false
	_apply_input_mode()
	TouchControls.input_mode_changed.connect(_on_input_mode_changed)
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_base_y = position.y
	modulate.a = Tuning.hint_min_alpha


func warm_up() -> void:
	if _glyphs == null:
		return
	_warm.clear()
	for style: StringName in InputGlyphs.STYLES:
		var glyphs := _new_glyphs()
		glyphs.refresh(style)
		_warm.append(glyphs)
	_warm_frames = WARM_UP_FRAMES
	queue_redraw()


func _process(delta: float) -> void:
	if visible != Tuning.fx_hints:
		visible = Tuning.fx_hints
	if not visible:
		return
	_time += delta
	# Far from the view nothing of the hint shows: no bob, fade or icon work.
	if _warm_frames == 0 and not _is_near_screen():
		_popped = false
		return
	position.y = _base_y + sin(_time * Tuning.hint_bob_speed) * Tuning.hint_bob_pixels
	_animate_glyphs(delta)
	if not is_instance_valid(Game.player):
		return
	var d := global_position.distance_to(Game.player.global_position)
	modulate.a = clampf(inverse_lerp(Tuning.hint_fade_distance.y, Tuning.hint_fade_distance.x, d), Tuning.hint_min_alpha, 1.0)
	if modulate.a >= Tuning.hint_pop_alpha and not _popped:
		_popped = true
		_play_pop()
	elif modulate.a <= Tuning.hint_reset_alpha:
		_popped = false


func _draw() -> void:
	if _glyphs != null:
		_glyphs.draw(self, Vector2.ZERO)
	for glyphs: InputGlyphs in _warm:
		glyphs.draw(self, Vector2.ZERO, WARM_UP_ALPHA)


## Icons loop only while the hint is near the screen, so far hints cost no redraw.
func _animate_glyphs(delta: float) -> void:
	if _glyphs == null:
		return
	if _warm_frames > 0:
		_warm_frames -= 1
		if _warm_frames == 0:
			_warm.clear()
		queue_redraw()
	if not _is_near_screen():
		return
	_glyphs.update(delta)
	var key := _glyphs.visual_key()
	if key == _drawn_key:
		return
	# The touch icons animate springs through most of their loop; they redraw at the idle motion rate.
	if _glyphs.style == InputGlyphs.STYLE_TOUCH:
		var step := floori(_time * Tuning.glyph_idle_motion_hz)
		if step == _drawn_step:
			return
		_drawn_step = step
	_drawn_key = key
	queue_redraw()


func _is_near_screen() -> bool:
	var at := get_global_transform_with_canvas().origin
	return get_viewport_rect().grow(ONSCREEN_MARGIN).has_point(at)


func _new_glyphs() -> InputGlyphs:
	return InputGlyphs.new(InputHints.HINTS[_key], Tuning.glyph_size, Tuning.glyph_label_font_size)


func _on_input_mode_changed(_mode: StringName) -> void:
	_apply_input_mode()


## A pad that connects or leaves can change the icon family (Xbox or PlayStation) with no change of the mode.
func _on_joy_connection_changed(_device: int, _connected: bool) -> void:
	if not Harness.ignores_input():
		_apply_input_mode()


## Touch players read the touch wording or see the touch controls; keyboard and pad players see their keys and buttons.
func _apply_input_mode() -> void:
	if _glyphs == null:
		$Label.text = Strings.text(_key, TouchControls.is_touch_mode())
		return
	if _glyphs.refresh():
		Harness.log_event("hint_icons", {"hint": String(_key), "style": String(_glyphs.style), "rows": Array(_glyphs.describe())})
	_drawn_key = null
	queue_redraw()


# A short scale pop when the slime comes close draws the eye to the hint.
func _play_pop() -> void:
	if _pop:
		_pop.kill()
	scale = Vector2.ONE * Tuning.hint_pop_scale
	_pop = create_tween()
	_pop.tween_property(self, "scale", Vector2.ONE, Tuning.hint_pop_time).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
