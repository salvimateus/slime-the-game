extends StaticBody2D
## Crystal wall that blocks a passage. One hot shot shatters it into shards and the shot smashes through.

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

const CRYSTALS_PER_TILE := 3
const GLINT_INTERVAL := Vector2(0.8, 2.0)
const GLINT_SIZE := 11.0
const GLINT_TIME := 0.4
const RING_RADIUS := 120.0
const DROPLET_RELEASE_MARGIN := 10.0

var broken := false

var _size := Vector2.ZERO
var _crystals: Array[PackedVector2Array] = []
var _facets: Array[PackedVector2Array] = []
var _tones: PackedFloat32Array = PackedFloat32Array()
var _glint_wait := 0.0
var _rng := RandomNumberGenerator.new()
var _batch := ShapeBatch.new()

@onready var _shape: CollisionShape2D = $CollisionShape2D


## rect is in the parent's space: the top-left corner and the size of the blocked cells.
func setup(rect: Rect2) -> void:
	position = rect.position
	reset_physics_interpolation()
	_size = rect.size
	collision_layer = Tuning.LAYER_WORLD
	collision_mask = 0
	var box := RectangleShape2D.new()
	box.size = _size
	_shape.shape = box
	_shape.position = _size * 0.5
	_rng.seed = int(rect.position.x) * 31 + int(rect.position.y)
	_build_crystals()
	_glint_wait = _rng.randf_range(GLINT_INTERVAL.x, GLINT_INTERVAL.y)
	queue_redraw()


## A hot prop breaks the wall at once and keeps flying.
func shot_hit(hit: Dictionary) -> Dictionary:
	if broken:
		return {}
	var at: Vector2 = hit.get("at", global_position + _size * 0.5)
	var dir: Vector2 = hit.get("dir", Vector2.RIGHT)
	_shatter(at, dir)
	return {"pierce": true}


func _shatter(at: Vector2, dir: Vector2) -> void:
	broken = true
	_shape.disabled = true
	collision_layer = 0
	visible = false
	set_process(false)
	var center := global_position + _size * 0.5
	if is_instance_valid(Game.field):
		Game.field.call(&"release_droplets", Rect2(global_position, _size).grow(DROPLET_RELEASE_MARGIN))
	Juice.hitstop(Tuning.barrier_hitstop)
	Juice.shake(Tuning.barrier_shake, &"barrier")
	Juice.punch(Tuning.barrier_punch, &"barrier")
	Juice.flash(Tuning.barrier_flash_color, Tuning.barrier_flash_time)
	if is_instance_valid(Juice.sparks):
		var colors := PackedColorArray([Tuning.barrier_light, Tuning.barrier_mid, Tuning.barrier_dark, Tuning.barrier_core])
		var tiles := maxi(int(round(_size.y / Tuning.tile_size)), 1)
		for i: int in tiles:
			var from := global_position + Vector2(_size.x * 0.5, (float(i) + 0.5) * Tuning.tile_size)
			var shard_dir := (dir + (from - at).normalized() * 0.6).normalized()
			Juice.sparks.call(&"debris", from, shard_dir, Tuning.barrier_shards_per_tile, Tuning.barrier_shard_speed, 70.0, Tuning.barrier_shard_size, colors, false)
			Juice.sparks.call(&"glint", from, GLINT_SIZE * 1.6, Tuning.barrier_core, GLINT_TIME)
		Juice.sparks.call(&"sparks", at, dir, 24, Vector2(300.0, 900.0), 80.0, Tuning.barrier_light, Vector2(2.0, 4.0))
		Juice.sparks.call(&"ring", center, RING_RADIUS, Tuning.barrier_light, 0.4)
	Sfx.play(&"shatter", center)
	Game.report_barrier_broken(center)


func _process(delta: float) -> void:
	_glint_wait -= delta
	if _glint_wait > 0.0 or not is_instance_valid(Juice.sparks):
		return
	_glint_wait = _rng.randf_range(GLINT_INTERVAL.x, GLINT_INTERVAL.y)
	var at := global_position + Vector2(_rng.randf_range(0.2, 0.8) * _size.x, _rng.randf_range(0.1, 0.9) * _size.y)
	Juice.sparks.call(&"glint", at, GLINT_SIZE, Tuning.barrier_core, GLINT_TIME)


## Upright crystals that overlap and fill the cell column, rebuilt only when the wall is set up.
## They stay inside the column vertically and bleed a little sideways, so the wall reads thicker than its collider.
func _build_crystals() -> void:
	_crystals.clear()
	_facets.clear()
	_tones.clear()
	var rows := maxi(int(round(_size.y / Tuning.tile_size)), 1) * CRYSTALS_PER_TILE
	for i: int in rows:
		var y := _size.y * (float(i) + 0.6) / float(rows)
		var x := _size.x * _rng.randf_range(0.35, 0.65)
		var half_w := _size.x * _rng.randf_range(0.4, 0.55)
		var lean := _rng.randf_range(-0.22, 0.22)
		var up := Vector2(lean, -1.0).normalized()
		var side := up.orthogonal()
		var half_h := minf(Tuning.tile_size * _rng.randf_range(0.5, 0.75), minf(y / absf(up.y), (_size.y - y) / (0.8 * absf(up.y))))
		var c := Vector2(x, y)
		var tip := c + up * half_h
		var foot := c - up * half_h * 0.8
		var pts := PackedVector2Array([tip, c + side * half_w - up * half_h * 0.25, foot + side * half_w * 0.8, foot - side * half_w * 0.8, c - side * half_w - up * half_h * 0.25])
		_crystals.append(pts)
		_facets.append(PackedVector2Array([tip, pts[4], pts[3], c + up * half_h * 0.05]))
		_tones.append(_rng.randf())


func _draw() -> void:
	if broken:
		return
	_batch.clear()
	_batch.feather = 0.0
	_batch.rect(Rect2(Vector2(_size.x * 0.08, 0.0), Vector2(_size.x * 0.84, _size.y)), Color(Tuning.barrier_dark, 0.9))
	for i: int in _crystals.size():
		var pts := _crystals[i]
		var center := (pts[0] + pts[3]) * 0.5
		var outline := PackedVector2Array()
		for p: Vector2 in pts:
			outline.append(center + (p - center) * 1.12)
		_batch.feather = 0.0
		_batch.polygon(outline, Tuning.ground_outline_color)
		_batch.polygon(pts, Tuning.barrier_dark.lerp(Tuning.barrier_mid, 0.5 + 0.5 * _tones[i]))
		_batch.polygon(_facets[i], Tuning.barrier_mid.lerp(Tuning.barrier_light, _tones[i]))
		_batch.feather = ShapeBatch.SOFT_EDGE
		_batch.stroke(PackedVector2Array([pts[0], pts[0].lerp(pts[3], 0.6)]), 2.0, Color(Tuning.barrier_core, 0.8), false, false)
	_batch.commit(get_canvas_item())
