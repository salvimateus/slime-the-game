extends Node
## Session state, seeded RNG and the gameplay events that the HUD, Harness and effects listen to.

signal player_damaged(amount: float, source: StringName, at: Vector2)
signal goo_absorbed(amount: float, at: Vector2)
signal goo_color_absorbed(amount: float, color: Color, body_color: Color)
signal goo_lost(amount: float, reason: StringName)
signal goo_gained(amount: float, reason: StringName)
signal mass_changed(mass: float, ratio: float)
signal player_died(source: StringName, at: Vector2)
signal respawn_requested
signal player_respawned(at: Vector2)
signal checkpoint_reached(id: StringName, at: Vector2)
signal goal_reached(summary: Dictionary)
signal level_started
signal prop_absorbed(kind: StringName, at: Vector2, carried: int)
signal prop_dropped(kind: StringName, at: Vector2, reason: StringName)
signal prop_shot(kind: StringName, at: Vector2, dir: Vector2, carried: int, force: float, predicted: Variant)
signal prop_bounced(kind: StringName, bounce: int, speed: float, at: Vector2, surface: StringName, hot: bool, dist: float)
signal prop_shattered(material: StringName, size: int, pieces: int, trap: StringName, at: Vector2, evicted: int)
signal target_hit(target: StringName, hp: int, at: Vector2)
signal enemy_died(enemy: StringName, at: Vector2)
signal barrier_broken(at: Vector2)
## A player move started, changed phase or ended (double_jump, skid, dodge, roll, wall_grab, crouch, ...).
signal player_moved(move: StringName, data: Dictionary)
## A temperature event of the slime: temp_state, fire_start, fire_end, flow_start, flow_end, ember_hit, cube_smash,
## cube_immune, ice_lock, puddle_lock. data holds the details of each one.
signal temperature_event(event: StringName, data: Dictionary)

const DEFAULT_SEED := 20261111
const INPUT_DEADZONE := 0.25
## Frames the mixer gets to release stopped playbacks before the quit, so no stream leaks at shutdown.
const QUIT_DRAIN_FRAMES := 6

var rng := RandomNumberGenerator.new()
var seed_value := DEFAULT_SEED
var tick := 0
## Same as tick until the goal, then keeps counting, so scripted input still reaches the goal screen.
var input_tick := 0
var _level_loaded := false
var sim_time := 0.0
var level_running := false
var respawn_point := Vector2.ZERO
var checkpoint_id: StringName = &"start"
var kill_y := 1.0e9
var deaths := 0
var goo_lost_total := 0.0
var goo_gained_total := 0.0
var goo_recovered_total := 0.0
var player: Node2D
var field: Node2D
## Container and factory of the rocks and crystals (scripts/props/prop_layer.gd).
var props: Node2D
var _quitting := false
## Analog trigger actions read with a press and a lower release threshold, so a half-pressed trigger does not flicker.
const TRIGGER_ACTIONS: Array[StringName] = [&"aim", &"fire"]
var _trigger_held := {}
var _trigger_pressed := {}


func _ready() -> void:
	_register_input()
	reseed(DEFAULT_SEED)


func _physics_process(delta: float) -> void:
	_update_triggers()
	if _level_loaded:
		input_tick += 1
	if level_running:
		tick += 1
		sim_time += delta


func trigger_held(action: StringName) -> bool:
	return bool(_trigger_held.get(action, false))


## True only on the physics tick the trigger crossed the press threshold.
func trigger_just_pressed(action: StringName) -> bool:
	return bool(_trigger_pressed.get(action, false))


func _update_triggers() -> void:
	for action: StringName in TRIGGER_ACTIONS:
		var strength := Input.get_action_raw_strength(action)
		var was: bool = _trigger_held.get(action, false)
		var held := strength >= Tuning.trigger_press or (was and strength > Tuning.trigger_release)
		_trigger_pressed[action] = held and not was
		_trigger_held[action] = held


func reseed(value: int) -> void:
	seed_value = value
	rng.seed = value


func reset_session() -> void:
	reseed(seed_value)
	tick = 0
	input_tick = 0
	_level_loaded = false
	sim_time = 0.0
	level_running = false
	checkpoint_id = &"start"
	deaths = 0
	goo_lost_total = 0.0
	goo_gained_total = 0.0
	goo_recovered_total = 0.0
	player = null
	field = null
	props = null


func start_level(spawn: Vector2, bounds: Rect2) -> void:
	respawn_point = spawn
	kill_y = bounds.end.y + Tuning.tile_size * 4.0
	level_running = true
	_level_loaded = true
	level_started.emit()


func set_checkpoint(id: StringName, at: Vector2) -> bool:
	if id == checkpoint_id:
		return false
	checkpoint_id = id
	respawn_point = at
	checkpoint_reached.emit(id, at)
	return true


func report_damage(amount: float, source: StringName, at: Vector2) -> void:
	player_damaged.emit(amount, source, at)


func report_absorb(amount: float, at: Vector2) -> void:
	if amount <= 0.0:
		return
	goo_recovered_total += amount
	goo_absorbed.emit(amount, at)


## The slime slurped `amount` of goo of another colour; body_color is its colour after the mix.
func report_color_absorb(amount: float, color: Color, body_color: Color) -> void:
	goo_color_absorbed.emit(amount, color, body_color)


func report_lost(amount: float, reason: StringName, emit_event := true) -> void:
	if amount <= 0.0:
		return
	goo_lost_total += amount
	if emit_event:
		goo_lost.emit(amount, reason)


func report_gained(amount: float, reason: StringName) -> void:
	if amount <= 0.0:
		return
	goo_gained_total += amount
	goo_gained.emit(amount, reason)


func report_mass(mass: float) -> void:
	mass_changed.emit(mass, mass / maxf(Tuning.mass_max, 0.0001))


func report_death(source: StringName, at: Vector2) -> void:
	deaths += 1
	player_died.emit(source, at)


func request_respawn() -> void:
	respawn_requested.emit()


func report_respawn(at: Vector2) -> void:
	player_respawned.emit(at)


func report_goal() -> void:
	level_running = false
	goal_reached.emit(summary())


func report_prop_absorbed(kind: StringName, at: Vector2, carried: int) -> void:
	prop_absorbed.emit(kind, at, carried)


func report_prop_dropped(kind: StringName, at: Vector2, reason: StringName) -> void:
	prop_dropped.emit(kind, at, reason)


## predicted is the first impact the aim preview computed for this shot, or null.
func report_prop_shot(kind: StringName, at: Vector2, dir: Vector2, carried: int, force: float, predicted: Variant) -> void:
	prop_shot.emit(kind, at, dir, carried, force, predicted)


## dist is the straight distance from where the prop was thrown or dropped.
func report_prop_bounce(kind: StringName, bounce: int, speed: float, at: Vector2, surface: StringName, hot: bool, dist: float) -> void:
	prop_bounced.emit(kind, bounce, speed, at, surface, hot, dist)


## size is the level of the prop that broke (0 is a full prop); evicted counts the pieces removed to make room.
func report_prop_shatter(material: StringName, size: int, pieces: int, trap: StringName, at: Vector2, evicted: int) -> void:
	prop_shattered.emit(material, size, pieces, trap, at, evicted)


func report_target_hit(target: StringName, hp: int, at: Vector2) -> void:
	target_hit.emit(target, hp, at)


func report_enemy_death(enemy: StringName, at: Vector2) -> void:
	enemy_died.emit(enemy, at)


func report_barrier_broken(at: Vector2) -> void:
	barrier_broken.emit(at)


func report_temperature(event: StringName, data: Dictionary) -> void:
	temperature_event.emit(event, data)


func report_move(move: StringName, data: Dictionary) -> void:
	player_moved.emit(move, data)


func summary() -> Dictionary:
	return {
		"time": sim_time,
		"deaths": deaths,
		"lost": goo_lost_total,
		"recovered": goo_recovered_total,
	}


## Conservation check: 0.0 means no goo appeared or vanished without a report.
func goo_balance() -> float:
	var player_mass := 0.0
	if is_instance_valid(player):
		player_mass = float(player.get("mass"))
	var pieces := 0.0
	if is_instance_valid(field) and field.has_method(&"total_piece_mass"):
		pieces = float(field.call(&"total_piece_mass"))
	return player_mass + pieces + goo_lost_total - goo_gained_total - Tuning.mass_start


func _register_input() -> void:
	_bind(&"move_left", [KEY_A, KEY_LEFT], [JOY_BUTTON_DPAD_LEFT], JOY_AXIS_LEFT_X, -1.0)
	_bind(&"move_right", [KEY_D, KEY_RIGHT], [JOY_BUTTON_DPAD_RIGHT], JOY_AXIS_LEFT_X, 1.0)
	_bind(&"jump", [KEY_SPACE, KEY_W, KEY_UP, KEY_Z], [JOY_BUTTON_A])
	_bind(&"shoot", [KEY_J, KEY_X], [JOY_BUTTON_X])
	_bind(&"aim", [], [], JOY_AXIS_TRIGGER_LEFT, 1.0, [MOUSE_BUTTON_RIGHT], 0.0)
	_bind(&"fire", [], [], JOY_AXIS_TRIGGER_RIGHT, 1.0, [MOUSE_BUTTON_LEFT], 0.0)
	_bind(&"run", [KEY_SHIFT], [JOY_BUTTON_RIGHT_SHOULDER])
	_bind(&"dodge", [KEY_K, KEY_C], [JOY_BUTTON_B])
	_bind(&"crouch", [KEY_S, KEY_DOWN], [JOY_BUTTON_DPAD_DOWN], JOY_AXIS_LEFT_Y, 1.0)
	_bind(&"aim_left", [], [], JOY_AXIS_RIGHT_X, -1.0)
	_bind(&"aim_right", [], [], JOY_AXIS_RIGHT_X, 1.0)
	_bind(&"aim_up", [], [], JOY_AXIS_RIGHT_Y, -1.0)
	_bind(&"aim_down", [], [], JOY_AXIS_RIGHT_Y, 1.0)
	_bind(&"restart", [KEY_R], [JOY_BUTTON_BACK])
	_bind(&"toggle_fullscreen", [KEY_F11], [])
	_bind(&"quit", [KEY_ESCAPE], [])
	_bind(&"toggle_perf", [KEY_F3], [])


## Adds the action once; an action that already exists keeps its own events.
## Trigger actions pass deadzone 0, so Game reads their raw strength with its own thresholds.
func _bind(action: StringName, keys: Array, buttons: Array, axis := -1, axis_dir := 0.0, mouse_buttons: Array = [], deadzone := INPUT_DEADZONE) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action, deadzone)
	for mouse_button: int in mouse_buttons:
		var mouse_event := InputEventMouseButton.new()
		mouse_event.button_index = mouse_button as MouseButton
		InputMap.action_add_event(action, mouse_event)
	for key: int in keys:
		var key_event := InputEventKey.new()
		key_event.physical_keycode = key as Key
		InputMap.action_add_event(action, key_event)
	for button: int in buttons:
		var button_event := InputEventJoypadButton.new()
		button_event.button_index = button as JoyButton
		InputMap.action_add_event(action, button_event)
	if axis >= 0:
		var motion_event := InputEventJoypadMotion.new()
		motion_event.axis = axis as JoyAxis
		motion_event.axis_value = axis_dir
		InputMap.action_add_event(action, motion_event)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_fullscreen"):
		var full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if full else DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif event.is_action_pressed(&"quit"):
		quit_game()


## The Android back button quits; project setting quit_on_go_back is off so the sounds stop first.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		quit_game()


## Stops every sound and waits for the mixer with the tree alive, then quits.
func quit_game() -> void:
	if _quitting:
		return
	_quitting = true
	get_tree().paused = true
	Sfx.stop_all()
	for i in QUIT_DRAIN_FRAMES:
		await get_tree().process_frame
	get_tree().quit()
