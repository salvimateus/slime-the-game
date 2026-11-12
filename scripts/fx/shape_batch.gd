extends RefCounted
## Batches flat shapes into one triangle array, so a canvas item that draws many of them costs one draw call.
## Each CanvasItem draw_colored_polygon, draw_circle and antialiased line is a separate draw call on the GPU.
## Each shape gets a thin strip that fades to clear at its edge, in place of antialiasing.
## Use: clear(), add shapes (in back-to-front order), then commit(get_canvas_item()) from the _draw of that item.
## The shapes add only points and colours; the triangle indices come from the list of shapes at commit, and a batch
## that draws the same list of shapes as the last commit reuses its indices.

const MITER_MIN := 0.35
## Edge fade in pixels that matches an antialiased CanvasItem draw; 0 gives the hard edge of draw_colored_polygon.
const SOFT_EDGE := 1.2
## Shape records in _shapes: kind, point count, flag (feathered polygon or closed stroke).
const SHAPE_POLYGON := 0
const SHAPE_STROKE := 1

## Unit circle points for each segment count, shared by every batch.
static var _unit_circles := {}

var feather := SOFT_EDGE
## Applied to every point added after it is set, like CanvasItem.draw_set_transform.
var transform := Transform2D.IDENTITY

var _points := PackedVector2Array()
var _colors := PackedColorArray()
var _shapes := PackedInt32Array()
var _indices := PackedInt32Array()
var _indexed_shapes := PackedInt32Array()


func clear() -> void:
	transform = Transform2D.IDENTITY
	_points.clear()
	_colors.clear()
	_shapes.clear()


func is_empty() -> bool:
	return _shapes.is_empty()


## Sends every shape added since clear() to the canvas item in one call.
func commit(item: RID) -> void:
	if _shapes.is_empty():
		return
	if _shapes != _indexed_shapes:
		_build_indices()
	RenderingServer.canvas_item_add_triangle_array(item, _indices, _points, _colors)


## Fills an outline that is star-shaped around its centroid (circles, ellipses, jelly bodies, convex shapes).
## vertex_colors, when given, holds one colour per outline point and replaces color.
func polygon(outline: PackedVector2Array, color: Color, vertex_colors := PackedColorArray()) -> void:
	var count := outline.size()
	var shaded := vertex_colors.size() == count
	if count < 3 or (color.a <= 0.0 and not shaded):
		return
	var center := Vector2.ZERO
	var center_color := color
	if shaded:
		center_color = Color(0.0, 0.0, 0.0, 0.0)
		for c: Color in vertex_colors:
			center_color += c
		center_color /= count
	for p: Vector2 in outline:
		center += p
	center /= count
	_points.append(transform * center)
	_colors.append(center_color)
	_points.append_array(transform * outline)
	if shaded:
		_colors.append_array(vertex_colors)
	else:
		_colors.append_array(_filled(color, count))
	var feathered := feather > 0.0
	_shapes.append(SHAPE_POLYGON)
	_shapes.append(count)
	_shapes.append(1 if feathered else 0)
	if not feathered:
		return
	var ring := PackedVector2Array()
	ring.resize(count)
	for i in count:
		var p := outline[i]
		ring[i] = p + (p - center).normalized() * feather
	_points.append_array(transform * ring)
	if shaded:
		var clear_colors := PackedColorArray()
		clear_colors.resize(count)
		for i in count:
			clear_colors[i] = Color(vertex_colors[i], 0.0)
		_colors.append_array(clear_colors)
	else:
		_colors.append_array(_filled(Color(color, 0.0), count))


func disc(center: Vector2, radius: float, color: Color) -> void:
	polygon(circle_points(center, Vector2.ONE * radius, 0.0), color)


func ring(center: Vector2, radius: float, width: float, color: Color) -> void:
	stroke(circle_points(center, Vector2.ONE * radius, 0.0), width, color, true)


func arc(center: Vector2, radius: float, from: float, to: float, width: float, color: Color, round_caps := true) -> void:
	var segments := maxi(ceili(_segments_for(radius) * absf(to - from) / TAU), 2)
	var points := PackedVector2Array()
	for i in segments + 1:
		points.append(center + Vector2.from_angle(lerpf(from, to, float(i) / segments)) * radius)
	stroke(points, width, color, false, round_caps)


## A thick line through the points with mitred joints; an open line gets round caps unless round_caps is off.
func stroke(points: PackedVector2Array, width: float, color: Color, closed := false, round_caps := true) -> void:
	var count := points.size()
	if count < 2 or color.a <= 0.0 or width <= 0.0:
		return
	var half := width * 0.5
	var outer_half := half + feather
	var clear_color := Color(color, 0.0)
	var strip := PackedVector2Array()
	strip.resize(count * 4)
	var colors := PackedColorArray()
	colors.resize(count * 4)
	for i in count:
		# Mitred joint normal, lengthened so the joint keeps the line width.
		var prev_i := i - 1
		var next_i := i + 1
		if closed:
			prev_i = posmod(prev_i, count)
			next_i = posmod(next_i, count)
		var p := points[i]
		var dir_in := (p - points[prev_i]).normalized() if prev_i >= 0 else Vector2.ZERO
		var dir_out := (points[next_i] - p).normalized() if next_i < count else Vector2.ZERO
		var dir := (dir_in + dir_out).normalized()
		if dir == Vector2.ZERO:
			dir = dir_in if dir_in != Vector2.ZERO else dir_out
		var n := dir.orthogonal()
		var reference := (dir_in if dir_in != Vector2.ZERO else dir_out).orthogonal()
		n = n / maxf(n.dot(reference), MITER_MIN)
		var k := i * 4
		strip[k] = p - n * outer_half
		strip[k + 1] = p - n * half
		strip[k + 2] = p + n * half
		strip[k + 3] = p + n * outer_half
		colors[k] = clear_color
		colors[k + 1] = color
		colors[k + 2] = color
		colors[k + 3] = clear_color
	_points.append_array(transform * strip)
	_colors.append_array(colors)
	_shapes.append(SHAPE_STROKE)
	_shapes.append(count)
	_shapes.append(1 if closed else 0)
	if not closed and round_caps:
		disc(points[0], half, color)
		disc(points[count - 1], half, color)


## Points around an ellipse of radii (x, y), turned by angle; the count follows the size.
static func circle_points(center: Vector2, radii: Vector2, angle: float) -> PackedVector2Array:
	var segments := _segments_for(maxf(radii.x, radii.y))
	var unit: PackedVector2Array = _unit_circles.get(segments, PackedVector2Array())
	if unit.is_empty():
		unit.resize(segments)
		for i in segments:
			var t := TAU * i / segments
			unit[i] = Vector2(cos(t), sin(t))
		_unit_circles[segments] = unit
	return Transform2D(angle, radii, 0.0, center) * unit


static func _segments_for(radius: float) -> int:
	return clampi(ceili(radius * 0.7), 12, 64)


## Axis-aligned rectangle in the local space of the transform: filled, or its outline when width is above 0.
func rect(area: Rect2, color: Color, width := 0.0) -> void:
	var corners := PackedVector2Array([area.position, Vector2(area.end.x, area.position.y), area.end, Vector2(area.position.x, area.end.y)])
	if width > 0.0:
		stroke(corners, width, color, true)
	else:
		polygon(corners, color)


static func _filled(color: Color, count: int) -> PackedColorArray:
	var colors := PackedColorArray()
	colors.resize(count)
	colors.fill(color)
	return colors


## Triangle indices for the recorded shapes: a fan and a feather strip for a polygon, three quad strips for a stroke.
func _build_indices() -> void:
	var total := 0
	for s in range(0, _shapes.size(), 3):
		var count := _shapes[s + 1]
		if _shapes[s] == SHAPE_POLYGON:
			total += count * (9 if _shapes[s + 2] == 1 else 3)
		else:
			total += (count if _shapes[s + 2] == 1 else count - 1) * 18
	_indices.resize(total)
	var w := 0
	var base := 0
	for s in range(0, _shapes.size(), 3):
		var count := _shapes[s + 1]
		var flag := _shapes[s + 2]
		if _shapes[s] == SHAPE_POLYGON:
			var inner := base + 1
			for i in count:
				_indices[w] = base
				_indices[w + 1] = inner + i
				_indices[w + 2] = inner + (i + 1) % count
				w += 3
			if flag == 1:
				var outer := inner + count
				for i in count:
					var j := (i + 1) % count
					_indices[w] = inner + i
					_indices[w + 1] = inner + j
					_indices[w + 2] = outer + j
					_indices[w + 3] = inner + i
					_indices[w + 4] = outer + j
					_indices[w + 5] = outer + i
					w += 6
				base = outer + count
			else:
				base = inner + count
		else:
			var spans := count if flag == 1 else count - 1
			for i in spans:
				var a := base + i * 4
				var b := base + ((i + 1) % count) * 4
				for k in 3:
					_indices[w] = a + k
					_indices[w + 1] = b + k
					_indices[w + 2] = b + k + 1
					_indices[w + 3] = a + k
					_indices[w + 4] = b + k + 1
					_indices[w + 5] = a + k + 1
					w += 6
			base += count * 4
	_indexed_shapes = _shapes.duplicate()
