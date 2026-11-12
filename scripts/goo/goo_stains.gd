extends Node2D
## Damp stains that sunk goo leaves on the soil: dark soft ellipses that grow while the goo sinks, then fade.
## A ring buffer, so the oldest stain gives way first; every stain draws in one triangle array.

const TEXTURE_SIZE := 64
const QUAD_ORDER: Array[int] = [0, 1, 2, 0, 2, 3]
const WARM_FRAMES := 4

var _pos := PackedVector2Array()
var _half := PackedVector2Array()
var _axis := PackedVector2Array()
## Clock time of each add: a stain's age is _clock - _born, so no loop counts ages up.
var _born := PackedFloat32Array()
var _clock := 0.0
## Clock time when the last stain has faded; slots up to _drawn_hi were drawn in the last frame.
var _end := 0.0
var _drawn_hi := 0
var _grow := PackedFloat32Array()
var _count := 0
var _next := 0
var _points := PackedVector2Array()
var _uvs := PackedVector2Array()
var _colors := PackedColorArray()
var _indices := PackedInt32Array()
var _texture: ImageTexture
var _warm_frames := WARM_FRAMES
var _drawn := false
## Local bounds of every stain since the last clear; the stains redraw only while it is in view.
var _bounds := Rect2()
var _dirty := false
var _drawn_step := -1


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var cap := maxi(Tuning.goo_stain_max, 1)
	_pos.resize(cap)
	_half.resize(cap)
	_axis.resize(cap)
	_born.resize(cap)
	_grow.resize(cap)
	_points.resize(cap * 4)
	_uvs.resize(cap * 4)
	_colors.resize(cap * 4)
	_indices.resize(cap * 6)
	for q: int in cap:
		_uvs[q * 4] = Vector2(0.0, 0.0)
		_uvs[q * 4 + 1] = Vector2(1.0, 0.0)
		_uvs[q * 4 + 2] = Vector2(1.0, 1.0)
		_uvs[q * 4 + 3] = Vector2(0.0, 1.0)
		for k: int in 6:
			_indices[q * 6 + k] = q * 4 + QUAD_ORDER[k]
	_texture = _make_texture()
	# The first frames draw one stain at almost zero alpha, so the first real stain does not hitch.
	add(Vector2.ZERO, Vector2.ONE * 8.0, Vector2.UP, 0.0)


func add(at: Vector2, half_size: Vector2, normal: Vector2, grow_time: float) -> void:
	if half_size.x <= 0.0 or half_size.y <= 0.0:
		return
	var i := _next
	_next = (_next + 1) % _pos.size()
	_count = mini(_count + 1, _pos.size())
	_pos[i] = to_local(at)
	_half[i] = half_size
	var n := normal.normalized() if normal != Vector2.ZERO else Vector2.UP
	# x axis of the stain runs along the surface.
	_axis[i] = Vector2(-n.y, n.x)
	_born[i] = _clock
	_grow[i] = maxf(grow_time, 0.0)
	var reach := Rect2(_pos[i], Vector2.ZERO).grow(maxf(half_size.x, half_size.y))
	_bounds = reach if _count == 1 else _bounds.merge(reach)
	_dirty = true
	_end = maxf(_end, _clock + _grow[i] + Tuning.goo_stain_fade_time)


func clear() -> void:
	_count = 0
	_next = 0
	# Slots drawn before stay out of the next draws, so their quads collapse to zero area here.
	for k: int in _drawn_hi * 4:
		_points[k] = Vector2.ZERO
	_drawn_hi = 0


func count() -> int:
	return _count


func _process(delta: float) -> void:
	if _warm_frames > 0:
		_warm_frames -= 1
		if _warm_frames == 0:
			clear()
	_clock += delta
	if _count > 0 and _clock >= _end and _warm_frames == 0:
		clear()
	if _count == 0:
		if _drawn:
			queue_redraw()
		return
	if _warm_frames > 0 or _dirty:
		_dirty = false
		queue_redraw()
		return
	if not _view_rect().intersects(_bounds):
		return
	# The fade is slow, so a redraw at a lower rate shows no step.
	var step := floori(_clock * Tuning.goo_stain_redraw_hz)
	if step != _drawn_step:
		_drawn_step = step
		queue_redraw()


func _view_rect() -> Rect2:
	var viewport := get_viewport()
	if viewport == null:
		return Rect2()
	return (get_global_transform_with_canvas().affine_inverse() * viewport.get_visible_rect()).grow(Tuning.tile_size)


func _draw() -> void:
	_drawn = _count > 0
	if not _drawn:
		return
	var base_color := Tuning.goo_stain_color
	var fade := maxf(Tuning.goo_stain_fade_time, 0.01)
	# Live slots, plus the slots drawn last frame that a clear left behind (they collapse to zero area once).
	var used := maxi(_count, _drawn_hi)
	_drawn_hi = _count
	for q: int in used:
		var base := q * 4
		var alpha := 0.0
		if q < _count:
			var age := _clock - _born[q]
			var grow := _grow[q]
			var appear := 1.0 if grow <= 0.0 else smoothstep(0.0, grow, age)
			alpha = base_color.a * appear * (1.0 - smoothstep(grow, grow + fade, age))
			if _warm_frames > 0:
				alpha = 0.01
		if alpha <= 0.0:
			for k: int in 4:
				_points[base + k] = Vector2.ZERO
			continue
		var grow_size := 1.0 if _grow[q] <= 0.0 else lerpf(0.6, 1.0, smoothstep(0.0, _grow[q], _clock - _born[q]))
		var ax := _axis[q] * _half[q].x * grow_size
		var ay := Vector2(-_axis[q].y, _axis[q].x) * _half[q].y * grow_size
		var p := _pos[q]
		_points[base] = p - ax - ay
		_points[base + 1] = p + ax - ay
		_points[base + 2] = p + ax + ay
		_points[base + 3] = p - ax + ay
		var c := Color(base_color, alpha)
		for k: int in 4:
			_colors[base + k] = c
	RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), _indices, _points, _colors, _uvs, PackedInt32Array(), PackedFloat32Array(), _texture.get_rid())


## Soft disc, denser toward the middle: reads as damp soil, not as a hard decal.
static func _make_texture() -> ImageTexture:
	var size := TEXTURE_SIZE
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var half := size * 0.5
	for y: int in size:
		for x: int in size:
			var d := Vector2(x + 0.5 - half, y + 0.5 - half).length() / half
			var v := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, v * (2.0 - v)))
	return ImageTexture.create_from_image(img)
