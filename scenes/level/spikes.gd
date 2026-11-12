extends "res://scripts/level/hazard.gd"
## Spike strip. The builder sets the width; the hitbox is smaller than the art so near misses feel fair.

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

const SPIKES_PER_TILE := 3
const SPIKE_HEIGHT := 34.0
const BASE_HEIGHT := 8.0
const TIP_SHARE := 0.3
const REDRAW_INTERVAL := 1.0 / 30.0
const STAIN_MAX := 10

var width := 64.0
var _twang_time: float = Tuning.spike_twang_time
var _twang_x := 0.0
var _twang_dir := 1.0
var _twang_gain := 1.0
var _stain_x := PackedFloat32Array()
var _stain_age := PackedFloat32Array()
var _stain_size := PackedFloat32Array()
var _redraw_wait := 0.0
var _batch := ShapeBatch.new()


func _ready() -> void:
	super()
	set_process(false)


func setup(w: float) -> void:
	width = maxf(w, 1.0)
	loss = Tuning.spike_loss
	source = &"spikes"
	var shape := RectangleShape2D.new()
	shape.size = Vector2(maxf(width - Tuning.spike_hitbox_inset * 2.0, 8.0), Tuning.spike_hitbox_height)
	$CollisionShape2D.shape = shape
	$CollisionShape2D.position = Vector2(width * 0.5, Tuning.tile_size - Tuning.spike_hitbox_height * 0.5)
	queue_redraw()


func hit_center() -> Vector2:
	return global_position + Vector2(width * 0.5, Tuning.tile_size)


func deflects_props() -> bool:
	return true


## The whole strip with the spike art, not only the smaller hitbox: a prop between two tips is still in the trap.
func reach_rect() -> Rect2:
	return Rect2(global_position, Vector2(width, Tuning.tile_size))


## Props bounce off the tips and get pushed toward the nearer end of the strip, so none comes to rest on it.
func deflect(at: Vector2, velocity: Vector2) -> Variant:
	var local_x := clampf(to_local(at).x, 0.0, width)
	var toward_end := -1.0 if local_x < width * 0.5 else 1.0
	var out := Vector2(velocity.x * 0.8 + toward_end * Tuning.deflect_spike_push, -maxf(absf(velocity.y) * 0.75, Tuning.deflect_min_speed))
	_twang(local_x, -signf(out.x) if out.x != 0.0 else 1.0)
	return out


## The struck spikes bend much further than on a bounce and ring out longer.
func on_prop_shattered(at: Vector2, strength: float) -> void:
	super(at, strength)
	_twang_gain = lerpf(1.0, Tuning.spike_shatter_twang_gain, strength)
	_twang_time = 0.0


func _on_hit_landed(amount: float, at: Vector2) -> void:
	var local_x := clampf(to_local(at).x, 0.0, width)
	_twang(local_x, -signf(at.x - hit_center().x) if at.x != hit_center().x else 1.0)
	var stains := clampi(int(Tuning.spike_stain_count_base + amount * Tuning.spike_stain_per_loss), Tuning.spike_stain_count_range.x, Tuning.spike_stain_count_range.y)
	var spacing := width / float(_spike_count())
	for i in stains:
		var offset := (float(i) - (stains - 1) * 0.5) * spacing
		_add_stain(clampf(local_x + offset, spacing * 0.5, width - spacing * 0.5), 3.0 + float((i * 7 + stains) % 3))
	_redraw_wait = 0.0
	set_process(true)
	queue_redraw()


func _twang(local_x: float, dir: float) -> void:
	_twang_time = 0.0
	_twang_gain = 1.0
	_twang_x = local_x
	_twang_dir = dir
	_redraw_wait = 0.0
	set_process(true)


func _add_stain(x: float, size: float) -> void:
	if _stain_x.size() >= STAIN_MAX:
		_stain_x.remove_at(0)
		_stain_age.remove_at(0)
		_stain_size.remove_at(0)
	_stain_x.append(x)
	_stain_age.append(0.0)
	_stain_size.append(size)


func _process(delta: float) -> void:
	_twang_time += delta
	var i := _stain_age.size() - 1
	while i >= 0:
		_stain_age[i] += delta
		if _stain_age[i] >= Tuning.spike_stain_life:
			_stain_x.remove_at(i)
			_stain_age.remove_at(i)
			_stain_size.remove_at(i)
		i -= 1
	var idle := _twang_time >= Tuning.spike_twang_time and _stain_age.is_empty()
	_redraw_wait -= delta
	if _redraw_wait <= 0.0 or idle:
		_redraw_wait = REDRAW_INTERVAL
		queue_redraw()
	if idle:
		set_process(false)


func _spike_count() -> int:
	return maxi(int(round(width / Tuning.tile_size)) * SPIKES_PER_TILE, 1)


func _bend_at(x: float) -> float:
	if _twang_time >= Tuning.spike_twang_time:
		return 0.0
	var dx := x - _twang_x
	var falloff := exp(-(dx * dx) / (2.0 * Tuning.spike_twang_spread * Tuning.spike_twang_spread))
	return Tuning.spike_twang_pixels * _twang_gain * _twang_dir * falloff * exp(-_twang_time * Tuning.spike_twang_decay) * cos(_twang_time * Tuning.spike_twang_freq)


func _draw() -> void:
	_batch.clear()
	var floor_y := Tuning.tile_size
	var base_y := floor_y - BASE_HEIGHT * 0.5
	var tip_y := floor_y - SPIKE_HEIGHT
	var count := _spike_count()
	var spike_w := width / float(count)
	for i in count:
		var cx := (float(i) + 0.5) * spike_w
		var left := Vector2(cx - spike_w * 0.5, base_y)
		var right := Vector2(cx + spike_w * 0.5, base_y)
		var mid := Vector2(cx, base_y)
		var tip := Vector2(cx + _bend_at(cx), tip_y)
		_batch.feather = 0.0
		_batch.polygon(PackedVector2Array([left, tip, mid]), Tuning.spike_bone_lit)
		_batch.polygon(PackedVector2Array([mid, tip, right]), Tuning.spike_bone_shade)
		var tl := tip.lerp(left, TIP_SHARE)
		var tm := tip.lerp(mid, TIP_SHARE)
		var tr := tip.lerp(right, TIP_SHARE)
		_batch.polygon(PackedVector2Array([tl, tip, tm]), Tuning.spike_tip_lit)
		_batch.polygon(PackedVector2Array([tm, tip, tr]), Tuning.spike_tip_shade)
		_batch.feather = ShapeBatch.SOFT_EDGE
		_batch.stroke(PackedVector2Array([left.lerp(tip, 0.15) + Vector2(1.5, 0.0), tip.lerp(left, 0.12) + Vector2(1.0, 0.0)]), 1.5, Tuning.spike_bone_highlight, false, false)
		_batch.stroke(PackedVector2Array([left, tip, right]), 2.0, Tuning.ground_outline_color, false, false)
	_batch.feather = 0.0
	_batch.rect(Rect2(0.0, floor_y - BASE_HEIGHT, width, BASE_HEIGHT), Tuning.spike_base_color)
	_batch.rect(Rect2(0.0, floor_y - BASE_HEIGHT, width, 2.0), Tuning.spike_base_top)
	_batch.feather = ShapeBatch.SOFT_EDGE
	_draw_stains(base_y, tip_y)
	_batch.commit(get_canvas_item())


func _draw_stains(base_y: float, tip_y: float) -> void:
	for i in _stain_x.size():
		var age := _stain_age[i]
		var alpha := clampf((Tuning.spike_stain_life - age) / Tuning.spike_stain_fade, 0.0, 1.0)
		var size := _stain_size[i] * lerpf(1.0, 0.7, age / Tuning.spike_stain_life)
		var y := minf(tip_y + 5.0 + age * Tuning.spike_stain_slide_speed, base_y - 4.0)
		var share := inverse_lerp(base_y, tip_y, y)
		var x := _stain_x[i] + _bend_at(_stain_x[i]) * share
		var center := Vector2(x, y)
		_batch.disc(center, size + 1.5, Color(Tuning.goo_rim_color, alpha))
		_batch.disc(center, size, Color(Tuning.goo_body_color, alpha))
		_batch.disc(center + Vector2(0.0, size * 0.9), size * 0.55, Color(Tuning.goo_body_color, alpha))
		_batch.disc(center + Vector2(-size * 0.35, -size * 0.35), size * 0.3, Color(1.0, 1.0, 1.0, 0.7 * alpha))
