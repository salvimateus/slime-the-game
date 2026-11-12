extends Area2D
## Goal pond. Ends the level with a celebration when the slime reaches it.

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

const POND_CENTER := Vector2(-52.0, 2.0)
const POND_RADII := Vector2(74.0, 15.0)
const POND_SEGMENTS := 40
const FLAG_BASE := Vector2(24.0, 0.0)
const FLAG_HEIGHT := 118.0
const FLAG_SIZE := Vector2(46.0, 28.0)
const FLAG_SEGMENTS := 8
const REDRAW_INTERVAL := 1.0 / 30.0
const WARM_UP_TIME := 0.12
## Local bounds of everything _draw_pond draws (widest ripple, flag tip), for the off-screen check.
const DRAW_BOUNDS := Rect2(-176.0, -136.0, 216.0, 176.0)

var reached := false

var _time := 0.0
var _redraw_wait := 0.0
## True when a redraw came due while off screen; see _process().
var _stale := false
var _near := 0.0
var _surge := 0.0
var _ripple: float = Tuning.goal_ripple_time
var _batch := ShapeBatch.new()

@onready var _pond: Node2D = $Pond
@onready var _sparkles: CPUParticles2D = $Sparkles
@onready var _burst: CPUParticles2D = $Burst


func _ready() -> void:
	_pond.draw.connect(_draw_pond)
	# The look runs only on screen: off screen nothing processes, and the first frame back in view redraws.
	var notifier := VisibleOnScreenNotifier2D.new()
	notifier.rect = DRAW_BOUNDS.grow(Tuning.tile_size * 2.0)
	notifier.screen_entered.connect(_on_screen_entered)
	notifier.screen_exited.connect(set_process.bind(false))
	add_child(notifier)
	set_process(false)


func _on_screen_entered() -> void:
	_stale = true
	set_process(true)


func warm_up() -> void:
	_sparkles.restart()
	_burst.visible = true
	_burst.restart()
	var tw := create_tween()
	tw.tween_interval(WARM_UP_TIME)
	tw.tween_callback(_end_warm_up)


func _end_warm_up() -> void:
	if not reached:
		_burst.visible = false


func _physics_process(_delta: float) -> void:
	if reached:
		return
	for body in get_overlapping_bodies():
		if body == Game.player and body.has_method("can_trigger") and body.call("can_trigger"):
			_reach(body as Node2D)
			return


func _process(delta: float) -> void:
	_time += delta
	_surge = maxf(_surge - delta * Tuning.goal_surge_decay, 0.0)
	_ripple = minf(_ripple + delta, Tuning.goal_ripple_time)
	if is_instance_valid(Game.player):
		_near = 1.0 - clampf(global_position.distance_to(Game.player.global_position) / Tuning.goal_near_distance, 0.0, 1.0)
	_redraw_wait -= delta
	var due := _redraw_wait <= 0.0
	if due:
		_redraw_wait = REDRAW_INTERVAL
	if not due and not _stale:
		return
	# Off screen a due redraw is skipped and remembered; the first frame back in view catches up.
	if _on_view():
		_stale = false
		_pond.queue_redraw()
	elif due:
		_stale = true


func _on_view() -> bool:
	var viewport := get_viewport()
	var view := (viewport.get_canvas_transform().affine_inverse() * viewport.get_visible_rect()).grow(Tuning.tile_size * 2.0)
	return view.intersects(Rect2(global_position + DRAW_BOUNDS.position, DRAW_BOUNDS.size))


func _reach(player: Node2D) -> void:
	reached = true
	var center := global_position + POND_CENTER
	if player.has_method("enter_goal"):
		player.call("enter_goal", center)
	Juice.celebrate()
	Sfx.play(&"goal", center)
	_burst.visible = true
	_burst.restart()
	_sparkles.speed_scale = Tuning.goal_sparkle_boost
	create_tween().tween_property(_sparkles, "speed_scale", 1.0, Tuning.goal_sparkle_settle_time)
	_surge = 1.0
	_ripple = 0.0
	var field := Game.field
	if is_instance_valid(field) and field.has_method("burst"):
		field.call("burst", center + Vector2(0.0, -10.0), Tuning.goal_confetti_count, Tuning.goal_confetti_speed, Tuning.goal_confetti_radius)


func _ellipse(center: Vector2, radii: Vector2, lift: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in POND_SEGMENTS:
		var a := TAU * i / POND_SEGMENTS
		var p := Vector2(cos(a) * radii.x, sin(a) * radii.y)
		if p.y < 0.0:
			p.y -= lift * absf(sin(a))
		pts.append(center + p)
	return pts


func _draw_pond() -> void:
	var glow := 0.5 + 0.5 * _near
	_batch.clear()
	_batch.feather = 0.0
	_batch.polygon(_ellipse(POND_CENTER + Vector2(0.0, 2.0), POND_RADII + Vector2(10.0, 7.0), 0.0), Tuning.goal_basin)
	_batch.polygon(_ellipse(POND_CENTER + Vector2(0.0, -1.0), POND_RADII + Vector2(7.0, 4.0), 0.0), Tuning.goal_basin_light)
	var lift := _surge * Tuning.goal_surge_lift * (0.6 + 0.4 * sin(_time * 18.0))
	_batch.polygon(_ellipse(POND_CENTER, POND_RADII, lift), Tuning.goal_gold_deep)
	_batch.polygon(_ellipse(POND_CENTER + Vector2(0.0, -2.0), POND_RADII * Vector2(0.86, 0.66), lift * 0.8), Tuning.goal_gold.lerp(Tuning.goal_gold_light, 0.25 * glow))
	_batch.feather = ShapeBatch.SOFT_EDGE
	for i in 3:
		var phase := fposmod(_time * 0.35 + i * 0.37, 1.0)
		var x := lerpf(-POND_RADII.x * 0.7, POND_RADII.x * 0.7, phase)
		var y := sin(_time * 2.0 + i) * POND_RADII.y * 0.3 - 2.0
		var alpha := sin(phase * PI) * (0.55 + 0.35 * glow)
		_batch.stroke(PackedVector2Array([POND_CENTER + Vector2(x - 9.0, y), POND_CENTER + Vector2(x + 9.0, y)]), 2.5, Color(Tuning.goal_gold_light, alpha), false, false)
	if _ripple < Tuning.goal_ripple_time:
		for i in Tuning.goal_ripple_count:
			var s := clampf((_ripple - i * 0.18) / (Tuning.goal_ripple_time - 0.36), 0.0, 1.0)
			if s <= 0.0 or s >= 1.0:
				continue
			var radii := POND_RADII * lerpf(0.3, 1.5, s)
			_batch.stroke(_ellipse(POND_CENTER, radii, 0.0), lerpf(5.0, 1.0, s), Color(Tuning.goal_gold_light, 1.0 - s), true)
	_draw_flag(glow)
	_batch.commit(_pond.get_canvas_item())


func _draw_flag(glow: float) -> void:
	var top := FLAG_BASE + Vector2(0.0, -FLAG_HEIGHT)
	_batch.feather = 0.0
	_batch.rect(Rect2(FLAG_BASE.x - 9.0, -8.0, 18.0, 8.0), Tuning.goal_basin)
	_batch.stroke(PackedVector2Array([FLAG_BASE, top]), 7.0, Tuning.ground_outline_color, false, false)
	_batch.stroke(PackedVector2Array([FLAG_BASE, top]), 3.5, Tuning.goal_pole, false, false)
	_batch.feather = ShapeBatch.SOFT_EDGE
	_batch.disc(top, 5.5, Tuning.goal_gold.lerp(Tuning.goal_gold_light, glow * 0.6))
	var speed := Tuning.goal_flag_wave_speed + Tuning.goal_flag_surge_speed * _surge
	var upper := PackedVector2Array()
	var lower := PackedVector2Array()
	for i in FLAG_SEGMENTS + 1:
		var u := float(i) / FLAG_SEGMENTS
		var wave := sin(u * 5.0 - _time * speed) * 5.0 * u
		var narrow := lerpf(1.0, 0.55, u)
		upper.append(top + Vector2(-u * FLAG_SIZE.x, 6.0 + wave))
		lower.append(top + Vector2(-u * FLAG_SIZE.x, 6.0 + FLAG_SIZE.y * narrow + wave))
	var outline := upper.duplicate()
	lower.reverse()
	outline.append_array(lower)
	# The waving flag is not star-shaped, so it fills as one quad per segment, striped with the shade colour.
	_batch.feather = 0.0
	for i in FLAG_SEGMENTS:
		var quad := PackedVector2Array([upper[i], upper[i + 1], lower[FLAG_SEGMENTS - i - 1], lower[FLAG_SEGMENTS - i]])
		_batch.polygon(quad, Tuning.goal_flag_shade if i % 2 == 1 else Tuning.goal_flag_color)
	_batch.feather = ShapeBatch.SOFT_EDGE
	_batch.stroke(outline, 2.0, Tuning.ground_outline_color, true)
