extends "res://scripts/level/hazard.gd"
## Patrolling saw blade. Hurts the player and shreds loose goo pieces.

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

const TEETH := 12
const TOOTH_DEPTH := 9.0
const DISC_SEGMENTS := 40
const RING_SEGMENTS := 16
const REDRAW_INTERVAL := 1.0 / 30.0
const TRACK_DEPTH := 6.0
const WARM_UP_TIME := 0.12

var _a := Vector2.ZERO
var _b := Vector2.ZERO
var _t := 0.0
var _dir := 1.0
var _pause := 0.0
var _spin := 0.0
var _bite := 0.0
var _goo_coat := 0.0
var _redraw_wait := 0.0
var _configured := false
var _blade_batch := ShapeBatch.new()
var _track_batch := ShapeBatch.new()

@onready var _visual: Node2D = $Visual
@onready var _track: Node2D = $Track
@onready var _sparks: CPUParticles2D = $Sparks
@onready var _hit_sparks: CPUParticles2D = $HitSparks
@onready var _audio: AudioStreamPlayer2D = $Audio


func _ready() -> void:
	super()
	_visual.draw.connect(_draw_blade)
	_track.draw.connect(_draw_track)


func setup(a: Vector2, b: Vector2, start: Vector2) -> void:
	_a = Vector2(minf(a.x, b.x), a.y)
	_b = Vector2(maxf(a.x, b.x), b.y)
	if _b.x - _a.x < 1.0:
		_t = 0.0
	else:
		_t = clampf(inverse_lerp(_a.x, _b.x, start.x), 0.0, 1.0)
	global_position = _a.lerp(_b, smoothstep(0.0, 1.0, _t))
	reset_physics_interpolation()
	loss = Tuning.saw_loss
	source = &"saw"
	var shape := CircleShape2D.new()
	shape.radius = Tuning.saw_hit_radius
	$CollisionShape2D.shape = shape
	_track.global_position = _a
	_track.reset_physics_interpolation()
	_track.queue_redraw()
	_visual.queue_redraw()
	_update_sparks_direction()
	var loop := Sfx.stream(&"saw_loop")
	if loop:
		_audio.stream = loop
		_audio.play()
	_configured = true


# A looping voice that is still in the audio server at shutdown leaks its stream, so release both on exit.
func _exit_tree() -> void:
	_audio.stop()
	_audio.stream = null


func _physics_process(delta: float) -> void:
	if not _configured:
		return
	var moving := _pause <= 0.0 and _b.x - _a.x >= 1.0
	if _pause > 0.0:
		_pause -= delta
	elif moving:
		_t += _dir * Tuning.saw_speed * delta / maxf(_a.distance_to(_b), 1.0)
		if _t >= 1.0 or _t <= 0.0:
			_t = clampf(_t, 0.0, 1.0)
			_dir = -_dir
			_pause = Tuning.saw_end_pause
			_update_sparks_direction()
			_visual.queue_redraw()
	global_position = _a.lerp(_b, smoothstep(0.0, 1.0, _t))
	_bite = maxf(_bite - delta * Tuning.saw_bite_decay, 0.0)
	_spin += delta * (Tuning.saw_spin_speed + Tuning.saw_bite_spin_boost * _bite) * _dir
	_visual.rotation = _spin
	_visual.scale = Vector2.ONE * (1.0 + Tuning.saw_bite_scale * _bite * _bite)
	_visual.position = Vector2(sin(_spin * 7.0), cos(_spin * 5.0)) * Tuning.saw_bite_jitter * _bite
	if _sparks.emitting != moving:
		_sparks.emitting = moving
	if _audio.playing:
		_audio.pitch_scale = 1.0 + Tuning.saw_bite_pitch * _bite
	for body in get_overlapping_bodies():
		if body.has_method("shred"):
			body.call("shred")
			if body.is_queued_for_deletion():
				_bite = maxf(_bite, Tuning.saw_shred_bite)
				_goo_coat = maxf(_goo_coat, Tuning.saw_shred_coat)
				_start_coat_redraw()


func _process(delta: float) -> void:
	_goo_coat = maxf(_goo_coat - delta * Tuning.saw_goo_coat_decay, 0.0)
	_redraw_wait -= delta
	if _redraw_wait <= 0.0 or _goo_coat <= 0.0:
		_redraw_wait = REDRAW_INTERVAL
		_visual.queue_redraw()
	if _goo_coat <= 0.0:
		set_process(false)


func warm_up() -> void:
	_hit_sparks.visible = true
	_hit_sparks.restart()
	var tw := create_tween()
	tw.tween_interval(WARM_UP_TIME)
	tw.tween_callback(_hit_sparks.hide)


func deflects_props() -> bool:
	return true


## The whole patrol of the blade: the floor under any point of the track is never a safe place for a prop.
func reach_rect() -> Rect2:
	var r := Tuning.saw_radius
	return Rect2(Vector2(_a.x - r, minf(_a.y, _b.y) - r), Vector2(_b.x - _a.x + r * 2.0, absf(_b.y - _a.y) + r * 2.0))


## Props glance off the blade along the radius with a small bite. The big spark spray and the shred sound belong only to
## a break (on_prop_shattered), so a prop that just bounces never reads as broken.
func deflect(at: Vector2, velocity: Vector2) -> Variant:
	var normal := (at - global_position).normalized()
	if normal == Vector2.ZERO:
		normal = Vector2.UP
	var out := velocity.bounce(normal) if velocity.dot(normal) < 0.0 else velocity
	out += normal.orthogonal() * -_dir * Tuning.deflect_min_speed * 0.5
	if out.length() < Tuning.deflect_min_speed:
		out = out.normalized() * Tuning.deflect_min_speed if out != Vector2.ZERO else normal * Tuning.deflect_min_speed
	_bite = maxf(_bite, Tuning.saw_deflect_bite)
	return out


## The blade chews the prop: a full bite with a speed burst and a second, bigger spray of sparks.
func on_prop_shattered(at: Vector2, strength: float) -> void:
	super(at, strength)
	_bite = maxf(_bite, lerpf(Tuning.saw_shred_bite, 1.0, strength))
	var normal := (at - global_position).normalized()
	if normal == Vector2.ZERO:
		normal = Vector2.UP
	_hit_sparks.visible = true
	_hit_sparks.global_position = global_position + normal * Tuning.saw_hit_radius
	_hit_sparks.restart()
	Sfx.play(&"shred", at, Tuning.saw_hit_pitch * 1.4, Tuning.saw_hit_volume_db - 4.0)
	if is_instance_valid(Juice.sparks):
		var tangent := normal.orthogonal() * -_dir
		var count := int(lerpf(Tuning.saw_shatter_spark_count.x, Tuning.saw_shatter_spark_count.y, strength))
		Juice.sparks.call(&"sparks", global_position + normal * Tuning.saw_radius, (tangent + normal * 0.4).normalized(), count, Tuning.saw_shatter_spark_speed, Tuning.saw_shatter_spark_spread, Tuning.saw_shatter_spark_color, Tuning.saw_shatter_spark_size)


func _on_hit_landed(_amount: float, _at: Vector2) -> void:
	_bite = 1.0
	_goo_coat = 1.0
	_hit_sparks.visible = true
	_hit_sparks.position = Vector2.ZERO
	_hit_sparks.restart()
	Sfx.play(&"shred", global_position, Tuning.saw_hit_pitch, Tuning.saw_hit_volume_db)
	_start_coat_redraw()


func _start_coat_redraw() -> void:
	_redraw_wait = 0.0
	set_process(true)


func _update_sparks_direction() -> void:
	_sparks.direction = Vector2(-_dir, -1.1)


func _draw_track() -> void:
	var length := _b.x - _a.x
	var floor_y := Tuning.tile_size * 0.5
	var rect := Rect2(0.0, floor_y - TRACK_DEPTH * 0.5, length, TRACK_DEPTH)
	_track_batch.clear()
	_track_batch.feather = 0.0
	_track_batch.rect(rect.grow(2.0), Tuning.saw_track_edge)
	_track_batch.rect(rect, Tuning.saw_track_color)
	_track_batch.feather = ShapeBatch.SOFT_EDGE
	for x: float in [0.0, length]:
		_track_batch.disc(Vector2(x, floor_y), 7.0, Tuning.saw_track_edge)
		_track_batch.disc(Vector2(x, floor_y), 4.0, Tuning.saw_ring_orange)
	_track_batch.commit(_track.get_canvas_item())


func _draw_blade() -> void:
	var outer := Tuning.saw_radius
	var teeth := _teeth_polygon(outer)
	var batch := _blade_batch
	batch.clear()
	batch.feather = 0.0
	batch.transform = Transform2D(-Tuning.saw_ghost_angle * _dir, Vector2.ZERO)
	batch.polygon(teeth, Color(Tuning.saw_steel_mid, Tuning.saw_ghost_alpha))
	batch.transform = Transform2D.IDENTITY
	batch.polygon(teeth, Tuning.saw_steel_dark)
	batch.polygon(_disc(outer - TOOTH_DEPTH - 1.0), Color.WHITE, _disc_colors())
	batch.feather = ShapeBatch.SOFT_EDGE
	batch.stroke(teeth, 2.0, Tuning.ground_outline_color, true)
	_draw_ring(outer * 0.5, outer * 0.64)
	batch.disc(Vector2.ZERO, outer * 0.24, Tuning.saw_hub_color)
	batch.disc(Vector2(-2.5, -2.5), outer * 0.08, Tuning.saw_steel_light)
	if _goo_coat > 0.0:
		_draw_goo_coat(outer)
	batch.commit(_visual.get_canvas_item())


func _teeth_polygon(outer: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var inner := outer - TOOTH_DEPTH
	var step := TAU / TEETH
	for i in TEETH:
		var a := i * step
		pts.append(Vector2.from_angle(a) * inner)
		pts.append(Vector2.from_angle(a + step * 0.72) * outer)
		pts.append(Vector2.from_angle(a + step * 0.86) * (outer - 2.0))
	return pts


func _disc(radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in DISC_SEGMENTS:
		pts.append(Vector2.from_angle(TAU * i / DISC_SEGMENTS) * radius)
	return pts


# A light band and a dark band around the disc read as brushed steel while the blade spins.
func _disc_colors() -> PackedColorArray:
	var colors := PackedColorArray()
	for i in DISC_SEGMENTS:
		var a := TAU * i / DISC_SEGMENTS
		var sheen := 0.5 + 0.5 * cos(a * 2.0 + 0.8)
		colors.append(Tuning.saw_steel_mid.lerp(Tuning.saw_steel_light, sheen))
	return colors


func _draw_ring(inner: float, outer: float) -> void:
	_blade_batch.disc(Vector2.ZERO, outer + 1.5, Tuning.saw_ring_dark)
	_blade_batch.feather = 0.0
	var step := TAU / RING_SEGMENTS
	for i in RING_SEGMENTS:
		var a0 := i * step
		var a1 := a0 + step
		var quad := PackedVector2Array([
			Vector2.from_angle(a0) * inner, Vector2.from_angle(a0) * outer,
			Vector2.from_angle(a1) * outer, Vector2.from_angle(a1) * inner,
		])
		_blade_batch.polygon(quad, Tuning.saw_ring_orange if i % 2 == 0 else Tuning.saw_ring_dark)
	_blade_batch.feather = ShapeBatch.SOFT_EDGE


func _draw_goo_coat(outer: float) -> void:
	var a := _goo_coat
	var body := Color(Tuning.goo_body_color, a)
	var rim := Color(Tuning.goo_rim_color, a)
	_blade_batch.arc(Vector2.ZERO, outer - 5.0, 0.3, 2.4, 9.0, rim, false)
	_blade_batch.arc(Vector2.ZERO, outer - 5.0, 0.3, 2.4, 6.0, body, false)
	for i in 4:
		var p := Vector2.from_angle(0.5 + i * 0.55) * (outer - 1.0)
		var r := 3.5 + float(i % 2) * 1.5
		_blade_batch.disc(p, r + 1.2, rim)
		_blade_batch.disc(p, r, body)

