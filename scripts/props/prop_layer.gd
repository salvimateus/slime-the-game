extends Node2D
## Container and factory of every rock and crystal in the level, loose or in flight, and their single draw call:
## every prop adds itself to one ShapeBatch, so pieces from a break never add draw calls.
## Past Tuning.prop_loose_max props, a break first removes old break pieces; dropped props always stay. See make_room().

const ThrowableScene := preload("res://scenes/props/throwable.tscn")
const Throwable := preload("res://scenes/props/throwable.gd")
const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")
const EmberFieldScript := preload("res://scripts/props/ember_field.gd")
## A prop this far outside the view (radius, ember glow and hot trail included) is not drawn.
const MOVING_VIEW_MARGIN := 400.0

var _embers: Node2D
var _next_serial := 0
var _dirty := true
var _was_animating := false
var _batch := ShapeBatch.new()
var _static_batch := ShapeBatch.new()
## Children before this index draw from _static_batch; see _process().
var _static_end := -1
var _static_valid := false


func _ready() -> void:
	Game.props = self
	z_index = Tuning.over_goo_z_index
	_embers = EmberFieldScript.new()
	_embers.name = &"Embers"
	_embers.z_index = Tuning.over_goo_z_index
	_add_embers.call_deferred()


## The embers are a sibling, so every child of this layer stays a prop.
func _add_embers() -> void:
	var parent := get_parent()
	if parent != null and is_instance_valid(_embers):
		parent.add_child(_embers)


func _exit_tree() -> void:
	if Game.props == self:
		Game.props = null
	if is_instance_valid(_embers) and _embers.get_parent() == null:
		_embers.free()


## A burning ember that falls off a flying ember shot; see scripts/props/ember_field.gd.
func shed_ember(at: Vector2, carry: Vector2) -> void:
	if is_instance_valid(_embers) and _embers.is_inside_tree():
		_embers.call(&"shed", at, carry)


## The embers join the tree a moment after the layer, so the warm-up waits for them.
func warm_up_embers(at: Vector2) -> void:
	if is_instance_valid(_embers):
		_embers.call_deferred(&"warm_up", at)


func ember_count() -> int:
	return int(_embers.call(&"count")) if is_instance_valid(_embers) and _embers.is_inside_tree() else 0


## One Throwable.audit() entry per prop in the level, for the end of a run log.
func audit() -> Array:
	var list := []
	for prop: Node in get_children():
		if not prop.is_queued_for_deletion():
			list.append(prop.call(&"audit"))
	return list


## A prop at rest where the level puts it. identity is {"kind", "seed", "home"}.
func place(identity: Dictionary, at: Vector2) -> Node2D:
	return _spawn(identity, at, Vector2.ZERO, Throwable.State.LOOSE)


## A prop that falls out of the slime (or breaks off a prop), harmless and not swallowable for a moment.
func drop(identity: Dictionary, at: Vector2, velocity: Vector2) -> Node2D:
	return _spawn(identity, at, velocity, Throwable.State.TUMBLE)


## A prop spat from the slime centre as a shot; see Throwable.launch().
func launch(identity: Dictionary, center: Vector2, dir: Vector2, spawn_dist: float, velocity: Vector2) -> Node2D:
	var prop := _spawn(identity, center, velocity, Throwable.State.LOOSE)
	prop.call(&"launch", center, dir, spawn_dist, velocity)
	return prop


func count() -> int:
	var n := 0
	for prop: Node in get_children():
		if not prop.is_queued_for_deletion():
			n += 1
	return n


## Frees room for up to `needed` new props while `leaving` (a prop about to break, or null) goes away.
## Evicts the oldest pieces that rest off screen, never a full prop, and only when that reaches at least `minimum`
## free places; otherwise nothing is evicted. Returns {"room": props that fit, "evicted": count}.
func make_room(needed: int, minimum: int, leaving: Node = null) -> Dictionary:
	var live := count()
	if leaving != null and not leaving.is_queued_for_deletion():
		live -= 1
	var room := Tuning.prop_loose_max - live
	if room >= needed:
		return {"room": room, "evicted": 0}
	var candidates: Array[Node] = []
	for prop: Node in get_children():
		if prop != leaving and bool(prop.call(&"can_evict")):
			candidates.append(prop)
	if room + candidates.size() < minimum:
		return {"room": maxi(room, 0), "evicted": 0}
	candidates.sort_custom(func(a: Node, b: Node) -> bool: return int(a.get(&"serial")) < int(b.get(&"serial")))
	var evicted := 0
	while room < needed and evicted < candidates.size():
		candidates[evicted].call(&"evict")
		evicted += 1
		room += 1
	return {"room": room, "evicted": evicted}


## Global position of the nearest prop the slime could swallow, or null.
func nearest(from: Vector2, max_dist: float) -> Variant:
	var best: Variant = null
	var best_d := max_dist * max_dist
	for prop: Node in get_children():
		if prop.is_queued_for_deletion() or not bool(prop.call(&"can_be_absorbed")):
			continue
		var at := (prop as Node2D).global_position
		var d := from.distance_squared_to(at)
		if d < best_d:
			best_d = d
			best = at
	return best


## A prop calls this when its drawing changed; one inside the cached run of resting props rebuilds that cache.
func mark_dirty(prop: Node = null) -> void:
	_dirty = true
	if prop == null or prop.get_parent() != self or prop.get_index() < _static_end:
		_static_valid = false


## Redraws while a prop moves, plus one frame after, so a prop that just stopped is drawn where it rests.
## The props before the first moving one keep a cached batch, rebuilt only when that run of children or a prop
## state changes; each frame rebuilds only the props from the first moving one on, so the draw order stays the same.
func _process(_delta: float) -> void:
	var first_moving := get_child_count()
	var index := 0
	for prop: Node in get_children():
		if bool(prop.call(&"is_animating")):
			first_moving = index
			break
		index += 1
	var animating := first_moving < get_child_count()
	if first_moving != _static_end:
		_static_valid = false
	_static_end = first_moving
	if _dirty or animating or _was_animating or not _static_valid:
		queue_redraw()
	_dirty = false
	_was_animating = animating


func _draw() -> void:
	var to_layer := get_global_transform().affine_inverse()
	var fraction := Engine.get_physics_interpolation_fraction()
	var children := get_children()
	var split := clampi(_static_end, 0, children.size())
	if not _static_valid:
		_static_batch.clear()
		for i: int in split:
			children[i].call(&"draw_into", _static_batch, to_layer, fraction)
		_static_valid = true
	_static_batch.commit(get_canvas_item())
	if split >= children.size():
		return
	_batch.clear()
	var viewport := get_viewport()
	var view := (viewport.get_canvas_transform().affine_inverse() * viewport.get_visible_rect()).grow(MOVING_VIEW_MARGIN)
	for i: int in range(split, children.size()):
		var prop := children[i] as Node2D
		if view.has_point(prop.global_position):
			prop.call(&"draw_into", _batch, to_layer, fraction)
	_batch.commit(get_canvas_item())


func _spawn(identity: Dictionary, at: Vector2, velocity: Vector2, mode: Throwable.State) -> Node2D:
	var prop := ThrowableScene.instantiate() as Node2D
	prop.position = to_local(at)
	prop.set(&"serial", _next_serial)
	_next_serial += 1
	add_child(prop)
	prop.call(&"setup", identity, at, velocity, mode)
	return prop
