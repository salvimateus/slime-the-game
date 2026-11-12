extends Node2D
## A canvas item that draws a few quads of fire.gdshader one time: its geometry never changes in a frame. The shader
## moves the fire with TIME and the owner moves the node through its transform, modulate and material uniforms.
## Pieces are added before the node enters the tree, or with redraw() after a change of drawn state.

## Integer part of UV.x that selects each piece in fire.gdshader (kind * 2 + u).
const KIND_BAND := 0.0
const KIND_GLOW := 2.0
const KIND_EMBER := 8.0
const KIND_BODY := 10.0
## Plain UV 0..1, for a shader of its own (the heat shimmer).
const KIND_PLAIN := 0.0

## Band pieces: the floor sits this share of the bed height above the quad bottom, the quad is this many bed heights
## tall, and the size travels in the vertex colour divided by these (the shader multiplies them back).
const BAND_FLOOR_SHARE := 0.12
const BAND_QUAD_SHARE := 1.37
const BAND_WIDTH_SCALE := 2048.0
const BAND_HEIGHT_SCALE := 512.0

var _points := PackedVector2Array()
var _colors := PackedColorArray()
var _uvs := PackedVector2Array()
var _indices := PackedInt32Array()


func clear_pieces() -> void:
	_points.clear()
	_colors.clear()
	_uvs.clear()
	_indices.clear()


## A quad over rect (local space) of one kind, its vertex colour carrying the data of that kind.
func add_piece(kind: float, rect: Rect2, data: Color) -> void:
	var first := _points.size()
	_points.append_array(PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]))
	_uvs.append_array(PackedVector2Array([Vector2(kind, 0.0), Vector2(kind + 1.0, 0.0), Vector2(kind + 1.0, 1.0), Vector2(kind, 1.0)]))
	for k: int in 4:
		_colors.append(data)
	_indices.append_array(PackedInt32Array([first, first + 1, first + 2, first, first + 2, first + 3]))


## A bed of flames over a floor that starts at `left` (the floor's left end) and runs `width` px; the flames rise up
## to 1.25 bed heights. seed 0..1.
func add_band(left: Vector2, width: float, bed_height: float, seed_value: float) -> void:
	var quad_h := bed_height * BAND_QUAD_SHARE
	var bottom := left.y + bed_height * BAND_FLOOR_SHARE
	add_piece(KIND_BAND, Rect2(left.x, bottom - quad_h, width, quad_h), Color(width / BAND_WIDTH_SCALE, quad_h / BAND_HEIGHT_SCALE, seed_value, 1.0))


## A soft light of radii (x, y) around center.
func add_glow(center: Vector2, radii: Vector2, color: Color) -> void:
	add_piece(KIND_GLOW, Rect2(center - radii, radii * 2.0), color)


func redraw() -> void:
	queue_redraw()


func _draw() -> void:
	if not _indices.is_empty():
		RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), _indices, _points, _colors, _uvs)
