extends Node
## CLI-driven capture, freeze, scripted input and state logs for runs with no human at the keyboard.
## Every Harness argument comes after "--" on the command line. With no argument the node does nothing.
## A scripted run hears only the input that Harness injects, and reads and writes no saved settings of the user unless
## --user-settings is given (see blocks_real_input and uses_user_settings()).

enum Sink { LOG, LOG_OR_STDOUT, LOG_AND_STDOUT }

const ARG_KINDS := {
	"seed": "int",
	"spawn": "spawn",
	"mass": "float",
	"input": "text",
	"input-inline": "text",
	"log": "text",
	"log-every": "int",
	"quit-at-tick": "int",
	"shot": "text",
	"frames": "int",
	"shots": "text",
	"at": "int_list",
	"freeze-at": "float",
	"frame-log": "flag",
	"perf": "flag",
	"no-hud": "flag",
	"no-hints": "flag",
	"touch": "flag",
	"safe-insets": "insets",
	"render-info": "flag",
	"perf-panel": "flag",
	"props": "props",
	"haptics": "haptics",
	"input-mode": "input_mode",
	"pad-name": "text",
	"temp": "float",
	"burn": "flag",
	"perf-summary": "flag",
	"juice-log": "flag",
	"user-settings": "flag",
	# Read by the Quality autoload.
	"quality": "text", "render-scale": "text", "quality-log": "flag", "quality-governor": "flag", "quality-save": "text", "slow-frame": "text",
	"quality-phone": "flag", "quality-fake-busy": "text", "slow-share": "text",
}
## "aim" holds the aim mode (like LT), "fire" fires (like RT), "shoot" is the quick shot (like X).
## "run" holds the run (like RB), "dodge" is the dodge or roll button (like B), "down" holds the stick down (crouch).
const INPUT_ACTIONS: PackedStringArray = ["left", "right", "jump", "restart", "shoot", "aim", "fire", "run", "dodge", "down"]
## "<tick> stick=<degrees>,<force>" holds the right stick at an angle (0 is right, 90 is down) and a deflection 0..1,
## until "<tick> stick=off".
const STICK_PREFIX := "stick="
## Device commands go through Input like a real device, so the game reads them with no scripted intent:
## "<tick> touch=<finger>,<x>,<y>" puts a finger down, "<tick> drag=<finger>,<x>,<y>[,<ticks>]" moves it (over
## <ticks> physics ticks when given), "<tick> lift=<finger>" lifts it, "<tick> key=<name>" taps a key for one tick,
## "<tick> pad=<button index>" taps a pad button, "<tick> axis=<axis index>,<value>" moves a pad axis and holds it,
## "<tick> joy=on|off" sends the connection signal of pad 0 (these three do not turn the touch mode on).
## x and y are canvas pixels, the space of the 1280x720 layout.
const TOUCH_PREFIX := "touch="
const DRAG_PREFIX := "drag="
const LIFT_PREFIX := "lift="
const KEY_PREFIX := "key="
const PAD_PREFIX := "pad="
const AXIS_PREFIX := "axis="
const JOY_PREFIX := "joy="
const PAD_PREFIXES: PackedStringArray = [PAD_PREFIX, AXIS_PREFIX, JOY_PREFIX]
## A key and a pad button that no action uses, so --input-mode switches the mode with no gameplay input.
const MODE_SWITCH_KEY := KEY_F24
const MODE_SWITCH_BUTTON := JOY_BUTTON_MISC1
const RENDER_INFO_EVERY := 60
const DEFAULT_LOG_EVERY := 30
const DEFAULT_SHOT_FRAME := 30
const PERF_LIMIT_MS := 25.0
## Frames after the level start that --perf-summary leaves out (load, shader and font warm-up).
const PERF_SUMMARY_SKIP := 120
## Absorbs float drift in the summed tick deltas, so --freeze-at=0.5 stops at tick 30 and not 31.
const FREEZE_EPSILON := 0.000001
## Runs after every gameplay node, so a state line shows the result of its own tick.
const PHYSICS_PRIORITY := 1000
## Arguments that make a scripted run, which hears only the input that Harness injects.
const SCRIPTED_RUN_ARGS: PackedStringArray = ["input", "input-inline", "log", "shot", "shots", "quit-at-tick"]

var spawn_override := ""
var mass_override := -1.0
var hide_hud := false
var hide_hints := false
## The game behaves as a touch device on desktop (set by --touch or by any touch command).
var force_touch := false
## Fake display insets in window pixels (left, top, right, bottom), as a notch or system bars would make.
var safe_insets := Vector4.ZERO
var open_perf_panel := false
## True while Harness feeds its own touch and key events through Input.
var injecting := false
## A scripted run (scripted input, a log, a shot or a quit tick): real keyboards, mice, touch screens and pads do not
## reach the game, only the events that Harness injects (with injecting set and device Tuning.harness_device).
## Set before any _ready, so every autoload can read it.
var blocks_real_input := false
## Pad name that the input icons read in place of the connected pad (--pad-name), to show the PlayStation family.
var pad_name := ""
## Temperature of the slime at the first spawn (--temp, -1 ice cube to +1 melted) and a fire at the first spawn (--burn).
var temperature_override := 0.0
var burn_override := false

var _args := {}
var _commands := {}
var _device_commands := {}
var _device_done_tick := 0
var _finger_pos := {}
## Finger -> [from, to, first tick, ticks] of a drag spread over several ticks.
var _glides := {}
var _key_releases := {}
var _render_info := false
var _draw_calls_max := 0
var _held := {}
var _tapped := {}
var _stick: Vector2 = Vector2.ZERO
var _scripted := false
var _done_tick := 0
var _log_every := DEFAULT_LOG_EVERY
var _log_file: FileAccess
var _log_stdout := false
var _quit_at := -1
var _freeze_at := -1.0
var _frozen := false
var _shot_frames: Array[int] = []
var _shots_left := 0
var _shot_path := ""
var _shots_dir := ""
var _frame := -1
var _level_tick := 0
var _level_active := false
var _finished := false
var _frame_log := false
## Logs every camera, time scale, sound and vibration call with its caller (EVENT juice, EVENT sfx).
var juice_log := false
var _perf := false
var _last_usec := 0
var _warned_no_player := false


func _init() -> void:
	for raw: String in OS.get_cmdline_user_args():
		var key := raw.trim_prefix("--").get_slice("=", 0)
		if SCRIPTED_RUN_ARGS.has(key):
			blocks_real_input = true


func _ready() -> void:
	if OS.is_debug_build():
		preload("res://scenes/player/cargo.gd").check_deform()
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = PHYSICS_PRIORITY
	set_process_input(blocks_real_input)
	set_process(false)
	set_physics_process(false)
	_parse_args()
	if _args.is_empty():
		return
	if _args.has("seed"):
		Game.reseed(String(_args.seed).to_int())
	spawn_override = _args.get("spawn", "")
	mass_override = String(_args.get("mass", "-1")).to_float()
	hide_hud = _args.has("no-hud")
	hide_hints = _args.has("no-hints")
	_log_every = String(_args.get("log-every", str(DEFAULT_LOG_EVERY))).to_int()
	_quit_at = String(_args.get("quit-at-tick", "-1")).to_int()
	_freeze_at = String(_args.get("freeze-at", "-1")).to_float()
	_frame_log = _args.has("frame-log")
	juice_log = _args.has("juice-log")
	_perf = _args.has("perf")
	_render_info = _args.has("render-info")
	open_perf_panel = _args.has("perf-panel")
	if _args.has("safe-insets"):
		var parts := String(_args["safe-insets"]).split(",")
		safe_insets = Vector4(parts[0].to_float(), parts[1].to_float(), parts[2].to_float(), parts[3].to_float())
	_setup_shots()
	_setup_log()
	_load_script()
	if blocks_real_input:
		_isolate_input_map()
	force_touch = _args.has("touch") or _has_touch_commands()
	pad_name = String(_args.get("pad-name", ""))
	temperature_override = String(_args.get("temp", "0")).to_float()
	burn_override = _args.has("burn")
	if _args.has("input-mode"):
		_force_input_mode.call_deferred(String(_args["input-mode"]))
	# The headless window is not 1280x720; touch coordinates need the layout size that a windowed run has.
	if force_touch and DisplayServer.get_name() == "headless":
		get_tree().root.size = Vector2i(ProjectSettings.get_setting("display/window/size/viewport_width"), ProjectSettings.get_setting("display/window/size/viewport_height"))
	_connect_events()
	call_deferred(&"_connect_touch_events")
	set_physics_process(_log_active() or _quit_at > 0 or _freeze_at >= 0.0 or not _device_commands.is_empty())
	set_process(_shots_left > 0 or _frame_log or _perf or _render_info)
	_record("READY", {"seed": Game.seed_value, "args": _args, "sfx_bake_ms": _num(Sfx.bake_ms)})
	if _perf:
		_line("BOOT " + _json({"ready_ms": Time.get_ticks_msec(), "sfx_bake_ms": _num(Sfx.bake_ms)}), Sink.LOG_OR_STDOUT)


## Asks the level for the spawn marker; an unknown name falls back to the level start with an error.
func spawn_position(level: Node) -> Vector2:
	var fallback: Vector2 = level.get("start_position")
	if spawn_override == "":
		return fallback
	if not bool(level.call("has_marker", spawn_override)):
		var names: PackedStringArray = level.call("marker_names")
		_error("unknown spawn '%s'; use one of %s or tile coordinates x,y" % [spawn_override, ", ".join(names)])
		return fallback
	return level.call("marker_position", spawn_override)


func has_scripted_input() -> bool:
	return _scripted


## The run may read and write the settings saved in user:// (perf.cfg, quality.cfg): a normal session, or a Harness
## run with --user-settings. Other Harness runs start from the defaults and leave the files alone.
func uses_user_settings() -> bool:
	return _args.is_empty() or _args.has("user-settings")


## Connected pads as the game may see them: none in a scripted run, so a real pad never changes it.
func connected_pads() -> Array[int]:
	if blocks_real_input:
		return [] as Array[int]
	return Input.get_connected_joypads()


## True when an input event or a pad signal must be ignored: a scripted run that is not injecting it now.
func ignores_input() -> bool:
	return blocks_real_input and not injecting


func intent_at(tick: int) -> Dictionary:
	while _done_tick < tick:
		_done_tick += 1
		for cmd: String in _commands.get(_done_tick, []):
			_apply(cmd, _done_tick)
	for action: String in _held.keys():
		var until: int = _held[action]
		if until >= 0 and tick > until:
			_held.erase(action)
	var move := (1.0 if _held.has("right") else 0.0) - (1.0 if _held.has("left") else 0.0)
	return {
		"move": move,
		"jump_pressed": _tapped.get("jump", -1) == tick,
		"jump_held": _held.has("jump"),
		"restart": _tapped.get("restart", -1) == tick,
		"shoot_pressed": _tapped.get("shoot", -1) == tick,
		"fire_pressed": _tapped.get("fire", -1) == tick,
		"aim_held": _held.has("aim"),
		"aim_vector": _stick,
		"run_held": _held.has("run"),
		"dodge_pressed": _tapped.get("dodge", -1) == tick,
		"down": 1.0 if _held.has("down") else 0.0,
	}


func _physics_process(_delta: float) -> void:
	if not _level_active or _finished or get_tree().paused:
		return
	_level_tick += 1
	_step_devices(Game.input_tick)
	if _log_active() and Game.level_running and _log_every > 0 and Game.tick % _log_every == 0:
		_record("STATE", _state())
	if _freeze_at >= 0.0 and not _frozen and Game.sim_time + FREEZE_EPSILON >= _freeze_at:
		_frozen = true
		get_tree().paused = true
		_event("frozen", {})
	# Counted here and not from Game.tick, which stops at the goal and would never reach the limit.
	if _quit_at > 0 and _level_tick >= _quit_at:
		_finish("quit_at_tick")


## A real event that reaches this point in a scripted run goes no further (GUI, unhandled input).
func _input(_event: InputEvent) -> void:
	if not injecting:
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if _perf:
		_check_frame_time()
	if _render_info:
		_track_render_info()
	if _frame < 0 or _finished:
		return
	if _frame_log:
		_write_frame()
	if _shot_frames.has(_frame):
		_capture(_shot_target(_frame))
	_frame += 1


func _parse_args() -> void:
	for raw: String in OS.get_cmdline_user_args():
		if not raw.begins_with("--"):
			_error("unknown argument '%s'" % raw)
			continue
		var arg := raw.trim_prefix("--")
		var key := arg
		var value := "true"
		var eq := arg.find("=")
		if eq >= 0:
			key = arg.substr(0, eq)
			value = arg.substr(eq + 1)
		if not ARG_KINDS.has(key):
			_error("unknown argument '%s'" % raw)
			continue
		var problem := _validate(key, value, eq >= 0)
		if problem != "":
			_error("ignored '%s': %s" % [raw, problem])
			continue
		_args[key] = value
	if _args.has("frames") and not _args.has("shot"):
		_error("--frames has no effect without --shot")
	if _args.has("at") and not _args.has("shots"):
		_error("--at has no effect without --shots")
	if _args.has("shot") and _args.has("shots"):
		_error("--shot and --shots both given; --shots is ignored")
		_args.erase("shots")


## Returns an empty string when the value is valid for the argument, else the reason.
func _validate(key: String, value: String, has_value: bool) -> String:
	var kind: String = ARG_KINDS[key]
	if kind == "flag":
		return "" if not has_value else "takes no value"
	if not has_value or value.strip_edges() == "":
		return "needs a value"
	match kind:
		"int":
			if not value.is_valid_int():
				return "not an integer"
			var number := value.to_int()
			if key == "quit-at-tick" and number < 1:
				return "must be 1 or more"
			if (key == "log-every" or key == "frames") and number < 0:
				return "must be 0 or more"
		"float":
			if not value.is_valid_float():
				return "not a number"
			var number := value.to_float()
			if key == "mass" and number <= 0.0:
				return "must be above 0"
			if key == "freeze-at" and number < 0.0:
				return "must be 0 or more"
			if key == "temp" and absf(number) > 1.0:
				return "must be from -1 to 1"
		"int_list":
			for part: String in value.split(","):
				if not part.strip_edges().is_valid_int() or part.to_int() < 0:
					return "needs a comma list of frame numbers (0 or more)"
		"spawn":
			if value.contains(" "):
				return "use a marker name or tile coordinates x,y"
		"props":
			for entry: String in value.split(";"):
				var parts := entry.split("@")
				var cell := parts[1].split(",") if parts.size() == 2 else PackedStringArray()
				if cell.size() != 2 or parts[0].strip_edges() == "" or not cell[0].is_valid_int() or not cell[1].is_valid_int():
					return "needs kind@x,y entries (tile coordinates) separated by ;"
		"haptics":
			if not value in ["pad", "touch", "keys"]:
				return "needs pad, touch or keys"
		"input_mode":
			if not value in ["pad", "keys"]:
				return "needs pad or keys (use --touch for the touch mode)"
		"insets":
			var parts := value.split(",")
			if parts.size() != 4:
				return "needs left,top,right,bottom in window pixels"
			for part: String in parts:
				if not part.strip_edges().is_valid_float() or part.to_float() < 0.0:
					return "needs left,top,right,bottom in window pixels, 0 or more"
	return ""


func _setup_shots() -> void:
	if _args.has("shot"):
		_shot_path = _os_path(_args.shot)
		_shot_frames = [String(_args.get("frames", str(DEFAULT_SHOT_FRAME))).to_int()]
	elif _args.has("shots"):
		_shots_dir = _os_path(_args.shots)
		for part: String in String(_args.get("at", str(DEFAULT_SHOT_FRAME))).split(","):
			var frame := part.strip_edges().to_int()
			if not _shot_frames.has(frame):
				_shot_frames.append(frame)
	_shots_left = _shot_frames.size()
	if _shots_left > 0 and DisplayServer.get_name() == "headless":
		_error("the headless renderer draws nothing; run the capture windowed")


func _setup_log() -> void:
	if not _args.has("log"):
		return
	var target: String = _args.log
	if target == "stdout":
		_log_stdout = true
		return
	var path := _os_path(target)
	if not _ensure_dir(path.get_base_dir()):
		_error("cannot create the folder of the log '%s'; logging to stdout" % path)
		_log_stdout = true
		return
	_log_file = FileAccess.open(path, FileAccess.WRITE)
	if _log_file == null:
		_error("cannot open the log '%s' (err=%d); logging to stdout" % [path, FileAccess.get_open_error()])
		_log_stdout = true


func _load_script() -> void:
	var text := ""
	if _args.has("input"):
		var path := _os_path(_args.input)
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			_error("cannot read the input script '%s' (err=%d)" % [path, FileAccess.get_open_error()])
		else:
			text += file.get_as_text() + "\n"
	if _args.has("input-inline"):
		text += String(_args["input-inline"])
	for raw_line: String in text.split("\n"):
		var line := raw_line
		var comment := line.find("#")
		if comment >= 0:
			line = line.substr(0, comment)
		for cmd: String in line.split(";"):
			_add_command(cmd.strip_edges())
	if not _commands.is_empty() and not _device_commands.is_empty():
		_error("action commands replace the device input, so the touch and key commands are ignored; use one kind per run")
		_device_commands.clear()
	_scripted = not _commands.is_empty()


func _add_command(cmd: String) -> void:
	if cmd == "":
		return
	var parts := cmd.split(" ", false)
	if parts.size() != 2 or not parts[0].is_valid_int() or parts[0].to_int() < 1:
		_error("ignored input command '%s': use '<tick> <action>[+|-|:N]' or '<tick> stick=<degrees>,<force>|off' with tick 1 or more" % cmd)
		return
	for prefix: String in [TOUCH_PREFIX, DRAG_PREFIX, LIFT_PREFIX, KEY_PREFIX, PAD_PREFIX, AXIS_PREFIX, JOY_PREFIX]:
		if parts[1].begins_with(prefix):
			var problem := _device_problem(prefix, parts[1].substr(prefix.length()))
			if problem != "":
				_error("ignored input command '%s': %s" % [cmd, problem])
				return
			var tick := parts[0].to_int()
			if not _device_commands.has(tick):
				_device_commands[tick] = [] as Array[String]
			(_device_commands[tick] as Array[String]).append(parts[1])
			return
	if parts[1].begins_with(STICK_PREFIX):
		var value := parts[1].substr(STICK_PREFIX.length())
		var pair := value.split(",")
		if value != "off" and (pair.size() != 2 or not pair[0].is_valid_float() or not pair[1].is_valid_float()):
			_error("ignored input command '%s': stick takes <degrees>,<force> or off" % cmd)
			return
		_queue_command(parts[0].to_int(), parts[1])
		return
	var action := _command_action(parts[1])
	if not INPUT_ACTIONS.has(action):
		_error("ignored input command '%s': action must be one of %s" % [cmd, ", ".join(INPUT_ACTIONS)])
		return
	var suffix := parts[1].substr(action.length())
	var valid_suffix := suffix == "" or suffix == "+" or suffix == "-"
	if suffix.begins_with(":"):
		var count := suffix.substr(1)
		valid_suffix = count.is_valid_int() and count.to_int() >= 1
	if not valid_suffix:
		_error("ignored input command '%s': suffix must be +, -, or :N with N 1 or more" % cmd)
		return
	_queue_command(parts[0].to_int(), parts[1])


func _queue_command(tick: int, token: String) -> void:
	if not _commands.has(tick):
		_commands[tick] = [] as Array[String]
	var list: Array[String] = _commands[tick]
	list.append(token)


func _command_action(token: String) -> String:
	var end := token.length()
	for marker: String in ["+", "-", ":"]:
		var at := token.find(marker)
		if at >= 0:
			end = mini(end, at)
	return token.substr(0, end)


func _apply(cmd: String, tick: int) -> void:
	if cmd.begins_with(STICK_PREFIX):
		var value := cmd.substr(STICK_PREFIX.length())
		var pair := value.split(",")
		_stick = Vector2.ZERO if value == "off" else Vector2.from_angle(deg_to_rad(pair[0].to_float())) * clampf(pair[1].to_float(), 0.0, 1.0)
		return
	var action := _command_action(cmd)
	var suffix := cmd.substr(action.length())
	if suffix == "+":
		_held[action] = -1
		_tapped[action] = tick
	elif suffix == "-":
		_held.erase(action)
	elif suffix.begins_with(":"):
		_held[action] = tick + suffix.substr(1).to_int() - 1
		_tapped[action] = tick
	else:
		_held[action] = tick
		_tapped[action] = tick


## Returns an empty string when the device command value is valid, else the reason.
func _device_problem(prefix: String, value: String) -> String:
	var parts := value.split(",")
	match prefix:
		KEY_PREFIX:
			return "" if OS.find_keycode_from_string(value) != KEY_NONE else "unknown key name '%s'" % value
		PAD_PREFIX:
			return "" if value.is_valid_int() and value.to_int() >= 0 and value.to_int() < JOY_BUTTON_SDL_MAX else "takes a pad button index, 0 to %d" % (JOY_BUTTON_SDL_MAX - 1)
		AXIS_PREFIX:
			var ok := parts.size() == 2 and parts[0].is_valid_int() and parts[0].to_int() >= 0 and parts[0].to_int() < JOY_AXIS_SDL_MAX and parts[1].is_valid_float()
			return "" if ok else "takes <axis index>,<value>"
		JOY_PREFIX:
			return "" if value in ["on", "off"] else "takes on or off"
		LIFT_PREFIX:
			return "" if value.is_valid_int() and value.to_int() >= 0 else "takes a finger index, 0 or more"
	var counts := [3, 4] if prefix == DRAG_PREFIX else [3]
	if not counts.has(parts.size()) or not parts[0].is_valid_int() or parts[0].to_int() < 0:
		return "takes <finger>,<x>,<y>" + (" and optional ,<ticks>" if prefix == DRAG_PREFIX else "")
	if not parts[1].is_valid_float() or not parts[2].is_valid_float():
		return "x and y must be numbers"
	if parts.size() == 4 and (not parts[3].is_valid_int() or parts[3].to_int() < 1):
		return "ticks must be 1 or more"
	return ""


## Every input map event matches only the Harness device id, so the events of real devices trigger no action.
func _isolate_input_map() -> void:
	for action: StringName in InputMap.get_actions():
		var events := InputMap.action_get_events(action)
		InputMap.action_erase_events(action)
		for event: InputEvent in events:
			var own := event.duplicate() as InputEvent
			own.device = Tuning.harness_device
			InputMap.action_add_event(action, own)


## Injects the device commands of this tick, the glide steps and the key releases, then flushes them through Input.
func _step_devices(tick: int) -> void:
	if _device_commands.is_empty():
		return
	injecting = true
	while _device_done_tick < tick:
		_device_done_tick += 1
		for key: Key in _key_releases.get(_device_done_tick, []):
			_inject_key(key, false)
		_key_releases.erase(_device_done_tick)
		for index: int in _glides.keys():
			var glide: Array = _glides[index]
			var t := clampf(float(_device_done_tick - int(glide[2]) + 1) / float(glide[3]), 0.0, 1.0)
			_inject_drag(index, (glide[0] as Vector2).lerp(glide[1], t))
			if t >= 1.0:
				_glides.erase(index)
		for cmd: String in _device_commands.get(_device_done_tick, []):
			_apply_device(cmd, _device_done_tick)
	Input.flush_buffered_events()
	injecting = false


func _apply_device(cmd: String, tick: int) -> void:
	if cmd.begins_with(PAD_PREFIX):
		_inject_pad_tap(cmd.substr(PAD_PREFIX.length()).to_int() as JoyButton)
		return
	if cmd.begins_with(AXIS_PREFIX):
		var axis_parts := cmd.substr(AXIS_PREFIX.length()).split(",")
		var motion := InputEventJoypadMotion.new()
		motion.device = Tuning.harness_device
		motion.axis = axis_parts[0].to_int() as JoyAxis
		motion.axis_value = axis_parts[1].to_float()
		Input.parse_input_event(motion)
		return
	if cmd.begins_with(JOY_PREFIX):
		Input.joy_connection_changed.emit(0, cmd.substr(JOY_PREFIX.length()) == "on")
		return
	if cmd.begins_with(KEY_PREFIX):
		var key := OS.find_keycode_from_string(cmd.substr(KEY_PREFIX.length()))
		_inject_key(key, true)
		if not _key_releases.has(tick + 1):
			_key_releases[tick + 1] = []
		(_key_releases[tick + 1] as Array).append(key)
		return
	if cmd.begins_with(LIFT_PREFIX):
		var finger := cmd.substr(LIFT_PREFIX.length()).to_int()
		_glides.erase(finger)
		_inject_touch(finger, _finger_pos.get(finger, Vector2.ZERO), false)
		_finger_pos.erase(finger)
		_event("finger", {"finger": finger, "down": false})
		return
	var is_touch := cmd.begins_with(TOUCH_PREFIX)
	var parts := cmd.substr((TOUCH_PREFIX if is_touch else DRAG_PREFIX).length()).split(",")
	var finger := parts[0].to_int()
	var at := Vector2(parts[1].to_float(), parts[2].to_float())
	if is_touch:
		_glides.erase(finger)
		_inject_touch(finger, at, true)
		_event("finger", {"finger": finger, "down": true, "at": _vec(at)})
	elif parts.size() == 4:
		_glides[finger] = [_finger_pos.get(finger, at), at, tick, parts[3].to_int()]
		_inject_drag(finger, (_glides[finger][0] as Vector2).lerp(at, 1.0 / parts[3].to_int()))
		if parts[3].to_int() == 1:
			_glides.erase(finger)
	else:
		_glides.erase(finger)
		_inject_drag(finger, at)


## Canvas pixels become window pixels, the space a real touch arrives in; the viewport maps them back.
func _to_window(at: Vector2) -> Vector2:
	return get_viewport().get_final_transform() * at


func _inject_touch(finger: int, at: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = finger
	event.position = _to_window(at)
	event.pressed = pressed
	_finger_pos[finger] = at
	Input.parse_input_event(event)


func _inject_drag(finger: int, at: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = finger
	event.position = _to_window(at)
	event.relative = event.position - _to_window(_finger_pos.get(finger, at))
	_finger_pos[finger] = at
	Input.parse_input_event(event)


func _inject_key(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.device = Tuning.harness_device
	event.keycode = key
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)


func _connect_touch_events() -> void:
	if not _log_active():
		return
	TouchControls.action_changed.connect(func(action: StringName, pressed: bool) -> void:
		_event("touch_action", {"action": String(action), "pressed": pressed}))
	TouchControls.input_mode_changed.connect(func(mode: StringName) -> void:
		_event("input_mode", {"mode": String(mode), "showing": TouchControls.is_showing()}))


func _track_render_info() -> void:
	var calls := int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	_draw_calls_max = maxi(_draw_calls_max, calls)
	if Engine.get_process_frames() % RENDER_INFO_EVERY == 0:
		_line("RENDER " + _json(_render_data()), Sink.LOG_OR_STDOUT)


func _render_data() -> Dictionary:
	return {
		"frame": Engine.get_process_frames(),
		"draw_calls": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"draw_calls_max": _draw_calls_max,
		"objects": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		"primitives": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		"method": RenderingServer.get_current_rendering_method(),
	}


func _connect_events() -> void:
	Game.level_started.connect(_on_level_started)
	# --haptics=<pad|touch|keys> forces the input mode of the vibration, so a run with no device logs what it would send.
	var haptics: Node = Juice.haptics
	if _args.has("haptics"):
		haptics.set(&"forced_mode", StringName(_args["haptics"]))
	haptics.set(&"logging", _log_active())
	haptics.connect(&"logged", _event)
	Game.player_damaged.connect(func(amount: float, source: StringName, at: Vector2) -> void:
		_event("damage", {"amount": _num(amount), "source": String(source), "at": _vec(at), "pieces": _piece_count()}))
	Game.goo_absorbed.connect(func(amount: float, at: Vector2) -> void:
		_event("absorb", {"amount": _num(amount), "at": _vec(at)}))
	Game.goo_color_absorbed.connect(func(amount: float, color: Color, body_color: Color) -> void:
		_event("color_absorb", {"amount": _num(amount), "color": "#" + color.to_html(false), "body": "#" + body_color.to_html(false)}))
	Game.goo_lost.connect(func(amount: float, reason: StringName) -> void:
		_event("lost", {"amount": _num(amount), "reason": String(reason)}))
	Game.goo_gained.connect(func(amount: float, reason: StringName) -> void:
		_event("gained", {"amount": _num(amount), "reason": String(reason)}))
	Game.mass_changed.connect(func(mass: float, ratio: float) -> void:
		_event("mass", {"mass": _num(mass), "ratio": _num(ratio)}))
	Game.player_died.connect(func(source: StringName, at: Vector2) -> void:
		_event("died", {"source": String(source), "at": _vec(at)}))
	Game.respawn_requested.connect(func() -> void:
		_event("respawn_requested", {}))
	Game.player_respawned.connect(func(at: Vector2) -> void:
		_event("respawned", {"at": _vec(at), "mass": _player_mass()}))
	Game.checkpoint_reached.connect(func(id: StringName, at: Vector2) -> void:
		_event("checkpoint", {"id": String(id), "at": _vec(at), "mass": _player_mass()}))
	Game.goal_reached.connect(func(summary: Dictionary) -> void:
		_event("goal", _rounded(summary)))
	Game.prop_absorbed.connect(func(kind: StringName, at: Vector2, carried: int) -> void:
		_event("prop_absorbed", {"kind": String(kind), "at": _vec(at), "load": carried, "capacity": _player_int("capacity")}))
	Game.prop_dropped.connect(func(kind: StringName, at: Vector2, reason: StringName) -> void:
		_event("prop_dropped", {"kind": String(kind), "at": _vec(at), "reason": String(reason), "load": _player_int("load_count")}))
	Game.prop_shot.connect(func(kind: StringName, at: Vector2, dir: Vector2, carried: int, force: float, predicted: Variant) -> void:
		_event("shot", {"kind": String(kind), "at": _vec(at), "dir": _vec(dir), "force": _num(force), "predicted": _vec(predicted) if predicted is Vector2 else null, "load": carried}))
	Game.prop_bounced.connect(func(kind: StringName, bounce: int, speed: float, at: Vector2, surface: StringName, hot: bool, dist: float) -> void:
		_event("bounce", {"kind": String(kind), "n": bounce, "hot": hot, "speed": _num(speed), "dist": _num(dist), "at": _vec(at), "surface": String(surface)}))
	Game.prop_shattered.connect(func(material: StringName, size: int, pieces: int, trap: StringName, at: Vector2, evicted: int) -> void:
		_event("prop_shatter", {"kind": String(material), "size": size, "pieces": pieces, "trap": String(trap), "at": _vec(at), "evicted": evicted, "props": int(Game.props.call("count")) if is_instance_valid(Game.props) else 0}))
	Game.target_hit.connect(func(target: StringName, hp: int, at: Vector2) -> void:
		_event("target_hit", {"target": String(target), "hp": hp, "at": _vec(at)}))
	Game.enemy_died.connect(func(enemy: StringName, at: Vector2) -> void:
		_event("enemy_death", {"enemy": String(enemy), "at": _vec(at)}))
	Game.barrier_broken.connect(func(at: Vector2) -> void:
		_event("barrier_break", {"at": _vec(at)}))
	Game.player_moved.connect(func(move: StringName, data: Dictionary) -> void:
		var line := {"move": String(move)}
		line.merge(_plain(data))
		_event("move", line))
	Game.temperature_event.connect(func(event: StringName, data: Dictionary) -> void:
		_event(String(event), _plain(data)))


## Event data with vectors, floats and names in their log form.
func _plain(data: Dictionary) -> Dictionary:
	var line := {}
	for key: Variant in data:
		var value: Variant = data[key]
		line[key] = _vec(value) if value is Vector2 else (_num(value) if value is float else (String(value) if value is StringName else value))
	return line


func _on_level_started() -> void:
	_level_active = true
	_frame = 0
	# _level_tick keeps counting across scene reloads, so --quit-at-tick ends a run that restarts the level.
	_done_tick = 0
	_device_done_tick = 0
	_glides.clear()
	_held.clear()
	_tapped.clear()
	_stick = Vector2.ZERO
	var data := {"tick": Game.tick, "boot_ms": Time.get_ticks_msec(), "spawn": spawn_override, "mass": _player_mass()}
	_line("LEVEL_START " + _json(data), Sink.LOG_OR_STDOUT)
	if _args.has("perf-summary"):
		PerfPanel.begin_run(PERF_SUMMARY_SKIP)
	_place_extra_props()


## --props=kind@x,y;... drops extra props (any kind, pieces included) at the centre of those tiles; they fall to the floor.
func _place_extra_props() -> void:
	if not _args.has("props") or not is_instance_valid(Game.props):
		return
	var tile: float = Tuning.tile_size
	var serial := 0
	for entry: String in String(_args["props"]).split(";"):
		var parts := entry.split("@")
		var cell := parts[1].split(",")
		var at := Vector2((cell[0].to_float() + 0.5) * tile, (cell[1].to_float() + 0.5) * tile)
		Game.props.call("place", {"kind": StringName(parts[0].strip_edges()), "seed": 900 + serial, "home": at}, at)
		serial += 1


func _state() -> Dictionary:
	var data := {"tick": Game.tick, "time": _num(Game.sim_time)}
	var player := Game.player
	if is_instance_valid(player):
		var velocity: Variant = player.get("velocity")
		data["pos"] = _vec(player.global_position)
		data["vel"] = _vec(velocity) if velocity is Vector2 else null
		data["mass"] = _player_mass()
		data["state"] = String(player.call("state_name")) if player.has_method("state_name") else ""
		data["on_floor"] = bool(player.call("is_on_floor")) if player.has_method("is_on_floor") else false
	else:
		_warn_no_player()
		data["pos"] = null
		data["vel"] = null
		data["mass"] = 0.0
		data["state"] = "NONE"
		data["on_floor"] = false
	data["load"] = _player_int("load_count")
	data["aiming"] = bool(Game.player.call("is_aiming")) if is_instance_valid(Game.player) and Game.player.has_method("is_aiming") else false
	if is_instance_valid(Game.player) and Game.player.has_method("move_name"):
		data["move"] = String(Game.player.call("move_name"))
		data["crouched"] = bool(Game.player.call("is_crouched"))
		data["running"] = bool(Game.player.call("is_running"))
		data["air_jumps"] = int(Game.player.call("air_jumps_left"))
		data["capacity"] = _player_int("capacity")
	if is_instance_valid(Game.player) and Game.player.has_method("temperature_state"):
		data.merge(_plain(Game.player.call("temperature_state")))
	data["props"] = int(Game.props.call("count")) if is_instance_valid(Game.props) else 0
	data["pieces"] = _piece_count()
	data["piece_mass"] = _num(float(_field_call("total_piece_mass", 0.0)))
	data["droplets"] = int(_field_call("droplet_count", 0))
	data["lost"] = _num(Game.goo_lost_total)
	data["gained"] = _num(Game.goo_gained_total)
	data["balance"] = _num(Game.goo_balance())
	var goo_color: Variant = Game.player.get("goo_color") if is_instance_valid(Game.player) else null
	data["color"] = "#" + (goo_color as Color).to_html(false) if goo_color is Color else ""
	data["time_scale"] = _num(Engine.time_scale)
	return data


func _write_frame() -> void:
	var data := {"f": _frame, "tick": Game.tick}
	var player := Game.player
	if is_instance_valid(player):
		var world_pos: Vector2 = player.call("visual_position") if player.has_method("visual_position") else player.global_position
		data["player_screen"] = _vec(get_viewport().get_canvas_transform() * world_pos)
	else:
		_warn_no_player()
		data["player_screen"] = null
	var camera := get_viewport().get_camera_2d()
	data["cam"] = _vec(camera.get_screen_center_position()) if camera != null else null
	data["zoom"] = _num(camera.zoom.x) if camera != null else null
	data["trauma"] = _num(float(camera.get(&"_trauma"))) if camera != null and camera.get(&"_trauma") != null else null
	data["time_scale"] = _num(Engine.time_scale)
	_line("FRAME " + _json(data), Sink.LOG_OR_STDOUT)


func _check_frame_time() -> void:
	var now := Time.get_ticks_usec()
	if _last_usec > 0:
		var ms := (now - _last_usec) / 1000.0
		if ms > PERF_LIMIT_MS:
			_line("PERF frame=%d ms=%.1f" % [Engine.get_process_frames(), ms], Sink.LOG_OR_STDOUT)
	_last_usec = now


func _shot_target(frame: int) -> String:
	if _shot_path != "":
		return _shot_path
	return _shots_dir.path_join("shot_%d.png" % frame)


func _capture(path: String) -> void:
	# The headless renderer never emits frame_post_draw, so it fails the shot at once instead of hanging.
	var err: Error = ERR_UNAVAILABLE
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		err = _save_viewport(path)
	_line("SHOT %s err=%d" % [path, err], Sink.LOG_AND_STDOUT)
	if _render_info:
		_line("RENDER " + _json(_render_data()), Sink.LOG_AND_STDOUT)
	_shots_left -= 1
	if _shots_left <= 0:
		_finish("shots")


func _save_viewport(path: String) -> Error:
	if not _ensure_dir(path.get_base_dir()):
		_error("cannot create the folder of the shot '%s'" % path)
		return ERR_CANT_CREATE
	var image := get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		_error("the viewport gave no image for '%s'" % path)
		return ERR_CANT_ACQUIRE_RESOURCE
	return image.save_png(path)


func _finish(reason: String) -> void:
	if _finished:
		return
	_finished = true
	if _log_active():
		var data := _state()
		data["reason"] = reason
		data["level_tick"] = _level_tick
		data.merge(_rounded(Game.summary()))
		if is_instance_valid(Game.props) and Game.props.has_method("audit"):
			_record("PROPS", {"list": Game.props.call("audit")})
		_record("SUMMARY", data)
	if _args.has("perf-summary"):
		_line("PERF_SUMMARY " + _json(_rounded(PerfPanel.run_summary())), Sink.LOG_OR_STDOUT)
	if _log_file != null:
		_log_file.close()
		_log_file = null
	Game.quit_game()


## Writes an EVENT line for a node outside Harness (only when a log is active).
func log_event(event_name: String, data: Dictionary) -> void:
	_event(event_name, data)


## With --juice-log: an EVENT line for a feedback call, with the first caller outside the autoloads.
func log_juice(event_name: String, data: Dictionary) -> void:
	if not juice_log:
		return
	for frame: Dictionary in get_stack():
		var source := String(frame.get("source", ""))
		if not source.begins_with("res://autoload/"):
			data["caller"] = "%s:%d" % [source.get_file(), int(frame.get("line", 0))]
			break
	_event(event_name, data)


func _has_touch_commands() -> bool:
	for tick: int in _device_commands:
		for cmd: String in _device_commands[tick]:
			if not Array(PAD_PREFIXES).any(func(prefix: String) -> bool: return cmd.begins_with(prefix)):
				return true
	return false


func _inject_pad_tap(button: JoyButton) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventJoypadButton.new()
		event.device = Tuning.harness_device
		event.button_index = button
		event.pressed = pressed
		Input.parse_input_event(event)


## Switches TouchControls to a mode with an input that no action uses, through the same path as a real device.
func _force_input_mode(mode: String) -> void:
	injecting = true
	if mode == "pad":
		_inject_pad_tap(MODE_SWITCH_BUTTON)
	else:
		_inject_key(MODE_SWITCH_KEY, true)
		_inject_key(MODE_SWITCH_KEY, false)
	Input.flush_buffered_events()
	injecting = false


func _event(event_name: String, data: Dictionary) -> void:
	if not _log_active():
		return
	var line := {"tick": Game.tick, "time": _num(Game.sim_time)}
	line.merge(data)
	_line("EVENT %s %s" % [event_name, _json(line)])


func _record(tag: String, data: Dictionary) -> void:
	if _log_active():
		_line(tag + " " + _json(data))


func _line(text: String, sink := Sink.LOG) -> void:
	if _log_file != null:
		_log_file.store_line(text)
		_log_file.flush()
		if sink == Sink.LOG_AND_STDOUT:
			print(text)
	elif _log_stdout or sink != Sink.LOG:
		print(text)


func _error(message: String) -> void:
	var text := "HARNESS ERROR " + message
	printerr(text)
	if _log_file != null:
		_log_file.store_line(text)
		_log_file.flush()


func _warn_no_player() -> void:
	if not _warned_no_player:
		_warned_no_player = true
		_error("no player in the scene (Game.player is not set); player fields are empty")


func _log_active() -> bool:
	return _log_stdout or _log_file != null


func _player_mass() -> float:
	if is_instance_valid(Game.player):
		return _num(float(Game.player.get("mass")))
	return 0.0


func _player_int(method: String) -> int:
	if is_instance_valid(Game.player) and Game.player.has_method(method):
		return int(Game.player.call(method))
	return 0


func _piece_count() -> int:
	return int(_field_call("piece_count", 0))


func _field_call(method: String, fallback: Variant) -> Variant:
	if is_instance_valid(Game.field) and Game.field.has_method(method):
		return Game.field.call(method)
	return fallback


func _ensure_dir(dir: String) -> bool:
	if dir == "" or DirAccess.dir_exists_absolute(dir):
		return true
	return DirAccess.make_dir_recursive_absolute(dir) == OK


## Godot accepts forward slashes on every platform; the Windows build gets backslash paths from the CLI.
func _os_path(path: String) -> String:
	return path.replace("\\", "/")


func _rounded(data: Dictionary) -> Dictionary:
	var out := {}
	for key: Variant in data:
		var value: Variant = data[key]
		out[key] = _num(value) if value is float else value
	return out


func _json(data: Dictionary) -> String:
	return JSON.stringify(data, "", false)


func _num(value: float) -> float:
	return snappedf(value, 0.001)


func _vec(value: Vector2) -> Array:
	return [_num(value.x), _num(value.y)]
