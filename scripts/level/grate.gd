extends StaticBody2D
## Metal grate across a passage, on Tuning.LAYER_GRATES: solid for the solid slime and for props, open for the melted
## slime and for loose goo, which seep between the bars. Drawn by the level's TemperatureArt.

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

var _size := Vector2.ZERO
var _shape := CollisionShape2D.new()


## rect is in the parent's space: the cells the grate fills.
func setup(rect: Rect2) -> void:
	position = rect.position
	reset_physics_interpolation()
	_size = rect.size
	collision_layer = Tuning.LAYER_GRATES
	collision_mask = 0
	var box := RectangleShape2D.new()
	# The bars are a thin plane in the middle of the cell.
	box.size = Vector2(Tuning.grate_bar_width * 2.0, _size.y)
	_shape.shape = box
	_shape.position = _size * 0.5
	if _shape.get_parent() == null:
		add_child(_shape)


## TemperatureArt contract: the look never changes, so it is drawn one time.
func art_is_static() -> bool:
	return true


## TemperatureArt contract: the region the grate covers, in the level's space.
func art_rect() -> Rect2:
	return Rect2(position, _size)


## TemperatureArt contract: adds the grate to the batch, whose transform puts this node's origin in place.
func draw_art(into: ShapeBatch, _t: float) -> void:
	var bar := Tuning.grate_bar_width
	var pitch := bar + Tuning.grate_bar_gap
	var inset := _size.x * 0.12
	var left := inset
	var right := _size.x - inset
	# A lattice: vertical bars with rungs between them, framed by two posts; the gaps show the room behind.
	var columns := maxi(int((right - left) / pitch), 2)
	var rows := maxi(int(_size.y / (pitch * 1.6)), 2)
	for i: int in rows:
		var y := (float(i) + 0.5) * _size.y / rows
		into.rect(Rect2(left, y - bar * 0.4, right - left, bar * 0.8), Tuning.ground_outline_color)
		into.rect(Rect2(left, y - bar * 0.25, right - left, bar * 0.5), Tuning.grate_color)
	for i: int in columns + 1:
		var x := lerpf(left, right, float(i) / columns)
		var w := bar * (1.6 if i == 0 or i == columns else 1.0)
		into.rect(Rect2(x - w * 0.5 - 1.5, 0.0, w + 3.0, _size.y), Tuning.ground_outline_color)
		into.rect(Rect2(x - w * 0.5, 0.0, w, _size.y), Tuning.grate_color)
		into.rect(Rect2(x - w * 0.5, 0.0, w * 0.35, _size.y), Tuning.grate_light)
