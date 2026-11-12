extends "res://scripts/level/temperature_zone.gd"
## Hot zone: warm rock that melts the slime by degrees. Its look is a warm glow on the floor, glowing vents that
## puff steam and a shimmer of heat haze that rises through the room.

const VENT_HALF_WIDTH := 0.22
const PUFFS_PER_VENT := 3

var _vents := PackedFloat32Array()


func _setup_look() -> void:
	heat = Tuning.temp_heat_rate
	kind = &"heat"
	_vents.clear()
	var tiles := int(roundf(area.size.x / Tuning.tile_size))
	var spacing := maxi(Tuning.heat_vent_spacing, 1)
	var first := spacing / 2
	for i: int in range(first, tiles, spacing):
		_vents.append((float(i) + 0.5) * Tuning.tile_size)


func _draw_zone(into: ShapeBatch, t: float) -> void:
	var size := area.size
	var floor_y := size.y
	var glow := Tuning.heat_glow_color
	var glow_top := floor_y - Tuning.tile_size * 1.6
	faded_band(into, Rect2(0.0, glow_top, size.x, floor_y - glow_top), Color(glow, 0.0), glow)
	_draw_haze(into, t, size)
	for i: int in _vents.size():
		_draw_vent(into, t, _vents[i], floor_y, float(i))


## Rising ribbons that sway; each one fades in at the floor and out near the ceiling.
func _draw_haze(into: ShapeBatch, t: float, size: Vector2) -> void:
	var count := maxi(Tuning.heat_haze_count, 1)
	var segments := 6
	var color := Tuning.heat_haze_color
	var phase_speed := Tuning.heat_haze_speed * 0.03
	for i: int in count:
		var seed_value := float(i) * 0.37
		var base_x := (float(i) + 0.5) / count * size.x + wave(t * 0.3, seed_value) * Tuning.tile_size * 0.4
		var flicker := 0.55 + 0.45 * sin(t * 0.8 + seed_value * 5.0)
		var prev := Vector2.ZERO
		for k: int in segments + 1:
			var y := size.y * (1.0 - float(k) / segments)
			# The phase grows with time, so the crests of the sway travel up the ribbon.
			var p := Vector2(base_x + sin(y * 0.025 + t * phase_speed + seed_value * 9.0) * Tuning.tile_size * 0.2, y)
			if k > 0:
				var fade := sin(PI * (float(k) - 0.5) / segments) * flicker
				into.stroke(PackedVector2Array([prev, p]), Tuning.tile_size * 0.16, Color(color, color.a * fade), false, false)
			prev = p


## A slot in the floor with a pulsing glow and puffs of steam on a fixed cycle of their own.
func _draw_vent(into: ShapeBatch, t: float, x: float, floor_y: float, index: float) -> void:
	var half := Tuning.tile_size * VENT_HALF_WIDTH
	var pulse := 0.6 + 0.4 * sin(t * 3.1 + index * 1.7)
	into.rect(Rect2(x - half - 2.0, floor_y - 7.0, half * 2.0 + 4.0, 9.0), Tuning.ground_outline_color)
	into.rect(Rect2(x - half, floor_y - 5.0, half * 2.0, 5.0), Tuning.heat_vent_color)
	into.rect(Rect2(x - half + 2.0, floor_y - 3.5, half * 2.0 - 4.0, 2.5), Color(Tuning.heat_vent_glow, Tuning.heat_vent_glow.a * pulse))
	into.disc(Vector2(x, floor_y - 4.0), half * 1.4, Color(Tuning.heat_vent_glow, 0.12 * pulse))
	var cycle := lerpf(Tuning.heat_steam_interval.x, Tuning.heat_steam_interval.y, 0.5 + 0.5 * sin(index * 3.3))
	for k: int in PUFFS_PER_VENT:
		var share := fposmod(t / cycle + index * 0.31 + float(k) / PUFFS_PER_VENT, 1.0)
		var at := Vector2(x + wave(t + float(k), index) * half * 0.6, floor_y - 6.0 - share * Tuning.tile_size * 1.8)
		var r := half * lerpf(0.5, 1.6, share)
		into.disc(at, r, Color(Tuning.heat_steam_color, Tuning.heat_steam_color.a * sin(PI * share)))
