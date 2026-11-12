extends Node2D
## Builds collision, static ground art and entities from an ASCII map.

const GroundRenderer := preload("res://scripts/level/ground_renderer.gd")
const SpikesScene := preload("res://scenes/level/spikes.tscn")
const SawScene := preload("res://scenes/level/saw.tscn")
const CheckpointScene := preload("res://scenes/level/checkpoint.tscn")
const GoalScene := preload("res://scenes/level/goal.tscn")
const HintScene := preload("res://scenes/level/hint.tscn")
const MiteScene := preload("res://scenes/level/mite.tscn")
const BarrierScene := preload("res://scenes/level/barrier.tscn")
const PropArt := preload("res://scripts/props/prop_art.gd")
const HeatZone := preload("res://scripts/level/heat_zone.gd")
const ColdZone := preload("res://scripts/level/cold_zone.gd")
const FireZone := preload("res://scripts/level/fire_zone.gd")
const Grate := preload("res://scripts/level/grate.gd")
const Pipe := preload("res://scripts/level/pipe.gd")
const TemperatureArt := preload("res://scripts/level/temperature_art.gd")
const DecorLayout := preload("res://scripts/level/decor_layout.gd")
const DecorLayer := preload("res://scripts/level/decor_layer.gd")
const DecorLive := preload("res://scripts/level/decor_live.gd")

const PLANK_THICKNESS := 14.0
const PLANK_MARGIN := 8.0
## Map glyphs that place an entity on a cell, so the ground art keeps that cell free of decor.
const ENTITY_GLYPHS := "^CGo|PrkmBbHf"
const PROP_GLYPHS := {"r": &"rock", "k": &"crystal"}
## Solid glyphs with their own surface: the ground art tints them and the player reads the floor from the body meta.
const SURFACE_GLYPHS := {"W": &"warm", "I": &"ice"}
## Decoration keeps this many cells away from entities, around hint texts and around the goal and checkpoints.
const DECOR_ENTITY_MARGIN := 1
const DECOR_HINT_MARGIN := Vector2i(4, 1)
const DECOR_GOAL_MARGIN := Vector2i(4, 3)
const DECOR_CHECKPOINT_MARGIN := Vector2i(2, 2)
## Draw order of the near decoration: over the goo (z 1) and the face, under the screen layers.
const DECOR_FRONT_Z := 3
## Flames reach a little less high than their cell, and in from its sides, so a jump over them clears them.
const FLAME_HIT_INSET := Vector2(6.0, 14.0)

var tile := 64.0
var size_cells := Vector2i.ZERO
var start_position := Vector2.ZERO
var bounds := Rect2()
## Loose props the level places: {"kind", "seed", "home"} with home the resting point on the floor of the cell.
var prop_spawns: Array[Dictionary] = []
var _markers := {}
var _art: Node2D


func build(level: GDScript) -> void:
	_clear()
	tile = Tuning.tile_size
	if level == null:
		push_error("LevelBuilder: no level script")
		return
	var constants := level.get_script_constant_map()
	var map: Array = constants.get("MAP", [])
	if map.is_empty():
		push_error("LevelBuilder: the level has no MAP rows")
		return
	var width := 0
	for row: String in map:
		width = maxi(width, row.length())
	size_cells = Vector2i(width, map.size())
	bounds = Rect2(Vector2.ZERO, Vector2(size_cells) * tile)
	start_position = Vector2(bounds.size.x * 0.5, tile * 0.5)
	var solid := {}
	var blocked := {}
	var one_way: Array[Vector2i] = []
	var checkpoints: Array[Vector2i] = []
	var barrier_cells: Array[Vector2i] = []
	var mites: Array[Vector2i] = []
	var surfaces := {}
	var grate_cells: Array[Vector2i] = []
	var flame_cells: Array[Vector2i] = []
	var plug_cells: Array[Vector2i] = []
	var decor_low := {}
	for y in map.size():
		var row: String = map[y]
		for x in row.length():
			var cell := Vector2i(x, y)
			var glyph := row[x]
			if ENTITY_GLYPHS.contains(glyph):
				blocked[cell] = true
			match glyph:
				"#":
					solid[cell] = true
				"W", "I":
					solid[cell] = true
					surfaces[cell] = SURFACE_GLYPHS[glyph]
				"H":
					grate_cells.append(cell)
				"f":
					flame_cells.append(cell)
				"b":
					plug_cells.append(cell)
				"=":
					one_way.append(cell)
				"P":
					start_position = cell_center(cell)
				"C":
					checkpoints.append(cell)
				"G":
					_spawn_goal(cell)
				"o":
					var patrol := _spawn_saw(cell, row)
					for px in range(patrol.x, patrol.y + 1):
						blocked[Vector2i(px, y)] = true
				"r", "k":
					_add_prop(cell, PROP_GLYPHS[glyph])
				"B":
					barrier_cells.append(cell)
				"m":
					mites.append(cell)
	for cell: Vector2i in mites:
		var walk := _mite_range(cell, map, solid)
		for px in range(walk.x, walk.y + 1):
			decor_low[Vector2i(px, cell.y)] = true
	var decor := DecorLayout.new()
	decor.build(solid, size_cells, tile, _decor_clear(map, blocked, one_way, constants), decor_low, constants.get("DECOR_THEMES", []))
	var decor_material := DecorLive.make_material()
	var back := DecorLayer.new()
	back.name = "DecorBack"
	add_child(back)
	move_child(back, 0)
	back.setup(decor.back, Tuning.decor_back_parallax, bounds.get_center())
	var renderer := GroundRenderer.new()
	renderer.name = "Ground"
	add_child(renderer)
	move_child(renderer, 1)
	renderer.call("setup", solid, one_way, size_cells, tile, blocked, surfaces, decor.decor, decor_material, Tuning.decor_section_cells)
	_art = TemperatureArt.new()
	_art.name = "TemperatureArt"
	add_child(_art)
	move_child(_art, 2)
	var live := DecorLive.new()
	live.name = "DecorLive"
	add_child(live)
	move_child(live, 3)
	live.setup(decor_material, decor.reactive)
	var front := DecorLayer.new()
	front.name = "DecorFront"
	front.z_index = DECOR_FRONT_Z
	add_child(front)
	front.setup(decor.front, Vector2.ZERO, Vector2.ZERO)
	_build_solids(solid, surfaces)
	_build_one_way(one_way)
	_spawn_spikes(map)
	_spawn_checkpoints(checkpoints)
	_spawn_barriers(barrier_cells)
	_spawn_plugs(plug_cells)
	# Registration order is draw order: the room looks first, then the pipes, grates and flames over them.
	_spawn_zones(constants.get("ZONES", []))
	_spawn_pipes(constants.get("PIPES", []))
	_spawn_grates(grate_cells)
	_spawn_flames(flame_cells)
	for cell: Vector2i in mites:
		_spawn_mite(cell, map, solid)
	var hints: Dictionary = constants.get("HINTS", {})
	if not Harness.hide_hints:
		for cell: Vector2i in hints:
			var hint := HintScene.instantiate() as Node2D
			hint.position = cell_center(cell)
			add_child(hint)
			hint.call("setup", hints[cell])
	_markers[&"start"] = start_position
	var markers: Dictionary = constants.get("MARKERS", {})
	for marker_name: StringName in markers:
		_markers[marker_name] = cell_center(markers[marker_name])


func cell_center(cell: Vector2i) -> Vector2:
	return (Vector2(cell) + Vector2(0.5, 0.5)) * tile


## Accepts a marker name ("ledge", "cp1") or tile coordinates ("46,13").
func marker_position(marker: String) -> Vector2:
	if _is_cell_text(marker):
		var parts := marker.split(",")
		return cell_center(Vector2i(parts[0].strip_edges().to_int(), parts[1].strip_edges().to_int()))
	var key := StringName(marker)
	if not _markers.has(key):
		push_warning("LevelBuilder: unknown marker '%s', using the start" % marker)
		return start_position
	return _markers[key]


func has_marker(marker: String) -> bool:
	return _is_cell_text(marker) or _markers.has(StringName(marker))


func marker_names() -> PackedStringArray:
	var names := PackedStringArray()
	for key: StringName in _markers:
		names.append(String(key))
	return names


func _is_cell_text(text: String) -> bool:
	var parts := text.split(",")
	return parts.size() == 2 and parts[0].strip_edges().is_valid_int() and parts[1].strip_edges().is_valid_int()


func _clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_markers.clear()
	prop_spawns.clear()
	size_cells = Vector2i.ZERO
	start_position = Vector2.ZERO
	bounds = Rect2()


## Plain rock is one body; each surface (ice, warm rock) is a body of its own with meta "surface", so the player
## can tell what it stands on.
func _build_solids(solid: Dictionary, surfaces: Dictionary) -> void:
	var groups := {&"": {}}
	for cell: Vector2i in solid:
		var surface: StringName = surfaces.get(cell, &"")
		if not groups.has(surface):
			groups[surface] = {}
		groups[surface][cell] = true
	for surface: StringName in groups:
		var body := StaticBody2D.new()
		body.name = "Solids" if surface == &"" else "Solids_%s" % surface
		body.collision_layer = Tuning.LAYER_WORLD
		body.collision_mask = 0
		if surface != &"":
			body.set_meta(&"surface", surface)
		add_child(body)
		_add_rects(body, groups[surface])


func _add_rects(body: StaticBody2D, solid: Dictionary) -> void:
	for rect in _merge_rects(solid):
		var shape := RectangleShape2D.new()
		shape.size = Vector2(rect.size) * tile
		var cs := CollisionShape2D.new()
		cs.shape = shape
		cs.position = (Vector2(rect.position) + Vector2(rect.size) * 0.5) * tile
		body.add_child(cs)


func _build_one_way(cells: Array[Vector2i]) -> void:
	var body := StaticBody2D.new()
	body.name = "Planks"
	body.collision_layer = Tuning.LAYER_PLATFORMS
	body.collision_mask = 0
	add_child(body)
	for run in _runs(cells):
		var shape := RectangleShape2D.new()
		shape.size = Vector2(run.size.x * tile, PLANK_THICKNESS)
		var cs := CollisionShape2D.new()
		cs.shape = shape
		cs.one_way_collision = true
		cs.one_way_collision_margin = PLANK_MARGIN
		cs.position = Vector2((run.position.x + run.size.x * 0.5) * tile, run.position.y * tile + PLANK_THICKNESS * 0.5)
		body.add_child(cs)


func _spawn_spikes(map: Array) -> void:
	var cells: Array[Vector2i] = []
	for y in map.size():
		var row: String = map[y]
		for x in row.length():
			if row[x] == "^":
				cells.append(Vector2i(x, y))
	for run in _runs(cells):
		var spikes := SpikesScene.instantiate() as Node2D
		spikes.position = Vector2(run.position) * tile
		add_child(spikes)
		spikes.call("setup", run.size.x * tile)


## The saw patrols between the nearest "|" on each side of its cell. A missing end keeps it in place on that side.
## Returns the patrol range in columns.
func _spawn_saw(cell: Vector2i, row: String) -> Vector2i:
	var left := row.rfind("|", cell.x)
	var right := row.find("|", cell.x)
	if left < 0:
		left = cell.x
	if right < 0:
		right = cell.x
	var saw := SawScene.instantiate() as Node2D
	add_child(saw)
	saw.call("setup", cell_center(Vector2i(left, cell.y)), cell_center(Vector2i(right, cell.y)), cell_center(cell))
	return Vector2i(left, right)


func _spawn_checkpoints(cells: Array[Vector2i]) -> void:
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x)
	for i in cells.size():
		var id := StringName("cp%d" % (i + 1))
		var cp := CheckpointScene.instantiate() as Node2D
		cp.position = Vector2(cells[i].x + 0.5, cells[i].y + 1.0) * tile
		add_child(cp)
		cp.call("setup", id, cell_center(cells[i]))
		_markers[id] = cell_center(cells[i])


## The prop rests on the floor of its cell; its seed comes from the cell, so every run draws the same rock.
func _add_prop(cell: Vector2i, kind: StringName) -> void:
	var home := Vector2(cell_center(cell).x, (cell.y + 1) * tile - PropArt.radius_of(kind))
	prop_spawns.append({"kind": kind, "seed": cell.x * 131 + cell.y * 17, "home": home})


## Each vertical run of "B" cells becomes one crystal wall.
func _spawn_barriers(cells: Array[Vector2i]) -> void:
	var set_cells := {}
	for c in cells:
		set_cells[c] = true
	for c in cells:
		if set_cells.has(c - Vector2i(0, 1)):
			continue
		var h := 1
		while set_cells.has(c + Vector2i(0, h)):
			h += 1
		var barrier := BarrierScene.instantiate() as Node2D
		add_child(barrier)
		barrier.call("setup", Rect2(Vector2(c) * tile, Vector2(1, h) * tile))


## Each horizontal run of "b" cells becomes one crystal plug, a barrier lying across a shaft.
func _spawn_plugs(cells: Array[Vector2i]) -> void:
	for run in _runs(cells):
		var plug := BarrierScene.instantiate() as Node2D
		add_child(plug)
		plug.call("setup", Rect2(Vector2(run.position) * tile, Vector2(run.size) * tile))


## Each vertical run of "H" cells becomes one grate.
func _spawn_grates(cells: Array[Vector2i]) -> void:
	for run in _columns(cells):
		var grate := Grate.new()
		grate.name = "Grate"
		add_child(grate)
		grate.call("setup", Rect2(Vector2(run.position) * tile, Vector2(run.size) * tile))
		_art.call("register", grate)


func _spawn_flames(cells: Array[Vector2i]) -> void:
	for run in _runs(cells):
		var flames := FireZone.new()
		flames.name = "Flames"
		add_child(flames)
		flames.call("setup", Rect2(Vector2(run.position) * tile, Vector2(run.size) * tile), FLAME_HIT_INSET)
		_art.call("register", flames)


func _spawn_zones(zones: Array) -> void:
	for zone: Dictionary in zones:
		var script: GDScript = HeatZone if zone.get("kind") == &"heat" else ColdZone
		var node := script.new() as Node2D
		node.name = "Zone_%s" % zone.get("kind")
		add_child(node)
		var cells: Rect2i = zone.get("rect")
		node.call("setup", Rect2(Vector2(cells.position) * tile, Vector2(cells.size) * tile))
		_art.call("register", node)


func _spawn_pipes(pipes: Array) -> void:
	for cells: Array in pipes:
		var pipe := Pipe.new()
		pipe.name = "Pipe"
		add_child(pipe)
		pipe.call("setup", cells, tile)
		_art.call("register", pipe)


## The mite walks the floor under its cell until a wall, a barrier, a drop, spikes or a "|" end on either side.
func _spawn_mite(cell: Vector2i, map: Array, solid: Dictionary) -> void:
	var walk := _mite_range(cell, map, solid)
	var mite := MiteScene.instantiate() as Node2D
	add_child(mite)
	mite.call("setup", cell_center(Vector2i(walk.x, cell.y)), cell_center(Vector2i(walk.y, cell.y)), cell_center(cell))


## The first and last column the mite of this cell walks.
func _mite_range(cell: Vector2i, map: Array, solid: Dictionary) -> Vector2i:
	var left := cell.x
	while _mite_can_walk(Vector2i(left - 1, cell.y), map, solid):
		left -= 1
		if _glyph(map, Vector2i(left, cell.y)) == "|":
			break
	var right := cell.x
	while _mite_can_walk(Vector2i(right + 1, cell.y), map, solid):
		right += 1
		if _glyph(map, Vector2i(right, cell.y)) == "|":
			break
	return Vector2i(left, right)


## Cells where no decoration grows: entities and their neighbours, planks, pipes, the space around hint texts, the
## goal and the checkpoints.
func _decor_clear(map: Array, blocked: Dictionary, one_way: Array[Vector2i], constants: Dictionary) -> Dictionary:
	var clear := {}
	for cell: Vector2i in blocked:
		for dx in range(-DECOR_ENTITY_MARGIN, DECOR_ENTITY_MARGIN + 1):
			clear[cell + Vector2i(dx, 0)] = true
		match _glyph(map, cell):
			"G":
				_mark_box(clear, cell, DECOR_GOAL_MARGIN)
			"C":
				_mark_box(clear, cell, DECOR_CHECKPOINT_MARGIN)
	for cell in one_way:
		clear[cell] = true
	var hints: Dictionary = constants.get("HINTS", {})
	for cell: Vector2i in hints:
		_mark_box(clear, cell, DECOR_HINT_MARGIN)
	for pipe: Array in constants.get("PIPES", []):
		for cell: Vector2i in pipe:
			_mark_box(clear, cell, Vector2i.ONE)
	return clear


## Marks the cells within margin of cell, and up to margin.y cells above it.
func _mark_box(cells: Dictionary, cell: Vector2i, margin: Vector2i) -> void:
	for dx in range(-margin.x, margin.x + 1):
		for dy in range(-margin.y, mini(margin.y, 1) + 1):
			cells[cell + Vector2i(dx, dy)] = true


func _mite_can_walk(cell: Vector2i, map: Array, solid: Dictionary) -> bool:
	if solid.has(cell) or not solid.has(cell + Vector2i(0, 1)):
		return false
	var glyph := _glyph(map, cell)
	return glyph != "B" and glyph != "^" and glyph != "f" and glyph != "H"


func _glyph(map: Array, cell: Vector2i) -> String:
	if cell.y < 0 or cell.y >= map.size():
		return ""
	var row: String = map[cell.y]
	if cell.x < 0 or cell.x >= row.length():
		return ""
	return row[cell.x]


func _spawn_goal(cell: Vector2i) -> void:
	var goal := GoalScene.instantiate() as Node2D
	goal.position = Vector2(cell.x + 0.5, cell.y + 1.0) * tile
	add_child(goal)
	_markers[&"goal"] = cell_center(cell)


## Horizontal runs of cells on the same row, as Rect2i in cell units (height 1).
func _runs(cells: Array[Vector2i]) -> Array[Rect2i]:
	var set_cells := {}
	for c in cells:
		set_cells[c] = true
	var out: Array[Rect2i] = []
	for c in cells:
		if set_cells.has(c - Vector2i(1, 0)):
			continue
		var w := 1
		while set_cells.has(c + Vector2i(w, 0)):
			w += 1
		out.append(Rect2i(c, Vector2i(w, 1)))
	return out


## Vertical runs of cells on the same column, as Rect2i in cell units (width 1).
func _columns(cells: Array[Vector2i]) -> Array[Rect2i]:
	var set_cells := {}
	for c in cells:
		set_cells[c] = true
	var out: Array[Rect2i] = []
	for c in cells:
		if set_cells.has(c - Vector2i(0, 1)):
			continue
		var h := 1
		while set_cells.has(c + Vector2i(0, h)):
			h += 1
		out.append(Rect2i(c, Vector2i(1, h)))
	return out


## Greedy merge of solid cells into large rectangles, so the slime does not catch on seams.
func _merge_rects(cells: Dictionary) -> Array[Rect2i]:
	var used := {}
	var rects: Array[Rect2i] = []
	for y in size_cells.y:
		for x in size_cells.x:
			var p := Vector2i(x, y)
			if not cells.has(p) or used.has(p):
				continue
			var w := 1
			while cells.has(Vector2i(x + w, y)) and not used.has(Vector2i(x + w, y)):
				w += 1
			var h := 1
			var grow := true
			while grow and y + h < size_cells.y:
				for i in w:
					var q := Vector2i(x + i, y + h)
					if not cells.has(q) or used.has(q):
						grow = false
						break
				if grow:
					h += 1
			for yy in h:
				for xx in w:
					used[Vector2i(x + xx, y + yy)] = true
			rects.append(Rect2i(x, y, w, h))
	return rects
