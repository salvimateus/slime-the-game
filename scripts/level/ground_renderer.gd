extends Node2D
## Draws the static terrain one time: textured fill, depth shading, crust lips, outlines, planks, surface marks and
## the decoration that the decor layout painted.
## The textured fill is one mesh. The overlay (ground lines, decoration and planks, drawn with decor.gdshader so the
## decoration can move on the GPU) is cut into sections of columns, one mesh each; the renderer skips the sections off
## screen, so a view costs two or three draw calls.

const GROUND_TEXTURE := "res://art/textures/ground.png"
const DECOR_SEED := 1337
const MeshSection := preload("res://scripts/level/mesh_section.gd")
const Painter := preload("res://scripts/level/decor_painter.gd")
const SIDES: Array[Vector2i] = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
const LIP_STEP := 8.0
const PLANK_HEIGHT := 14.0
const CIRCLE_SEGMENTS := 12
const FALLBACK_SIZE := 256
## Rows of a fill block; its columns are the section width.
const FILL_BLOCK_ROWS := 12

var _solid := {}
var _one_way: Array[Vector2i] = []
var _blocked := {}
## Cell -> surface name (&"warm", &"ice") for cells with their own tint and lip.
var _surfaces := {}
## Grid corners near a warm or ice cell; the other corners keep the plain rock tint at no cost.
var _surface_corners := {}
var _size := Vector2i.ZERO
var _tile := 64.0
var _tex: Texture2D
var _depth := {}
var _rng := RandomNumberGenerator.new()
var _wave_phase := 0.0
var _verts := PackedVector2Array()
var _colors := PackedColorArray()
var _section_cells := 48


## blocked holds cells with entities on them (spikes, checkpoints, goal, saws), where no surface mark goes.
## surfaces maps solid cells to &"warm" or &"ice"; those cells get their own tint, lip and marks.
## decor: section index -> DecorPainter, drawn over the lips and under the planks of that section with decor_material.
## Sections are section_cells columns wide, the same cut as the decor layout.
func setup(solid: Dictionary, one_way: Array[Vector2i], size: Vector2i, tile: float, blocked := {}, surfaces := {}, decor := {}, decor_material: Material = null, section_cells := 48) -> void:
	_section_cells = maxi(section_cells, 1)
	_solid = solid
	_one_way = one_way
	_blocked = blocked
	_surfaces = surfaces
	_surface_corners.clear()
	var reach := maxi(Tuning.surface_tint_blend_cells, 1)
	for c: Vector2i in surfaces:
		for y: int in range(c.y, c.y + 2):
			for x: int in range(c.x - reach + 1, c.x + reach + 1):
				_surface_corners[Vector2i(x, y)] = true
	_size = size
	_tile = maxf(tile, 1.0)
	_rng.seed = DECOR_SEED
	_wave_phase = _rng.randf() * TAU
	_tex = _load_ground_texture()
	_depth.clear()
	_compute_depth()
	_build_sections(decor, decor_material)


func _build_sections(decor: Dictionary, decor_material: Material) -> void:
	var cells := {}
	for p: Vector2i in _solid:
		var index := floori(float(p.x) / _section_cells)
		if not cells.has(index):
			cells[index] = [] as Array[Vector2i]
		(cells[index] as Array[Vector2i]).append(p)
	var planks := {}
	for run in _plank_runs():
		var index := floori(float(run.position.x) / _section_cells)
		if not planks.has(index):
			planks[index] = [] as Array[Rect2i]
		(planks[index] as Array[Rect2i]).append(run)
	var indices := {}
	for key: int in cells:
		indices[key] = true
	for key: int in decor:
		indices[key] = true
	for key: int in planks:
		indices[key] = true
	var order := indices.keys()
	order.sort()
	# The fill quads never overlap, so the fill is cut in blocks of section columns by FILL_BLOCK_ROWS rows: a view
	# draws only the blocks it touches. The overlay holds the decoration, whose draw order matters, and is cut in
	# column sections only.
	var blocks := {}
	for p: Vector2i in _solid:
		var key := Vector2i(floori(float(p.x) / _section_cells), floori(float(p.y) / FILL_BLOCK_ROWS))
		if not blocks.has(key):
			blocks[key] = [] as Array[Vector2i]
		(blocks[key] as Array[Vector2i]).append(p)
	var fill := Node2D.new()
	fill.name = "Fill"
	add_child(fill)
	for key: Vector2i in blocks:
		var mesh := _build_fill_mesh(blocks[key])
		if mesh:
			var block := MeshSection.new()
			block.name = "Fill_%d_%d" % [key.x, key.y]
			fill.add_child(block)
			block.setup(mesh, _tex, null, true)
	var overlays: Array[ArrayMesh] = []
	for index: int in order:
		var section_cells: Array[Vector2i] = cells.get(index, [] as Array[Vector2i])
		var section_planks: Array[Rect2i] = planks.get(index, [] as Array[Rect2i])
		overlays.append(_build_overlay_mesh(section_cells, decor.get(index), section_planks))
	for k in overlays.size():
		if overlays[k] == null:
			continue
		var node := MeshSection.new()
		node.name = "Overlay_%d" % order[k]
		add_child(node)
		node.setup(overlays[k], null, decor_material)


func _load_ground_texture() -> Texture2D:
	if ResourceLoader.exists(GROUND_TEXTURE, "Texture2D"):
		var res := load(GROUND_TEXTURE)
		if res is Texture2D:
			return res
	return _fallback_texture()


# Keeps the level readable before the painted texture is imported.
func _fallback_texture() -> Texture2D:
	var noise := FastNoiseLite.new()
	noise.seed = 3
	noise.frequency = 0.02
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.7, 0.7, 0.7))
	ramp.set_color(1, Color(1.0, 1.0, 1.0))
	var tex := NoiseTexture2D.new()
	tex.width = FALLBACK_SIZE
	tex.height = FALLBACK_SIZE
	tex.seamless = true
	tex.noise = noise
	tex.color_ramp = ramp
	tex.changed.connect(queue_redraw, CONNECT_ONE_SHOT)
	return tex


func _compute_depth() -> void:
	var frontier: Array[Vector2i] = []
	for p: Vector2i in _solid:
		if _is_exposed(p):
			_depth[p] = 0
			frontier.append(p)
	while not frontier.is_empty():
		var next: Array[Vector2i] = []
		for p in frontier:
			for d in SIDES:
				var q: Vector2i = p + d
				if _solid.has(q) and not _depth.has(q):
					_depth[q] = int(_depth[p]) + 1
					next.append(q)
		frontier = next


func _is_exposed(p: Vector2i) -> bool:
	for d in SIDES:
		if _is_air(p + d):
			return true
	return false


## Empty and inside the map. Cells outside the map count as rock, so the border gets no outline.
func _is_air(q: Vector2i) -> bool:
	return q.x >= 0 and q.y >= 0 and q.x < _size.x and q.y < _size.y and not _solid.has(q)


func _shade(depth: float) -> float:
	return maxf(pow(Tuning.ground_shade_step, depth), Tuning.ground_shade_min)


## Mean depth of the solid cells around a grid corner, so the shading blends across cells.
func _corner_depth(v: Vector2i) -> float:
	var total := 0.0
	var count := 0
	for c: Vector2i in [v + Vector2i(-1, -1), v + Vector2i(0, -1), v + Vector2i(-1, 0), v]:
		if _depth.has(c):
			total += float(_depth[c])
			count += 1
	return total / float(count) if count > 0 else 0.0


func _build_fill_mesh(cells: Array[Vector2i]) -> ArrayMesh:
	var verts := PackedVector2Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv_scale := 1.0 / maxf(Tuning.ground_texture_world_size, 1.0)
	var corners: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 0), Vector2i(1, 1), Vector2i(0, 1)]
	# A grid corner is shared by up to four cells and six vertices; its shade is computed one time.
	var shades := {}
	for p in cells:
		for k in corners:
			var v := p + k
			var world := Vector2(v) * _tile
			var c: Variant = shades.get(v)
			if c == null:
				var depth := _corner_depth(v)
				var s := _shade(depth)
				c = _corner_tint(v, depth) * Color(s, s, s)
				shades[v] = c
			verts.append(world)
			colors.append(c)
			uvs.append(world * uv_scale)
	return _make_mesh(verts, colors, uvs)


## Rock tint at a grid corner. A warm or ice surface blends into the plain rock along the rows over the solid cells
## beside the corner (Tuning.surface_tint_blend_cells on each side) and fades with the depth below the surface, so a
## temperature room has no hard tint edge in the rock.
func _corner_tint(v: Vector2i, depth: float) -> Color:
	var base := Tuning.ground_tint
	if not _surface_corners.has(v):
		return base
	var reach := maxi(Tuning.surface_tint_blend_cells, 1)
	var warm := 0
	var ice := 0
	var solid := 0
	for y: int in range(v.y - 1, v.y + 1):
		for x: int in range(v.x - reach, v.x + reach):
			var c := Vector2i(x, y)
			if not _solid.has(c):
				continue
			solid += 1
			match _surfaces.get(c, &""):
				&"warm":
					warm += 1
				&"ice":
					ice += 1
	if solid == 0 or warm + ice == 0:
		return base
	var fade := 1.0 - smoothstep(Tuning.surface_tint_depth.x, Tuning.surface_tint_depth.y, depth)
	var tint := base.lerp(base * Tuning.heat_rock_tint, fade * float(warm) / solid)
	return tint.lerp(base.lerp(Tuning.ice_rock_tint, 0.85), fade * float(ice) / solid)


func _lip_color_of(p: Vector2i) -> Color:
	match _surfaces.get(p, &""):
		&"warm":
			return Tuning.heat_lip_color
		&"ice":
			return Tuning.ice_lip_color
	return Tuning.ground_lip_color


func _build_overlay_mesh(cells: Array[Vector2i], decor: Painter, plank_runs: Array[Rect2i]) -> ArrayMesh:
	_verts = PackedVector2Array()
	_colors = PackedColorArray()
	var tops: Array[Vector2i] = []
	for p in cells:
		_add_side_outlines(p)
		if _is_air(p + Vector2i.UP):
			tops.append(p)
	for p in tops:
		_add_lip(p)
	for p in tops:
		_add_lip_details(p)
	for p in tops:
		_add_decor(p)
	var lines := Painter.new()
	lines.append(_verts, _colors, PackedVector2Array())
	if decor:
		lines.append(decor.points, decor.colors, decor.uvs)
	_verts = PackedVector2Array()
	_colors = PackedColorArray()
	for run in plank_runs:
		_add_plank(run)
	lines.append(_verts, _colors, PackedVector2Array())
	_verts = PackedVector2Array()
	_colors = PackedColorArray()
	return Painter.make_mesh(lines.points, lines.colors, lines.uvs)


func _make_mesh(verts: PackedVector2Array, colors: PackedColorArray, uvs: PackedVector2Array) -> ArrayMesh:
	if verts.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	if not uvs.is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _add_side_outlines(p: Vector2i) -> void:
	var o := Vector2(p) * _tile
	var w := Tuning.ground_outline_width
	var c := Tuning.ground_outline_color
	if _is_air(p + Vector2i.LEFT):
		_rect(Rect2(o.x, o.y, w, _tile), c)
	if _is_air(p + Vector2i.RIGHT):
		_rect(Rect2(o.x + _tile - w, o.y, w, _tile), c)
	if _is_air(p + Vector2i.DOWN):
		_rect(Rect2(o.x, o.y + _tile - w, _tile, w), c)


func _lip_y(world_x: float, top: float) -> float:
	return top + Tuning.ground_lip_depth + Tuning.ground_lip_wave * sin(world_x * Tuning.ground_lip_wave_freq + _wave_phase)


func _add_lip(p: Vector2i) -> void:
	var o := Vector2(p) * _tile
	var steps := maxi(int(ceil(_tile / LIP_STEP)), 1)
	var lip := _lip_color_of(p)
	var shadow := Tuning.ground_lip_shadow
	var highlight := lip.lightened(0.3)
	for i in steps:
		var x0 := o.x + _tile * float(i) / steps
		var x1 := o.x + _tile * float(i + 1) / steps
		var y0 := _lip_y(x0, o.y)
		var y1 := _lip_y(x1, o.y)
		_quad(Vector2(x0, o.y), Vector2(x1, o.y), Vector2(x1, y1), Vector2(x0, y0), lip)
		_quad(Vector2(x0, y0), Vector2(x1, y1), Vector2(x1, y1 + Tuning.ground_lip_shadow_size), Vector2(x0, y0 + Tuning.ground_lip_shadow_size), shadow)
	_rect(Rect2(o.x, o.y + Tuning.ground_outline_width * 0.5, _tile, 2.0), highlight)
	_rect(Rect2(o.x, o.y - Tuning.ground_outline_width * 0.5, _tile, Tuning.ground_outline_width), Tuning.ground_outline_color)


## Rounded outer corners and crust drips that hang from the lip.
func _add_lip_details(p: Vector2i) -> void:
	var o := Vector2(p) * _tile
	var lip := _lip_color_of(p)
	var outline := Tuning.ground_outline_color
	for side: int in [-1, 1]:
		var neighbor := p + Vector2i(side, 0)
		if not _is_air(neighbor):
			continue
		var corner := Vector2(o.x if side < 0 else o.x + _tile, o.y + Tuning.ground_corner_radius)
		_circle(corner, Tuning.ground_corner_radius + Tuning.ground_outline_width * 0.5, outline)
		_circle(corner, Tuning.ground_corner_radius, lip)
	if _rng.randf() < Tuning.ground_drip_chance:
		var x := o.x + _rng.randf_range(10.0, _tile - 10.0)
		var length := _rng.randf_range(6.0, 14.0)
		var top := _lip_y(x, o.y) - 1.0
		var r := _rng.randf_range(3.0, 4.5)
		_circle(Vector2(x, top + length + Tuning.ground_lip_shadow_size), r, Tuning.ground_lip_shadow)
		_rect(Rect2(x - r * 0.6, top, r * 1.2, length), lip)
		_circle(Vector2(x, top + length), r, lip)


func _add_decor(p: Vector2i) -> void:
	if not _surfaces.has(p) or _blocked.has(p + Vector2i.UP) or _rng.randf() >= Tuning.ground_surface_mark_chance:
		return
	_add_surface_decor(p)


## Warm rock gets a glowing crack, ice a pale glint streak.
func _add_surface_decor(p: Vector2i) -> void:
	var o := Vector2(p) * _tile
	var x := o.x + _rng.randf_range(10.0, _tile - 10.0)
	var top := o.y + Tuning.ground_lip_depth + 4.0
	if _surfaces[p] == &"warm":
		var a := Vector2(x, top)
		var b := a + Vector2(_rng.randf_range(-8.0, 8.0), _rng.randf_range(10.0, 16.0))
		var c := b + Vector2(_rng.randf_range(-8.0, 8.0), _rng.randf_range(8.0, 14.0))
		for seg: Array in [[a, b], [b, c]]:
			_line(seg[0], seg[1], 4.0, Tuning.ground_outline_color)
			_line(seg[0], seg[1], 2.0, Tuning.heat_vent_glow)
	else:
		var length := _rng.randf_range(10.0, 20.0)
		_line(Vector2(x, top + 6.0), Vector2(x + length, top + 6.0 + length * 0.5), 2.5, Color(1.0, 1.0, 1.0, 0.55))


func _line(a: Vector2, b: Vector2, width: float, color: Color) -> void:
	var n := (b - a).normalized().orthogonal() * width * 0.5
	_quad(a - n, b - n, b + n, a + n, color)


func _plank_runs() -> Array[Rect2i]:
	var cells := {}
	for c in _one_way:
		cells[c] = true
	var runs: Array[Rect2i] = []
	for c in _one_way:
		if cells.has(c - Vector2i(1, 0)):
			continue
		var w := 1
		while cells.has(c + Vector2i(w, 0)):
			w += 1
		runs.append(Rect2i(c, Vector2i(w, 1)))
	return runs


## Collision sits on the top 14 px of the cell, so the plank art matches it exactly.
func _add_plank(run: Rect2i) -> void:
	var x0 := run.position.x * _tile
	var x1 := (run.position.x + run.size.x) * _tile
	var y := run.position.y * _tile
	var h := PLANK_HEIGHT
	var r := h * 0.5
	var shadow := Color(0.0, 0.0, 0.0, 0.22)
	_rect(Rect2(x0 + 6.0, y + h, x1 - x0 - 12.0, Tuning.ground_plank_shadow_size * 0.5), shadow)
	_rect(Rect2(x0 + 10.0, y + h + Tuning.ground_plank_shadow_size * 0.5, x1 - x0 - 20.0, Tuning.ground_plank_shadow_size * 0.5), Color(shadow, 0.1))
	_capsule(x0 + r, x1 - r, y + r, r + 1.5, Tuning.ground_outline_color)
	_capsule(x0 + r, x1 - r, y + r, r, Tuning.plank_color)
	_rect(Rect2(x0 + r, y + 2.0, x1 - x0 - h, 2.0), Tuning.plank_color.lightened(0.3))
	_rect(Rect2(x0 + r, y + h * 0.62, x1 - x0 - h, 1.0), Tuning.plank_color.darkened(0.25))
	for i in run.size.x:
		var tile_x := x0 + i * _tile
		_circle(Vector2(tile_x + _tile * 0.25, y + r), 2.0, Tuning.ground_outline_color)
		_circle(Vector2(tile_x + _tile * 0.75, y + r), 2.0, Tuning.ground_outline_color)


func _capsule(x0: float, x1: float, cy: float, r: float, color: Color) -> void:
	_rect(Rect2(x0, cy - r, maxf(x1 - x0, 0.0), r * 2.0), color)
	_circle(Vector2(x0, cy), r, color)
	_circle(Vector2(x1, cy), r, color)


func _rect(rect: Rect2, color: Color) -> void:
	_quad(rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y), color)


func _quad(a: Vector2, b: Vector2, c: Vector2, d: Vector2, color: Color) -> void:
	_verts.append_array(PackedVector2Array([a, b, c, a, c, d]))
	for i in 6:
		_colors.append(color)


func _circle(center: Vector2, r: float, color: Color) -> void:
	_arc_fan(center, r, 0.0, TAU, CIRCLE_SEGMENTS, color)


func _arc_fan(center: Vector2, r: float, from: float, to: float, segments: int, color: Color) -> void:
	for i in segments:
		var a0 := lerpf(from, to, float(i) / segments)
		var a1 := lerpf(from, to, float(i + 1) / segments)
		_verts.append_array(PackedVector2Array([center, center + Vector2.from_angle(a0) * r, center + Vector2.from_angle(a1) * r]))
		_colors.append(color)
		_colors.append(color)
		_colors.append(color)
