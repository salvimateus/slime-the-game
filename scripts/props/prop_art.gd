extends RefCounted
## Drawing of rocks and crystals, shared by loose props and by the props that float inside the slime.
## Shapes rotate with the prop; the light facets stay lit from the top left.
## draw_prop adds into a ShapeBatch, so one canvas item draws all its props in one draw call.

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

const ROCK_POINTS := 9
const ROCK_JITTER := Vector2(0.74, 1.0)
const CRYSTAL_SHAPE: Array[Vector2] = [
	Vector2(0.0, -1.3), Vector2(0.6, -0.5), Vector2(0.6, 0.55), Vector2(0.0, 1.15), Vector2(-0.6, 0.55), Vector2(-0.6, -0.5),
]
const OUTLINE_GROW := 1.16
const LIGHT_OFFSET := Vector2(-0.22, -0.26)
## A kind names the material and the size level: "rock" is a full rock, "rock_chunk" and "rock_chip" are its pieces.
## The size lives in the kind, so every holder of a prop identity (cargo, player, log) carries it unchanged.
const SIZE_SUFFIXES: Array[String] = ["", "_chunk", "_chip"]

static var _rock_cache := {}
static var _kind_info := {}


static func material_of(kind: StringName) -> StringName:
	return _info(kind)[0]


## 0 is a full prop; each break adds one level.
static func size_of(kind: StringName) -> int:
	return _info(kind)[1]


static func kind_of(material: StringName, size: int) -> StringName:
	return StringName(String(material) + SIZE_SUFFIXES[clampi(size, 0, size_levels() - 1)])


static func size_levels() -> int:
	return mini(SIZE_SUFFIXES.size(), Tuning.prop_size_scale.size())


## Pieces that a prop of this kind breaks into on a trap; 0 for the smallest size, which only bounces.
static func shatter_pieces(kind: StringName) -> int:
	var size := size_of(kind)
	if size >= size_levels() - 1 or size >= Tuning.prop_shatter_pieces.size():
		return 0
	return Tuning.prop_shatter_pieces[size]


static func radius_of(kind: StringName) -> float:
	var info: Array = _info(kind)
	var base := Tuning.prop_crystal_radius if info[0] == &"crystal" else Tuning.prop_rock_radius
	return base * Tuning.prop_size_scale[info[1]]


static func restitution_of(kind: StringName) -> float:
	return Tuning.prop_crystal_restitution if material_of(kind) == &"crystal" else Tuning.prop_rock_restitution


static func spark_color_of(kind: StringName) -> Color:
	return Tuning.bounce_spark_color_crystal if material_of(kind) == &"crystal" else Tuning.bounce_spark_color


static func palette_of(kind: StringName) -> PackedColorArray:
	if material_of(kind) == &"crystal":
		return PackedColorArray([Tuning.prop_crystal_light, Tuning.prop_crystal_mid, Tuning.prop_crystal_dark])
	return PackedColorArray([Tuning.prop_rock_light, Tuning.prop_rock_mid, Tuning.prop_rock_dark])


## [material, size level]; a kind with no size suffix is a full prop of that material.
static func _info(kind: StringName) -> Array:
	if _kind_info.has(kind):
		return _kind_info[kind]
	var text := String(kind)
	var info := [kind, 0]
	for size: int in range(size_levels() - 1, 0, -1):
		if text.ends_with(SIZE_SUFFIXES[size]):
			info = [StringName(text.trim_suffix(SIZE_SUFFIXES[size])), size]
			break
	_kind_info[kind] = info
	return info


## Adds one prop to `batch`. tint and tint_amount pull every color toward the goo; flash pushes it to white.
static func draw_prop(batch: ShapeBatch, kind: StringName, shape_seed: int, at: Vector2, angle: float, radius: float, tint := Color.WHITE, tint_amount := 0.0, alpha := 1.0, flash := 0.0) -> void:
	if radius <= 0.0:
		return
	var unit := _unit_shape(kind, shape_seed)
	var rot := Transform2D(angle, Vector2.ZERO)
	var pts := PackedVector2Array()
	pts.resize(unit.size())
	for i: int in unit.size():
		pts[i] = rot * unit[i] * radius
	var pal := palette_of(kind)
	var outline := _shade(Tuning.prop_outline_color, tint, tint_amount * 0.5, alpha, flash)
	var light := _shade(pal[0], tint, tint_amount, alpha, flash)
	var mid := _shade(pal[1], tint, tint_amount, alpha, flash)
	var dark := _shade(pal[2], tint, tint_amount, alpha, flash)
	batch.feather = 0.0
	batch.polygon(_offset(pts, at, OUTLINE_GROW, Vector2.ZERO), outline)
	batch.polygon(_offset(pts, at, 1.0, Vector2.ZERO), dark)
	batch.polygon(_offset(pts, at, 0.84, Vector2(-0.06, -0.08) * radius), mid)
	if material_of(kind) == &"crystal":
		var top := rot * unit[0] * radius
		var bottom := rot * unit[3] * radius
		var left_half := PackedVector2Array([at + top, at + rot * unit[5] * radius, at + rot * unit[4] * radius, at + bottom])
		batch.polygon(left_half, light)
		batch.feather = ShapeBatch.SOFT_EDGE
		batch.stroke(PackedVector2Array([at + top * 0.8, at + bottom * 0.5]), maxf(radius * 0.12, 1.0), _shade(Color.WHITE, tint, tint_amount * 0.5, alpha * 0.8, flash), false, false)
	else:
		batch.polygon(_offset(pts, at, 0.46, LIGHT_OFFSET * radius), light)
	batch.feather = ShapeBatch.SOFT_EDGE
	batch.disc(at + Vector2(-0.38, -0.42) * radius, maxf(radius * 0.13, 0.8), _shade(Color.WHITE, tint, tint_amount * 0.5, alpha * 0.85, flash))


## Outline of a prop of radius 1, before the turn; the cargo builds its own geometry from it.
static func unit_shape(kind: StringName, shape_seed: int) -> PackedVector2Array:
	return _unit_shape(kind, shape_seed)


static func _unit_shape(kind: StringName, shape_seed: int) -> PackedVector2Array:
	if material_of(kind) == &"crystal":
		return PackedVector2Array(CRYSTAL_SHAPE)
	var key := shape_seed % 64
	if _rock_cache.has(key):
		return _rock_cache[key]
	var rng := RandomNumberGenerator.new()
	rng.seed = 7000 + key
	var pts := PackedVector2Array()
	for i: int in ROCK_POINTS:
		var a := TAU * (float(i) + rng.randf_range(-0.25, 0.25)) / ROCK_POINTS
		pts.append(Vector2.from_angle(a) * rng.randf_range(ROCK_JITTER.x, ROCK_JITTER.y))
	_rock_cache[key] = pts
	return pts


static func _offset(pts: PackedVector2Array, at: Vector2, scale: float, shift: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(pts.size())
	for i: int in pts.size():
		out[i] = at + shift + pts[i] * scale
	return out


static func _shade(color: Color, tint: Color, tint_amount: float, alpha: float, flash: float) -> Color:
	var c := color.lerp(tint, clampf(tint_amount, 0.0, 1.0)).lerp(Color.WHITE, clampf(flash, 0.0, 1.0))
	c.a = color.a * clampf(alpha, 0.0, 1.0)
	return c
