extends CanvasLayer
## Animated HUD: pops counter, clock, checkpoint toast and the level complete panel. The slime size is the life display.
## The last line of the panel is the jump icon of the input mode in use with "Play again".

const Strings := preload("res://scripts/ui/strings.gd")
const SafeArea := preload("res://scripts/ui/safe_area.gd")
const InputGlyphs := preload("res://scripts/ui/input_glyphs.gd")
const InputHints := preload("res://scripts/ui/input_hints.gd")
const AGAIN_KEY := &"complete_again"

const WARM_UP_FRAMES := 4
const WARM_UP_ALPHA := 0.01

@onready var _root: Control = $Root
@onready var _deaths: Label = $Root/Deaths
@onready var _clock: Label = $Root/Clock
@onready var _toast: Label = $Root/Toast
@onready var _complete: PanelContainer = $Root/Complete
@onready var _title: Label = $Root/Complete/Lines/Title
@onready var _stat_time: Label = $Root/Complete/Lines/Time
@onready var _stat_deaths: Label = $Root/Complete/Lines/Deaths
@onready var _stat_lost: Label = $Root/Complete/Lines/Lost
@onready var _stat_recovered: Label = $Root/Complete/Lines/Recovered
@onready var _again: Control = $Root/Complete/Lines/Again

var _shown_deaths := -1
var _shown_clock_ds := -1
var _summary := {}
var _count_step := -1
var _deaths_tween: Tween
var _toast_tween: Tween
var _panel_tween: Tween
var _again_tween: Tween
var _safe := Rect2()
var _again_glyphs := InputGlyphs.new(InputHints.HINTS[AGAIN_KEY], Tuning.hud_glyph_size, Tuning.hud_glyph_label_font_size)
## One icon set per input style, drawn almost clear during the warm-up.
var _again_warm: Array[InputGlyphs] = []
var _again_key: Variant = null
var _again_step := -1
var _again_time := 0.0


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_title.text = Strings.TEXT[&"complete_title"]
	_again.draw.connect(_draw_again)
	_apply_again_icons()
	_toast.visible = false
	_complete.visible = false
	_update_info_labels()
	_apply_safe_area()
	TouchControls.input_mode_changed.connect(func(_mode: StringName) -> void: _apply_again_icons())
	Input.joy_connection_changed.connect(func(_device: int, _connected: bool) -> void:
		if not Harness.ignores_input():
			_apply_again_icons())
	Game.checkpoint_reached.connect(_on_checkpoint_reached)
	Game.player_died.connect(_on_player_died)
	Game.goal_reached.connect(_on_goal_reached)


## Renders every HUD element and animation once at almost zero opacity, so their first real use does not hitch.
func warm_up() -> void:
	_root.modulate.a = WARM_UP_ALPHA
	for style: StringName in InputGlyphs.STYLES:
		var glyphs := InputGlyphs.new(InputHints.HINTS[AGAIN_KEY], Tuning.hud_glyph_size, Tuning.hud_glyph_label_font_size)
		glyphs.refresh(style)
		_again_warm.append(glyphs)
	_pop_deaths()
	_show_toast(Strings.TEXT[&"toast_checkpoint"])
	_show_complete({"time": 0.0, "deaths": 0, "lost": 0.0, "recovered": 0.0}, false)
	for i in WARM_UP_FRAMES:
		await get_tree().process_frame
	for tween: Tween in [_deaths_tween, _toast_tween, _panel_tween, _again_tween]:
		_kill(tween)
	_deaths.scale = Vector2.ONE
	_again_warm.clear()
	_again_key = null
	_toast.visible = false
	_complete.visible = false
	_root.modulate.a = 1.0


func _process(delta: float) -> void:
	_apply_safe_area()
	_update_info_labels()
	if _complete.visible:
		_animate_again(Juice.real_delta(delta))


## Redraws the "Play again" icons only when their drawn state changes, like the level hints.
func _animate_again(delta: float) -> void:
	_again_glyphs.update(delta)
	_again_time += delta
	if not _again_warm.is_empty():
		_again.queue_redraw()
		return
	var key := _again_glyphs.visual_key()
	if key == _again_key:
		return
	if _again_glyphs.style == InputGlyphs.STYLE_TOUCH:
		var step := floori(_again_time * Tuning.glyph_idle_motion_hz)
		if step == _again_step:
			return
		_again_step = step
	_again_key = key
	_again.queue_redraw()


## Text changes only when the shown value changes, so labels do not relayout every frame.
func _update_info_labels() -> void:
	if Game.deaths != _shown_deaths:
		_shown_deaths = Game.deaths
		_deaths.text = Strings.TEXT[&"hud_deaths"] % _shown_deaths
	var deciseconds := floori(Game.sim_time * 10.0)
	if deciseconds != _shown_clock_ds:
		_shown_clock_ds = deciseconds
		_clock.text = _format_time(Game.sim_time)


## Keeps every HUD element out of a notch, a cutout or the system bars.
func _apply_safe_area() -> void:
	var safe := SafeArea.rect(get_viewport())
	if safe == _safe:
		return
	_safe = safe
	var view := get_viewport().get_visible_rect().size
	_root.offset_left = safe.position.x
	_root.offset_top = safe.position.y
	_root.offset_right = safe.end.x - view.x
	_root.offset_bottom = safe.end.y - view.y


func _apply_again_icons() -> void:
	_again_glyphs.refresh()
	_again.custom_minimum_size = _again_glyphs.size
	_again_key = null
	_again.queue_redraw()


func _draw_again() -> void:
	var center := _again.size * 0.5
	_again_glyphs.draw(_again, center)
	for glyphs: InputGlyphs in _again_warm:
		glyphs.draw(_again, center)


func _on_player_died(_source: StringName, _at: Vector2) -> void:
	_update_info_labels()
	_pop_deaths()


func _on_checkpoint_reached(_id: StringName, _at: Vector2) -> void:
	_show_toast(Strings.TEXT[&"toast_checkpoint"])


func _on_goal_reached(summary: Dictionary) -> void:
	_show_complete(summary, true)


func _pop_deaths() -> void:
	_kill(_deaths_tween)
	_deaths.scale = Vector2.ONE * Tuning.hud_death_pop_scale
	_deaths_tween = _new_tween()
	_deaths_tween.tween_property(_deaths, ^"scale", Vector2.ONE, Tuning.hud_pop_time).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _show_toast(text: String) -> void:
	_kill(_toast_tween)
	_toast.text = text
	_toast.visible = true
	_toast.modulate.a = 1.0
	_toast.pivot_offset = _toast.size * 0.5
	_toast.scale = Vector2.ONE * Tuning.hud_toast_start_scale
	_toast_tween = _new_tween()
	_toast_tween.tween_property(_toast, ^"scale", Vector2.ONE, Tuning.hud_toast_pop_time).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_toast_tween.tween_interval(Tuning.hud_toast_hold)
	_toast_tween.tween_property(_toast, ^"modulate:a", 0.0, Tuning.hud_toast_fade)
	_toast_tween.tween_callback(_toast.hide)


func _show_complete(summary: Dictionary, with_sound: bool) -> void:
	_kill(_panel_tween)
	_kill(_again_tween)
	_summary = summary
	_count_step = -1
	_set_count(0.0, false)
	_complete.visible = true
	_complete.modulate.a = 0.0
	_complete.pivot_offset = _complete.size * 0.5
	_complete.scale = Vector2.ONE * Tuning.hud_panel_start_scale
	_again.modulate.a = 0.0
	_panel_tween = _new_tween()
	_panel_tween.tween_property(_complete, ^"modulate:a", 1.0, Tuning.hud_panel_pop_time * Tuning.hud_panel_fade_share)
	_panel_tween.parallel().tween_property(_complete, ^"scale", Vector2.ONE, Tuning.hud_panel_pop_time).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_panel_tween.tween_interval(Tuning.hud_count_delay)
	_panel_tween.tween_method(_set_count.bind(with_sound), 0.0, 1.0, Tuning.hud_count_time)
	_panel_tween.tween_callback(_blink_again)


func _set_count(progress: float, with_sound: bool) -> void:
	var step := floori(progress * Tuning.hud_count_steps)
	if with_sound and step != _count_step:
		Sfx.play(&"ui_tick", null, 1.0 + Tuning.hud_count_pitch_rise * progress)
	_count_step = step
	var time: float = float(_summary.get("time", 0.0))
	var deaths: int = int(_summary.get("deaths", 0))
	var lost: float = float(_summary.get("lost", 0.0))
	var recovered: float = float(_summary.get("recovered", 0.0))
	_stat_time.text = Strings.TEXT[&"complete_time"] % _format_time(time * progress)
	_stat_deaths.text = Strings.TEXT[&"complete_deaths"] % roundi(deaths * progress)
	_stat_lost.text = Strings.TEXT[&"complete_lost"] % roundi(lost * progress)
	_stat_recovered.text = Strings.TEXT[&"complete_recovered"] % roundi(recovered * progress)


func _blink_again() -> void:
	_kill(_again_tween)
	_again.modulate.a = 1.0
	_again_tween = _new_tween().set_loops()
	_again_tween.tween_property(_again, ^"modulate:a", Tuning.hud_again_blink_alpha, Tuning.hud_again_blink_time).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_again_tween.tween_property(_again, ^"modulate:a", 1.0, Tuning.hud_again_blink_time).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## Formats seconds as mm:ss.d.
static func _format_time(seconds: float) -> String:
	var deciseconds := maxi(floori(seconds * 10.0), 0)
	var minutes := floori(deciseconds / 600.0)
	var whole_seconds := posmod(floori(deciseconds / 10.0), 60)
	return "%02d:%02d.%d" % [minutes, whole_seconds, deciseconds % 10]


func _new_tween() -> Tween:
	var tween := create_tween()
	tween.set_ignore_time_scale(true)
	return tween


func _kill(tween: Tween) -> void:
	if tween != null and tween.is_valid():
		tween.kill()
