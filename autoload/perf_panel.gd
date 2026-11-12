extends CanvasLayer
## In-game performance panel: frame, script, draw and render times, draw calls, device and GPU names, and switches for
## the costly systems, saved in user://. Hidden by default: the toggle_perf action (F3, or the small touch button)
## opens it. On a keyboard the number keys flip the switches; on touch a tap on a switch flips it.
## It also times every frame (always on, a few clock reads), so Harness --perf-summary and the panel read the same data:
## script = every _process and _physics_process callback, draw = every _draw callback (the deferred redraw flush),
## render = the RenderingServer frame (canvas render, submit and swap, which can wait for the GPU).

const SafeArea := preload("res://scripts/ui/safe_area.gd")
const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

const SETTINGS_PATH := "user://perf.cfg"
const SETTINGS_SECTION := "systems"
## Above the touch controls, so a tap on a row never reaches them.
const CANVAS_LAYER := 60
const MARGIN := 14.0
const TOP_OFFSET := 84.0
const LINE_GAP := 5.0
const BOX_SIZE := 22.0
const COLUMNS := 2
## Runs before and after every other node, so the two stamps bracket all script callbacks of a frame.
const FIRST_PRIORITY := -1000000
const LAST_PRIORITY := 1000000
## Each switch is a bool field of Tuning that its system reads every frame.
const SWITCHES: Array[Dictionary] = [
	{"field": &"fx_sparks", "label": "Sparks, debris"},
	{"field": &"fx_droplets", "label": "Goo droplets"},
	{"field": &"fx_background", "label": "Background"},
	{"field": &"fx_vignette", "label": "Vignette"},
	{"field": &"goo_gloss", "label": "Goo gloss"},
	{"field": &"haptics_enabled", "label": "Vibration"},
	{"field": &"fx_fire_rich", "label": "Rich fire"},
	{"field": &"fx_decor_motion", "label": "Moving decor"},
	{"field": &"fx_hints", "label": "Hints"},
	{"field": &"fx_enemies", "label": "Enemies"},
	{"field": &"fx_touch_redraw", "label": "Touch redraw"},
	{"field": &"fx_temperature_art", "label": "Temp. art"},
	{"field": &"", "label": "Quality", "action": &"quality"},
	{"field": &"", "label": "Render", "action": &"render"},
]
const SWITCH_KEYS: Array[Key] = [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9, KEY_0, KEY_MINUS, KEY_EQUAL, KEY_F5, KEY_F6]
## Switches of fields that a quality level owns are saved here, as overrides that last until the next level change.
const OVERRIDES_SECTION := "overrides"
const WARM_UP_FRAMES := 4
const WARM_UP_ALPHA := 0.01


## Stamps the start of the process and physics callbacks of each frame.
class FirstStamp extends Node:
	var process_start := 0
	var physics_start := 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_priority = FIRST_PRIORITY
		process_physics_priority = FIRST_PRIORITY

	func _process(_delta: float) -> void:
		process_start = Time.get_ticks_usec()

	func _physics_process(_delta: float) -> void:
		physics_start = Time.get_ticks_usec()


var _open := false
var _canvas: Control
var _style: StyleBoxFlat
var _lines := PackedStringArray()
var _panel_rect := Rect2()
var _row_rects: Array[Rect2] = []
var _scale := 1.0
var _refresh := 0.0
var _draw_calls_max := 0
## Fingers that started on the panel; their drag and release are consumed too.
var _fingers := {}
var _warm_frames := 0
var _boxes := ShapeBatch.new()

var _first: FirstStamp
var _physics_usec := 0
var _process_end := 0
var _pre_draw := 0
var _last_post := 0
## Sums over the panel window: frames, frame, process, physics, draw, render (usec) and the worst frame.
var _win := PackedInt64Array([0, 0, 0, 0, 0, 0, 0])
## The same sums over a run (Harness --perf-summary), plus draw calls, objects and primitives.
var _run := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
var _run_on := false
var _run_skip := 0
## Hand flips of the fields that Quality owns: field -> value.
var _overrides := {}
var _last_busy_ms := 0.0


func _ready() -> void:
	layer = CANVAS_LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = LAST_PRIORITY
	process_physics_priority = LAST_PRIORITY
	_first = FirstStamp.new()
	_first.name = "FirstStamp"
	add_child(_first)
	RenderingServer.frame_pre_draw.connect(_on_pre_draw)
	RenderingServer.frame_post_draw.connect(_on_post_draw)
	_canvas = Control.new()
	_canvas.name = "PerfCanvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.visible = false
	_canvas.draw.connect(_draw_panel)
	add_child(_canvas)
	_style = StyleBoxFlat.new()
	_style.bg_color = Color(0.035, 0.05, 0.08, 0.88)
	_style.border_color = Tuning.goo_body_color
	_style.set_border_width_all(3)
	_style.set_corner_radius_all(16)
	_load_settings()
	if Harness.open_perf_panel:
		_set_open(true)


func is_open() -> bool:
	return _open


func toggle() -> void:
	_set_open(not _open)


## Starts the run sums; the first skip frames are left out (load and warm-up).
func begin_run(skip: int) -> void:
	_run.fill(0)
	_run_skip = skip
	_run_on = true
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


## Averages of the run in ms (and draw counts), for Harness --perf-summary.
func run_summary() -> Dictionary:
	var n := maxf(float(_run[0]), 1.0)
	return {
		"frames": _run[0],
		"frame_avg": _run[1] / n / 1000.0,
		"frame_worst": _run[6] / 1000.0,
		"process_avg": _run[2] / n / 1000.0,
		"physics_avg": _run[3] / n / 1000.0,
		"script_avg": (_run[2] + _run[3]) / n / 1000.0,
		"draw_avg": _run[4] / n / 1000.0,
		"render_avg": _run[5] / n / 1000.0,
		"draw_calls_avg": _run[7] / n,
		"draw_calls_max": _run[10],
		"objects_avg": _run[8] / n,
		"primitives_avg": _run[9] / n,
	}


## Draws the panel text once at almost zero opacity during the load, so the font cache does not hitch on first open.
func warm_up() -> void:
	Quality.warm_up()
	if _open:
		return
	_warm_frames = WARM_UP_FRAMES
	_canvas.visible = true
	_canvas.modulate.a = WARM_UP_ALPHA
	_rebuild()


func _set_open(open: bool) -> void:
	_open = open
	_warm_frames = 0
	_canvas.visible = open
	_canvas.modulate.a = 1.0
	_fingers.clear()
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), open or _run_on or Quality.wants_render_time())
	_draw_calls_max = 0
	_win.fill(0)
	_refresh = 0.0
	if open:
		_rebuild()


func _physics_process(_delta: float) -> void:
	_physics_usec += Time.get_ticks_usec() - _first.physics_start


func _process(delta: float) -> void:
	if Input.is_action_just_pressed(&"toggle_perf"):
		toggle()
	_process_end = Time.get_ticks_usec()
	if _warm_frames > 0:
		_warm_frames -= 1
		if _warm_frames == 0 and not _open:
			_canvas.visible = false
			_canvas.modulate.a = 1.0
		return
	if not _open:
		return
	_draw_calls_max = maxi(_draw_calls_max, _draw_calls())
	_refresh -= Juice.real_delta(delta)
	if _refresh <= 0.0:
		_refresh = Tuning.perf_refresh_time
		_rebuild()


func _on_pre_draw() -> void:
	_pre_draw = Time.get_ticks_usec()


## One frame is complete: the process stamps, the draw flush up to the render and the render itself.
func _on_post_draw() -> void:
	var now := Time.get_ticks_usec()
	var frame := now - _last_post if _last_post > 0 else 0
	_last_post = now
	var process := maxi(_process_end - _first.process_start, 0)
	var physics := _physics_usec
	_physics_usec = 0
	var draw := maxi(_pre_draw - _process_end, 0)
	var render := maxi(now - _pre_draw, 0)
	_last_busy_ms = (process + physics + draw) / 1000.0
	if frame <= 0:
		return
	_add(_win, frame, process, physics, draw, render)
	if _run_on:
		if _run_skip > 0:
			_run_skip -= 1
			return
		_add(_run, frame, process, physics, draw, render)
		var calls := _draw_calls()
		_run[7] += calls
		_run[8] += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
		_run[9] += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		_run[10] = maxi(_run[10], calls)


func _add(sums: PackedInt64Array, frame: int, process: int, physics: int, draw: int, render: int) -> void:
	sums[0] += 1
	sums[1] += frame
	sums[2] += process
	sums[3] += physics
	sums[4] += draw
	sums[5] += render
	sums[6] = maxi(sums[6], frame)


func _input(event: InputEvent) -> void:
	if not _open or Harness.ignores_input():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var row := SWITCH_KEYS.find((event as InputEventKey).physical_keycode)
		if row >= 0 and row < SWITCHES.size():
			_flip(row)
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed and _panel_rect.has_point(touch.position):
			_fingers[touch.index] = true
			for row in _row_rects.size():
				if _row_rects[row].has_point(touch.position):
					_flip(row)
			get_viewport().set_input_as_handled()
		elif not touch.pressed and _fingers.has(touch.index):
			_fingers.erase(touch.index)
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and _fingers.has((event as InputEventScreenDrag).index):
		get_viewport().set_input_as_handled()


func _flip(row: int) -> void:
	var action: StringName = SWITCHES[row].get("action", &"")
	if action == &"quality":
		Quality.cycle_mode()
	elif action == &"render":
		Quality.cycle_render_mode()
	else:
		var field: StringName = SWITCHES[row].field
		var value := not bool(Tuning.get(field))
		Tuning.set(field, value)
		if Quality.owns(field):
			if value == Quality.level_value(field):
				_overrides.erase(field)
			else:
				_overrides[field] = value
		_save_settings()
	_rebuild()


## Script, physics and draw flush time of the last frame in ms (Quality reads it for its margin).
func last_script_and_draw_ms() -> float:
	return _last_busy_ms


## Sets the hand flips of the quality fields again over the values of the level.
func apply_overrides() -> void:
	for field: StringName in _overrides:
		Tuning.set(field, _overrides[field])


## A new quality level drops the hand flips of its fields.
func clear_overrides() -> void:
	if _overrides.is_empty():
		return
	_overrides.clear()
	_save_settings()
	if _open:
		_rebuild()


func _load_settings() -> void:
	if not Harness.uses_user_settings():
		return
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	for entry: Dictionary in SWITCHES:
		var field: StringName = entry.field
		if field == &"":
			continue
		if Quality.owns(field):
			# An old file saved every switch; only a hand flip in the overrides section beats the quality level.
			if config.has_section_key(OVERRIDES_SECTION, String(field)):
				_overrides[field] = bool(config.get_value(OVERRIDES_SECTION, String(field)))
			continue
		Tuning.set(field, bool(config.get_value(SETTINGS_SECTION, String(field), Tuning.get(field))))
	apply_overrides()


func _save_settings() -> void:
	if not Harness.uses_user_settings():
		return
	var config := ConfigFile.new()
	for entry: Dictionary in SWITCHES:
		var field: StringName = entry.field
		if field == &"" or Quality.owns(field):
			continue
		config.set_value(SETTINGS_SECTION, String(field), bool(Tuning.get(field)))
	for field: StringName in _overrides:
		config.set_value(OVERRIDES_SECTION, String(field), _overrides[field])
	var err := config.save(SETTINGS_PATH)
	if err != OK:
		push_warning("PerfPanel: cannot save %s (err=%d)" % [SETTINGS_PATH, err])


func _draw_calls() -> int:
	return int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))


func _rebuild() -> void:
	var viewport_rid := get_viewport().get_viewport_rid()
	var n := maxf(float(_win[0]), 1.0)
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
	_lines = PackedStringArray([
		"%d FPS (display %d Hz)   frame %.1f ms   worst %.1f" % [Engine.get_frames_per_second(), roundi(DisplayServer.screen_get_refresh_rate()), _win[1] / n / 1000.0, _win[6] / 1000.0],
		"Script %.1f   draw %.1f   render %.1f ms" % [(_win[2] + _win[3]) / n / 1000.0, _win[4] / n / 1000.0, _win[5] / n / 1000.0],
		"GPU %s" % ("%.2f ms" % gpu if gpu > 0.0 else "n/a"),
		"Calls %d (max %d)   prims %d" % [_draw_calls(), _draw_calls_max, RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)],
		"Objects %d" % RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		"Device  %s" % OS.get_model_name(),
		"GPU  %s" % RenderingServer.get_video_adapter_name(),
		"Renderer  %s / %s" % [RenderingServer.get_current_rendering_method(), RenderingServer.get_current_rendering_driver_name()],
		Quality.describe(),
		"VRAM %.0f MB   tex %.0f MB   RAM %.0f MB" % [Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0, OS.get_static_memory_usage() / 1048576.0],
	])
	_win.fill(0)
	_canvas.queue_redraw()


func _layout() -> void:
	var view := get_viewport().get_visible_rect().size
	_scale = clampf(minf(view.x, view.y) / Tuning.touch_layout_reference, Tuning.touch_scale_range.x, Tuning.touch_scale_range.y)
	var safe := SafeArea.rect(get_viewport())
	var line_h := (Tuning.perf_font_size + LINE_GAP) * _scale
	var row_h := Tuning.perf_row_height * _scale
	var rows := ceili(float(SWITCHES.size()) / COLUMNS)
	var size := Vector2(Tuning.perf_panel_width * _scale, MARGIN * 2.0 * _scale + line_h * _lines.size() + row_h * rows)
	_panel_rect = Rect2(safe.position + Vector2(24.0, TOP_OFFSET) * _scale, size)
	_row_rects.clear()
	var top := _panel_rect.position.y + MARGIN * _scale + line_h * _lines.size()
	var col_w := size.x / COLUMNS
	for i in SWITCHES.size():
		var col := i / rows
		var row := i % rows
		_row_rects.append(Rect2(_panel_rect.position.x + col_w * col, top + row_h * row, col_w, row_h))


func _draw_panel() -> void:
	_layout()
	var font := ThemeDB.fallback_font
	var font_size := roundi(Tuning.perf_font_size * _scale)
	_canvas.draw_style_box(_style, _panel_rect)
	var x := _panel_rect.position.x + MARGIN * _scale
	var line_h := (Tuning.perf_font_size + LINE_GAP) * _scale
	var y := _panel_rect.position.y + MARGIN * _scale + font_size
	for line: String in _lines:
		_canvas.draw_string(font, Vector2(x, y), line, HORIZONTAL_ALIGNMENT_LEFT, _panel_rect.size.x - MARGIN * 2.0 * _scale, font_size, Color(0.9, 0.95, 1.0))
		y += line_h
	var touch := TouchControls.is_touch_mode()
	# Every box goes into one batch before the labels, so the boxes and the text each take one draw call.
	_boxes.clear()
	_boxes.feather = 0.0
	for i in SWITCHES.size():
		var box := _box_rect(i)
		_boxes.rect(box, Tuning.goo_body_color if _switch_on(i) else Color(0.2, 0.22, 0.26))
		_boxes.rect(box, Color(0.9, 0.95, 1.0, 0.8), 2.0)
	_boxes.commit(_canvas.get_canvas_item())
	for i in SWITCHES.size():
		var rect := _row_rects[i]
		var on := _switch_on(i)
		var box := _box_rect(i)
		var label := _switch_label(i)
		if not touch:
			label = "[%s] %s" % [OS.get_keycode_string(SWITCH_KEYS[i]), label]
		var label_x := box.end.x + 10.0 * _scale
		_canvas.draw_string(font, Vector2(label_x, rect.get_center().y + font_size * 0.35), label, HORIZONTAL_ALIGNMENT_LEFT, rect.end.x - label_x - 4.0, font_size, Color(1.0, 1.0, 1.0) if on else Color(0.6, 0.62, 0.66))


func _switch_on(i: int) -> bool:
	var field: StringName = SWITCHES[i].field
	return true if field == &"" else bool(Tuning.get(field))


func _switch_label(i: int) -> String:
	var label: String = SWITCHES[i].label
	match SWITCHES[i].get("action", &""):
		&"quality": label += " " + Quality.MODE_NAMES[Quality.mode()]
		&"render": label += " " + Quality.RENDER_NAMES[Quality.render_mode()]
	var field: StringName = SWITCHES[i].field
	if _overrides.has(field):
		label += " *"
	return label


func _box_rect(i: int) -> Rect2:
	var rect := _row_rects[i]
	return Rect2(Vector2(rect.position.x + MARGIN * _scale, rect.get_center().y - BOX_SIZE * 0.5 * _scale), Vector2.ONE * BOX_SIZE * _scale)
