extends Node2D
## A static decoration layer: one mesh, or one mesh per section of columns so the renderer skips those off screen. A layer with parallax slides by a share
## of the camera travel away from the level centre, so it seems farther (share > 0) than the play layer; that costs
## one transform write per frame.

const MeshSection := preload("res://scripts/level/mesh_section.gd")
const Painter := preload("res://scripts/level/decor_painter.gd")

var parallax := Vector2.ZERO
## Microseconds of the last _process, for the performance measurements.
var last_process_usec := 0
var _anchor := Vector2.ZERO


## sections: section index -> Painter. merge puts every section into one mesh (one draw call for a light layer).
func setup(sections: Dictionary, layer_parallax: Vector2, anchor: Vector2, merge := false, shader_material: Material = null) -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	parallax = layer_parallax
	_anchor = anchor
	var keys := sections.keys()
	keys.sort()
	var merged := Painter.new()
	for index: int in keys:
		var p: Painter = sections[index]
		if merge:
			merged.append(p.points, p.colors, p.uvs)
		else:
			_add_section("Section_%d" % index, p, shader_material)
	if merge:
		_add_section("All", merged, shader_material)
	set_process(parallax != Vector2.ZERO)


func _add_section(section_name: String, p: Painter, shader_material: Material) -> void:
	var mesh := Painter.make_mesh(p.points, p.colors, p.uvs if shader_material else PackedVector2Array())
	if mesh == null:
		return
	var section := MeshSection.new()
	section.name = section_name
	add_child(section)
	section.setup(mesh, null, shader_material)


func _process(_delta: float) -> void:
	var start := Time.get_ticks_usec()
	var viewport := get_viewport()
	if viewport:
		var center := viewport.get_canvas_transform().affine_inverse() * (viewport.get_visible_rect().size * 0.5)
		position = (center - _anchor) * parallax
	last_process_usec = Time.get_ticks_usec() - start
