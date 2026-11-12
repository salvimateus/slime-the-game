extends Area2D
## Base for a region that pushes the temperature of the slime, as Hazard does for damage. The player polls it every
## physics tick through temperature_push(). Subclasses set the push in setup and add their look in _draw_zone();
## the level's TemperatureArt (scripts/level/temperature_art.gd) draws every zone, grate and pipe in one batch.

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

## Melt (above 0) or freeze (below 0) rate per second.
var heat := 0.0
## Rate that only thaws a frozen body back to 0.
var thaw := 0.0
var ignites := false
var extinguishes := false
var kind: StringName = &"zone"
## Region in global space, set by setup().
var area := Rect2()

var _shape := CollisionShape2D.new()


## rect is in the parent's space; hit_inset shrinks the hit volume on each side (pixels), the look keeps the full rect.
func setup(rect: Rect2, hit_inset := Vector2.ZERO) -> void:
	position = rect.position
	reset_physics_interpolation()
	area = rect
	collision_layer = Tuning.LAYER_ZONES
	collision_mask = 0
	monitoring = false
	monitorable = true
	var box := RectangleShape2D.new()
	box.size = (rect.size - hit_inset * 2.0).max(Vector2.ONE)
	_shape.shape = box
	_shape.position = rect.size * 0.5
	if _shape.get_parent() == null:
		add_child(_shape)
	_setup_look()


## What this zone does to the slime this tick.
func temperature_push() -> Dictionary:
	return {"heat": heat, "thaw": thaw, "ignite": ignites, "extinguish": extinguishes, "kind": kind}


## TemperatureArt contract: the region the look covers, in the level's space.
func art_rect() -> Rect2:
	return area


## TemperatureArt contract: adds the look of time t to the batch, whose transform puts this node's origin in place.
func draw_art(into: ShapeBatch, t: float) -> void:
	_draw_zone(into, t)


## Subclasses: one-time look data from area (local space is area.size, origin at the top-left corner).
func _setup_look() -> void:
	pass


## Subclasses: add the look of this frame to the batch, in local space.
func _draw_zone(_into: ShapeBatch, _t: float) -> void:
	pass


## A band over rect with colour top at its top edge and bottom at its bottom edge, which fades to clear over the
## first and last Tuning.zone_edge_fade_tiles of its width, so the look has no hard side edge.
static func faded_band(into: ShapeBatch, rect: Rect2, top: Color, bottom: Color) -> void:
	var fade := minf(Tuning.tile_size * Tuning.zone_edge_fade_tiles, rect.size.x * 0.5)
	var xs := [rect.position.x, rect.position.x + fade, rect.end.x - fade, rect.end.x]
	var y0 := rect.position.y
	var y1 := rect.end.y
	for i: int in 3:
		var a: float = xs[i]
		var b: float = xs[i + 1]
		if b - a <= 0.0:
			continue
		var left := 0.0 if i == 0 else 1.0
		var right := 0.0 if i == 2 else 1.0
		into.polygon(PackedVector2Array([Vector2(a, y0), Vector2(b, y0), Vector2(b, y1), Vector2(a, y1)]), bottom, PackedColorArray([
			Color(top, top.a * left), Color(top, top.a * right), Color(bottom, bottom.a * right), Color(bottom, bottom.a * left)]))


## 0..1 at x along a zone of the given width: 0 at its ends, 1 past the edge fade.
static func edge_fade(x: float, width: float) -> float:
	var fade := maxf(Tuning.tile_size * Tuning.zone_edge_fade_tiles, 1.0)
	return clampf(minf(x, width - x) / fade, 0.0, 1.0)


## Cheap smooth noise in -1..1 for the look; no gameplay depends on it.
static func wave(t: float, seed_value: float) -> float:
	return sin(t * 1.7 + seed_value * 12.9898) * 0.6 + sin(t * 2.9 + seed_value * 4.1414) * 0.4
