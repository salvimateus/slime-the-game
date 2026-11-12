extends RefCounted
## Places the decoration of a level by a seeded rule: it walks every floor, ceiling and wall cell, picks a kind by the
## theme of its column and the densities of Tuning, and keeps clear of the cells the builder marks.
## Everything is painted one time into triangle lists, one list per layer and per section of columns, so the renderer
## skips the sections off screen and a frame costs no GDScript. Pieces that move carry their motion in their UVs
## (decor.gdshader). Mushrooms and hanging pieces also go into `reactive`, so DecorLive can push them when the slime
## or a shot touches them. It never reads Game.rng, so the gameplay random stream stays the same.

const Painter := preload("res://scripts/level/decor_painter.gd")
const DecorArt := preload("res://scripts/level/decor_art.gd")

## Ceiling kinds that hang and sway.
const HANGING_KINDS: Array[StringName] = [&"root", &"vine", &"dead_root", &"charred_root", &"glow_worm"]
const TALL_LIMIT_CELLS := 3
const HANG_SEGMENTS := 4
const GLINT_SIZE := 9.0
const PUFFS := 3
const EMBERS := 4
const CACHE_PATH := "user://decor_cache.zst"
## Uncompressed cache of older builds (about 10 times larger), removed after a new cache is written.
const OLD_CACHE_PATH := "user://decor_cache.bin"
## Bump when the cache format changes.
const CACHE_VERSION := 2
## Header of a file written by FileAccess.open_compressed.
const CACHE_MAGIC := "GCPF"
const CACHE_SOURCES: PackedStringArray = ["res://scripts/level/decor_layout.gd", "res://scripts/level/decor_art.gd", "res://scripts/level/decor_painter.gd"]
## Columns on each side of a near clump that must be free of rock, so the clump never covers a wall face.
const FRONT_WALL_CLEAR := 5

## Section index -> Painter, for the layer drawn with the ground (decor), behind it (back) and over the play (front).
var decor := {}
var back := {}
var front := {}
## Reactive pieces sorted by x: {"kind": &"mushroom" or &"hanging", "id", "pos", "height", "half", "length", "spore"}.
var reactive: Array[Dictionary] = []

var _solid := {}
var _clear := {}
var _low := {}
var _size := Vector2i.ZERO
var _tile := 64.0
var _section_px := 1.0
var _themes: Array = []
var _rng := RandomNumberGenerator.new()
var _taken := {}


## clear: cells with no decoration at all; low: cells where only low floor pieces grow.
## themes: [[first column, theme], ...] sorted by column.
func build(solid: Dictionary, size: Vector2i, tile: float, clear: Dictionary, low: Dictionary, themes: Array) -> void:
	_solid = solid
	_clear = clear
	_low = low
	_size = size
	_tile = tile
	_section_px = maxf(Tuning.decor_section_cells * tile, tile)
	_themes = themes
	_rng.seed = Tuning.decor_seed
	var key := _cache_key()
	if _load_cache(key):
		return
	_place_back_and_front()
	for x in _size.x:
		for y in _size.y:
			var cell := Vector2i(x, y)
			if not _is_air(cell):
				continue
			if _solid.has(cell + Vector2i.DOWN):
				_place_floor(cell)
			if _solid.has(cell + Vector2i.UP):
				_place_ceiling(cell)
	_place_walls()
	reactive.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.pos.x) < float(b.pos.x))
	_save_cache(key)


## The layout of the last build is kept in user://, so the next start of the same game and level skips the painting.
## The key covers the inputs, every decor_ and ground_ value of Tuning and the bytes of the scripts that paint.
func _cache_key() -> PackedByteArray:
	var tuning := []
	for prop: Dictionary in Tuning.get_property_list():
		var prop_name: String = prop.name
		if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and (prop_name.begins_with("decor_") or prop_name.begins_with("ground_")):
			tuning.append([prop_name, Tuning.get(prop_name)])
	var sources := []
	for path: String in CACHE_SOURCES:
		for file: String in [path, path + "c"]:
			if FileAccess.file_exists(file):
				sources.append(FileAccess.get_md5(file))
	var inputs := [CACHE_VERSION, _solid.keys(), _size, _tile, _clear.keys(), _low.keys(), _themes, tuning, sources]
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(var_to_bytes(inputs))
	return ctx.finish()


func _load_cache(key: PackedByteArray) -> bool:
	if not Tuning.decor_cache or not FileAccess.file_exists(CACHE_PATH):
		return false
	# The cache is Zstandard-compressed; a file with no compressed header counts as a miss.
	var head := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if head == null or head.get_length() < 4 or head.get_buffer(4).get_string_from_ascii() != CACHE_MAGIC:
		return false
	head.close()
	var file := FileAccess.open_compressed(CACHE_PATH, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if file == null:
		return false
	var data: Variant = file.get_var()
	if not (data is Dictionary) or not (data.get("key") is PackedByteArray) or data.key != key:
		return false
	decor = _painters_from(data.get("decor", {}))
	back = _painters_from(data.get("back", {}))
	front = _painters_from(data.get("front", {}))
	reactive.assign(data.get("reactive", []))
	return true


func _save_cache(key: PackedByteArray) -> void:
	if not Tuning.decor_cache:
		return
	# Written beside the cache and renamed over it, so a game that starts at the same time never reads half a file.
	var temp := CACHE_PATH + ".%d.tmp" % OS.get_process_id()
	var file := FileAccess.open_compressed(temp, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if file == null:
		return
	file.store_var({"key": key, "decor": _arrays_of(decor), "back": _arrays_of(back), "front": _arrays_of(front), "reactive": reactive})
	file.close()
	DirAccess.rename_absolute(temp, CACHE_PATH)
	if FileAccess.file_exists(OLD_CACHE_PATH):
		DirAccess.remove_absolute(OLD_CACHE_PATH)


static func _arrays_of(layer: Dictionary) -> Dictionary:
	var out := {}
	for index: int in layer:
		var p: Painter = layer[index]
		out[index] = [p.points, p.colors, p.uvs]
	return out


static func _painters_from(arrays: Dictionary) -> Dictionary:
	var out := {}
	for index: int in arrays:
		var p := Painter.new()
		p.points = arrays[index][0]
		p.colors = arrays[index][1]
		p.uvs = arrays[index][2]
		out[index] = p
	return out


func section_of(x: float) -> int:
	return int(floor(x / _section_px))


func theme_at(column: int) -> StringName:
	var theme: StringName = &"cave"
	for entry: Array in _themes:
		if column >= int(entry[0]):
			theme = entry[1]
	return theme


## The painter of a layer for the section that holds pos, with its transform set to pos and no motion.
func _at(layer: Dictionary, pos: Vector2, feather := Painter.SOFT_EDGE) -> Painter:
	var index := section_of(pos.x)
	if not layer.has(index):
		layer[index] = Painter.new()
	var p: Painter = layer[index]
	p.transform = Transform2D(0.0, pos)
	p.feather = feather
	p.set_motion(Painter.STATIC)
	return p


func _is_air(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < _size.x and cell.y < _size.y and not _solid.has(cell)


func _density(theme: StringName, key: String) -> float:
	var table: Dictionary = Tuning.decor_density.get(theme, {})
	return float(table.get(key, 0.0))


func _pick_kind(table: Dictionary, allowed: Array[StringName] = []) -> StringName:
	var total := 0.0
	for kind: StringName in table:
		if allowed.is_empty() or allowed.has(kind):
			total += float(table[kind])
	if total <= 0.0:
		return &""
	var roll := _rng.randf() * total
	for kind: StringName in table:
		if not allowed.is_empty() and not allowed.has(kind):
			continue
		roll -= float(table[kind])
		if roll <= 0.0:
			return kind
	return &""


## Free air cells going up (dir -1) or down (dir 1) from a cell, counting the cell itself, up to limit.
func _free_run(cell: Vector2i, dir: int, limit: int) -> int:
	var n := 0
	var at := cell
	while n < limit and _is_air(at) and not _clear.has(at):
		n += 1
		at.y += dir
	return n


## Air cells from a cell to the next rock, ignoring the clear marks.
func _air_run(cell: Vector2i, dir: int, limit: int) -> int:
	var n := 0
	var at := cell
	while n < limit and _is_air(at):
		n += 1
		at.y += dir
	return n


func _place_floor(cell: Vector2i) -> void:
	if _clear.has(cell) or _taken.has(cell):
		return
	var theme := theme_at(cell.x)
	var ground := Vector2(cell.x * _tile, (cell.y + 1) * _tile)
	if _rng.randf() < _density(theme, "soil"):
		var soil := _pick_kind(Tuning.decor_soil_kinds.get(theme, {}))
		if soil != &"":
			DecorArt.soil_piece(_at(decor, ground + Vector2(_tile * 0.5, Tuning.ground_lip_depth + 4.0)), _rng_for(cell, 3), soil, theme)
	if _rng.randf() < _density(theme, "scatter"):
		var scatter := _pick_kind(Tuning.decor_floor_kinds.get(theme, {}), Tuning.decor_low_kinds)
		if scatter != &"" and scatter != &"embers":
			_paint_floor_static(_at(decor, ground + Vector2(_rng.randf_range(0.1, 0.9) * _tile, 0.0)), scatter, theme, cell, 1, 7)
	if _rng.randf() >= _density(theme, "floor"):
		return
	var allowed: Array[StringName] = []
	if _low.has(cell):
		allowed = Tuning.decor_low_kinds
	var kind := _pick_kind(Tuning.decor_floor_kinds.get(theme, {}), allowed)
	if kind == &"":
		return
	var free_up := _free_run(cell, -1, TALL_LIMIT_CELLS)
	var at := ground + Vector2(_rng.randf_range(0.25, 0.75) * _tile, 0.0)
	var rng := _rng_for(cell, 1)
	_taken[cell] = true
	match kind:
		&"mushroom", &"frozen_mushroom":
			var height := _mushroom_height(free_up)
			_add_mushroom(at, height, kind == &"frozen_mushroom", theme, rng)
			if height > _tile:
				_taken[cell + Vector2i.RIGHT] = true
		&"mushroom_group":
			var count := _rng.randi_range(Tuning.decor_mushroom_group.x, Tuning.decor_mushroom_group.y)
			for i in count:
				var height := _rng.randf_range(Tuning.decor_mushroom_small.x, Tuning.decor_mushroom_small.y) * (1.25 if i == 0 else 1.0)
				_add_mushroom(at + Vector2((i - (count - 1) * 0.5) * 16.0 + _rng.randf_range(-4.0, 4.0), 0.0), height, false, theme, rng)
		&"crystal":
			var size := _rng.randf_range(Tuning.decor_crystal_size.x, Tuning.decor_crystal_size.y) * (1.0 if free_up >= 2 else 0.6)
			var tips := DecorArt.crystal(_at(decor, at), rng, size, Tuning.decor_crystal_colors.get(theme, Color.WHITE))
			if not tips.is_empty():
				var p := _at(decor, at + tips[0])
				p.transform = p.transform.scaled_local(Vector2.ONE * GLINT_SIZE)
				p.set_motion(Painter.GLINT, rng.randf(), rng.randf_range(Tuning.decor_glint_period.x, Tuning.decor_glint_period.y))
				DecorArt.star(p, Color(1.0, 1.0, 1.0, 0.95))
		&"vent":
			DecorArt.vent(_at(decor, at), rng)
			for k in PUFFS:
				var p := _at(decor, at + Vector2(0.0, -8.0))
				p.transform = p.transform.scaled_local(Vector2.ONE * rng.randf_range(9.0, 14.0))
				p.set_motion(Painter.RISE, (float(k) + rng.randf() * 0.3) / PUFFS, 90.0)
				DecorArt.dot(p, Color(1.0, 0.82, 0.6, 0.3), true)
		&"embers":
			DecorArt.ash(_at(decor, at), rng)
			_add_embers(at, rng)
		_:
			_paint_floor_static(_at(decor, at), kind, theme, cell, free_up)


func _add_embers(at: Vector2, rng: RandomNumberGenerator) -> void:
	for k in EMBERS:
		var p := _at(decor, at + Vector2(rng.randf_range(-10.0, 10.0), -10.0))
		p.transform = p.transform.scaled_local(Vector2.ONE * rng.randf_range(2.0, 3.2))
		p.set_motion(Painter.RISE, (float(k) + rng.randf() * 0.4) / EMBERS, 120.0)
		DecorArt.dot(p, Tuning.decor_ember_color, true)


func _paint_floor_static(p: Painter, kind: StringName, theme: StringName, cell: Vector2i, free_up: int, salt := 1) -> void:
	var rng := _rng_for(cell, salt)
	match kind:
		&"rock", &"frost_rock":
			DecorArt.rock(p, rng, rng.randf_range(Tuning.decor_rock_size.x, Tuning.decor_rock_size.y), kind == &"frost_rock")
		&"pebbles":
			DecorArt.pebbles(p, rng)
		&"bones":
			DecorArt.bones(p, rng)
		&"roots":
			DecorArt.roots(p, rng, Tuning.decor_root_color)
		&"dead_roots":
			DecorArt.roots(p, rng, Tuning.decor_dead_root_color)
		&"stalagmite":
			var h := rng.randf_range(Tuning.decor_stalagmite_size.x, Tuning.decor_stalagmite_size.y) * (1.0 if free_up >= 2 else 0.6)
			var color := Tuning.decor_ice_color if theme == &"cold" else Tuning.decor_rock_colors[rng.randi() % Tuning.decor_rock_colors.size()]
			DecorArt.stalagmite(p, rng, Vector2(h * 0.95, h), color)
		&"puddle":
			DecorArt.puddle(p, rng, Tuning.decor_ice_color if theme == &"cold" else Tuning.decor_puddle_color)
		&"moss":
			DecorArt.moss(p, rng)
		&"ash":
			DecorArt.ash(p, rng)
		&"stump":
			DecorArt.stump(p, rng)
			if rng.randf() < 0.6:
				_add_embers(p.transform.origin, rng)


func _mushroom_height(free_up: int) -> float:
	var mix := Tuning.decor_mushroom_mix
	var roll := _rng.randf() * (mix.x + mix.y + mix.z)
	var range_v := Tuning.decor_mushroom_small
	if roll >= mix.x + mix.y and free_up >= 2:
		range_v = Tuning.decor_mushroom_large
	elif roll >= mix.x:
		range_v = Tuning.decor_mushroom_face
	return maxf(minf(_rng.randf_range(range_v.x, range_v.y), free_up * _tile - 6.0), 12.0)


## Paints a mushroom that squashes around its foot, with a pulsing glow under the cap for some.
func _add_mushroom(at: Vector2, height: float, frozen: bool, theme: StringName, rng: RandomNumberGenerator) -> void:
	var id := reactive.size() + 1
	var palette: Array[Color] = Tuning.decor_frozen_cap_colors if frozen else (Tuning.decor_goal_cap_colors if theme == &"goal" else Tuning.decor_cap_colors)
	var cap_color := palette[rng.randi() % palette.size()]
	var spore := rng.randi() % maxi(Tuning.decor_glow_colors.size(), 1)
	var body := Painter.new()
	body.transform = Transform2D(0.0, at)
	body.set_motion(Painter.SQUASH, 0.0, 0.0, id)
	var glow_at := DecorArt.mushroom(body, rng, height, cap_color, frozen)
	if not frozen and rng.randf() < Tuning.decor_mushroom_glow_chance and not Tuning.decor_glow_colors.is_empty():
		var glow := _at(decor, at + glow_at)
		glow.set_motion(Painter.SQUASH_PULSE, rng.randf(), 0.0, id)
		DecorArt.mushroom_glow(glow, Vector2.ZERO, height * 0.5, Tuning.decor_glow_colors[spore])
	_at(decor, at).append(body.points, body.colors, body.uvs)
	reactive.append({"kind": &"mushroom", "id": id, "pos": at, "height": height, "half": height * 0.5, "spore": spore})


func _place_ceiling(cell: Vector2i) -> void:
	if _clear.has(cell):
		return
	var theme := theme_at(cell.x)
	if _rng.randf() >= _density(theme, "ceiling"):
		return
	var kind := _pick_kind(Tuning.decor_ceiling_kinds.get(theme, {}))
	if kind == &"":
		return
	var gap := _air_run(cell, 1, 40)
	var free_down := _free_run(cell, 1, 6)
	var at := Vector2((cell.x + _rng.randf_range(0.2, 0.8)) * _tile, cell.y * _tile)
	var rng := _rng_for(cell, 2)
	if HANGING_KINDS.has(kind) and gap >= 4:
		var length := minf(_rng.randf_range(Tuning.decor_hang_length.x, Tuning.decor_hang_length.y), minf(gap * _tile * Tuning.decor_hang_max_share, free_down * _tile))
		if length >= 30.0:
			_add_hanging(at, kind, length, rng)
			return
	if kind == &"drip" and gap >= 3:
		var size := Vector2(14.0, rng.randf_range(16.0, 26.0))
		DecorArt.stalactite(_at(decor, at), rng, size, Tuning.decor_rock_colors[0])
		var p := _at(decor, at + Vector2(0.0, size.y * 0.9 + 2.0))
		p.transform = p.transform.scaled_local(Vector2(2.4, 3.4))
		p.set_motion(Painter.DROP, rng.randf(), gap * _tile - size.y - 8.0)
		DecorArt.dot(p, Tuning.decor_drop_color, false)
		return
	var scale := 1.0 if gap >= 3 else 0.55
	if kind == &"icicle" or theme == &"cold":
		DecorArt.icicle(_at(decor, at), rng, Tuning.decor_icicle_size * scale)
	else:
		var h := rng.randf_range(Tuning.decor_stalactite_size.x, Tuning.decor_stalactite_size.y) * scale
		DecorArt.stalactite(_at(decor, at), rng, Vector2(h * 0.95, h), Tuning.decor_rock_colors[rng.randi() % Tuning.decor_rock_colors.size()])


## A root, vine or glow worm hangs straight in the mesh; the shader bends it by the depth of each point.
func _add_hanging(at: Vector2, kind: StringName, length: float, rng: RandomNumberGenerator) -> void:
	var id := reactive.size() + 1
	var phase := rng.randf()
	var seg_len := length / HANG_SEGMENTS
	for k in HANG_SEGMENTS:
		var p := _at(decor, at + Vector2(0.0, seg_len * k))
		p.set_motion(Painter.SWAY, phase, 0.0, id, at.y)
		DecorArt.hanging_segment(p, rng, kind, seg_len, lerpf(7.0, 2.0, float(k) / HANG_SEGMENTS), lerpf(7.0, 2.0, float(k + 1) / HANG_SEGMENTS))
	if kind == &"glow_worm":
		var bulb := _at(decor, at + Vector2(0.0, length))
		bulb.set_motion(Painter.SWAY_PULSE, phase, 0.0, id, at.y)
		DecorArt.glow_bulb(bulb, Tuning.decor_glow_worm_colors[rng.randi() % Tuning.decor_glow_worm_colors.size()], rng.randf_range(4.0, 6.5))
	reactive.append({"kind": &"hanging", "id": id, "pos": at, "length": length})


func _place_walls() -> void:
	for x in _size.x:
		for y in _size.y:
			var cell := Vector2i(x, y)
			if not _solid.has(cell):
				continue
			for side: int in [-1, 1]:
				var air := cell + Vector2i(side, 0)
				if not _is_air(air) or _clear.has(air):
					continue
				var theme := theme_at(air.x)
				if _rng.randf() >= _density(theme, "wall"):
					continue
				var kind := _pick_kind(Tuning.decor_wall_kinds.get(theme, {}))
				if kind == &"":
					continue
				# A shelf right above a floor would read as a step, so it becomes a crack there.
				if kind == &"shelf" and (_solid.has(air + Vector2i.DOWN) or _clear.has(air + Vector2i.UP)):
					kind = &"crack"
				var face_x := (cell.x + (1 if side > 0 else 0)) * _tile
				var p := _at(decor, Vector2(face_x, (y + _rng.randf_range(0.25, 0.75)) * _tile))
				DecorArt.wall_piece(p, _rng_for(cell, 4 + side), kind, float(side), theme)


## Far silhouettes stand on floors and hang from ceilings at the spacing of the theme; near shapes hang a short way
## from the ceilings of tall rooms, high above any path of the slime. Both are opaque, so they cost no blending.
func _place_back_and_front() -> void:
	var next_back := {}
	var next_front := {}
	for x in _size.x:
		for y in _size.y:
			var cell := Vector2i(x, y)
			if not _is_air(cell):
				continue
			var theme := theme_at(x)
			var floor_here := _solid.has(cell + Vector2i.DOWN)
			var ceiling_here := _solid.has(cell + Vector2i.UP)
			if not floor_here and not ceiling_here:
				continue
			var key := Vector2i(y, 1 if floor_here else 0)
			var spacing := _density(theme, "back")
			if spacing > 0.0 and x >= int(next_back.get(key, -1)):
				var room := _air_run(cell, -1 if floor_here else 1, 12)
				if room >= 3:
					next_back[key] = x + int(spacing * _rng.randf_range(0.7, 1.4)) + 1
					var height := minf(_rng.randf_range(Tuning.decor_back_height.x, Tuning.decor_back_height.y), room * _tile * 0.85)
					var base := Vector2((x + _rng.randf_range(0.0, 1.0)) * _tile, (y + 1) * _tile if floor_here else y * _tile)
					var color: Color = Tuning.decor_back_colors.get(theme, Color(0.1, 0.08, 0.15))
					DecorArt.silhouette(_at(back, base, Tuning.decor_back_feather), _rng_for(cell, 5), height, color.lightened(_rng.randf_range(-0.04, 0.06)), not floor_here)
			var front_spacing := _density(theme, "front")
			if not ceiling_here or front_spacing <= 0.0 or x < int(next_front.get(key, -1)):
				continue
			if _air_run(cell, 1, 20) < Tuning.decor_front_min_room or not _front_spot(cell):
				continue
			next_front[key] = x + int(front_spacing * _rng.randf_range(0.8, 1.3)) + 1
			var rng := _rng_for(cell, 6)
			var p := _at(front, Vector2((x + 0.5) * _tile, y * _tile), Tuning.decor_front_feather)
			DecorArt.front_clump(p, rng, rng.randf_range(Tuning.decor_front_hang.x, Tuning.decor_front_hang.y))


## A near clump needs thick rock above it and no wall close by, so it reads as the edge of the cave roof.
func _front_spot(cell: Vector2i) -> bool:
	for dy in range(1, 4):
		if not _solid.has(cell - Vector2i(0, dy)):
			return false
	for dx in range(-FRONT_WALL_CLEAR, FRONT_WALL_CLEAR + 1):
		for dy in 3:
			if _solid.has(cell + Vector2i(dx, dy)):
				return false
	return true


func _seed_of(cell: Vector2i, salt: int) -> int:
	return Tuning.decor_seed * 31 + cell.x * 7919 + cell.y * 104729 + salt * 15485863


func _rng_for(cell: Vector2i, salt: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed_of(cell, salt)
	return rng
