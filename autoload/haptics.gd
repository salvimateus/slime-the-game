extends Node
## Vibration engine of Juice: controller rumble and phone vibration from the preset table in Tuning.
## One vibration plays at a time. A rate limit and priorities keep many small events from summing to a buzz.

signal logged(event_name: String, data: Dictionary)

const MODE_PAD := &"pad"
const MODE_TOUCH := &"touch"
const MODE_KEYS := &"keys"
const PAD_AXIS_SWITCH := 0.5
# A fade step overlaps the next one a little, so the rumble does not drop out between steps.
const FADE_STEP_OVERLAP := 1.5

## Input mode that overrides TouchControls; the Harness sets it for runs with no device.
var forced_mode: StringName = &""
## When true, every start and every drop goes out through `logged`.
var logging := false

var _warned := {}
var _last_start := {}
var _clock_ms := 0.0
var _last_any_start := -1.0e9
var _pad_device := 0
var _was_paused := false
# Active vibration.
var _active := false
var _preset: StringName = &""
var _mode: StringName = &""
var _low := 0.0
var _high := 0.0
var _phone_amp := 0.0
var _ms := 0.0
var _phone_ms := 0.0
var _pulses := 1
var _gap := 0.0
var _fade := false
var _prio := 0
var _elapsed := 0.0
var _total := 0.0
var _sent_pulse := -1
var _next_fade_send := 0.0


func _ready() -> void:
	var pads := Harness.connected_pads()
	if not pads.is_empty():
		_pad_device = pads[0]
	get_tree().root.window_input.connect(_on_window_input)
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_connect_input_mode.call_deferred()


func _connect_input_mode() -> void:
	var touch := get_node_or_null(^"/root/TouchControls")
	if touch != null and touch.has_signal(&"input_mode_changed"):
		touch.connect(&"input_mode_changed", func(_mode_name: StringName) -> void: stop(&"input_mode"))


func play(preset: StringName, strength: float) -> void:
	var presets: Dictionary = Tuning.haptics_presets
	if not presets.has(preset):
		if not _warned.has(preset):
			_warned[preset] = true
			push_warning("Juice.haptic: unknown preset '%s'" % preset)
		return
	if not Tuning.haptics_enabled or Tuning.haptics_strength <= 0.0 or get_tree().paused:
		return
	var mode := current_mode()
	if mode != MODE_PAD and mode != MODE_TOUCH:
		return
	var p: Dictionary = presets[preset]
	var prio: int = int(p.get("prio", 1))
	var cooldown: float = float(p.get("cooldown_ms", 0.0))
	var last: float = float(_last_start.get(preset, -1.0e9))
	if _clock_ms - last < cooldown:
		_drop(preset, &"cooldown")
		return
	var active_rank := _active_rank()
	if prio < active_rank:
		_drop(preset, &"busy")
		return
	if prio <= active_rank or (_clock_ms - _last_any_start < Tuning.haptics_min_gap_ms and prio <= _prio):
		# Same rank while the active one still holds, or too soon after the last start: keep the first one.
		_drop(preset, &"rate")
		return
	strength = clampf(strength, 0.0, 1.0)
	var floor_share: float = float(p.get("floor", 0.5))
	var level := lerpf(floor_share, 1.0, strength) * clampf(Tuning.haptics_strength, 0.0, 1.0)
	_preset = preset
	_mode = mode
	_low = clampf(float(p.get("low", 0.0)) * level, 0.0, 1.0)
	_high = clampf(float(p.get("high", 0.0)) * level, 0.0, 1.0)
	_phone_amp = clampf(float(p.get("phone_amp", 0.5)) * level, 0.0, 1.0)
	_ms = maxf(float(p.get("ms", 50.0)), 1.0)
	_phone_ms = maxf(float(p.get("phone_ms", _ms)), 1.0)
	_pulses = maxi(int(p.get("pulses", 1)), 1)
	if mode == MODE_TOUCH:
		_ms = _phone_ms
	_gap = maxf(float(p.get("gap_ms", 0.0)), 0.0)
	_fade = bool(p.get("fade", false))
	_prio = prio
	_elapsed = 0.0
	_total = _ms * _pulses + _gap * (_pulses - 1)
	_sent_pulse = -1
	_next_fade_send = 0.0
	_active = true
	_last_start[preset] = _clock_ms
	_last_any_start = _clock_ms
	if logging:
		var data := {"preset": String(preset), "strength": snappedf(strength, 0.001), "mode": String(mode), "pulses": _pulses, "gap_ms": _gap, "fade": _fade}
		if mode == MODE_PAD:
			data["device"] = _pad_device
			data["strong"] = snappedf(_low, 0.001)
			data["weak"] = snappedf(_high, 0.001)
			data["ms"] = _ms
		else:
			data["phone_amp"] = snappedf(_phone_amp, 0.001)
			data["phone_ms"] = _phone_ms
		logged.emit("haptic", data)
	_step(0.0)


## Stops every motor and forgets the active vibration. A stop before the natural end is logged with its reason.
func stop(reason: StringName = &"end") -> void:
	if not _active:
		return
	_active = false
	_prio = 0
	if logging and reason != &"end":
		logged.emit("haptic_stop", {"preset": String(_preset), "reason": String(reason), "elapsed_ms": snappedf(_elapsed, 0.1)})
	if _mode == MODE_PAD:
		Input.stop_joy_vibration(_pad_device)
	# A phone pulse is never longer than one fade step or one short pulse, so it ends on its own.


func current_mode() -> StringName:
	if forced_mode != &"":
		return forced_mode
	var touch := get_node_or_null(^"/root/TouchControls")
	if touch == null:
		return MODE_KEYS
	return touch.get(&"input_mode")


func _process(delta: float) -> void:
	var real := Juice.real_delta(delta) * 1000.0
	_clock_ms += real
	var paused := get_tree().paused
	if paused and not _was_paused:
		stop(&"pause")
	elif _active and not Tuning.haptics_enabled:
		stop(&"off")
	_was_paused = paused
	if _active and not paused:
		_step(real)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_EXIT_TREE:
			stop(&"app")


func _step(real_ms: float) -> void:
	_elapsed += real_ms
	if _elapsed >= _total:
		stop()
		return
	var period := _ms + _gap
	var pulse := mini(floori(_elapsed / period), _pulses - 1)
	var in_pulse := _elapsed - pulse * period < _ms
	if not in_pulse:
		return
	if _fade:
		if _elapsed < _next_fade_send:
			return
		var level := 1.0 - _elapsed / _total
		var step_ms := minf(Tuning.haptics_fade_step_ms, _total - _elapsed)
		_next_fade_send = _elapsed + Tuning.haptics_fade_step_ms
		_send(_low * level, _high * level, _phone_amp * level, step_ms * FADE_STEP_OVERLAP, step_ms)
	elif pulse != _sent_pulse:
		_sent_pulse = pulse
		_send(_low, _high, _phone_amp, _ms, _ms)


func _send(strong: float, weak: float, phone_amp: float, pad_ms: float, phone_ms: float) -> void:
	if _mode == MODE_PAD:
		Input.start_joy_vibration(_pad_device, weak, strong, pad_ms / 1000.0)
	elif OS.has_feature("mobile"):
		Input.vibrate_handheld(int(phone_ms), phone_amp)


## Priority that a new event must reach to replace the active vibration; 0 once it is near its end.
func _active_rank() -> int:
	if not _active:
		return 0
	if _total - _elapsed < _total * Tuning.haptics_yield_share:
		return 0
	return _prio


func _drop(preset: StringName, reason: StringName) -> void:
	if logging:
		logged.emit("haptic_drop", {"preset": String(preset), "reason": String(reason), "active": String(_preset) if _active else ""})


func _on_window_input(event: InputEvent) -> void:
	if Harness.ignores_input():
		return
	if event is InputEventJoypadButton:
		if event.pressed:
			_pad_device = _pad_of(event)
	elif event is InputEventJoypadMotion:
		if absf(event.axis_value) > PAD_AXIS_SWITCH:
			_pad_device = _pad_of(event)


## The pad that Harness injects stands in for pad 0.
static func _pad_of(event: InputEvent) -> int:
	return 0 if event.device == Tuning.harness_device else event.device


func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if connected or device != _pad_device or Harness.ignores_input():
		return
	stop(&"disconnect")
	var pads := Harness.connected_pads()
	if not pads.is_empty():
		_pad_device = pads[0]
