extends RefCounted
## Input icons drawn with code: keycaps, mouse buttons, Xbox and PlayStation buttons, sticks, triggers, the D-pad and
## small copies of the touch controls. One instance draws one hint definition (rows of input steps with a short label,
## see scripts/ui/input_hints.gd) for one input style. The icons come from the InputMap events of each action, so a
## change of a binding changes the icons.
## Every shape goes to one ShapeBatch and every text after it, so a line of icons costs two draw calls.
## Use: refresh() on a change of the input mode, update(delta) once per frame, draw(item, center) from the _draw of item.

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")
const TouchButton := preload("res://scripts/ui/touch/touch_button.gd")
const TouchStick := preload("res://scripts/ui/touch/touch_stick.gd")
const Strings := preload("res://scripts/ui/strings.gd")

const STYLE_KEYS := &"keys"
const STYLE_XBOX := &"xbox"
const STYLE_PS := &"ps"
const STYLE_TOUCH := &"touch"
const STYLES: Array[StringName] = [STYLE_KEYS, STYLE_XBOX, STYLE_PS, STYLE_TOUCH]

## How a step is pressed: a short press, a press that stays down, a direction, or a touch drag and release.
const TAP := &"tap"
const HOLD := &"hold"
const DIR := &"dir"
const DRAG := &"drag"
## How a step links to the step before it: at the same time, or after it.
## A state icon (flame, snow, cube, drop) shows a state of the slime and is never pressed.
const STATE := &"state"
const STATES: Array[StringName] = [&"flame", &"snow", &"cube", &"drop"]
const JOIN_PLUS := &"plus"
const JOIN_THEN := &"then"

const KIND_KEY := &"key"
const KIND_MOUSE := &"mouse"
const KIND_FACE := &"face"
const KIND_SHOULDER := &"shoulder"
const KIND_STICK := &"stick"
const KIND_DPAD := &"dpad"
const KIND_MENU := &"menu"
const KIND_TOUCH_BUTTON := &"touch_button"
const KIND_TOUCH_STICK := &"touch_stick"
const KIND_STATE := &"state"
const KIND_OR := &"or"
const KIND_PLUS := &"plus"
const KIND_THEN := &"then"
const KIND_LABEL := &"label"
const SEPARATORS: Array[StringName] = [KIND_OR, KIND_PLUS, KIND_THEN]
## Icons with a round outline: their glow and ripple are round too.
const ROUND_KINDS: Array[StringName] = [KIND_FACE, KIND_STICK, KIND_MENU, KIND_DPAD]

## Direction of each action that a direction step can show.
const ACTION_DIRS := {
	&"move_left": Vector2.LEFT,
	&"move_right": Vector2.RIGHT,
	&"crouch": Vector2.DOWN,
	&"aim_left": Vector2.LEFT,
	&"aim_right": Vector2.RIGHT,
	&"aim_up": Vector2.UP,
	&"aim_down": Vector2.DOWN,
}
## The pointer aims on a keyboard: these actions have no key, so they show the mouse with arrows.
const POINTER_ACTIONS: Array[StringName] = [&"aim_left", &"aim_right", &"aim_up", &"aim_down"]
## The touch control that does each action: a button kind of TouchButton, or the move stick with a direction.
const TOUCH_CONTROLS := {
	&"jump": {"kind": KIND_TOUCH_BUTTON, "control": &"jump"},
	&"shoot": {"kind": KIND_TOUCH_BUTTON, "control": &"shoot"},
	&"aim": {"kind": KIND_TOUCH_BUTTON, "control": &"aim"},
	&"fire": {"kind": KIND_TOUCH_BUTTON, "control": &"aim"},
	&"dodge": {"kind": KIND_TOUCH_BUTTON, "control": &"dodge"},
	&"restart": {"kind": KIND_TOUCH_BUTTON, "control": &"restart"},
	&"move_left": {"kind": KIND_TOUCH_STICK},
	&"move_right": {"kind": KIND_TOUCH_STICK},
	&"crouch": {"kind": KIND_TOUCH_STICK},
	&"run": {"kind": KIND_TOUCH_STICK, "rim": true},
}
const PS_NAME_MARKS: PackedStringArray = ["playstation", "dualsense", "dualshock", "ps3", "ps4", "ps5", "sony"]
const XBOX_FACE_LETTERS: PackedStringArray = ["A", "B", "X", "Y"]
const KEY_NAMES := {
	KEY_SPACE: "Space",
	KEY_SHIFT: "Shift",
	KEY_CTRL: "Ctrl",
	KEY_ALT: "Alt",
	KEY_TAB: "Tab",
	KEY_ENTER: "Enter",
	KEY_ESCAPE: "Esc",
	KEY_BACKSPACE: "Back",
}
const ARROW_KEYS := {KEY_LEFT: Vector2.LEFT, KEY_RIGHT: Vector2.RIGHT, KEY_UP: Vector2.UP, KEY_DOWN: Vector2.DOWN}
const DPAD_DIRS := {
	JOY_BUTTON_DPAD_UP: Vector2.UP,
	JOY_BUTTON_DPAD_DOWN: Vector2.DOWN,
	JOY_BUTTON_DPAD_LEFT: Vector2.LEFT,
	JOY_BUTTON_DPAD_RIGHT: Vector2.RIGHT,
}
const CORNER_STEPS := 5
## Display servers that map a physical key to the label of the keyboard layout (an AZERTY Z where QWERTY has W).
const LAYOUT_DISPLAY_SERVERS: PackedStringArray = ["Windows", "X11", "Wayland", "macOS"]
## Drag direction of the touch aim copy, up and back like a lob from the right side of the screen.
const TOUCH_DRAG_DIR := Vector2(-0.8, -0.6)

static var _font: Font

## The style that the hint resolves to; empty until the first refresh().
var style: StringName = &""
## Size of the drawn block, centred on the point given to draw().
var size := Vector2.ZERO

var _definition: Array
var _unit := 38.0
var _label_size := 22
var _rows: Array[Dictionary] = []
var _has_icons := false
var _clock := 0.0
var _pop_clock := 1000.0
var _batch := ShapeBatch.new()
var _texts: Array[Array] = []


## definition holds the rows of a hint (scripts/ui/input_hints.gd).
func _init(definition: Array, unit: float, label_size: int) -> void:
	_definition = definition
	_unit = unit
	_label_size = label_size


## Bold default font shared by every legend and label, so all text of a line batches into one draw call.
static func font() -> Font:
	if _font == null:
		var bold := FontVariation.new()
		bold.base_font = ThemeDB.fallback_font
		bold.variation_embolden = Tuning.glyph_font_embolden
		_font = bold
	return _font


## The style for the input mode of TouchControls and the name of the connected pad.
static func current_style() -> StringName:
	if TouchControls.is_touch_mode():
		return STYLE_TOUCH
	if TouchControls.input_mode == &"pad":
		return STYLE_PS if is_playstation_name(pad_name()) else STYLE_XBOX
	return STYLE_KEYS


static func pad_name() -> String:
	if Harness.pad_name != "":
		return Harness.pad_name
	var pads := Harness.connected_pads()
	return Input.get_joy_name(pads[0]) if not pads.is_empty() else ""


static func is_playstation_name(text: String) -> bool:
	var lower := text.to_lower()
	for mark: String in PS_NAME_MARKS:
		if lower.contains(mark):
			return true
	return false


## Resolves the icons for a style (the current one when empty). Returns true when the icons changed; a change starts
## the pop of the icons.
func refresh(for_style: StringName = &"") -> bool:
	var next_style := for_style if for_style != &"" else current_style()
	var signature := _describe_rows(_rows)
	var previous := style
	style = next_style
	_build_rows()
	var changed := previous != style or _describe_rows(_rows) != signature
	if changed and previous != &"":
		_pop_clock = 0.0
	return changed


## True when at least one row has an icon; else the block shows only the row labels, which name no input.
func has_icons() -> bool:
	return _has_icons


## One text per row for logs: the icon signatures and the label.
func describe() -> PackedStringArray:
	return _describe_rows(_rows)


func update(delta: float) -> void:
	_clock += delta
	_pop_clock += delta
	for row: Dictionary in _rows:
		var t := fmod(_clock, float(row["cycle"]))
		for it: Dictionary in row["items"]:
			if it.has("touch"):
				_step_touch(row, it, t, delta)


## Everything that draw() reads from the loop, with the press curves snapped below a visible step, so the hint can
## skip a redraw while the key stays the same. Continuous decorations (the "then" nudge, the state marks) step at
## Tuning.glyph_idle_motion_hz.
func visual_key() -> Array:
	var key := [style, _rows.size()]
	var motion := false
	for row: Dictionary in _rows:
		var t := fmod(_clock, float(row["cycle"]))
		for it: Dictionary in row["items"]:
			var kind: StringName = it["kind"]
			key.append(_pop_amount(int(it["order"])))
			if kind == KIND_LABEL or kind == KIND_OR or kind == KIND_PLUS:
				continue
			if kind == KIND_THEN or kind == KIND_STATE:
				motion = true
				continue
			var state := _press_of(row, it, t)
			key.append(snappedf(float(state[0]), 0.002))
			key.append(state[1])
			var press: StringName = it.get("press", TAP)
			if press == TAP:
				var age := _window_age(row, it, t)
				key.append(age if age < Tuning.glyph_ripple_time else -1.0)
			elif press == HOLD or press == DRAG:
				key.append(snappedf(_window_progress(row, it, t), 0.002))
			if it.has("touch"):
				key.append(it["touch"].visual_key())
	if motion:
		key.append(floori(_clock * Tuning.glyph_idle_motion_hz))
	return key


## Draws the block centred on center into the canvas item; alpha below 1 is for the warm-up pass.
func draw(item: CanvasItem, center: Vector2, alpha := 1.0) -> void:
	_batch.clear()
	_texts.clear()
	var top := center.y - size.y * 0.5
	for row: Dictionary in _rows:
		var t := fmod(_clock, float(row["cycle"]))
		var row_y := top + float(row["y"])
		var left := center.x - float(row["width"]) * 0.5
		for it: Dictionary in row["items"]:
			var origin := Vector2(left + float(it["x"]), row_y)
			var pop := _pop_amount(int(it["order"]))
			var a := alpha * clampf(pop * 3.0, 0.0, 1.0)
			var scale := lerpf(Tuning.glyph_pop_from, 1.0, _ease_out_back(pop))
			_batch.transform = Transform2D(0.0, Vector2(scale, scale), 0.0, origin)
			_draw_item(row, it, t, a)
	_batch.transform = Transform2D.IDENTITY
	_batch.commit(item.get_canvas_item())
	# Every outline first, then every fill: each pass reads one font cache texture, so the text batches.
	var shifted := false
	for outline_pass: bool in [true, false]:
		for text: Array in _texts:
			if outline_pass and int(text[3]) <= 0:
				continue
			shifted = _draw_text(item, text, outline_pass, shifted)
	if shifted:
		item.draw_set_transform_matrix(Transform2D.IDENTITY)


## Draws the outline or the fill of one queued text; returns true while a pop transform is set on the item.
func _draw_text(item: CanvasItem, text: Array, outline_pass: bool, shifted: bool) -> bool:
	var xform: Transform2D = text[5]
	var pos: Vector2 = text[1]
	var still_shifted := shifted
	if xform.x == Vector2.RIGHT and xform.y == Vector2.DOWN:
		if shifted:
			item.draw_set_transform_matrix(Transform2D.IDENTITY)
			still_shifted = false
		pos += xform.origin
	else:
		item.draw_set_transform_matrix(xform)
		still_shifted = true
	var line: TextLine = text[0]
	if outline_pass:
		line.draw_outline(item.get_canvas_item(), pos, int(text[3]), text[4])
	else:
		line.draw(item.get_canvas_item(), pos, text[2])
	return still_shifted


# --- Resolution -------------------------------------------------------------------------------------------------

func _build_rows() -> void:
	_rows.clear()
	_has_icons = false
	var touch := style == STYLE_TOUCH
	for row_def: Dictionary in _definition:
		var steps: Array = row_def.get("touch", row_def["steps"]) if touch else row_def["steps"]
		var row := _build_row(steps, Strings.text(row_def["label"], touch))
		if not row.is_empty():
			_rows.append(row)
			_has_icons = true
	# No binding for this device: the labels alone, so no text of another platform ever shows.
	if not _has_icons:
		for row_def: Dictionary in _definition:
			_rows.append(_label_row(Strings.text(row_def["label"], touch)))
	_layout()


func _build_row(steps: Array, label: String) -> Dictionary:
	var items: Array[Dictionary] = []
	var windows: Array[Dictionary] = []
	var combo := steps.size() > 1
	var at := Tuning.glyph_lead_time
	var hold_windows: Array[int] = []
	for step: Dictionary in steps:
		if step.has("state"):
			_append_join(items, step)
			items.append({"kind": KIND_STATE, "state": step["state"], "press": STATE})
			continue
		var actions: Array = step["actions"]
		var press: StringName = step.get("press", TAP)
		var crossed: bool = step.get("crossed", false)
		var sets := _binding_sets(actions, press)
		if sets.is_empty():
			continue
		_append_join(items, step)
		var first_window := windows.size()
		# A crossed-out input is never pressed, so it takes no time in the loop.
		var count := 0 if crossed else (actions.size() if press == DIR else 1)
		var slot := _slot(press, combo)
		for j in count:
			var release := at + slot * Tuning.glyph_dir_share
			if press == TAP:
				release = at + Tuning.glyph_tap_hold
			elif press == DRAG:
				release = at + slot * Tuning.glyph_drag_share
			windows.append({"start": at, "release": release, "press": press})
			if press == HOLD or (press == DIR and j == count - 1):
				hold_windows.append(windows.size() - 1)
			at += slot
		if (combo or crossed or step.get("single", false)) and sets.size() > 1:
			sets.resize(1)
		for set_index in sets.size():
			if set_index > 0:
				items.append({"kind": KIND_OR})
			for icon: Dictionary in sets[set_index]:
				var shifted: Array[int] = []
				for w: int in icon["windows"]:
					shifted.append(first_window + (w if press == DIR else 0))
				icon["windows"] = [] as Array[int] if crossed else shifted
				icon["press"] = press
				icon["crossed"] = crossed
				items.append(icon)
	if items.is_empty():
		return {}
	# A held step, and the last direction of a step that later steps follow, stay down until the whole combo ends.
	for w: int in hold_windows:
		if combo or windows[w]["press"] == HOLD:
			windows[w]["release"] = maxf(at, float(windows[w]["start"]) + Tuning.glyph_tap_hold)
	items.append(_label_item(label))
	return {"items": items, "windows": windows, "cycle": at + Tuning.glyph_rest_time}


func _append_join(items: Array[Dictionary], step: Dictionary) -> void:
	if not items.is_empty():
		items.append({"kind": KIND_PLUS if step.get("join", JOIN_THEN) == JOIN_PLUS else KIND_THEN})


func _label_row(text: String) -> Dictionary:
	return {"items": [_label_item(text)] as Array[Dictionary], "windows": [] as Array[Dictionary], "cycle": 1.0}


func _label_item(text: String) -> Dictionary:
	var line := _text_line(text, _label_size)
	if line.get_size().x > Tuning.glyph_label_max_width:
		line.width = Tuning.glyph_label_max_width
		line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return {"kind": KIND_LABEL, "text": line, "label": text}


func _slot(press: StringName, combo: bool) -> float:
	match press:
		HOLD:
			return Tuning.glyph_step_time if combo else Tuning.glyph_hold_time
		DIR:
			return Tuning.glyph_dir_time
		DRAG:
			return Tuning.glyph_drag_time
	return Tuning.glyph_tap_time


## Returns [primary icons] and, when every action has a second binding that looks different, [alternative icons].
func _binding_sets(actions: Array, press: StringName) -> Array:
	var per_action: Array = []
	for action: StringName in actions:
		per_action.append(_icons_for_action(action, press))
	var sets: Array = []
	for rank in 2:
		var icons: Array[Dictionary] = []
		var complete := true
		for j in per_action.size():
			var options: Array = per_action[j]
			if options.size() > rank:
				var icon: Dictionary = (options[rank] as Dictionary).duplicate()
				icon["windows"] = [j] as Array[int]
				var dir: Vector2 = ACTION_DIRS.get(actions[j], Vector2.ZERO)
				icon["dirs"] = [dir] as Array[Vector2]
				icons.append(icon)
			else:
				complete = false
		if icons.is_empty() or (rank > 0 and not complete):
			break
		var merged := _merge(icons)
		if rank > 0 and _signatures(merged) == _signatures(sets[0]):
			break
		sets.append(merged)
	return sets


## Every icon option of an action for the style, the main binding first.
func _icons_for_action(action: StringName, press: StringName) -> Array:
	var options: Array = []
	if style == STYLE_TOUCH:
		if TOUCH_CONTROLS.has(action):
			options.append((TOUCH_CONTROLS[action] as Dictionary).duplicate())
		elif POINTER_ACTIONS.has(action):
			options.append({"kind": KIND_TOUCH_BUTTON, "control": &"aim"})
		return options
	if not InputMap.has_action(action):
		return options
	var axes: Array = []
	for event: InputEvent in InputMap.action_get_events(action):
		var icon := _icon_for_event(event)
		if icon.is_empty():
			continue
		if event is InputEventJoypadMotion and press == DIR:
			axes.append(icon)
		else:
			options.append(icon)
	# A direction reads best on the stick, so the stick comes first on a pad.
	options = axes + options
	if options.is_empty() and style == STYLE_KEYS and POINTER_ACTIONS.has(action):
		options.append({"kind": KIND_MOUSE, "move": true})
	return options


func _icon_for_event(event: InputEvent) -> Dictionary:
	if style == STYLE_KEYS:
		if event is InputEventKey:
			var key_event := event as InputEventKey
			var code := key_event.physical_keycode if key_event.physical_keycode != KEY_NONE else key_event.keycode
			return _key_icon(code)
		if event is InputEventMouseButton:
			return {"kind": KIND_MOUSE, "button": int((event as InputEventMouseButton).button_index)}
		return {}
	if event is InputEventJoypadButton:
		return _pad_button_icon(int((event as InputEventJoypadButton).button_index))
	if event is InputEventJoypadMotion:
		var axis := int((event as InputEventJoypadMotion).axis)
		if axis == JOY_AXIS_TRIGGER_LEFT or axis == JOY_AXIS_TRIGGER_RIGHT:
			return {"kind": KIND_SHOULDER, "side": -1 if axis == JOY_AXIS_TRIGGER_LEFT else 1, "trigger": true}
		return {"kind": KIND_STICK, "side": -1 if axis <= JOY_AXIS_LEFT_Y else 1}
	return {}


func _key_icon(code: Key) -> Dictionary:
	if ARROW_KEYS.has(code):
		return {"kind": KIND_KEY, "legend": "", "arrow": ARROW_KEYS[code], "code": int(code)}
	var legend: String = KEY_NAMES.get(code, "")
	if legend == "":
		var label := KEY_NONE
		if LAYOUT_DISPLAY_SERVERS.has(DisplayServer.get_name()):
			label = DisplayServer.keyboard_get_label_from_physical(code)
		legend = OS.get_keycode_string(label if label != KEY_NONE else code)
	if legend == "":
		legend = "?"
	return {"kind": KIND_KEY, "legend": legend, "code": int(code)}


func _pad_button_icon(button: int) -> Dictionary:
	if button <= JOY_BUTTON_Y:
		return {"kind": KIND_FACE, "button": button}
	if button == JOY_BUTTON_LEFT_SHOULDER or button == JOY_BUTTON_RIGHT_SHOULDER:
		return {"kind": KIND_SHOULDER, "side": -1 if button == JOY_BUTTON_LEFT_SHOULDER else 1, "trigger": false}
	if button == JOY_BUTTON_LEFT_STICK or button == JOY_BUTTON_RIGHT_STICK:
		return {"kind": KIND_STICK, "side": -1 if button == JOY_BUTTON_LEFT_STICK else 1, "click": true}
	if DPAD_DIRS.has(button):
		return {"kind": KIND_DPAD, "pad_dir": DPAD_DIRS[button]}
	return {"kind": KIND_MENU, "button": button}


## Joins icons that show one device part (a stick, the D-pad, the pointer, the touch stick) or the same button.
func _merge(icons: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var by_signature := {}
	for icon: Dictionary in icons:
		var key := _signature(icon)
		if by_signature.has(key):
			var target: Dictionary = by_signature[key]
			(target["windows"] as Array[int]).append_array(icon["windows"])
			(target["dirs"] as Array[Vector2]).append_array(icon["dirs"])
			if icon.has("pad_dir"):
				(target["pad_dirs"] as Array[Vector2]).append(icon["pad_dir"])
			continue
		if icon.has("pad_dir"):
			icon["pad_dirs"] = [icon["pad_dir"]] as Array[Vector2]
		by_signature[key] = icon
		out.append(icon)
	return out


func _signature(icon: Dictionary) -> String:
	var kind: StringName = icon["kind"]
	match kind:
		KIND_KEY:
			return "key:%s" % _key_name(icon)
		KIND_MOUSE:
			return "mouse:move" if icon.get("move", false) else "mouse:%d" % int(icon["button"])
		KIND_FACE:
			return "face:%s" % _face_name(int(icon["button"]))
		KIND_SHOULDER:
			return "%s:%s" % [kind, _shoulder_label(icon)]
		KIND_STICK:
			return "stick:%s%s" % ["L" if int(icon["side"]) < 0 else "R", "_click" if icon.get("click", false) else ""]
		KIND_DPAD:
			return "dpad"
		KIND_MENU:
			return "menu:%d" % int(icon["button"])
		KIND_TOUCH_BUTTON:
			return "touch_button:%s" % icon["control"]
		KIND_TOUCH_STICK:
			return "touch_stick%s" % (":rim" if icon.get("rim", false) else "")
		KIND_STATE:
			return "state:%s" % icon["state"]
	return String(kind)


func _signatures(icons: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for icon: Dictionary in icons:
		out.append(_signature(icon))
	return out


func _describe_rows(rows: Array[Dictionary]) -> PackedStringArray:
	var out := PackedStringArray()
	for row: Dictionary in rows:
		var parts := PackedStringArray()
		for it: Dictionary in row["items"]:
			match it["kind"]:
				KIND_LABEL:
					parts.append("'%s'" % it["label"])
				KIND_OR:
					parts.append("/")
				KIND_PLUS:
					parts.append("+")
				KIND_THEN:
					parts.append(">")
				_:
					parts.append("%s(%s)" % [_signature(it), "crossed" if it.get("crossed", false) else it.get("press", TAP)])
		out.append(" ".join(parts))
	return out


func _key_name(icon: Dictionary) -> String:
	if icon.has("arrow"):
		var arrow: Vector2 = icon["arrow"]
		return {Vector2.LEFT: "Left", Vector2.RIGHT: "Right", Vector2.UP: "Up", Vector2.DOWN: "Down"}.get(arrow, "Arrow")
	return String(icon["legend"])


func _face_name(button: int) -> String:
	if style == STYLE_PS:
		return ["cross", "circle", "square", "triangle"][button]
	return XBOX_FACE_LETTERS[button]


func _shoulder_label(icon: Dictionary) -> String:
	var left := int(icon["side"]) < 0
	var trigger: bool = icon["trigger"]
	if style == STYLE_PS:
		return ("L" if left else "R") + ("2" if trigger else "1")
	return ("L" if left else "R") + ("T" if trigger else "B")


# --- Layout -----------------------------------------------------------------------------------------------------

func _layout() -> void:
	var u := _unit
	var order := 0
	var widest := 0.0
	var y := 0.0
	for row_index in _rows.size():
		var row: Dictionary = _rows[row_index]
		var x := 0.0
		var items: Array[Dictionary] = row["items"]
		for i in items.size():
			var it: Dictionary = items[i]
			_prepare(it)
			var w: float = it["w"]
			if i > 0:
				x += u * (Tuning.glyph_label_gap if it["kind"] == KIND_LABEL else Tuning.glyph_gap)
			it["x"] = x + w * 0.5
			it["order"] = order
			order += 1
			x += w
		row["width"] = x
		var has_icon := items.size() > 1
		var row_h := u if has_icon else (items[0]["text"] as TextLine).get_size().y
		row["y"] = y + row_h * 0.5
		y += row_h + (u * Tuning.glyph_row_gap if row_index < _rows.size() - 1 else 0.0)
		widest = maxf(widest, x)
	# Room under the icons for the hold bar.
	size = Vector2(widest, y + (u * Tuning.glyph_bar_offset if _has_icons else 0.0))


## Sets the width of an item and builds its legend text and its touch control copy.
func _prepare(it: Dictionary) -> void:
	var u := _unit
	var kind: StringName = it["kind"]
	match kind:
		KIND_LABEL:
			it["w"] = (it["text"] as TextLine).get_size().x
		KIND_KEY:
			var legend: String = it.get("legend", "")
			var w := u * Tuning.glyph_key_min_width
			if legend.length() > 1:
				var line := _text_line(legend, _label_size)
				it["text"] = line
				w = maxf(w, line.get_size().x + u * Tuning.glyph_key_padding)
				if it.get("code", 0) == KEY_SPACE:
					w = maxf(w, u * Tuning.glyph_space_width)
			elif legend != "":
				it["text"] = _text_line(legend, _label_size)
			it["w"] = w
		KIND_MOUSE:
			it["w"] = u * (Tuning.glyph_mouse_move_width if it.get("move", false) else Tuning.glyph_mouse_width)
		KIND_FACE:
			it["w"] = u
			var letter := XBOX_FACE_LETTERS[int(it["button"])]
			if style != STYLE_PS:
				it["text"] = _text_line(letter, _label_size)
		KIND_SHOULDER:
			it["w"] = u * (Tuning.glyph_trigger_width if it["trigger"] else Tuning.glyph_bumper_width)
			it["text"] = _text_line(_shoulder_label(it), _label_size)
		KIND_STICK:
			it["w"] = u * Tuning.glyph_stick_width
			it["text"] = _text_line("L" if int(it["side"]) < 0 else "R", _label_size)
		KIND_DPAD:
			it["w"] = u
		KIND_MENU:
			it["w"] = u * 0.8
		KIND_TOUCH_BUTTON:
			var button := TouchButton.new(it["control"], &"", _touch_accent(it["control"]))
			button.radius = u * Tuning.glyph_touch_radius
			button.appear = 1.0
			it["touch"] = button
			it["w"] = u * (Tuning.glyph_touch_drag_width if it.get("press", TAP) == DRAG else 1.0)
		KIND_TOUCH_STICK:
			var stick := TouchStick.new()
			var radius := u * Tuning.glyph_touch_stick_radius
			stick.place(Vector2.ZERO, radius, radius * Tuning.glyph_touch_knob_share)
			stick.appear = 1.0
			stick.press(Vector2.ZERO)
			it["touch"] = stick
			# The knob can sit on the rim, so the room reaches past the base by a knob radius.
			it["w"] = radius * (1.0 + Tuning.glyph_touch_knob_share) * 2.0
		KIND_STATE:
			it["w"] = u * 0.9
		KIND_OR:
			it["w"] = u * 0.4
		KIND_PLUS:
			it["w"] = u * 0.5
		KIND_THEN:
			it["w"] = u * 0.6


func _touch_accent(control: StringName) -> Color:
	match control:
		&"jump":
			return Tuning.touch_accent_jump
		&"shoot":
			return Tuning.touch_accent_shoot
		&"aim":
			return Tuning.touch_accent_aim
		&"dodge":
			return Tuning.touch_accent_dodge
	return Tuning.touch_accent_neutral


func _text_line(text: String, font_size: int) -> TextLine:
	var line := TextLine.new()
	line.add_string(text, font(), font_size)
	return line


# --- Timeline ---------------------------------------------------------------------------------------------------

## Press amount 0..1 of an icon at time t of its row loop, and the direction of the window that presses it most.
func _press_of(row: Dictionary, it: Dictionary, t: float) -> Array:
	var windows: Array = row["windows"]
	var best := 0.0
	var dir := Vector2.ZERO
	var best_index := -1
	var icon_windows: Array = it.get("windows", [])
	var dirs: Array = it.get("dirs", [])
	for k in icon_windows.size():
		var amount := _window_press(windows[icon_windows[k]], t)
		if amount > best or best_index < 0:
			best = amount
			best_index = k
			dir = dirs[k] if k < dirs.size() else Vector2.ZERO
	return [best, dir, best_index]


static func _window_press(win: Dictionary, t: float) -> float:
	var start: float = win["start"]
	if t < start:
		return 0.0
	var on := _smooth((t - start) / maxf(Tuning.glyph_press_in, 0.001))
	var off := _smooth((t - float(win["release"])) / maxf(Tuning.glyph_release_time, 0.001))
	return on * (1.0 - off)


## 0..1 progress of the first window of an icon from its press to its release, for the hold bar.
func _window_progress(row: Dictionary, it: Dictionary, t: float) -> float:
	var icon_windows: Array = it.get("windows", [])
	if icon_windows.is_empty():
		return 0.0
	var win: Dictionary = row["windows"][icon_windows[0]]
	var start: float = win["start"]
	var release: float = win["release"]
	return clampf((t - start) / maxf(release - start, 0.001), 0.0, 1.0)


func _window_age(row: Dictionary, it: Dictionary, t: float) -> float:
	var icon_windows: Array = it.get("windows", [])
	var best := INF
	for w: int in icon_windows:
		var age := t - float(row["windows"][w]["start"])
		if age >= 0.0:
			best = minf(best, age)
	return best


func _step_touch(row: Dictionary, it: Dictionary, t: float, delta: float) -> void:
	var state := _press_of(row, it, t)
	var amount: float = state[0]
	var dir: Vector2 = state[1]
	if it["kind"] == KIND_TOUCH_BUTTON:
		var button: TouchButton = it["touch"]
		if amount > 0.5 and not button.pressed:
			button.press(Vector2.ZERO)
		elif amount <= 0.5 and button.pressed:
			button.release()
		button.update(delta)
		return
	var stick: TouchStick = it["touch"]
	var reach := 1.0 if it.get("rim", false) else Tuning.glyph_touch_stick_reach
	if it.get("rim", false):
		dir = Vector2.RIGHT
	stick.drag(dir * stick.radius * reach * amount)
	stick.run_output()
	stick.crouch_output()
	stick.update(delta)


func _pop_amount(order: int) -> float:
	return clampf((_pop_clock - order * Tuning.glyph_pop_stagger) / maxf(Tuning.glyph_pop_time, 0.001), 0.0, 1.0)


# --- Drawing ----------------------------------------------------------------------------------------------------

func _draw_item(row: Dictionary, it: Dictionary, t: float, a: float) -> void:
	if a <= 0.0:
		return
	var state := _press_of(row, it, t)
	var p: float = state[0]
	var dir: Vector2 = state[1]
	var kind: StringName = it["kind"]
	if p > 0.01 and not SEPARATORS.has(kind) and kind != KIND_LABEL and kind != KIND_TOUCH_BUTTON and kind != KIND_TOUCH_STICK:
		_draw_press_glow(it, p, a)
	match kind:
		KIND_LABEL:
			var line: TextLine = it["text"]
			_text(line, -line.get_size() * 0.5, Color(Tuning.glyph_label_color, a), Tuning.glyph_label_outline, Color(Tuning.glyph_outline_color, a))
			return
		KIND_OR, KIND_PLUS, KIND_THEN:
			_draw_separator(kind, a)
			return
		KIND_KEY:
			_draw_key(it, p, a)
		KIND_MOUSE:
			_draw_mouse(it, p, dir, a)
		KIND_FACE:
			_draw_face(it, p, a)
		KIND_SHOULDER:
			_draw_shoulder(it, p, a)
		KIND_STICK:
			_draw_stick(it, p, dir, a)
		KIND_DPAD:
			_draw_dpad(it, p, dir, a)
		KIND_MENU:
			_draw_menu(it, p, a)
		KIND_TOUCH_BUTTON:
			_draw_touch_button(row, it, t, p, a)
		KIND_TOUCH_STICK:
			(it["touch"] as TouchStick).draw(_batch)
		KIND_STATE:
			_draw_state(it, a)
	if it.get("crossed", false):
		_draw_cross(it, a)
	# The touch copies make their own press splash, so they only take the hold bar.
	if kind != KIND_TOUCH_BUTTON and kind != KIND_TOUCH_STICK or it.get("press", TAP) == HOLD:
		_draw_feedback(row, it, t, a)


## A soft halo behind a pressed icon, so a press reads at a glance even where the icon sinks only a few pixels.
func _draw_press_glow(it: Dictionary, p: float, a: float) -> void:
	var u := _unit
	var w: float = it["w"]
	var area := Rect2(-w * 0.5, -u * 0.5, w, u)
	var color := Tuning.glyph_lit_color
	if ROUND_KINDS.has(it["kind"]):
		var r := minf(w, u) * 0.5
		_batch.disc(Vector2(0.0, u * 0.04), r + u * 0.2, Color(color, a * p * Tuning.glyph_glow_alpha * 0.5))
		_batch.disc(Vector2(0.0, u * 0.04), r + u * 0.1, Color(color, a * p * Tuning.glyph_glow_alpha))
		return
	_batch.polygon(_round_rect(area.grow(u * 0.2), u * 0.4), Color(color, a * p * Tuning.glyph_glow_alpha * 0.5))
	_batch.polygon(_round_rect(area.grow(u * 0.1), u * 0.3), Color(color, a * p * Tuning.glyph_glow_alpha))


## The tap ripple and the hold bar that tell a short press from a long one.
func _draw_feedback(row: Dictionary, it: Dictionary, t: float, a: float) -> void:
	var u := _unit
	var press: StringName = it.get("press", TAP)
	var age := _window_age(row, it, t)
	if press == TAP and age < Tuning.glyph_ripple_time:
		var k := age / Tuning.glyph_ripple_time
		var grow := u * lerpf(0.04, 0.32, ease(k, 0.5))
		var area := Rect2(-float(it["w"]) * 0.5, -u * 0.5, float(it["w"]), u).grow(grow)
		var corner := (minf(float(it["w"]), u) * 0.5 if ROUND_KINDS.has(it["kind"]) else u * 0.2) + grow
		_batch.stroke(_round_rect(area, corner), u * 0.06 * (1.0 - k) + 0.5, Color(Tuning.glyph_lit_color, a * (1.0 - k) * 0.7), true)
	elif press == HOLD:
		var w: float = float(it["w"]) * 0.8
		var half_h := u * (Tuning.glyph_touch_stick_radius if it["kind"] == KIND_TOUCH_STICK else 0.5)
		var y := half_h + u * Tuning.glyph_bar_offset * 0.55
		var h := u * Tuning.glyph_bar_height
		var progress: float = _window_progress(row, it, t) * float(_press_of(row, it, t)[0])
		var track := Rect2(-w * 0.5, y - h * 0.5, w, h)
		_batch.polygon(_round_rect(track.grow(1.5), h), Color(Tuning.glyph_outline_color, a * 0.8))
		_batch.polygon(_round_rect(track, h * 0.5), Color(Tuning.glyph_bar_track, a))
		if progress > 0.01:
			var fill := Rect2(track.position, Vector2(maxf(w * progress, h), h))
			_batch.polygon(_round_rect(fill, h * 0.5), Color(Tuning.glyph_lit_color, a))


func _draw_separator(kind: StringName, a: float) -> void:
	var u := _unit
	var color := Color(Tuning.glyph_separator_color, a * Tuning.glyph_separator_color.a)
	var outline := Color(Tuning.glyph_outline_color, a * 0.8)
	var lines: Array[PackedVector2Array] = []
	var width := u * 0.09
	match kind:
		KIND_OR:
			lines.append(PackedVector2Array([Vector2(u * 0.09, -u * 0.27), Vector2(-u * 0.09, u * 0.27)]))
			width = u * 0.07
		KIND_PLUS:
			lines.append(PackedVector2Array([Vector2(-u * 0.17, 0.0), Vector2(u * 0.17, 0.0)]))
			lines.append(PackedVector2Array([Vector2(0.0, -u * 0.17), Vector2(0.0, u * 0.17)]))
		KIND_THEN:
			var nudge := sin(_clock * TAU * Tuning.glyph_then_nudge_hz) * u * 0.04
			lines.append(PackedVector2Array([Vector2(-u * 0.2 + nudge, 0.0), Vector2(u * 0.12 + nudge, 0.0)]))
			lines.append(PackedVector2Array([Vector2(u * 0.0 + nudge, -u * 0.14), Vector2(u * 0.16 + nudge, 0.0), Vector2(u * 0.0 + nudge, u * 0.14)]))
	for line: PackedVector2Array in lines:
		_batch.stroke(line, width + Tuning.glyph_outline_width * 2.0, outline)
	for line: PackedVector2Array in lines:
		_batch.stroke(line, width, color)


func _draw_key(it: Dictionary, p: float, a: float) -> void:
	var u := _unit
	var w: float = it["w"]
	var ow := Tuning.glyph_outline_width
	var depth := u * Tuning.glyph_key_depth
	var sink := depth * Tuning.glyph_press_sink * p
	var body := Rect2(-w * 0.5, -u * 0.5, w, u)
	var corner := u * 0.2
	_batch.polygon(_offset(_round_rect(body.grow(ow), corner + ow), Vector2(0.0, ow * 2.0)), Color(Tuning.glyph_shadow_color, a * Tuning.glyph_shadow_color.a))
	_batch.polygon(_round_rect(body.grow(ow), corner + ow), Color(Tuning.glyph_outline_color, a))
	_batch.polygon(_round_rect(body, corner), Color(Tuning.glyph_key_side, a))
	var inset := u * 0.08
	var face := Rect2(body.position.x + inset, body.position.y + inset * 0.6 + sink, w - inset * 2.0, u - depth - inset * 0.6)
	var top := Tuning.glyph_key_top.lerp(Tuning.glyph_key_lit, p * Tuning.glyph_key_lit_share)
	_batch.polygon(_round_rect(face.grow(1.0), corner * 0.8), Color(Tuning.glyph_key_side.darkened(0.12), a))
	_gradient_polygon(_round_rect(face, corner * 0.75), face, top.lightened(0.1), top.darkened(0.08), a)
	var gloss := Rect2(face.position + Vector2(face.size.x * 0.1, face.size.y * 0.1), Vector2(face.size.x * 0.42, u * 0.07))
	_batch.polygon(_round_rect(gloss, u * 0.035), Color(1.0, 1.0, 1.0, a * 0.6))
	var center := face.get_center()
	if it.has("arrow"):
		_draw_arrow(center, it["arrow"], u * 0.42, Color(Tuning.glyph_key_legend, a))
	elif it.has("text"):
		var line: TextLine = it["text"]
		_text(line, center - line.get_size() * 0.5, Color(Tuning.glyph_key_legend, a))


func _draw_mouse(it: Dictionary, p: float, dir: Vector2, a: float) -> void:
	var u := _unit
	var ow := Tuning.glyph_outline_width
	var w := u * Tuning.glyph_mouse_width
	var move: bool = it.get("move", false)
	var shift := dir * u * 0.08 * p if move else Vector2.ZERO
	var body := Rect2(-w * 0.5 + shift.x, -u * 0.5 + shift.y, w, u)
	var outline := _round_rect(body, w * 0.46)
	_batch.polygon(_offset(_round_rect(body.grow(ow), w * 0.46 + ow), Vector2(0.0, ow * 2.0)), Color(Tuning.glyph_shadow_color, a * Tuning.glyph_shadow_color.a))
	_batch.polygon(_round_rect(body.grow(ow), w * 0.46 + ow), Color(Tuning.glyph_outline_color, a))
	_gradient_polygon(outline, body, Tuning.glyph_key_top.lightened(0.08), Tuning.glyph_key_side, a)
	var split_y := body.position.y + u * 0.44
	if not move:
		var left := int(it["button"]) == MOUSE_BUTTON_LEFT
		var quad := Rect2(Vector2(body.position.x - 2.0 if left else body.get_center().x, body.position.y - 2.0), Vector2(w * 0.5 + 2.0, split_y - body.position.y + 2.0))
		var lit := Tuning.glyph_mouse_lit.lerp(Tuning.glyph_lit_color, p)
		for region: PackedVector2Array in Geometry2D.intersect_polygons(outline, _rect_points(quad)):
			_batch.polygon(_offset(region, Vector2(0.0, u * 0.03 * p)), Color(lit, a * lerpf(0.7, 1.0, p)))
	var seam := Color(Tuning.glyph_key_side.darkened(0.3), a)
	_batch.stroke(PackedVector2Array([Vector2(body.position.x + 1.0, split_y), Vector2(body.end.x - 1.0, split_y)]), 1.6, seam, false, false)
	_batch.stroke(PackedVector2Array([Vector2(body.get_center().x, body.position.y + 1.0), Vector2(body.get_center().x, split_y)]), 1.6, seam, false, false)
	var wheel := Rect2(Vector2(body.get_center().x - u * 0.06, split_y - u * 0.27), Vector2(u * 0.12, u * 0.2))
	_batch.polygon(_round_rect(wheel, u * 0.06), Color(Tuning.glyph_outline_color, a))
	_batch.polygon(_round_rect(Rect2(body.position + Vector2(w * 0.2, u * 0.62), Vector2(w * 0.18, u * 0.06)), u * 0.03), Color(1.0, 1.0, 1.0, a * 0.5))
	if move:
		var dirs: Array = it.get("dirs", [])
		for d: Vector2 in dirs:
			var on := p if d == dir else 0.0
			var reach := Vector2(w * 0.5 + u * 0.2, u * 0.5 + u * 0.1)
			var at := Vector2(d.x * reach.x, d.y * reach.y) + d * u * 0.05 * on
			_draw_pointer_arrow(at, d, u * 0.2, on, a)


func _draw_face(it: Dictionary, p: float, a: float) -> void:
	var u := _unit
	var button := int(it["button"])
	var ow := Tuning.glyph_outline_width
	var r := u * 0.46
	var depth := r * 0.3
	var sink := depth * Tuning.glyph_press_sink * p
	var ps := style == STYLE_PS
	var color: Color = (Tuning.glyph_ps_body if ps else Tuning.glyph_xbox_colors[button])
	color = color.lightened(0.12 * p)
	var top_center := Vector2(0.0, -depth * 0.5 + sink)
	var base_center := Vector2(0.0, depth * 0.5)
	_batch.disc(base_center + Vector2(0.0, ow * 2.0), r + ow, Color(Tuning.glyph_shadow_color, a * Tuning.glyph_shadow_color.a))
	_batch.disc(base_center, r + ow, Color(Tuning.glyph_outline_color, a))
	_batch.disc(top_center, r + ow, Color(Tuning.glyph_outline_color, a))
	_batch.disc(base_center, r, Color(color.darkened(0.45), a))
	var disc := ShapeBatch.circle_points(top_center, Vector2(r, r), 0.0)
	_gradient_polygon(disc, Rect2(top_center - Vector2(r, r), Vector2(r, r) * 2.0), color.lightened(0.18), color.darkened(0.1), a)
	_batch.polygon(ShapeBatch.circle_points(top_center + Vector2(-r * 0.28, -r * 0.5), Vector2(r * 0.34, r * 0.15), -0.35), Color(1.0, 1.0, 1.0, a * 0.45))
	if ps:
		_draw_ps_symbol(button, top_center, r, a)
	else:
		var line: TextLine = it["text"]
		_text(line, top_center - line.get_size() * 0.5, Color(Tuning.glyph_pad_legend, a))


func _draw_ps_symbol(button: int, c: Vector2, r: float, a: float) -> void:
	var color: Color = Tuning.glyph_ps_colors[button]
	color = Color(color, a)
	var width := r * 0.17
	match button:
		JOY_BUTTON_A:
			var s := r * 0.36
			_batch.stroke(PackedVector2Array([c + Vector2(-s, -s), c + Vector2(s, s)]), width, color)
			_batch.stroke(PackedVector2Array([c + Vector2(s, -s), c + Vector2(-s, s)]), width, color)
		JOY_BUTTON_B:
			_batch.ring(c, r * 0.4, width, color)
		JOY_BUTTON_X:
			_batch.rect(Rect2(c - Vector2(r, r) * 0.36, Vector2(r, r) * 0.72), color, width)
		JOY_BUTTON_Y:
			var tri := PackedVector2Array()
			for i in 3:
				tri.append(c + Vector2.from_angle(-PI * 0.5 + TAU * i / 3.0) * r * 0.46 + Vector2(0.0, r * 0.06))
			_batch.stroke(tri, width, color, true)


func _draw_shoulder(it: Dictionary, p: float, a: float) -> void:
	var u := _unit
	var trigger: bool = it["trigger"]
	var ow := Tuning.glyph_outline_width
	var w: float = it["w"]
	var h := u * (0.95 if trigger else 0.72)
	var depth := h * (0.2 if trigger else 0.26)
	var sink := depth * Tuning.glyph_press_sink * p
	var shape := _shoulder_points(w, h, trigger, int(it["side"]))
	var lift := Vector2(0.0, -depth * 0.5)
	_batch.polygon(_offset(_grow_points(shape, ow), Vector2(0.0, depth * 0.5 + ow * 2.0)), Color(Tuning.glyph_shadow_color, a * Tuning.glyph_shadow_color.a))
	_batch.polygon(_offset(_grow_points(shape, ow), Vector2(0.0, depth * 0.5)), Color(Tuning.glyph_outline_color, a))
	_batch.polygon(_offset(_grow_points(shape, ow), lift + Vector2(0.0, sink)), Color(Tuning.glyph_outline_color, a))
	_batch.polygon(_offset(shape, Vector2(0.0, depth * 0.5)), Color(Tuning.glyph_pad_side, a))
	var top := _offset(shape, lift + Vector2(0.0, sink))
	var body := Tuning.glyph_pad_body.lightened(0.1 * p)
	_gradient_polygon(top, Rect2(-w * 0.5, -h * 0.5 + lift.y + sink, w, h), body.lightened(0.16), body.darkened(0.1), a)
	_batch.polygon(_round_rect(Rect2(Vector2(-w * 0.28, -h * 0.36 + lift.y + sink), Vector2(w * 0.4, u * 0.06)), u * 0.03), Color(1.0, 1.0, 1.0, a * 0.35))
	var line: TextLine = it["text"]
	var center := Vector2(0.0, lift.y + sink + h * (0.08 if trigger else 0.04))
	_text(line, center - line.get_size() * 0.5, Color(Tuning.glyph_pad_legend, a))


## Outline of a bumper (wide, domed top) or a trigger (tall, domed top, narrower at the bottom), centred on 0.
func _shoulder_points(w: float, h: float, trigger: bool, side: int) -> PackedVector2Array:
	var points := _round_rect(Rect2(-w * 0.5, -h * 0.5, w, h), minf(w, h) * (0.38 if trigger else 0.45))
	for i in points.size():
		var q := points[i]
		var across := q.x / (w * 0.5)
		if q.y < 0.0:
			var dome := 1.0 - across * across
			# The outer end of a bumper rises, as on the pad.
			var tilt := 0.0 if trigger else across * float(-side) * 0.12
			q.y -= h * ((0.16 if trigger else 0.1) * dome + tilt)
		if trigger:
			q.x *= lerpf(1.0, 0.8, clampf((q.y + h * 0.5) / h, 0.0, 1.0))
		points[i] = q
	return points


func _draw_stick(it: Dictionary, p: float, dir: Vector2, a: float) -> void:
	var u := _unit
	var ow := Tuning.glyph_outline_width
	var r := u * 0.46
	var click: bool = it.get("click", false)
	_batch.disc(Vector2(0.0, ow * 2.0), r + ow, Color(Tuning.glyph_shadow_color, a * Tuning.glyph_shadow_color.a))
	_batch.disc(Vector2.ZERO, r + ow, Color(Tuning.glyph_outline_color, a))
	_batch.disc(Vector2.ZERO, r, Color(Tuning.glyph_pad_side, a))
	_batch.ring(Vector2.ZERO, r * 0.88, r * 0.06, Color(Tuning.glyph_pad_body, a * 0.6))
	if not click:
		for d: Vector2 in it.get("dirs", []):
			if d == Vector2.ZERO:
				continue
			var on := p if d == dir else 0.0
			_draw_pointer_arrow(d * (r + u * 0.17 + u * 0.05 * on), d, u * 0.2, on, a)
	var knob_r := r * 0.72 * (1.0 - 0.08 * p if click else 1.0)
	var knob := (dir * r * 0.3 * p) if not click else Vector2.ZERO
	var kdepth := knob_r * 0.22
	_batch.disc(knob + Vector2(0.0, kdepth), knob_r + ow, Color(Tuning.glyph_outline_color, a))
	_batch.disc(knob, knob_r + ow, Color(Tuning.glyph_outline_color, a))
	_batch.disc(knob + Vector2(0.0, kdepth), knob_r, Color(Tuning.glyph_pad_side.lightened(0.05), a))
	var body := Tuning.glyph_pad_body.lightened(0.1 * p)
	var disc := ShapeBatch.circle_points(knob, Vector2(knob_r, knob_r), 0.0)
	_gradient_polygon(disc, Rect2(knob - Vector2(knob_r, knob_r), Vector2(knob_r, knob_r) * 2.0), body.lightened(0.18), body.darkened(0.1), a)
	_batch.ring(knob, knob_r * 0.7, knob_r * 0.1, Color(body.darkened(0.25), a * 0.8))
	_batch.polygon(ShapeBatch.circle_points(knob + Vector2(-knob_r * 0.3, -knob_r * 0.52), Vector2(knob_r * 0.3, knob_r * 0.13), -0.35), Color(1.0, 1.0, 1.0, a * 0.4))
	var line: TextLine = it["text"]
	_text(line, knob - line.get_size() * 0.5, Color(Tuning.glyph_pad_legend, a))
	if click:
		# Two arcs above and below that pulse out on the click.
		for side: float in [-1.0, 1.0]:
			var mid := PI * 0.5 * side
			var radius := r + u * (0.12 + 0.08 * p)
			_batch.arc(Vector2.ZERO, radius, mid - 0.6, mid + 0.6, u * 0.06, Color(Tuning.glyph_lit_color, a * (0.4 + 0.6 * p)))


func _draw_dpad(it: Dictionary, p: float, dir: Vector2, a: float) -> void:
	var u := _unit
	var ow := Tuning.glyph_outline_width
	var arm := u * 0.34
	var half := u * 0.5
	var bars: Array[Rect2] = [Rect2(-half, -arm * 0.5, u, arm), Rect2(-arm * 0.5, -half, arm, u)]
	var depth := u * 0.08
	for bar: Rect2 in bars:
		_batch.polygon(_offset(_round_rect(bar.grow(ow), u * 0.08 + ow), Vector2(0.0, depth + ow * 2.0)), Color(Tuning.glyph_shadow_color, a * Tuning.glyph_shadow_color.a))
	for bar: Rect2 in bars:
		_batch.polygon(_offset(_round_rect(bar.grow(ow), u * 0.08 + ow), Vector2(0.0, depth)), Color(Tuning.glyph_outline_color, a))
	for bar: Rect2 in bars:
		_batch.polygon(_offset(_round_rect(bar, u * 0.08), Vector2(0.0, depth)), Color(Tuning.glyph_pad_side, a))
	for bar: Rect2 in bars:
		_batch.polygon(_round_rect(bar.grow(ow), u * 0.08 + ow), Color(Tuning.glyph_outline_color, a))
	for bar: Rect2 in bars:
		_gradient_polygon(_round_rect(bar, u * 0.08), Rect2(-half, -half, u, u), Tuning.glyph_pad_body.lightened(0.16), Tuning.glyph_pad_body.darkened(0.08), a)
	_batch.disc(Vector2.ZERO, arm * 0.28, Color(Tuning.glyph_pad_side, a * 0.7))
	var pad_dirs: Array = it.get("pad_dirs", [])
	for d: Vector2 in [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]:
		var shown := pad_dirs.has(d)
		var on := p if d == dir else 0.0
		var tip := d * u * 0.4
		if on > 0.0:
			var arm_rect := Rect2(Vector2.ZERO, Vector2.ZERO)
			if d.x != 0.0:
				arm_rect = Rect2(Vector2(minf(0.0, d.x * half) + (arm * 0.5 if d.x > 0.0 else 0.0), -arm * 0.5), Vector2(half - arm * 0.5, arm))
			else:
				arm_rect = Rect2(Vector2(-arm * 0.5, minf(0.0, d.y * half) + (arm * 0.5 if d.y > 0.0 else 0.0)), Vector2(arm, half - arm * 0.5))
			_batch.polygon(_round_rect(arm_rect.grow(-1.5), u * 0.06), Color(Tuning.glyph_lit_color, a * on * 0.85))
		var tri_color := Tuning.glyph_pad_legend if shown else Tuning.glyph_pad_side.lightened(0.15)
		tri_color = tri_color.lerp(Tuning.glyph_outline_color, on * 0.8)
		var side := d.orthogonal() * u * 0.08
		_batch.polygon(PackedVector2Array([tip, tip - d * u * 0.13 + side, tip - d * u * 0.13 - side]), Color(tri_color, a * (1.0 if shown else 0.6)))


func _draw_menu(it: Dictionary, p: float, a: float) -> void:
	var u := _unit
	var ow := Tuning.glyph_outline_width
	var r := u * 0.34
	var sink := r * 0.15 * p
	_batch.disc(Vector2(0.0, ow * 2.0 + r * 0.15), r + ow, Color(Tuning.glyph_shadow_color, a * Tuning.glyph_shadow_color.a))
	_batch.disc(Vector2(0.0, r * 0.15), r + ow, Color(Tuning.glyph_outline_color, a))
	_batch.disc(Vector2(0.0, r * 0.15), r, Color(Tuning.glyph_pad_side, a))
	_batch.disc(Vector2(0.0, sink), r + ow, Color(Tuning.glyph_outline_color, a))
	_batch.disc(Vector2(0.0, sink), r, Color(Tuning.glyph_pad_body.lightened(0.1 * p), a))
	var c := Vector2(0.0, sink)
	var color := Color(Tuning.glyph_pad_legend, a)
	match int(it["button"]):
		JOY_BUTTON_BACK:
			_batch.rect(Rect2(c + Vector2(-r * 0.45, -r * 0.35), Vector2(r * 0.55, r * 0.45)), color, r * 0.12)
			_batch.rect(Rect2(c + Vector2(-r * 0.1, -r * 0.1), Vector2(r * 0.55, r * 0.45)), color, r * 0.12)
		JOY_BUTTON_START:
			for k in 3:
				var y := (k - 1) * r * 0.3
				_batch.stroke(PackedVector2Array([c + Vector2(-r * 0.4, y), c + Vector2(r * 0.4, y)]), r * 0.13, color)
		_:
			_batch.ring(c, r * 0.45, r * 0.13, color)


## A copy of the touch button; a drag step also pulls a knob out of the button and lets it go.
func _draw_touch_button(row: Dictionary, it: Dictionary, t: float, p: float, a: float) -> void:
	var button: TouchButton = it["touch"]
	var drag: bool = it.get("press", TAP) == DRAG
	var shift := Vector2(_unit * (float(it["w"]) / _unit - 1.0) * 0.5, 0.0) if drag else Vector2.ZERO
	var keep := _batch.transform
	_batch.transform = keep * Transform2D(0.0, shift)
	button.draw(_batch)
	if drag and p > 0.0:
		var reach := _smooth(_window_progress(row, it, t) * 1.4) * button.radius * Tuning.glyph_touch_drag_reach
		var knob := TOUCH_DRAG_DIR * reach
		var accent := Color(button.accent, a * p)
		for k in 3:
			_batch.disc(knob * (k + 1) / 4.0, button.radius * 0.07, Color(accent, accent.a * 0.7))
		_batch.disc(knob, button.radius * 0.36, Color(Tuning.touch_fill_color, a * p * 0.8))
		_batch.ring(knob, button.radius * 0.36, button.radius * 0.08, accent)
		_batch.disc(knob + Vector2(-0.3, -0.35) * button.radius * 0.36, button.radius * 0.1, Color(1.0, 1.0, 1.0, a * p * 0.5))
	_batch.transform = keep


## Slime state marks: a flickering flame, a turning snowflake, an ice cube with a glint, a bobbing goo drop.
func _draw_state(it: Dictionary, a: float) -> void:
	var u := _unit
	var ow := Tuning.glyph_outline_width
	var outline := Color(Tuning.glyph_outline_color, a)
	var phase := _clock * TAU * Tuning.glyph_state_hz
	match it["state"]:
		&"flame":
			var flick := 1.0 + 0.08 * sin(phase * 2.3) + 0.05 * sin(phase * 3.7)
			var outer := _teardrop(Vector2(0.0, u * 0.12), u * 0.3, u * 0.36 * flick, 0.08 * sin(phase * 1.7))
			_batch.polygon(_grow_points(outer, ow), outline)
			_gradient_polygon(outer, Rect2(-u * 0.3, -u * 0.5, u * 0.6, u), Tuning.glyph_flame_outer.lightened(0.15), Tuning.glyph_flame_outer.darkened(0.15), a)
			var inner := _teardrop(Vector2(0.0, u * 0.2), u * 0.16, u * 0.2 * (2.0 - flick), -0.1 * sin(phase * 2.1))
			_batch.polygon(inner, Color(Tuning.glyph_flame_inner, a))
		&"drop":
			var bob := sin(phase) * u * 0.04
			var drop := _teardrop(Vector2(0.0, u * 0.12 + bob), u * 0.3, u * 0.32, 0.0)
			_batch.polygon(_grow_points(drop, ow), outline)
			_gradient_polygon(drop, Rect2(-u * 0.3, -u * 0.5, u * 0.6, u), Tuning.glyph_drop_color.lightened(0.2), Tuning.glyph_drop_color.darkened(0.2), a)
			_batch.polygon(ShapeBatch.circle_points(Vector2(-u * 0.1, u * 0.06 + bob), Vector2(u * 0.06, u * 0.1), -0.4), Color(1.0, 1.0, 1.0, a * 0.6))
		&"snow":
			var turn := phase * 0.15
			var arms: Array[PackedVector2Array] = []
			for k in 3:
				var d := Vector2.from_angle(turn + PI * k / 3.0)
				arms.append(PackedVector2Array([-d * u * 0.4, d * u * 0.4]))
				for end: float in [-1.0, 1.0]:
					var base := d * u * 0.24 * end
					var side := d.orthogonal() * u * 0.1
					arms.append(PackedVector2Array([base + side + d * u * 0.1 * end, base, base - side + d * u * 0.1 * end]))
			for arm: PackedVector2Array in arms:
				_batch.stroke(arm, u * 0.08 + ow * 2.0, outline)
			for arm: PackedVector2Array in arms:
				_batch.stroke(arm, u * 0.08, Color(Tuning.glyph_snow_color, a))
		&"cube":
			var box := Rect2(-u * 0.36, -u * 0.36, u * 0.72, u * 0.72)
			_batch.polygon(_round_rect(box.grow(ow), u * 0.12 + ow), outline)
			_gradient_polygon(_round_rect(box, u * 0.12), box, Tuning.glyph_ice_color.lightened(0.25), Tuning.glyph_ice_color.darkened(0.15), a)
			var top := Rect2(box.position + Vector2(u * 0.08, u * 0.07), Vector2(box.size.x - u * 0.16, u * 0.2))
			_batch.polygon(_round_rect(top, u * 0.06), Color(1.0, 1.0, 1.0, a * 0.35))
			var glint := fposmod(phase * 0.25, 1.0)
			if glint < 0.35:
				var x := lerpf(-u * 0.3, u * 0.3, glint / 0.35)
				_batch.stroke(PackedVector2Array([Vector2(x - u * 0.08, u * 0.28), Vector2(x + u * 0.08, -u * 0.28)]), u * 0.06, Color(1.0, 1.0, 1.0, a * 0.7), false, false)


## A red ring with a slash over an input that this state blocks.
func _draw_cross(it: Dictionary, a: float) -> void:
	var u := _unit
	var r := minf(float(it["w"]), u) * 0.56
	var ow := Tuning.glyph_outline_width
	var color := Color(Tuning.glyph_cross_color, a)
	var outline := Color(Tuning.glyph_outline_color, a)
	var slash := PackedVector2Array([Vector2.from_angle(PI * 0.75) * r, Vector2.from_angle(-PI * 0.25) * r])
	_batch.ring(Vector2.ZERO, r, u * 0.09 + ow * 2.0, outline)
	_batch.stroke(slash, u * 0.09 + ow * 2.0, outline, false, false)
	_batch.ring(Vector2.ZERO, r, u * 0.09, color)
	_batch.stroke(slash, u * 0.09, color, false, false)


## A drop shape: a round bottom of radius at center with its tip height above, leaned by lean (radians).
static func _teardrop(center: Vector2, radius: float, height: float, lean: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	var gap := 0.65
	var steps := 14
	points.append(center + Vector2(0.0, -radius - height).rotated(lean))
	for i in steps + 1:
		var angle := -PI * 0.5 + gap + (TAU - gap * 2.0) * i / steps
		points.append(center + Vector2.from_angle(angle) * radius)
	return points


## A small arrow that sits beside a stick or the mouse; it is lit and larger while its direction is held.
func _draw_pointer_arrow(at: Vector2, d: Vector2, length: float, on: float, a: float) -> void:
	var side := d.orthogonal() * length * 0.55 * (1.0 + 0.25 * on)
	var tip := at + d * length * 0.5 * (1.0 + 0.2 * on)
	var back := at - d * length * 0.5
	var tri := PackedVector2Array([tip, back + side, back - side])
	_batch.polygon(_grow_points(tri, Tuning.glyph_outline_width), Color(Tuning.glyph_outline_color, a * 0.9))
	var color := Tuning.glyph_arrow_dim.lerp(Tuning.glyph_lit_color, on)
	_batch.polygon(tri, Color(color, a * lerpf(Tuning.glyph_arrow_dim.a, 1.0, on)))


## A thick arrow (stem and head) for an arrow keycap.
func _draw_arrow(c: Vector2, d: Vector2, length: float, color: Color) -> void:
	var tip := c + d * length * 0.5
	var head_back := tip - d * length * 0.5
	var side := d.orthogonal() * length * 0.36
	_batch.polygon(PackedVector2Array([tip, head_back + side, head_back - side]), color)
	_batch.stroke(PackedVector2Array([c - d * length * 0.5, head_back + d * 1.0]), length * 0.2, color, false, false)


func _text(line: TextLine, pos: Vector2, color: Color, outline := 0, outline_color := Color.BLACK) -> void:
	_texts.append([line, pos, color, outline, outline_color, _batch.transform])


# --- Shape helpers ----------------------------------------------------------------------------------------------

## Fills a convex outline with a vertical gradient from top_color to bottom_color across area.
func _gradient_polygon(points: PackedVector2Array, area: Rect2, top_color: Color, bottom_color: Color, a: float) -> void:
	var colors := PackedColorArray()
	colors.resize(points.size())
	for i in points.size():
		var k := clampf((points[i].y - area.position.y) / maxf(area.size.y, 0.001), 0.0, 1.0)
		colors[i] = Color(top_color.lerp(bottom_color, k), a)
	_batch.polygon(points, Color(top_color, a), colors)


static func _round_rect(area: Rect2, radius: float) -> PackedVector2Array:
	var rad := clampf(radius, 0.0, minf(area.size.x, area.size.y) * 0.5)
	var centers := [
		Vector2(area.end.x - rad, area.position.y + rad),
		Vector2(area.end.x - rad, area.end.y - rad),
		Vector2(area.position.x + rad, area.end.y - rad),
		Vector2(area.position.x + rad, area.position.y + rad),
	]
	var points := PackedVector2Array()
	for c in 4:
		var start := -PI * 0.5 + c * PI * 0.5
		for s in CORNER_STEPS + 1:
			points.append(centers[c] + Vector2.from_angle(start + PI * 0.5 * s / CORNER_STEPS) * rad)
	return points


static func _rect_points(area: Rect2) -> PackedVector2Array:
	return PackedVector2Array([area.position, Vector2(area.end.x, area.position.y), area.end, Vector2(area.position.x, area.end.y)])


static func _offset(points: PackedVector2Array, by: Vector2) -> PackedVector2Array:
	var out := points.duplicate()
	for i in out.size():
		out[i] += by
	return out


## Pushes every point of a convex outline away from its centroid by amount, for the dark outline under a shape.
static func _grow_points(points: PackedVector2Array, amount: float) -> PackedVector2Array:
	var center := Vector2.ZERO
	for q: Vector2 in points:
		center += q
	center /= maxf(points.size(), 1)
	var out := points.duplicate()
	for i in out.size():
		out[i] += (out[i] - center).normalized() * amount
	return out


static func _smooth(x: float) -> float:
	var k := clampf(x, 0.0, 1.0)
	return k * k * (3.0 - 2.0 * k)


static func _ease_out_back(t: float) -> float:
	var s := 1.70158
	var u := t - 1.0
	return 1.0 + (s + 1.0) * u * u * u + s * u * u
