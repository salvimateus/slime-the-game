extends RefCounted
## Geometry of the props and bubbles inside the slime, for cargo.gdshader. Each prop shape is built one time, at
## radius 1 and before the turn; the shader places, turns, sizes and tints it from the per-prop data of the cargo.
## The lists are plain triangles (no index array), so the props of a load join with append_array alone.
## Per vertex: VERTEX is the shape point (a unit direction on a disc), COLOR the base colour (alpha 0 on the soft rim),
## UV.x the layer code (the cargo adds the slot), UV.y the packed rim normal of a stroke.
## The layers repeat what PropArt.draw_prop and the cargo light edge, glow and gloss draw, in the same order.

const PropArt := preload("res://scripts/props/prop_art.gd")
const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

const EDGE := 0
const GLOW := 1
const OUTLINE := 2
const BODY := 3
const MID := 4
const LIGHT := 5
const STROKE := 6
const SPOT := 7
const GLOSS := 8
const BUBBLE := 9
## Code steps above the layer: drawn in the front item, and the slot of the prop or bubble.
const FRONT := 16
const SLOT := 32
## Glow disc radius (in prop radii) that sets its segment count; the shader pulses it from 1.5 to 1.8.
const GLOW_REF := 1.65
const GLOSS_FROM := PI * 1.1
const GLOSS_TO := PI * 1.45
const NORMAL_STEP := 256.0
const NORMAL_SPAN := 2048.0
const NORMAL_BIAS := 4.0
const QUAD_CORNERS: Array[Vector2] = [Vector2(-1.0, -1.0), Vector2(1.0, -1.0), Vector2(1.0, 1.0), Vector2(-1.0, 1.0)]
const QUAD_ORDER: Array[int] = [0, 1, 2, 0, 2, 3]

static var _cache := {}

## [points, colors, codes] of one prop drawn at about `radius` pixels, which sets the segment counts of its discs and
## arc as ShapeBatch would; shared and cached, so callers must not change them.
static func prop(kind: StringName, shape_seed: int, radius: float) -> Array:
	var is_crystal := PropArt.material_of(kind) == &"crystal"
	var segments := Vector4i(ShapeBatch._segments_for(radius * (1.0 + Tuning.carry_edge_width)), ShapeBatch._segments_for(radius * GLOW_REF), ShapeBatch._segments_for(maxf(radius * 0.13, 0.8)), maxi(ceili(ShapeBatch._segments_for(radius * 0.95) * (GLOSS_TO - GLOSS_FROM) / TAU), 2))
	var key := "%s:%d:%s" % [PropArt.material_of(kind), 0 if is_crystal else shape_seed % 64, segments]
	if _cache.has(key):
		return _cache[key]
	var geo := Builder.new()
	geo.build_prop(kind, shape_seed, is_crystal, segments)
	var out := [geo.points, geo.colors, geo.codes]
	_cache[key] = out
	return out


## Quads of `count` bubbles, one per slot.
static func bubbles(count: int) -> Array:
	var geo := Builder.new()
	for b: int in count:
		for k: int in QUAD_ORDER:
			geo.vertex(QUAD_CORNERS[k], Color.WHITE, b * SLOT + BUBBLE)
	return [geo.points, geo.colors, geo.codes]


## Collects the triangle list of one prop or of the bubble quads.
class Builder:
	var points := PackedVector2Array()
	var colors := PackedColorArray()
	var codes := PackedVector2Array()

	func build_prop(kind: StringName, shape_seed: int, is_crystal: bool, segments: Vector4i) -> void:
		var unit := PropArt.unit_shape(kind, shape_seed)
		var pal := PropArt.palette_of(kind)
		_disc(EDGE, segments.x, Color(Tuning.carry_edge_color, 1.0))
		_disc(GLOW, segments.y, Color(Tuning.ember_hot, 1.0))
		_fan(OUTLINE, Transform2D.IDENTITY.scaled(Vector2.ONE * PropArt.OUTLINE_GROW) * unit, Tuning.prop_outline_color)
		_fan(BODY, unit, pal[2])
		_fan(MID, Transform2D.IDENTITY.scaled(Vector2.ONE * 0.84) * unit, pal[1])
		if is_crystal:
			_fan(BODY, PackedVector2Array([unit[0], unit[5], unit[4], unit[3]]), pal[0])
			_stroke(STROKE, PackedVector2Array([unit[0] * 0.8, unit[3] * 0.5]), Color(1.0, 1.0, 1.0, 0.8))
		else:
			_fan(LIGHT, Transform2D.IDENTITY.scaled(Vector2.ONE * 0.46) * unit, pal[0])
		_disc(SPOT, segments.z, Color(1.0, 1.0, 1.0, 0.85))
		var spans := segments.w
		var arc := PackedVector2Array()
		for i: int in spans + 1:
			arc.append(Vector2.from_angle(lerpf(GLOSS_FROM, GLOSS_TO, float(i) / spans)))
		_stroke(GLOSS, arc, Color.WHITE)

	func vertex(p: Vector2, color: Color, code: int, normal := Vector2.ZERO) -> void:
		points.append(p)
		colors.append(color)
		var q := ((normal + Vector2.ONE * NORMAL_BIAS) * NORMAL_STEP).round().clamp(Vector2.ZERO, Vector2.ONE * (NORMAL_SPAN - 1.0))
		codes.append(Vector2(code, q.x * NORMAL_SPAN + q.y))


	## Hard-edged fan around the mean of the outline points, like ShapeBatch.polygon with feather 0.
	func _fan(code: int, outline: PackedVector2Array, color: Color) -> void:
		var center := Vector2.ZERO
		for p: Vector2 in outline:
			center += p
		center /= outline.size()
		for i: int in outline.size():
			vertex(center, color, code)
			vertex(outline[i], color, code)
			vertex(outline[(i + 1) % outline.size()], color, code)


	## Unit disc with the soft rim of ShapeBatch.disc: the shader sets the radius, and the rim points (alpha 0) sit one
	## soft edge further out.
	func _disc(code: int, segments: int, color: Color) -> void:
		var clear := Color(color, 0.0)
		for i: int in segments:
			var a := Vector2(cos(TAU * i / segments), sin(TAU * i / segments))
			var j := (i + 1) % segments
			var b := Vector2(cos(TAU * j / segments), sin(TAU * j / segments))
			vertex(Vector2.ZERO, color, code)
			vertex(a, color, code)
			vertex(b, color, code)
			vertex(a, color, code)
			vertex(b, color, code)
			vertex(b, clear, code)
			vertex(a, color, code)
			vertex(b, clear, code)
			vertex(a, clear, code)


	## Open line with the mitred joints and soft sides of ShapeBatch.stroke (no caps). Each point carries its signed
	## mitre normal; the shader moves it out by the half width, plus the soft edge on the rim.
	func _stroke(code: int, line: PackedVector2Array, color: Color) -> void:
		var count := line.size()
		var normals := PackedVector2Array()
		normals.resize(count)
		for i: int in count:
			var p := line[i]
			var dir_in := (p - line[i - 1]).normalized() if i > 0 else Vector2.ZERO
			var dir_out := (line[i + 1] - p).normalized() if i < count - 1 else Vector2.ZERO
			var dir := (dir_in + dir_out).normalized()
			if dir == Vector2.ZERO:
				dir = dir_in if dir_in != Vector2.ZERO else dir_out
			var n := dir.orthogonal()
			var reference := (dir_in if dir_in != Vector2.ZERO else dir_out).orthogonal()
			normals[i] = n / maxf(n.dot(reference), ShapeBatch.MITER_MIN)
		var clear := Color(color, 0.0)
		var side_colors: Array[Color] = [clear, color, color, clear]
		var side_signs: Array[float] = [-1.0, -1.0, 1.0, 1.0]
		for i: int in count - 1:
			for k: int in 3:
				for corner: Vector2i in [Vector2i(i, k), Vector2i(i + 1, k), Vector2i(i + 1, k + 1), Vector2i(i, k), Vector2i(i + 1, k + 1), Vector2i(i, k + 1)]:
					vertex(line[corner.x], side_colors[corner.y], code, normals[corner.x] * side_signs[corner.y])
