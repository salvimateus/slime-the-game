extends Node2D
## Draws the look of every temperature zone, flame patch, grate and pipe of the level. Each registered node keeps its
## own look and answers the contract art_rect() -> Rect2 (level space) and draw_art(batch, t), which adds its shapes in
## its own local space. A node that answers art_is_static() -> true (grates, pipe tubes) is drawn one time into a static
## canvas item, behind or in front of the moving looks as its registration order says. The moving looks (zones,
## flames) are drawn in one batch at Tuning.temperature_art_hz, and only while one of them is near the screen.

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

var _nodes: Array[Node2D] = []
var _batch := ShapeBatch.new()
var _time := 0.0
## Seconds left in which every node is drawn, on screen or not, so no look compiles on its first frame in view.
var _warm := 0.0
var _drawn := false
var _drawn_step := -1
## Static looks registered before the first moving look (drawn behind it) and after it (drawn in front).
var _static_below: Array[Node2D] = []
var _static_above: Array[Node2D] = []
var _below_item: RID
var _above_item: RID
var _static_dirty := false


func _ready() -> void:
	_below_item = _make_item(true)
	_above_item = _make_item(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for item: RID in [_below_item, _above_item]:
			if item.is_valid():
				RenderingServer.free_rid(item)


func register(node: Node2D) -> void:
	if node.has_method(&"art_is_static") and bool(node.call(&"art_is_static")):
		(_static_below if _nodes.is_empty() else _static_above).append(node)
		_static_dirty = true
		return
	_nodes.append(node)


func warm_up() -> void:
	_warm = 0.2


func _process(delta: float) -> void:
	if visible != Tuning.fx_temperature_art:
		visible = Tuning.fx_temperature_art
	if not visible:
		return
	_time += delta
	_warm = maxf(_warm - delta, 0.0)
	if _static_dirty:
		_static_dirty = false
		_draw_static(_below_item, _static_below)
		_draw_static(_above_item, _static_above)
	if not (_warm > 0.0 or _drawn or _any_on_screen()):
		return
	var step := floori(_time * Tuning.temperature_art_hz)
	if step != _drawn_step or _warm > 0.0:
		_drawn_step = step
		queue_redraw()


func _draw() -> void:
	_batch.clear()
	var view := _view_rect()
	var drawn := false
	for node: Node2D in _nodes:
		if not is_instance_valid(node):
			continue
		var rect: Rect2 = node.call(&"art_rect")
		if _warm <= 0.0 and not view.intersects(rect):
			continue
		_batch.transform = node.transform
		node.call(&"draw_art", _batch, _time)
		drawn = true
	_batch.transform = Transform2D.IDENTITY
	_batch.commit(get_canvas_item())
	_drawn = drawn


func _make_item(behind: bool) -> RID:
	var item := RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(item, get_canvas_item())
	RenderingServer.canvas_item_set_draw_behind_parent(item, behind)
	return item


func _draw_static(item: RID, nodes: Array[Node2D]) -> void:
	RenderingServer.canvas_item_clear(item)
	var batch := ShapeBatch.new()
	for node: Node2D in nodes:
		if is_instance_valid(node):
			batch.transform = node.transform
			node.call(&"draw_art", batch, 0.0)
	batch.commit(item)


func _any_on_screen() -> bool:
	var view := _view_rect()
	for node: Node2D in _nodes:
		if is_instance_valid(node) and view.intersects(node.call(&"art_rect")):
			return true
	return false


func _view_rect() -> Rect2:
	var viewport := get_viewport()
	if viewport == null:
		return Rect2()
	return (viewport.get_canvas_transform().affine_inverse() * viewport.get_visible_rect()).grow(Tuning.tile_size)
