extends CanvasLayer
## Touch controls: a floating move stick on the left and goo buttons on the right. Each control draws into its own
## child canvas item of one canvas node, and only when its look changes, so the controls at rest cost no rebuild.
## Each finger stays bound to the control it started on until it lifts. A touch becomes Input.action_press on the
## same InputMap actions as the pad, so gameplay code never knows that touch exists.

signal input_mode_changed(mode: StringName)
## The controls pressed or released an InputMap action.
signal action_changed(action: StringName, pressed: bool)

const TouchStick := preload("res://scripts/ui/touch/touch_stick.gd")
const TouchButton := preload("res://scripts/ui/touch/touch_button.gd")
const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")
const SafeArea := preload("res://scripts/ui/safe_area.gd")

const MODE_TOUCH := &"touch"
const MODE_KEYS := &"keys"
const MODE_PAD := &"pad"
## Above the HUD and the screen effects, so the vignette and the iris never hide a control.
const CANVAS_LAYER := 55
## A stick or trigger counts as input past this deflection, so drift or a trigger at rest never takes the mode.
const PAD_AXIS_SWITCH := 0.5
## Phone and media keys that are not game input: a volume press on a phone keeps the touch mode.
const SYSTEM_KEYS: Array[Key] = [KEY_VOLUMEUP, KEY_VOLUMEDOWN, KEY_VOLUMEMUTE, KEY_BACK, KEY_MENU, KEY_HOMEPAGE, KEY_SEARCH, KEY_MEDIAPLAY, KEY_MEDIASTOP, KEY_MEDIAPREVIOUS, KEY_MEDIANEXT, KEY_MEDIARECORD, KEY_STANDBY]
const BIND_STICK := &"stick"
const AIM_ACTIONS: Array[StringName] = [&"fire", &"aim", &"aim_left", &"aim_right", &"aim_up", &"aim_down"]
const AIM_DOTS := 36
const SPRING_MAX_STEP := 1.0 / 120.0
## Keeps a fed aim vector just past the right stick dead zone of the player, so the smallest drag still aims.
const AIM_FEED_EPSILON := 0.002
const WARM_UP_FRAMES := 4
const WARM_UP_ALPHA := 0.01
## Drawn elements: the stick, the aim reach, six buttons and the aim knob, in back-to-front order.
const ELEMENTS := 9

enum Context { NONE, PLAY, DOWN, GOAL }
enum AimPhase { IDLE, DRAG, FIRING }

var touch_enabled := false
var input_mode: StringName = MODE_KEYS

var _forced := false
## False until the first real input; a pad that connects before it takes the mode (Android reports pads late).
var _had_input := false
## Mode of the last real input; it takes effect when the hold after the last change ends.
var _pending_mode: StringName = MODE_KEYS
var _mode_hold: SceneTreeTimer
var _mode_queued := false
var _shown := false
var _context := Context.NONE
var _canvas: Control
var _batch := ShapeBatch.new()
var _safe := Rect2()
var _scale := 1.0
var _clock := 0.0
var _stick: TouchStick
var _jump: TouchButton
var _shoot: TouchButton
var _aim: TouchButton
var _dodge: TouchButton
var _restart: TouchButton
var _perf: TouchButton
## Hit-test order; drawing goes in reverse.
var _buttons: Array = []
## Finger index -> BIND_STICK or the TouchButton it started on.
var _bindings := {}
## Action -> [clock, physics frame] of its press.
var _pressed := {}
## Actions that wait for their minimum hold before the release.
var _hold_until := {}
var _aim_phase := AimPhase.IDLE
var _aim_vec := Vector2.ZERO
var _aim_knob := Vector2.ZERO
var _aim_knob_vel := Vector2.ZERO
var _aim_open := 0.0
var _fire_started := 0.0
var _fire_pressed_at := 0.0
var _fire_released_frame := -1
var _shot_seen := false
var _warm_frames := 0
## One canvas item, batch and last drawn key for each drawn element: stick, aim reach, buttons (reverse order), aim knob.
var _items: Array[RID] = []
var _item_batches: Array = []
var _item_keys: Array = []
var _text_key: Array = []
# View size, canvas transform and fake insets of the last layout.
var _laid_view := Vector2.ZERO
var _laid_transform := Transform2D()
var _laid_insets := Vector4.ZERO


func _ready() -> void:
	layer = CANVAS_LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_forced = Harness.force_touch
	touch_enabled = _forced or DisplayServer.is_touchscreen_available()
	var pads := Harness.connected_pads()
	# A desktop with a touch screen starts on the keyboard; a phone with no pad starts on touch.
	if touch_enabled and (_forced or (pads.is_empty() and _touch_first())):
		input_mode = MODE_TOUCH
	elif not pads.is_empty():
		input_mode = MODE_PAD
	_pending_mode = input_mode
	_canvas = Control.new()
	_canvas.name = "TouchCanvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.modulate.a = 0.0
	_canvas.draw.connect(_draw_controls)
	add_child(_canvas)
	for i in ELEMENTS:
		var item := RenderingServer.canvas_item_create()
		RenderingServer.canvas_item_set_parent(item, _canvas.get_canvas_item())
		# Behind the parent, so the load count that the canvas node draws stays on top.
		RenderingServer.canvas_item_set_draw_behind_parent(item, true)
		_items.append(item)
		_item_batches.append(ShapeBatch.new())
		_item_keys.append(null)
	_stick = TouchStick.new()
	_jump = TouchButton.new(&"jump", &"jump", Tuning.touch_accent_jump)
	_shoot = TouchButton.new(&"shoot", &"shoot", Tuning.touch_accent_shoot)
	_aim = TouchButton.new(&"aim", &"aim", Tuning.touch_accent_aim)
	_dodge = TouchButton.new(&"dodge", &"dodge", Tuning.touch_accent_dodge)
	_restart = TouchButton.new(&"restart", &"restart", Tuning.touch_accent_neutral)
	_perf = TouchButton.new(&"perf", &"toggle_perf", Tuning.touch_accent_neutral)
	_buttons = [_jump, _shoot, _aim, _dodge, _restart, _perf]
	set_process(touch_enabled)
	set_process_input(touch_enabled)
	get_tree().root.window_input.connect(_on_window_input)
	get_viewport().size_changed.connect(_cancel_all)
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	Game.prop_shot.connect(_on_prop_shot)


func _exit_tree() -> void:
	_cancel_all()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for item: RID in _items:
			RenderingServer.free_rid(item)
		return
	# A finger held while the app goes to the background never sends its release.
	if what == NOTIFICATION_APPLICATION_PAUSED or (what == NOTIFICATION_APPLICATION_FOCUS_OUT and not _forced):
		_cancel_all()


func is_touch_mode() -> bool:
	return touch_enabled and input_mode == MODE_TOUCH


func is_showing() -> bool:
	return _shown


## Renders every control state once at almost zero opacity, so the first real touch does not hitch.
func warm_up() -> void:
	if not touch_enabled:
		return
	_layout()
	_stick.appear = 1.0
	for b: TouchButton in _buttons:
		b.appear = 1.0
		b.lit = 1.0
		b.burst(b.center)
	_aim_open = 1.0
	_warm_frames = WARM_UP_FRAMES


func _on_window_input(event: InputEvent) -> void:
	# A forced touch run and a scripted run keep their mode against real input; only the injected events switch it.
	if (_forced or Harness.blocks_real_input) and not Harness.injecting:
		return
	if event is InputEventScreenTouch:
		# A finger is never ambiguous and the touched control must work at once, so touch skips the hold.
		if event.pressed and touch_enabled:
			_request_mode(MODE_TOUCH, true)
	elif event is InputEventKey:
		if event.pressed and not event.echo and not SYSTEM_KEYS.has(event.keycode):
			_request_mode(MODE_KEYS)
	elif event is InputEventMouseButton:
		if event.pressed and event.device != InputEvent.DEVICE_ID_EMULATION:
			_request_mode(MODE_KEYS)
	elif event is InputEventJoypadButton:
		if event.pressed:
			_request_mode(MODE_PAD)
	elif event is InputEventJoypadMotion:
		var axis := (event as InputEventJoypadMotion).axis
		var value := (event as InputEventJoypadMotion).axis_value
		var trigger := axis == JOY_AXIS_TRIGGER_LEFT or axis == JOY_AXIS_TRIGGER_RIGHT
		if (value if trigger else absf(value)) > PAD_AXIS_SWITCH:
			_request_mode(MODE_PAD)


func _on_joy_connection_changed(_device: int, connected: bool) -> void:
	if Harness.ignores_input():
		return
	if connected:
		# A pad that connects in play takes the mode only with its first input.
		if not _had_input:
			_set_mode(MODE_PAD)
	elif Harness.connected_pads().is_empty() and input_mode == MODE_PAD:
		_set_mode(MODE_TOUCH if touch_enabled and (_forced or _touch_first()) else MODE_KEYS)


static func _touch_first() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios")


## The last real input wins: inputs of one frame settle at its end, and after a change the mode holds a moment,
## so two devices at once never flicker.
func _request_mode(mode: StringName, at_once := false) -> void:
	_had_input = true
	_pending_mode = mode
	if at_once:
		_set_mode(mode)
	elif not _mode_queued and (_mode_hold == null or _mode_hold.time_left <= 0.0):
		_mode_queued = true
		_apply_pending_mode.call_deferred()


func _apply_pending_mode() -> void:
	_mode_queued = false
	_set_mode(_pending_mode)


func _on_mode_hold_end() -> void:
	_set_mode(_pending_mode)


func _set_mode(mode: StringName) -> void:
	_pending_mode = mode
	if mode == input_mode:
		return
	input_mode = mode
	_mode_hold = get_tree().create_timer(Tuning.input_mode_hold, true, false, true)
	_mode_hold.timeout.connect(_on_mode_hold_end)
	if touch_enabled:
		_refresh_shown()
	input_mode_changed.emit(mode)


func _on_prop_shot(_kind: StringName, _at: Vector2, _dir: Vector2, _carried: int, _force: float, _predicted: Variant) -> void:
	if _aim_phase == AimPhase.FIRING:
		_shot_seen = true


func _input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch or event is InputEventScreenDrag) or Harness.ignores_input():
		return
	_refresh_shown()
	if not _shown:
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_finger_down(touch.index, touch.position)
		else:
			_finger_up(touch.index, touch.canceled)
	else:
		var drag := event as InputEventScreenDrag
		_finger_drag(drag.index, drag.position)


func _finger_down(index: int, p: Vector2) -> void:
	# A finger index can come back without its release; the old binding goes first.
	if _bindings.has(index):
		_finger_up(index, true)
	_layout()
	_apply_flags()
	for b: TouchButton in _buttons:
		if b.hit(p):
			_press_button(index, b, p)
			return
	var in_left_zone := p.x < _safe.position.x + _safe.size.x * Tuning.touch_left_zone and p.y > _safe.position.y + _safe.size.y * Tuning.touch_top_band
	if _stick.shown and not _stick.active and in_left_zone:
		_bindings[index] = BIND_STICK
		_stick.press(p)
		_haptic(&"ui_stick")


func _press_button(index: int, b: TouchButton, p: Vector2) -> void:
	if b == _aim:
		# One finger aims; a second finger, or a press while the last shot still leaves, does nothing.
		if _aim_phase != AimPhase.IDLE:
			return
		_aim_phase = AimPhase.DRAG
		_aim_vec = Vector2.ZERO
		_aim_knob = Vector2.ZERO
		_aim_knob_vel = Vector2.ZERO
	_bindings[index] = b
	var first := not b.pressed
	b.press(p)
	if first:
		_press_action(b.action, 1.0)
	_haptic(&"ui_press")


func _finger_drag(index: int, p: Vector2) -> void:
	var bound: Variant = _bindings.get(index)
	if bound is StringName and bound == BIND_STICK:
		_stick.drag(p)
	elif bound is TouchButton and bound == _aim and _aim_phase == AimPhase.DRAG:
		_aim_vec = ((p - _aim.center) / maxf(_aim.radius * Tuning.touch_aim_range, 1.0)).limit_length(1.0)


func _finger_up(index: int, canceled: bool) -> void:
	var bound: Variant = _bindings.get(index)
	_bindings.erase(index)
	if bound is StringName and bound == BIND_STICK:
		_stick.release()
		_feed_move()
	elif bound is TouchButton:
		var b: TouchButton = bound
		b.release()
		if b.pressed:
			return
		if b == _aim:
			_end_aim(canceled)
		else:
			_release_soon(b.action)


func _end_aim(canceled: bool) -> void:
	if canceled or _aim_vec.length() <= Tuning.touch_aim_cancel_radius:
		_aim_phase = AimPhase.IDLE
		_aim_vec = Vector2.ZERO
		for action: StringName in AIM_ACTIONS:
			_release_soon(action)
		_haptic(&"ui_cancel")
		Sfx.play(&"drip", null, 0.7, Tuning.touch_cancel_volume_db)
		return
	_aim_phase = AimPhase.FIRING
	_shot_seen = false
	_fire_started = _clock
	_fire_pressed_at = _clock
	_press_action(&"fire", 1.0)
	_aim.burst(_aim.center + _aim_vec * _aim.radius)
	_haptic(&"ui_fire")


## The release of the aim finger is the shot: fire stays held until a shot leaves, pressed again while the player
## is still in its shot cooldown, and the whole aim lets go after a give-up time (dead slime, goal).
func _step_fire() -> void:
	if _shot_seen or _clock - _fire_started >= Tuning.touch_fire_give_up:
		_aim_phase = AimPhase.IDLE
		_aim_vec = Vector2.ZERO
		for action: StringName in AIM_ACTIONS:
			_release_soon(action)
		return
	if _pressed.has(&"fire"):
		if _clock - _fire_pressed_at >= Tuning.touch_fire_retry and _held_long_enough(&"fire"):
			_release_now(&"fire")
			_fire_released_frame = Engine.get_physics_frames()
	elif Engine.get_physics_frames() > _fire_released_frame:
		_press_action(&"fire", 1.0)
		_fire_pressed_at = _clock


func _process(delta: float) -> void:
	var real := Juice.real_delta(delta)
	_clock += real
	_refresh_shown()
	_step_releases()
	if _aim_phase == AimPhase.FIRING:
		_step_fire()
	var target_alpha := 0.0
	if _shown:
		target_alpha = Tuning.touch_down_alpha if _context == Context.DOWN else 1.0
	_canvas.modulate.a = move_toward(_canvas.modulate.a, target_alpha, real / maxf(Tuning.touch_fade_time, 0.001))
	if _warm_frames > 0:
		_warm_frames -= 1
		_canvas.modulate.a = maxf(_canvas.modulate.a, WARM_UP_ALPHA)
	_canvas.visible = _canvas.modulate.a > 0.0
	if not _canvas.visible:
		return
	_layout_if_changed()
	if _shown:
		_feed_move()
		if _aim_phase != AimPhase.IDLE:
			_feed_aim()
	_update_pips()
	_aim.alert = 1.0 if _aim_phase == AimPhase.DRAG and _aim_vec.length() <= Tuning.touch_aim_cancel_radius else 0.0
	_aim_open = move_toward(_aim_open, 1.0 if _aim_phase == AimPhase.DRAG else 0.0, real / maxf(Tuning.touch_appear_time, 0.001))
	var knob_target := _aim_vec * _aim.radius * Tuning.touch_aim_range if _aim_phase == AimPhase.DRAG else Vector2.ZERO
	var remaining := real
	while remaining > 0.0:
		var step := minf(remaining, SPRING_MAX_STEP)
		_aim_knob_vel += ((knob_target - _aim_knob) * Tuning.touch_stick_knob_stiffness - _aim_knob_vel * Tuning.touch_stick_knob_damping) * step
		_aim_knob += _aim_knob_vel * step
		remaining -= step
	# Snapped, so the stick redraws only while the fade moves between steps.
	_stick.veil = snappedf(_slime_under_stick(), 0.25)
	_stick.update(real)
	for b: TouchButton in _buttons:
		b.lit = 1.0 if (b == _jump and _context == Context.GOAL) or _warm_frames > 0 else 0.0
		b.update(real)
	_redraw_changed()


func _refresh_shown() -> void:
	_context = _find_context() if touch_enabled else Context.NONE
	var on := touch_enabled and input_mode == MODE_TOUCH and _context != Context.NONE
	if on != _shown:
		_shown = on
		if not on:
			_cancel_all()
	_apply_flags()


func _find_context() -> Context:
	var player := Game.player
	if not is_instance_valid(player) or not player.is_inside_tree() or Game.input_tick <= 0:
		return Context.NONE
	match String(player.call(&"state_name")):
		"GOAL":
			return Context.GOAL
		"DEAD", "SPAWNING":
			return Context.DOWN
	return Context.PLAY


## Which controls the context shows; a control that hides lets go of its fingers and its action.
func _apply_flags() -> void:
	var playing := _shown and (_context == Context.PLAY or _context == Context.DOWN)
	_stick.shown = playing
	_jump.shown = _shown
	_shoot.shown = playing
	_aim.shown = playing
	_dodge.shown = playing
	_restart.shown = _shown
	_perf.shown = _shown
	if not _stick.shown and _stick.active:
		_unbind(BIND_STICK)
		_stick.release()
	for b: TouchButton in _buttons:
		if not b.shown and b.pressed:
			_unbind(b)
			b.clear()
			if b == _aim:
				_aim_phase = AimPhase.IDLE
				_aim_vec = Vector2.ZERO
				for action: StringName in AIM_ACTIONS:
					_release_now(action)
			else:
				_release_now(b.action)


func _unbind(control: Variant) -> void:
	for index: int in _bindings.keys():
		if is_same(_bindings[index], control):
			_bindings.erase(index)


## Places the controls again only when the view size or the canvas transform changed since the last layout.
func _layout_if_changed() -> void:
	var viewport := get_viewport()
	var view := viewport.get_visible_rect().size
	var to_window := viewport.get_final_transform()
	if view == _laid_view and to_window == _laid_transform and Harness.safe_insets == _laid_insets:
		return
	_layout()


func _layout() -> void:
	_laid_view = get_viewport().get_visible_rect().size
	_laid_transform = get_viewport().get_final_transform()
	_laid_insets = Harness.safe_insets
	var view := _laid_view
	_safe = SafeArea.rect(get_viewport())
	_scale = clampf(minf(view.x, view.y) / Tuning.touch_layout_reference, Tuning.touch_scale_range.x, Tuning.touch_scale_range.y)
	var bottom_left := Vector2(_safe.position.x, _safe.end.y)
	var top_right := Vector2(_safe.end.x, _safe.position.y)
	_stick.place((bottom_left + Vector2(Tuning.touch_stick_home.x, -Tuning.touch_stick_home.y) * _scale).round(), Tuning.touch_stick_radius * _scale, Tuning.touch_stick_knob_radius * _scale)
	_place(_jump, _safe.end - Tuning.touch_jump_offset * _scale, Tuning.touch_jump_radius)
	_place(_shoot, _safe.end - Tuning.touch_shoot_offset * _scale, Tuning.touch_shoot_radius)
	_place(_aim, _safe.end - Tuning.touch_aim_offset * _scale, Tuning.touch_aim_radius)
	_place(_dodge, _safe.end - Tuning.touch_dodge_offset * _scale, Tuning.touch_dodge_radius)
	_place(_restart, top_right + Vector2(-Tuning.touch_restart_offset.x, Tuning.touch_restart_offset.y) * _scale, Tuning.touch_restart_radius)
	_place(_perf, top_right + Vector2(-Tuning.touch_perf_offset.x, Tuning.touch_perf_offset.y) * _scale, Tuning.touch_perf_radius)


func _place(b: TouchButton, at: Vector2, base_radius: float) -> void:
	b.center = at.round()
	b.radius = base_radius * _scale


## 0..1: how close the slime on screen comes to the idle stick, from the start of the fade band to a touch of the rim.
func _slime_under_stick() -> float:
	var player := Game.player
	if _stick.active or not is_instance_valid(player) or not player.is_inside_tree():
		return 0.0
	var body: Variant = player.get(&"body_visual")
	var r := Tuning.radius_full
	if body is Node2D and is_instance_valid(body) and (body as Node2D).has_method(&"radius"):
		r = float((body as Node2D).call(&"radius"))
	var canvas := get_viewport().get_canvas_transform()
	var at: Vector2 = canvas * Vector2(player.call(&"visual_position"))
	var gap := at.distance_to(_stick.base) - _stick.radius - r * canvas.get_scale().x
	return 1.0 - clampf(gap / maxf(Tuning.touch_stick_veil_band * _scale, 1.0), 0.0, 1.0)


func _update_pips() -> void:
	var player := Game.player
	if is_instance_valid(player) and player.has_method(&"capacity"):
		_shoot.pip_capacity = int(player.call(&"capacity"))
		_shoot.pip_load = int(player.call(&"load_count"))
	else:
		_shoot.pip_capacity = 0


## The stick moves, runs at full deflection and crouches when pulled down.
func _feed_move() -> void:
	var x := _stick.move_output() if _stick.shown else 0.0
	_press_action(&"move_right", maxf(x, 0.0))
	_press_action(&"move_left", maxf(-x, 0.0))
	var player := Game.player
	_stick.run_blocked = is_instance_valid(player) and player.has_method(&"run_blocked") and bool(player.call(&"run_blocked"))
	_press_action(&"run", 1.0 if _stick.shown and _stick.run_output() else 0.0)
	_press_action(&"crouch", _stick.crouch_output() if _stick.shown else 0.0)


func _feed_aim() -> void:
	var v := _aim_feed_vector()
	_press_action(&"aim_right", maxf(v.x, 0.0))
	_press_action(&"aim_left", maxf(-v.x, 0.0))
	_press_action(&"aim_down", maxf(v.y, 0.0))
	_press_action(&"aim_up", maxf(-v.y, 0.0))


## Drag past the cancel ring maps to the whole force range. The player reads the right stick with a radial dead zone,
## so the fed length starts just past it; the slingshot flags flip the direction so that only the touch flag counts.
func _aim_feed_vector() -> Vector2:
	var length := _aim_vec.length()
	var cancel := Tuning.touch_aim_cancel_radius
	if length <= cancel:
		return Vector2.ZERO
	var force_share := clampf(inverse_lerp(cancel, 1.0, length), 0.0, 1.0)
	var fed := minf(lerpf(Tuning.aim_stick_deadzone + AIM_FEED_EPSILON, 1.0, force_share), 1.0)
	var dir := _aim_vec / length
	if Tuning.touch_aim_slingshot != Tuning.aim_invert_slingshot:
		dir = -dir
	return dir * fed


## Force the player reads from the current drag, after its own force curve.
func _aim_force() -> float:
	var share := clampf(inverse_lerp(Tuning.touch_aim_cancel_radius, 1.0, _aim_vec.length()), 0.0, 1.0)
	return pow(share, Tuning.aim_force_curve)


func _press_action(action: StringName, strength: float) -> void:
	if not InputMap.has_action(action):
		return
	if strength <= 0.0:
		if _pressed.has(action):
			_release_now(action)
		return
	_hold_until.erase(action)
	Input.action_press(action, minf(strength, 1.0))
	if not _pressed.has(action):
		_pressed[action] = [_clock, Engine.get_physics_frames()]
		action_changed.emit(action, true)


func _release_soon(action: StringName) -> void:
	if _pressed.has(action):
		_hold_until[action] = true


## Taps can be shorter than a physics tick, and a hitstop can stretch a tick: an action is held for a minimum
## real time and a minimum count of physics ticks.
func _held_long_enough(action: StringName) -> bool:
	var at: Array = _pressed[action]
	return _clock >= float(at[0]) + Tuning.touch_min_hold and Engine.get_physics_frames() >= int(at[1]) + Tuning.touch_min_hold_ticks


func _step_releases() -> void:
	for action: StringName in _hold_until.keys():
		if not _pressed.has(action):
			_hold_until.erase(action)
		elif _held_long_enough(action):
			_release_now(action)


func _release_now(action: StringName) -> void:
	_hold_until.erase(action)
	if not _pressed.has(action):
		return
	_pressed.erase(action)
	Input.action_release(action)
	action_changed.emit(action, false)


func _cancel_all() -> void:
	if _stick == null:
		return
	_stick.release()
	for b: TouchButton in _buttons:
		b.clear()
	_bindings.clear()
	_aim_phase = AimPhase.IDLE
	_aim_vec = Vector2.ZERO
	for action: StringName in _pressed.keys():
		_release_now(action)


## Juice sends the vibration to the phone and limits its rate.
func _haptic(preset: StringName) -> void:
	Juice.haptic(preset)


func _draw_controls() -> void:
	_draw_load_count()


## Rebuilds only the elements whose look changed since their last draw; the rest keep their canvas item as it is.
func _redraw_changed() -> void:
	if not Tuning.fx_touch_redraw:
		return
	var feather := Tuning.touch_feather * _scale
	for i in ELEMENTS:
		var key := _element_key(i)
		key.append(feather)
		if key == _item_keys[i]:
			continue
		_item_keys[i] = key
		_batch = _item_batches[i]
		_batch.clear()
		_batch.feather = feather
		_draw_element(i)
		RenderingServer.canvas_item_clear(_items[i])
		_batch.commit(_items[i])
	var text_key := [_shoot.count_anchor(), _shoot.pip_load, _shoot.appear, _shoot.accent]
	if text_key != _text_key:
		_text_key = text_key
		_canvas.queue_redraw()


func _element_button(i: int) -> TouchButton:
	return _buttons[_buttons.size() - 1 - (i - 1)]


func _element_key(i: int) -> Array:
	if i == 0:
		return _stick.visual_key()
	if i == ELEMENTS - 1:
		if _aim.appear <= 0.0 or (_aim_phase == AimPhase.IDLE and _aim_knob.length() < 1.0):
			return []
		return [_aim.appear, _aim.center, _aim.radius, _aim.accent, _aim.alert, _aim_knob.snapped(Vector2(0.01, 0.01))]
	if i == 1:
		if _aim_open <= 0.0 or _aim.appear <= 0.0:
			return []
		return [_aim_open, _aim.center, _aim.radius, _aim.accent, _aim.alert, _aim_vec, _scale]
	return _element_button(i - 1).visual_key()


func _draw_element(i: int) -> void:
	if i == 0:
		_stick.draw(_batch)
	elif i == 1:
		_draw_aim_reach()
	elif i == ELEMENTS - 1:
		_draw_aim_knob()
	else:
		_element_button(i - 1).draw(_batch)


## Reach ring of the aim drag, the cancel ring in the middle and the force arc around the drag direction.
func _draw_aim_reach() -> void:
	if _aim_open <= 0.0 or _aim.appear <= 0.0:
		return
	var a := ease(_aim_open, 0.5)
	var reach := _aim.radius * Tuning.touch_aim_range * lerpf(0.7, 1.0, a)
	var accent := _aim.accent
	_batch.disc(_aim.center, reach, Color(Tuning.touch_fill_color, a * 0.3))
	var dot_r := 2.5 * _scale
	for i in AIM_DOTS:
		_batch.disc(_aim.center + Vector2.from_angle(TAU * i / AIM_DOTS) * reach, dot_r, Color(accent, a * 0.6))
	var force := _aim_force()
	if force > 0.0 and _aim.alert < 1.0:
		var start := _aim_vec.angle() - PI * force
		_batch.arc(_aim.center, reach, start, start + TAU * force, 6.0 * _scale, Color(accent.lightened(0.3), a * 0.95))
	var cancel_r := reach * Tuning.touch_aim_cancel_radius
	_batch.disc(_aim.center, cancel_r, Color(Tuning.touch_accent_cancel, a * 0.12 * (0.5 + _aim.alert)))
	_batch.ring(_aim.center, cancel_r, 2.0 * _scale, Color(Tuning.touch_accent_cancel, a * (0.3 + 0.5 * _aim.alert)))


## Goo neck from the aim button to the finger, and the knob under the finger (a cross while a release cancels).
func _draw_aim_knob() -> void:
	if _aim.appear <= 0.0 or (_aim_phase == AimPhase.IDLE and _aim_knob.length() < 1.0):
		return
	var a := ease(_aim.appear, 0.4)
	var color := _aim.accent.lerp(Tuning.touch_accent_cancel, _aim.alert)
	var k := _aim.center + _aim_knob
	var kr := _aim.radius * 0.42
	if _aim_knob.length() > 1.0:
		var side := _aim_knob.normalized().orthogonal()
		_batch.polygon(PackedVector2Array([_aim.center + side * kr * 0.35, k + side * kr * 0.6, k - side * kr * 0.6, _aim.center - side * kr * 0.35]), Color(color.darkened(0.4), a * 0.7))
	_batch.disc(k, kr, Color(color, a * 0.92))
	_batch.ring(k, kr, kr * 0.14, Color(Tuning.touch_fill_color, a))
	_batch.disc(k + Vector2(-0.32, -0.38) * kr, kr * 0.24, Color(1.0, 1.0, 1.0, a * 0.45))
	if _aim.alert > 0.0:
		var d := kr * 0.42
		var ink := Color(Tuning.touch_fill_color, a * _aim.alert)
		_batch.stroke(PackedVector2Array([k + Vector2(-d, -d), k + Vector2(d, d)]), kr * 0.2, ink)
		_batch.stroke(PackedVector2Array([k + Vector2(-d, d), k + Vector2(d, -d)]), kr * 0.2, ink)


## The load number over the quick shot gauge, once the room is too large for pips.
func _draw_load_count() -> void:
	var anchor := _shoot.count_anchor()
	if anchor.z <= 0.0:
		return
	var font := ThemeDB.fallback_font
	var size := int(maxf(anchor.z, 10.0))
	var text := str(_shoot.pip_load)
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var at := Vector2(anchor.x - width * 0.5, anchor.y + size * 0.35)
	var a := ease(_shoot.appear, 0.4)
	_canvas.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, maxi(int(size * 0.25), 2), Color(Tuning.touch_fill_color, a))
	_canvas.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(_shoot.accent.lightened(0.3), a))
