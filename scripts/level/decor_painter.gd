extends RefCounted
## Paints flat shapes into a plain triangle list (one point per corner, no index array), so a whole layer of decor can
## become one mesh, or a piece can be moved each frame with one native Transform2D * PackedVector2Array.
## Every filled shape gets a thin outer strip that fades to clear, in place of antialiasing; a larger feather gives
## the soft edge of the far and near silhouettes.
## Each point also gets a UV that tells decor.gdshader how the point moves: UV.x is the motion kind plus its phase,
## UV.y the parameter of that kind (see set_motion). Static points get (0, 0).

const SOFT_EDGE := 1.2
const MIN_SEGMENTS := 8
const MAX_SEGMENTS := 24
## Motion kinds; keep the numbers equal to the ones in decor.gdshader.
const STATIC := 0
const SWAY := 1
const PULSE := 2
const GLINT := 3
const DROP := 4
const RISE := 5
const SQUASH := 6
const SQUASH_PULSE := 7
const SWAY_PULSE := 8
## Reactive pieces pack their id and the depth below their anchor into UV.y as id * ID_STRIDE + depth.
const ID_STRIDE := 1024.0
const PHASE_SCALE := 0.98

var points := PackedVector2Array()
var colors := PackedColorArray()
var uvs := PackedVector2Array()
var feather := SOFT_EDGE
## Applied to every point added after it is set.
var transform := Transform2D.IDENTITY

var _kind := STATIC
var _phase := 0.0
var _param := 0.0
var _id := 0
var _anchor_y := 0.0


func clear() -> void:
	points = PackedVector2Array()
	colors = PackedColorArray()
	uvs = PackedVector2Array()
	transform = Transform2D.IDENTITY
	feather = SOFT_EDGE
	set_motion(STATIC)


## Motion of the points added after this call. phase is 0..1. For SWAY kinds, anchor_y is the level y the piece hangs
## from; for SQUASH kinds the pivot comes from the shader; for DROP and RISE, param is the travel in px; for GLINT,
## the period in seconds. id (1 or more) names a reactive piece in the shader slots.
func set_motion(kind: int, phase := 0.0, param := 0.0, id := 0, anchor_y := 0.0) -> void:
	_kind = kind
	_phase = clampf(phase, 0.0, 1.0) * PHASE_SCALE
	_param = param
	_id = id
	_anchor_y = anchor_y


## Adds another triangle list after this one.
func append(other_points: PackedVector2Array, other_colors: PackedColorArray, other_uvs: PackedVector2Array) -> void:
	points.append_array(other_points)
	colors.append_array(other_colors)
	if other_uvs.size() == other_points.size():
		uvs.append_array(other_uvs)
	else:
		# New elements of a resized packed array are zero, which is the static motion.
		uvs.resize(uvs.size() + other_points.size())


func is_empty() -> bool:
	return points.is_empty()


## Fills an outline that is star-shaped around its centroid.
func polygon(outline: PackedVector2Array, color: Color) -> void:
	var count := outline.size()
	if count < 3 or color.a <= 0.0:
		return
	var center := Vector2.ZERO
	for p: Vector2 in outline:
		center += p
	center /= count
	var feathered := feather > 0.0
	var tris := count * (3 if feathered else 1)
	var local := PackedVector2Array()
	local.resize(tris * 3)
	var cols := PackedColorArray()
	cols.resize(tris * 3)
	cols.fill(color)
	var k := 0
	for i in count:
		local[k] = center
		local[k + 1] = outline[i]
		local[k + 2] = outline[(i + 1) % count]
		k += 3
	if feathered:
		var clear_color := Color(color, 0.0)
		for i in count:
			var a := outline[i]
			var b := outline[(i + 1) % count]
			var a2 := a + (a - center).normalized() * feather
			var b2 := b + (b - center).normalized() * feather
			local[k] = a
			local[k + 1] = b
			local[k + 2] = b2
			local[k + 3] = a
			local[k + 4] = b2
			local[k + 5] = a2
			cols[k + 2] = clear_color
			cols[k + 4] = clear_color
			cols[k + 5] = clear_color
			k += 6
	_add_points(transform * local, cols)


func disc(center: Vector2, radius: float, color: Color) -> void:
	polygon(ellipse_points(center, Vector2.ONE * radius, 0.0), color)


func ellipse(center: Vector2, radii: Vector2, angle: float, color: Color) -> void:
	polygon(ellipse_points(center, radii, angle), color)


## A thick open line through the points; the width can taper from start_width to end_width.
func stroke(line: PackedVector2Array, start_width: float, color: Color, end_width := -1.0) -> void:
	var count := line.size()
	if count < 2 or color.a <= 0.0:
		return
	if end_width < 0.0:
		end_width = start_width
	var clear_color := Color(color, 0.0)
	var feathered := feather > 0.0
	var per := 18 if feathered else 6
	var local := PackedVector2Array()
	local.resize((count - 1) * per)
	var cols := PackedColorArray()
	cols.resize((count - 1) * per)
	cols.fill(color)
	var k := 0
	var prev_l := Vector2.ZERO
	var prev_r := Vector2.ZERO
	var prev_lo := Vector2.ZERO
	var prev_ro := Vector2.ZERO
	for i in count:
		var dir := Vector2.ZERO
		if i > 0:
			dir += (line[i] - line[i - 1]).normalized()
		if i < count - 1:
			dir += (line[i + 1] - line[i]).normalized()
		var normal := dir.normalized().orthogonal()
		var half := lerpf(start_width, end_width, float(i) / (count - 1)) * 0.5
		var l := line[i] + normal * half
		var r := line[i] - normal * half
		var lo := l + normal * feather
		var ro := r - normal * feather
		if i > 0:
			local[k] = prev_l
			local[k + 1] = l
			local[k + 2] = r
			local[k + 3] = prev_l
			local[k + 4] = r
			local[k + 5] = prev_r
			if feathered:
				local[k + 6] = prev_lo
				local[k + 7] = lo
				local[k + 8] = l
				local[k + 9] = prev_lo
				local[k + 10] = l
				local[k + 11] = prev_l
				local[k + 12] = prev_r
				local[k + 13] = r
				local[k + 14] = ro
				local[k + 15] = prev_r
				local[k + 16] = ro
				local[k + 17] = prev_ro
				cols[k + 6] = clear_color
				cols[k + 7] = clear_color
				cols[k + 9] = clear_color
				cols[k + 14] = clear_color
				cols[k + 16] = clear_color
				cols[k + 17] = clear_color
			k += per
		prev_l = l
		prev_r = r
		prev_lo = lo
		prev_ro = ro
	_add_points(transform * local, cols)


func rect(area: Rect2, color: Color) -> void:
	polygon(PackedVector2Array([area.position, Vector2(area.end.x, area.position.y), area.end, Vector2(area.position.x, area.end.y)]), color)


## The top half of an ellipse (a dome) whose flat side sits on base_y, bulged a little below by under.
func dome(center: Vector2, radii: Vector2, under: float, color: Color) -> void:
	var seg := _segments_for(maxf(radii.x, radii.y))
	var pts := PackedVector2Array()
	for i in seg + 1:
		var t := PI + PI * float(i) / seg
		pts.append(center + Vector2(cos(t) * radii.x, sin(t) * radii.y))
	if under > 0.0:
		pts.append(center + Vector2(radii.x * 0.5, under))
		pts.append(center + Vector2(-radii.x * 0.5, under))
	polygon(pts, color)


static func ellipse_points(center: Vector2, radii: Vector2, angle: float) -> PackedVector2Array:
	var seg := _segments_for(maxf(radii.x, radii.y))
	var pts := PackedVector2Array()
	pts.resize(seg)
	for i in seg:
		var t := TAU * i / seg
		pts[i] = center + Vector2(cos(t) * radii.x, sin(t) * radii.y).rotated(angle)
	return pts


static func _segments_for(radius: float) -> int:
	return clampi(ceili(radius * 0.45), MIN_SEGMENTS, MAX_SEGMENTS)


## Builds a mesh from a triangle list; null when the list is empty. UVs are optional.
static func make_mesh(mesh_points: PackedVector2Array, mesh_colors: PackedColorArray, mesh_uvs := PackedVector2Array()) -> ArrayMesh:
	if mesh_points.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = mesh_points
	arrays[Mesh.ARRAY_COLOR] = mesh_colors
	if mesh_uvs.size() == mesh_points.size():
		arrays[Mesh.ARRAY_TEX_UV] = mesh_uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _tri(a: Vector2, b: Vector2, c: Vector2, ca: Color, cb: Color, cc: Color) -> void:
	var pa := transform * a
	var pb := transform * b
	var pc := transform * c
	points.append(pa)
	points.append(pb)
	points.append(pc)
	if _kind == STATIC:
		uvs.append(Vector2.ZERO)
		uvs.append(Vector2.ZERO)
		uvs.append(Vector2.ZERO)
	else:
		uvs.append(_uv_for(pa))
		uvs.append(_uv_for(pb))
		uvs.append(_uv_for(pc))
	colors.append(ca)
	colors.append(cb)
	colors.append(cc)


## Appends points already in level space, with their colours and the UVs of the current motion.
func _add_points(world: PackedVector2Array, cols: PackedColorArray) -> void:
	var start := uvs.size()
	points.append_array(world)
	colors.append_array(cols)
	uvs.resize(start + world.size())
	if _kind == STATIC:
		return
	for i in world.size():
		uvs[start + i] = _uv_for(world[i])


func _uv_for(world: Vector2) -> Vector2:
	if _kind == STATIC:
		return Vector2.ZERO
	var y := _param
	match _kind:
		SWAY, SWAY_PULSE:
			y = _id * ID_STRIDE + clampf(world.y - _anchor_y, 0.0, ID_STRIDE - 1.0)
		SQUASH, SQUASH_PULSE:
			y = _id * ID_STRIDE
	return Vector2(_kind + _phase, y)
