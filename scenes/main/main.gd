extends Node2D
## Boots the level: builds it, wires the slime to the goo field, warms every effect up and runs respawns.

const Level01 := preload("res://scripts/level/level_01.gd")

const WARM_UP_FRAMES := 4
const WARM_UP_PROP_SPEED := 600.0
const COVER_FADE_TIME := 0.2

@onready var level: Node2D = $Level
@onready var field: Node2D = $GooField
@onready var props: Node2D = $Props
@onready var sparks: Node2D = $Sparks
@onready var aim_preview: Node2D = $AimPreview
@onready var body_visual: Node2D = $GooField/SlimeBody
@onready var player: CharacterBody2D = $Player
@onready var camera: Camera2D = $GameCamera
@onready var hud: CanvasLayer = $HUD
@onready var screen_fx: CanvasLayer = $ScreenFX

var _iris_closing := false
var _reloading := false


func _ready() -> void:
	Game.reset_session()
	Game.player = player
	Game.field = field
	Game.props = props
	level.call("build", Level01)
	for spawn_data: Dictionary in level.get("prop_spawns"):
		props.call("place", spawn_data, spawn_data.home)
	player.set("body_visual", body_visual)
	player.set("field", field)
	player.get_node("Face").set("body", body_visual)
	player.get_node("Cargo").set("body", body_visual)
	player.set("aim_preview", aim_preview)
	aim_preview.set("anchor", player)
	camera.set("target", player)
	var bounds: Rect2 = level.get("bounds")
	camera.call("set_bounds", bounds)
	hud.visible = not Harness.hide_hud
	Game.respawn_requested.connect(_on_respawn_requested)
	var spawn: Vector2 = level.get("start_position")
	if Harness.spawn_override != "":
		spawn = Harness.spawn_position(level)
	var start_mass: float = Tuning.mass_start if Harness.mass_override < 0.0 else minf(Harness.mass_override, Tuning.mass_max)
	player.set_physics_process(false)
	player.global_position = spawn
	camera.global_position = spawn
	await _warm_up(spawn)
	player.set_physics_process(true)
	Game.start_level(spawn, bounds)
	if start_mass < Tuning.mass_start:
		Game.report_lost(Tuning.mass_start - start_mass, &"override", false)
	elif start_mass > Tuning.mass_start:
		Game.report_gained(start_mass - Tuning.mass_start, &"override")
	player.call("spawn_at", spawn, start_mass)
	camera.call("snap")
	screen_fx.call("hide_cover", COVER_FADE_TIME)
	screen_fx.call("iris_open", _screen_pos(), Tuning.iris_open_time)


## Renders the goo surface, droplets, props, sparks, screen layers, HUD, touch controls, performance panel and level effects
## behind the opaque cover, so their first real use does not hitch.
func _warm_up(at: Vector2) -> void:
	field.call("spawn_piece", at, 6.0, Vector2(0.0, -200.0), true)
	var warm_props: Array[Node2D] = []
	for kind: StringName in [&"rock", &"crystal"]:
		warm_props.append(props.call("launch", {"kind": kind, "seed": 0, "home": at}, at, Vector2.UP, 0.0, Vector2(0.0, -WARM_UP_PROP_SPEED)))
	sparks.call("sparks", at, Vector2.UP, 8, Vector2(100.0, 300.0), 90.0, Tuning.bounce_spark_color)
	sparks.call("debris", at, Vector2.UP, 4, Vector2(100.0, 300.0), 90.0, Vector2(4.0, 8.0), PackedColorArray([Tuning.barrier_mid]), false)
	sparks.call("debris", at, Vector2.UP, 4, Vector2(100.0, 300.0), 90.0, Vector2(3.0, 6.0), PackedColorArray([Tuning.mite_shell]), true)
	sparks.call("ring", at, 60.0, Tuning.barrier_light, 0.3)
	sparks.call("glint", at, 10.0, Color.WHITE, 0.3)
	player.get_node("Cargo").call("warm_up")
	player.call("warm_up_temperature")
	props.call("warm_up_embers", at)
	aim_preview.call("show_aim", &"rock", at, Vector2(1.0, -1.0).normalized(), 0.0, Vector2(600.0, -600.0), true)
	field.call("spray", at, Vector2.UP, 12, Vector2(100.0, 300.0), 90.0, Vector2(2.0, 5.0))
	field.call("burst", at, 8, Vector2(100.0, 300.0), Vector2(2.0, 5.0))
	screen_fx.call("warm_up")
	hud.call("warm_up")
	TouchControls.warm_up()
	PerfPanel.warm_up()
	for node: Node in level.get_children():
		if node.has_method("warm_up"):
			node.call("warm_up")
	for i in WARM_UP_FRAMES:
		await get_tree().process_frame
		# The spawn sound waits for the sound bake; a wait here stays in a covered frame that ends before LEVEL_START.
		if i == WARM_UP_FRAMES - 2:
			Sfx.finish_bake()
	field.call("clear_pieces", false)
	field.call("clear_droplets")
	for prop: Node2D in warm_props:
		prop.queue_free()
	sparks.call("clear")
	aim_preview.call("hide_aim")
	Juice.reset()


func _physics_process(_delta: float) -> void:
	if _reloading or player.call("state_name") != "GOAL":
		return
	var intent: Dictionary = player.get("intent")
	if Input.is_action_just_pressed(&"jump") or Input.is_action_just_pressed(&"restart") or bool(intent.get("restart", false)):
		_reload()


## Global state (time scale, pause, muffle) outlives the scene, so it goes back to normal before the reload.
func _reload() -> void:
	_reloading = true
	Juice.reset()
	get_tree().paused = false
	get_tree().reload_current_scene()


func _on_respawn_requested() -> void:
	if _iris_closing or _reloading:
		return
	_iris_closing = true
	await screen_fx.call("iris_close", _screen_pos(), Tuning.iris_close_time)
	_iris_closing = false
	field.call("clear_pieces", true)
	field.call("clear_droplets")
	Juice.reset()
	player.call("spawn_at", Game.respawn_point, Tuning.mass_start)
	camera.call("snap")
	Game.report_respawn(Game.respawn_point)
	screen_fx.call("iris_open", _screen_pos(), Tuning.iris_open_time)


func _screen_pos() -> Vector2:
	return get_viewport().get_canvas_transform() * Vector2(player.call("visual_position"))
