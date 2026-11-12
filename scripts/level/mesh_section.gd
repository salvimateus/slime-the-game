extends Node2D
## One section of a static layer: draws one mesh, so the renderer skips it whole when it is off screen.

var _mesh: ArrayMesh
var _texture: Texture2D


func setup(mesh: ArrayMesh, texture: Texture2D = null, shader_material: Material = null, repeat := false) -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_mesh = mesh
	_texture = texture
	material = shader_material
	if repeat:
		texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	queue_redraw()


func _draw() -> void:
	if _mesh:
		draw_mesh(_mesh, _texture)
