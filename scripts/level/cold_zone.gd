extends "res://scripts/level/temperature_zone.gd"
## Cold zone: ice walls and cold mist that freeze the slime by degrees and put a fire out at once. Its look is a blue
## cast over the room, slow banks of mist along the floor, falling snow and glints on the ice.

const MIST_SEGMENTS := 14
const GLINTS := 6


func _setup_look() -> void:
	heat = -Tuning.temp_cold_rate
	extinguishes = true
	kind = &"cold"


func _draw_zone(into: ShapeBatch, t: float) -> void:
	var size := area.size
	faded_band(into, Rect2(Vector2.ZERO, size), Tuning.cold_tint_color, Tuning.cold_tint_color)
	_draw_snow(into, t, size)
	_draw_mist(into, t, size)
	_draw_glints(into, t, size)


func _draw_snow(into: ShapeBatch, t: float, size: Vector2) -> void:
	var count := maxi(Tuning.cold_snow_count, 0)
	for i: int in count:
		var seed_value := float(i) * 0.618
		var speed := lerpf(40.0, 90.0, fposmod(seed_value * 7.3, 1.0))
		var y := fposmod(t * speed + seed_value * size.y * 3.1, size.y)
		var x := fposmod(seed_value * size.x * 5.7 + sin(t * 0.9 + seed_value * 11.0) * 18.0, size.x)
		var r := lerpf(1.5, 3.2, fposmod(seed_value * 3.9, 1.0)) * Tuning.character_scale * 0.6
		var fade := sin(PI * y / maxf(size.y, 1.0)) * edge_fade(x, size.x)
		into.disc(Vector2(x, y), r, Color(Tuning.cold_snow_color, Tuning.cold_snow_color.a * fade))


## Wide soft banks that drift along the floor and breathe up and down.
func _draw_mist(into: ShapeBatch, t: float, size: Vector2) -> void:
	var count := maxi(Tuning.cold_mist_count, 1)
	var color := Tuning.cold_mist_color
	for i: int in count:
		var seed_value := float(i) * 0.43
		var width := Tuning.tile_size * lerpf(2.5, 4.0, fposmod(seed_value * 5.1, 1.0))
		var x := fposmod(t * lerpf(14.0, 30.0, fposmod(seed_value * 2.3, 1.0)) * (1.0 if i % 2 == 0 else -1.0) + seed_value * size.x * 3.0, size.x + width) - width * 0.5
		var height := Tuning.tile_size * (0.55 + 0.2 * sin(t * 0.7 + seed_value * 6.0))
		var center := Vector2(x, size.y - height * 0.45)
		var outline := ShapeBatch.circle_points(center, Vector2(width * 0.5, height * 0.5), 0.0)
		var colors := PackedColorArray()
		for p: Vector2 in outline:
			colors.append(Color(color, 0.0) if p.y < center.y else Color(color, color.a * 0.6 * edge_fade(p.x, size.x)))
		into.polygon(outline, color, colors)


## Short four-point sparkles on the walls and the ceiling of the room.
func _draw_glints(into: ShapeBatch, t: float, size: Vector2) -> void:
	for i: int in GLINTS:
		var seed_value := float(i) * 1.37
		var cycle := 2.2 + fposmod(seed_value, 1.0) * 1.6
		var share := fposmod(t / cycle + seed_value, 1.0)
		if share > 0.25:
			continue
		var flare := sin(PI * share / 0.25)
		var at := Vector2(fposmod(seed_value * size.x * 3.3, size.x), fposmod(seed_value * 91.0, size.y * 0.6) + 6.0)
		var s := Tuning.tile_size * 0.16 * flare
		var c := Color(Tuning.frost_glint_color, flare)
		into.stroke(PackedVector2Array([at - Vector2(s, 0.0), at + Vector2(s, 0.0)]), maxf(s * 0.2, 1.0), c, false, false)
		into.stroke(PackedVector2Array([at - Vector2(0.0, s * 0.7), at + Vector2(0.0, s * 0.7)]), maxf(s * 0.16, 1.0), c, false, false)
