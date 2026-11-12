extends Area2D
## Respawn point. Lights up, refills the slime and tells Game when the slime touches it.

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

const BULB_CENTER := Vector2(0.0, -112.0)
const BULB_RADIUS := 18.0
const BULB_SEGMENTS := 32
const SURFACE_POINTS := 10
const REDRAW_INTERVAL := 1.0 / 30.0
const WARM_UP_TIME := 0.12

var id: StringName
var respawn_point := Vector2.ZERO
var active := false

var _current := false
var _fill: float = Tuning.checkpoint_idle_fill
var _glow := 0.0
var _shock := 1.0
var _near := 0.0
var _time := 0.0
var _redraw_wait := 0.0
## True when a redraw came due while off screen; the checkpoint catches up when it comes back into view.
var _stale := false
var _tween: Tween
var _batch := ShapeBatch.new()
# The post, the glass and the bulb rim never change while the bulb holds still, so they sit in two child canvas items
# (one behind Visual, one in front) that redraw only on a wobble or a shock; Visual itself redraws only the liquid.
var _back: Node2D
var _front: Node2D
var _back_batch := ShapeBatch.new()
var _front_batch := ShapeBatch.new()
var _wobble := 0.0
var _front_shock := 1.0

@onready var _visual: Node2D = $Visual
@onready var _halo: Sprite2D = $Halo
@onready var _burst: CPUParticles2D = $Burst


func _ready() -> void:
	_back = Node2D.new()
	_back.name = &"Back"
	_back.show_behind_parent = true
	_visual.add_child(_back)
	_front = Node2D.new()
	_front.name = &"Front"
	_visual.add_child(_front)
	_visual.draw.connect(_draw_visual)
	_back.draw.connect(_draw_back)
	_front.draw.connect(_draw_front)
	Game.checkpoint_reached.connect(_on_checkpoint_reached)
	Game.player_respawned.connect(_on_player_respawned)
	# The look runs only on screen: off screen nothing processes, and the first frame back in view redraws.
	var notifier := VisibleOnScreenNotifier2D.new()
	notifier.rect = _view_rect().grow(Tuning.tile_size * 2.0)
	notifier.screen_entered.connect(_on_screen_entered)
	notifier.screen_exited.connect(set_process.bind(false))
	add_child(notifier)
	set_process(false)


func _on_screen_entered() -> void:
	_stale = true
	set_process(true)


func setup(cp_id: StringName, at: Vector2) -> void:
	id = cp_id
	respawn_point = at


func warm_up() -> void:
	_halo.visible = true
	_halo.modulate.a = 0.01
	_burst.visible = true
	_burst.restart()
	var tw := create_tween()
	tw.tween_interval(WARM_UP_TIME)
	tw.tween_callback(_end_warm_up)


func _end_warm_up() -> void:
	_burst.visible = false
	if not active:
		_halo.visible = false


func _physics_process(_delta: float) -> void:
	if active:
		return
	for body in get_overlapping_bodies():
		if body == Game.player and body.has_method("can_trigger") and body.call("can_trigger"):
			_activate()
			return


func _process(delta: float) -> void:
	_time += delta
	_shock = minf(_shock + delta / Tuning.checkpoint_shock_time, 1.0)
	var near := 0.0
	if not active and is_instance_valid(Game.player):
		near = 1.0 - clampf(global_position.distance_to(Game.player.global_position) / Tuning.checkpoint_near_distance, 0.0, 1.0)
	var animating := active or near > 0.0 or _near > 0.0 or _shock < 1.0
	_near = near
	if not animating and not _stale:
		return
	var due := false
	if animating:
		_redraw_wait -= delta
		if _redraw_wait <= 0.0:
			_redraw_wait = REDRAW_INTERVAL
			due = true
	if not due and not _stale:
		return
	# Off screen a due redraw is skipped and remembered; the first frame back in view catches up.
	if _on_view():
		_stale = false
		_redraw()
	elif due:
		_stale = true


func _redraw() -> void:
	var wobble := sin(_time * Tuning.checkpoint_near_wobble_speed) * Tuning.checkpoint_near_wobble * _near
	if wobble != _wobble:
		_wobble = wobble
		_back.queue_redraw()
		_front.queue_redraw()
	elif _shock < 1.0 or _front_shock < 1.0:
		_front.queue_redraw()
	_visual.queue_redraw()


func _on_view() -> bool:
	var viewport := get_viewport()
	var view := (viewport.get_canvas_transform().affine_inverse() * viewport.get_visible_rect()).grow(Tuning.tile_size * 2.0)
	var rect := _view_rect()
	return view.intersects(Rect2(global_position + rect.position, rect.size))


## Local bounds of everything the checkpoint draws, the shock ring included.
func _view_rect() -> Rect2:
	var reach := maxf(Tuning.checkpoint_shock_radius.y, BULB_RADIUS) + 12.0
	return Rect2(Vector2(-reach, BULB_CENTER.y - reach), Vector2(reach * 2.0, reach - BULB_CENTER.y + 4.0))


func _activate() -> void:
	active = true
	Game.set_checkpoint(id, respawn_point)
	if Tuning.checkpoint_refill and is_instance_valid(Game.player) and Game.player.has_method("refill"):
		Game.player.call("refill", Tuning.mass_max)
	Sfx.play(&"checkpoint", global_position)
	Juice.shake(Tuning.checkpoint_shake, &"checkpoint")
	Juice.punch(Tuning.checkpoint_punch, &"checkpoint")
	Juice.flash(Tuning.checkpoint_flash_color, Tuning.checkpoint_flash_time)
	_burst.visible = true
	_burst.restart()
	_shock = 0.0
	_spray_toward_player()
	_set_current(true)
	_play_fill()


func _play_fill() -> void:
	if _tween:
		_tween.kill()
	_halo.visible = true
	_halo.modulate.a = 1.0
	_halo.scale = Vector2.ONE * Tuning.checkpoint_halo_scale * Tuning.checkpoint_halo_start
	_visual.scale = Tuning.checkpoint_activate_squash
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(self, "_fill", 1.0, Tuning.checkpoint_fill_time).from(Tuning.checkpoint_idle_fill).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "_glow", 1.0, Tuning.checkpoint_fill_time * 0.5).from(0.0)
	_tween.tween_property(_halo, "scale", Vector2.ONE * Tuning.checkpoint_halo_scale, Tuning.checkpoint_halo_pop_time).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_visual, "scale", Vector2.ONE, Tuning.checkpoint_activate_settle_time).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _spray_toward_player() -> void:
	var field := Game.field
	if not is_instance_valid(field) or not field.has_method("spray"):
		return
	var origin := global_position + BULB_CENTER
	var dir := Vector2.UP
	if is_instance_valid(Game.player):
		dir = (Game.player.global_position - origin).normalized()
		if dir == Vector2.ZERO:
			dir = Vector2.UP
	field.call("spray", origin, dir, Tuning.checkpoint_stream_count, Tuning.checkpoint_stream_speed, Tuning.checkpoint_stream_spread, Tuning.checkpoint_stream_radius)


func _set_current(value: bool) -> void:
	_current = value
	if not active:
		return
	var tw := create_tween()
	tw.tween_property(_halo, "modulate:a", 1.0 if value else Tuning.checkpoint_halo_idle_alpha, Tuning.checkpoint_halo_fade_time)


func _on_checkpoint_reached(reached_id: StringName, _at: Vector2) -> void:
	if reached_id != id and _current:
		_set_current(false)


func _on_player_respawned(at: Vector2) -> void:
	if not active or at.distance_to(respawn_point) > 1.0:
		return
	_shock = 0.0
	_burst.visible = true
	_burst.restart()
	_halo.scale = Vector2.ONE * Tuning.checkpoint_halo_scale * Tuning.checkpoint_respawn_halo
	_visual.scale = Tuning.checkpoint_respawn_squash
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_halo, "scale", Vector2.ONE * Tuning.checkpoint_halo_scale, Tuning.checkpoint_respawn_halo_time).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_visual, "scale", Vector2.ONE, Tuning.checkpoint_respawn_settle_time).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _bulb_transform() -> Transform2D:
	return Transform2D(0.0, Vector2(1.0 + _wobble, 1.0 - _wobble), 0.0, BULB_CENTER)


## Behind the liquid: the stone base, the post, the collar and the glass.
func _draw_back() -> void:
	var batch := _back_batch
	batch.clear()
	batch.feather = 0.0
	batch.rect(Rect2(-18.0, -12.0, 36.0, 12.0), Tuning.checkpoint_stone)
	batch.rect(Rect2(-18.0, -12.0, 36.0, 3.0), Tuning.checkpoint_stone_light)
	batch.rect(Rect2(-18.0, -12.0, 36.0, 12.0), Tuning.ground_outline_color, 2.0)
	batch.rect(Rect2(-5.0, -92.0, 10.0, 80.0), Tuning.plank_color.darkened(0.15))
	batch.rect(Rect2(-5.0, -92.0, 3.0, 80.0), Tuning.plank_color.lightened(0.15))
	batch.rect(Rect2(-5.0, -92.0, 10.0, 80.0), Tuning.ground_outline_color, 2.0)
	batch.rect(Rect2(-11.0, -98.0, 22.0, 8.0), Tuning.checkpoint_metal)
	batch.rect(Rect2(-11.0, -98.0, 22.0, 8.0), Tuning.ground_outline_color, 2.0)
	batch.transform = _bulb_transform()
	batch.feather = ShapeBatch.SOFT_EDGE
	batch.disc(Vector2.ZERO, BULB_RADIUS, Tuning.checkpoint_glass)
	batch.commit(_back.get_canvas_item())


## The goo inside the bulb and its bubbles, the only part that moves while the checkpoint idles.
func _draw_visual() -> void:
	var r := BULB_RADIUS
	var bulb := _bulb_transform()
	_batch.clear()
	_batch.transform = bulb
	_batch.feather = ShapeBatch.SOFT_EDGE
	var level := clampf(_fill, 0.0, 1.1)
	var surface_y := r - 2.0 * r * level
	var goo := Tuning.checkpoint_empty_goo.lerp(Tuning.goo_body_color, _glow)
	var deep := Tuning.checkpoint_empty_goo.darkened(0.3).lerp(Tuning.goo_deep_color, _glow)
	var liquid := _liquid_polygon(r - 2.5, surface_y, 1.6 if active else 0.6)
	if liquid.size() >= 3:
		_batch.feather = 0.0
		_batch.polygon(liquid, deep)
		_batch.transform = bulb * Transform2D(0.0, Vector2(0.8, 0.8), 0.0, Vector2(0.0, 2.0))
		_batch.polygon(liquid, goo)
		_batch.transform = bulb
		_batch.feather = ShapeBatch.SOFT_EDGE
	if active:
		for i in 3:
			var phase := fposmod(_time * 0.7 + i * 0.33, 1.0)
			var bubble := Vector2(sin(i * 2.1 + _time) * 7.0, lerpf(r - 5.0, surface_y + 3.0, phase))
			_batch.disc(bubble, 1.5 + i * 0.5, Color(1.0, 1.0, 1.0, 0.5 * (1.0 - phase)))
	_batch.commit(_visual.get_canvas_item())


## In front of the liquid: the rim, the gloss and the cap of the bulb, then the shock ring.
func _draw_front() -> void:
	var r := BULB_RADIUS
	var batch := _front_batch
	batch.clear()
	batch.transform = _bulb_transform()
	batch.feather = ShapeBatch.SOFT_EDGE
	batch.ring(Vector2.ZERO, r, 3.5, Tuning.ground_outline_color)
	batch.ring(Vector2.ZERO, r - 1.5, 1.5, Tuning.checkpoint_glass_edge)
	batch.arc(Vector2.ZERO, r * 0.65, PI * 1.1, PI * 1.45, 2.5, Color(1.0, 1.0, 1.0, 0.8), false)
	batch.feather = 0.0
	batch.rect(Rect2(-5.0, -r - 7.0, 10.0, 7.0), Tuning.checkpoint_metal)
	batch.rect(Rect2(-5.0, -r - 7.0, 10.0, 7.0), Tuning.ground_outline_color, 2.0)
	batch.transform = Transform2D.IDENTITY
	_front_shock = _shock
	if _shock < 1.0:
		var s := ease(_shock, 0.4)
		var radius := lerpf(Tuning.checkpoint_shock_radius.x, Tuning.checkpoint_shock_radius.y, s)
		batch.ring(BULB_CENTER, radius, lerpf(10.0, 1.5, s), Color(Tuning.checkpoint_shock_color, 1.0 - _shock))
	batch.commit(_front.get_canvas_item())


## The part of a circle below a wavy surface line: the bottom arc, then the surface from left to right.
func _liquid_polygon(radius: float, surface_y: float, wave_amp: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	if surface_y >= radius - 0.5:
		return pts
	var s := maxf(surface_y, -radius + 0.5)
	var a := asin(s / radius)
	for i in BULB_SEGMENTS + 1:
		pts.append(Vector2.from_angle(lerpf(a, PI - a, float(i) / BULB_SEGMENTS)) * radius)
	var half := sqrt(maxf(radius * radius - s * s, 0.0))
	for i in range(1, SURFACE_POINTS):
		var x := lerpf(-half, half, float(i) / SURFACE_POINTS)
		var edge := 1.0 - (x * x) / maxf(half * half, 0.0001)
		pts.append(Vector2(x, s + sin(x * 0.35 + _time * 6.0) * wave_amp * edge))
	return pts
