extends RefCounted
## The look of each decoration kind, painted into a DecorPainter in local space. Floor pieces stand on (0, 0) and grow
## up (-y); ceiling pieces hang from (0, 0) down (+y); wall pieces sit on the face at (0, 0) with the open air toward
## +x when side is 1. Every random detail comes from the seed of the item, so a piece always looks the same.

const Painter := preload("res://scripts/level/decor_painter.gd")

const OUTLINE := 2.5


static func outline_color() -> Color:
	return Tuning.ground_outline_color


static func _pick(rng: RandomNumberGenerator, colors: Array[Color]) -> Color:
	if colors.is_empty():
		return Color.WHITE
	return colors[rng.randi() % colors.size()]


static func _closed(pts: PackedVector2Array) -> PackedVector2Array:
	var out := pts.duplicate()
	if not out.is_empty():
		out.append(out[0])
	return out


## A filled shape with a dark outline around it.
static func _outlined(p: Painter, pts: PackedVector2Array, color: Color, width := OUTLINE) -> void:
	p.stroke(_closed(pts), width * 2.0, outline_color())
	p.polygon(pts, color)


static func _wobbly_ellipse(rng: RandomNumberGenerator, center: Vector2, radii: Vector2, count: int, jitter: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in count:
		var t := TAU * i / count
		var k := 1.0 + rng.randf_range(-jitter, jitter)
		pts.append(center + Vector2(cos(t) * radii.x, sin(t) * radii.y) * k)
	return pts


## Points of a cap: a dome, a bell or a cone, with its rim at y = 0 and the top at -height.
static func _cap_points(width: float, height: float, style: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var half := width * 0.5
	var steps := 14
	for i in steps + 1:
		var u := float(i) / steps
		var x := lerpf(-half, half, u)
		var n := absf(x) / half
		var y: float
		match style:
			1:
				y = -height * pow(1.0 - n * n, 0.35)
			2:
				y = -height * (1.0 - pow(n, 1.6))
			_:
				y = -height * sqrt(maxf(1.0 - n * n, 0.0))
		pts.append(Vector2(x, y))
	pts.append(Vector2(half * 0.75, height * 0.16))
	pts.append(Vector2(-half * 0.75, height * 0.16))
	return pts


## One mushroom standing on (0, 0). Returns the local point under the cap where a glow sits.
static func mushroom(p: Painter, rng: RandomNumberGenerator, height: float, cap_color: Color, frosted := false) -> Vector2:
	var cap_w := height * rng.randf_range(Tuning.decor_mushroom_cap_ratio.x, Tuning.decor_mushroom_cap_ratio.y)
	var style := rng.randi_range(0, 2)
	var cap_h := cap_w * (0.42 if style == 0 else (0.55 if style == 1 else 0.7))
	var stem_h := maxf(height - cap_h * 0.85, height * 0.35)
	var stem_w := maxf(cap_w * rng.randf_range(0.2, 0.28), 5.0)
	var lean := rng.randf_range(-0.12, 0.12) * height
	var top := Vector2(lean, -stem_h)
	var stem := PackedVector2Array([
		Vector2(-stem_w * 0.7, 0.0), Vector2(-stem_w * 0.55, -stem_h * 0.35),
		top + Vector2(-stem_w * 0.42, 0.0), top + Vector2(stem_w * 0.42, 0.0),
		Vector2(stem_w * 0.55, -stem_h * 0.35), Vector2(stem_w * 0.7, 0.0),
	])
	_outlined(p, stem, Tuning.decor_stem_color)
	p.stroke(PackedVector2Array([Vector2(stem_w * 0.3, -2.0), top + Vector2(stem_w * 0.22, cap_h * 0.2)]), maxf(stem_w * 0.22, 1.5), Tuning.decor_stem_color.darkened(0.18))
	var cap := _cap_points(cap_w, cap_h, style)
	var offset := Transform2D(0.0, top)
	var placed := offset * cap
	p.stroke(_closed(placed), OUTLINE * 2.0, outline_color())
	p.polygon(placed, cap_color)
	p.ellipse(top + Vector2(0.0, cap_h * 0.1), Vector2(cap_w * 0.4, cap_h * 0.11), 0.0, cap_color.darkened(0.42))
	p.polygon(offset * _cap_points(cap_w * 0.72, cap_h * 0.68, style), cap_color.lightened(0.12))
	var spots := rng.randi_range(2, 5)
	for i in spots:
		var u := rng.randf_range(-0.36, 0.36)
		var v := rng.randf_range(0.35, 0.8)
		var at := top + Vector2(u * cap_w, -cap_h * v * sqrt(maxf(1.0 - 4.0 * u * u, 0.1)))
		p.disc(at, maxf(cap_w * rng.randf_range(0.05, 0.09), 1.5), Tuning.decor_spot_color)
	var arc := PackedVector2Array()
	for i in 5:
		var t := lerpf(PI * 1.18, PI * 1.45, float(i) / 4.0)
		arc.append(top + Vector2(cos(t) * cap_w * 0.36, sin(t) * cap_h * 0.75))
	p.stroke(arc, maxf(cap_w * 0.06, 1.5), Color(1.0, 1.0, 1.0, 0.45))
	if frosted:
		var rim := PackedVector2Array()
		for i in range(2, cap.size() - 4):
			rim.append(placed[i] + Vector2(0.0, 1.5))
		p.stroke(rim, maxf(cap_h * 0.18, 3.0), Tuning.decor_frost_color)
	return top + Vector2(0.0, cap_h * 0.2)


static func mushroom_glow(p: Painter, at: Vector2, radius: float, color: Color) -> void:
	var old := p.feather
	p.feather = radius * 0.5
	p.disc(at, radius, color)
	p.disc(at, radius * 0.55, Color(color, color.a * 1.4))
	p.feather = old


## Half-sunk rock in ground colours, so it reads as part of the floor and never as a loose prop.
static func rock(p: Painter, rng: RandomNumberGenerator, size: float, frosted := false) -> void:
	var color := _pick(rng, Tuning.decor_rock_colors)
	var pts := PackedVector2Array()
	var count := rng.randi_range(6, 8)
	var h := size * rng.randf_range(0.45, 0.7)
	for i in count + 1:
		var t := PI + PI * float(i) / count
		var k := rng.randf_range(0.82, 1.08)
		pts.append(Vector2(cos(t) * size * 0.5 * k, sin(t) * h * k + 5.0))
	pts.append(Vector2(size * 0.3, 8.0))
	pts.append(Vector2(-size * 0.3, 8.0))
	_outlined(p, pts, color)
	p.polygon(Transform2D(0.0, Vector2(0.8, 0.6), 0.0, Vector2(-size * 0.06, -h * 0.25)) * pts, color.lightened(0.1))
	p.stroke(PackedVector2Array([Vector2(-size * 0.3, -h * 0.55), Vector2(-size * 0.05, -h * 0.85), Vector2(size * 0.15, -h * 0.8)]), 2.5, Tuning.ground_lip_color.darkened(0.15))
	if frosted:
		p.dome(Vector2(0.0, -h * 0.55), Vector2(size * 0.42, h * 0.42), 2.0, Tuning.decor_frost_color)


static func pebbles(p: Painter, rng: RandomNumberGenerator) -> void:
	for i in rng.randi_range(3, 6):
		var r := rng.randf_range(Tuning.decor_pebble_size.x, Tuning.decor_pebble_size.y)
		var at := Vector2(rng.randf_range(-26.0, 26.0), 3.0 - r * 0.45)
		var pts := _wobbly_ellipse(rng, at, Vector2(r, r * 0.7), 9, 0.12)
		_outlined(p, pts, _pick(rng, Tuning.decor_rock_colors).lightened(rng.randf_range(0.0, 0.2)), 2.0)


static func crystal(p: Painter, rng: RandomNumberGenerator, size: float, color: Color) -> PackedVector2Array:
	var tips := PackedVector2Array()
	var count := rng.randi_range(3, 5)
	for i in count:
		var lean := lerpf(-0.55, 0.55, (float(i) + rng.randf_range(0.2, 0.8)) / count)
		var h := size * rng.randf_range(0.5, 1.0) * (1.0 - absf(lean) * 0.5)
		var w := size * rng.randf_range(0.16, 0.24)
		var base := Vector2(lean * size * 0.35, 6.0)
		var dir := Vector2(sin(lean), -cos(lean))
		var side := dir.orthogonal()
		var tip := base + dir * h
		var shard := PackedVector2Array([base - side * w * 0.5, base - side * w * 0.5 + dir * h * 0.78, tip, base + side * w * 0.5 + dir * h * 0.78, base + side * w * 0.5])
		_outlined(p, shard, color.darkened(0.25), 2.0)
		p.polygon(PackedVector2Array([base, base - side * w * 0.45 + dir * h * 0.76, tip, base + dir * h * 0.7]), color)
		p.stroke(PackedVector2Array([base - side * w * 0.25 + dir * h * 0.2, base - side * w * 0.22 + dir * h * 0.7]), 2.0, Color(1.0, 1.0, 1.0, 0.65))
		tips.append(tip)
	return tips


static func bones(p: Painter, rng: RandomNumberGenerator) -> void:
	var color := Tuning.decor_bone_color
	if rng.randf() < 0.45:
		var r := rng.randf_range(11.0, 16.0)
		var skull := _wobbly_ellipse(rng, Vector2(0.0, -r * 0.8), Vector2(r, r * 0.85), 12, 0.04)
		_outlined(p, skull, color, 2.0)
		p.rect(Rect2(-r * 0.55, -r * 0.2, r * 1.1, r * 0.45), color)
		p.disc(Vector2(-r * 0.38, -r * 0.85), r * 0.24, outline_color())
		p.disc(Vector2(r * 0.38, -r * 0.85), r * 0.24, outline_color())
		p.disc(Vector2(0.0, -r * 0.4), r * 0.1, outline_color())
	var length := rng.randf_range(26.0, 44.0)
	var angle := rng.randf_range(-0.25, 0.25)
	var a := Vector2(-length * 0.5, -5.0).rotated(angle) + Vector2(rng.randf_range(-10.0, 10.0), 0.0)
	var b := a + Vector2(length, 0.0).rotated(angle)
	p.stroke(PackedVector2Array([a, b]), 9.0, outline_color())
	p.stroke(PackedVector2Array([a, b]), 5.5, color)
	for end: Vector2 in [a, b]:
		var n := Vector2(0.0, 3.5).rotated(angle)
		p.disc(end + n, 5.0, outline_color())
		p.disc(end - n, 5.0, outline_color())
		p.disc(end + n, 3.6, color)
		p.disc(end - n, 3.6, color)


static func roots(p: Painter, rng: RandomNumberGenerator, color: Color) -> void:
	for i in rng.randi_range(2, 3):
		var start := Vector2(rng.randf_range(-24.0, 24.0), 8.0)
		var pts := PackedVector2Array([start])
		var dir := Vector2(rng.randf_range(-1.0, 1.0), -rng.randf_range(0.5, 1.2)).normalized()
		var at := start
		for k in 4:
			dir = dir.rotated(rng.randf_range(-0.6, 0.6))
			dir.y = minf(dir.y, 0.25)
			at += dir * rng.randf_range(8.0, 15.0)
			at.y = minf(at.y, 2.0)
			pts.append(at)
		p.stroke(pts, 7.0, outline_color(), 3.0)
		p.stroke(pts, 4.5, color, 1.5)


## A low rounded rock mound with a blunt top, so it never reads as a spike.
static func stalagmite(p: Painter, rng: RandomNumberGenerator, size: Vector2, color: Color) -> void:
	var w := size.x
	var h := size.y
	var pts := PackedVector2Array([Vector2(-w * 0.5, 6.0), Vector2(-w * 0.4, -h * 0.35), Vector2(-w * 0.22, -h * 0.8), Vector2(0.0, -h), Vector2(w * 0.22, -h * 0.8), Vector2(w * 0.38, -h * 0.3), Vector2(w * 0.5, 6.0)])
	_outlined(p, pts, color)
	p.disc(Vector2(0.0, -h * 0.86), w * 0.22, color)
	p.stroke(PackedVector2Array([Vector2(-w * 0.28, -h * 0.15), Vector2(-w * 0.12, -h * 0.7)]), 3.0, color.lightened(0.18))
	if rng.randf() < 0.5:
		p.stroke(PackedVector2Array([Vector2(w * 0.08, -h * 0.5), Vector2(w * 0.26, -h * 0.15)]), 2.0, color.darkened(0.3))


static func puddle(p: Painter, rng: RandomNumberGenerator, color: Color) -> void:
	var r := rng.randf_range(26.0, 54.0)
	p.ellipse(Vector2(0.0, 4.0), Vector2(r + 3.0, 7.0), 0.0, outline_color())
	p.ellipse(Vector2(0.0, 3.5), Vector2(r, 5.5), 0.0, color)
	p.stroke(PackedVector2Array([Vector2(-r * 0.5, 2.5), Vector2(-r * 0.1, 2.0)]), 2.0, Color(1.0, 1.0, 1.0, 0.5))


static func moss(p: Painter, rng: RandomNumberGenerator) -> void:
	var width := rng.randf_range(24.0, 56.0)
	var count := int(width / 7.0) + 2
	var dark := _pick(rng, Tuning.decor_moss_colors)
	for i in count:
		var x := lerpf(-width * 0.5, width * 0.5, float(i) / (count - 1))
		var r := rng.randf_range(5.0, 9.0) * (1.0 - absf(x) / width)
		p.disc(Vector2(x, 2.0 - r * 0.4), r + 1.5, outline_color())
	for i in count:
		var x := lerpf(-width * 0.5, width * 0.5, float(i) / (count - 1))
		var r := rng.randf_range(5.0, 9.0) * (1.0 - absf(x) / width)
		p.disc(Vector2(x, 2.0 - r * 0.4), r, dark.lightened(rng.randf_range(0.0, 0.18)))
	for i in rng.randi_range(2, 4):
		var x := rng.randf_range(-width * 0.4, width * 0.4)
		p.disc(Vector2(x, -6.0), 1.6, Tuning.decor_spot_color)


static func vent(p: Painter, rng: RandomNumberGenerator) -> void:
	var r := rng.randf_range(16.0, 24.0)
	for i in 5:
		var t := lerpf(PI * 1.05, PI * 1.95, float(i) / 4.0)
		var at := Vector2(cos(t) * r * 1.25, 3.0 + sin(t) * 6.0)
		_outlined(p, _wobbly_ellipse(rng, at, Vector2(7.0, 5.0), 8, 0.15), _pick(rng, Tuning.decor_rock_colors), 2.0)
	p.ellipse(Vector2(0.0, 3.0), Vector2(r + 2.0, 6.5), 0.0, Tuning.decor_glow_crack_color)
	p.ellipse(Vector2(0.0, 3.5), Vector2(r * 0.8, 4.5), 0.0, outline_color())


static func ash(p: Painter, rng: RandomNumberGenerator) -> void:
	var w := rng.randf_range(34.0, 70.0)
	var h := w * rng.randf_range(0.18, 0.3)
	p.dome(Vector2(0.0, 5.0), Vector2(w * 0.5 + 2.0, h + 2.0), 0.0, outline_color())
	p.dome(Vector2(0.0, 5.0), Vector2(w * 0.5, h), 0.0, Tuning.decor_ash_color)
	p.dome(Vector2(-w * 0.08, 5.0), Vector2(w * 0.32, h * 0.7), 0.0, Tuning.decor_ash_color.lightened(0.15))
	for i in rng.randi_range(3, 6):
		p.disc(Vector2(rng.randf_range(-w * 0.35, w * 0.35), rng.randf_range(-h * 0.6, 2.0)), rng.randf_range(1.5, 3.0), Tuning.decor_charred_color)
	if rng.randf() < 0.6:
		p.disc(Vector2(rng.randf_range(-w * 0.2, w * 0.2), -h * 0.3), 2.5, Tuning.decor_ember_color)


static func stump(p: Painter, rng: RandomNumberGenerator) -> void:
	var w := rng.randf_range(26.0, 40.0)
	var h := rng.randf_range(34.0, 62.0)
	var pts := PackedVector2Array([Vector2(-w * 0.75, 6.0), Vector2(-w * 0.5, -h * 0.2), Vector2(-w * 0.48, -h * 0.85), Vector2(-w * 0.25, -h), Vector2(-w * 0.05, -h * 0.78), Vector2(w * 0.18, -h * 1.05), Vector2(w * 0.48, -h * 0.75), Vector2(w * 0.5, -h * 0.2), Vector2(w * 0.8, 6.0)])
	_outlined(p, pts, Tuning.decor_charred_color)
	for i in 3:
		var x := lerpf(-w * 0.3, w * 0.3, float(i) / 2.0)
		var crack := PackedVector2Array([Vector2(x, -h * 0.15), Vector2(x + rng.randf_range(-4.0, 4.0), -h * 0.45), Vector2(x + rng.randf_range(-4.0, 4.0), -h * 0.7)])
		p.stroke(crack, 3.0, Tuning.decor_ember_color.darkened(0.2))
		p.stroke(crack, 1.3, Color(1.0, 0.85, 0.5))


static func icicle(p: Painter, rng: RandomNumberGenerator, size: Vector2) -> void:
	for i in rng.randi_range(1, 3):
		var w := size.x * rng.randf_range(0.6, 1.0)
		var h := size.y * rng.randf_range(0.55, 1.0)
		var x := rng.randf_range(-14.0, 14.0)
		var pts := PackedVector2Array([Vector2(x - w * 0.5, -4.0), Vector2(x + w * 0.5, -4.0), Vector2(x + w * 0.18, h * 0.75), Vector2(x, h), Vector2(x - w * 0.18, h * 0.75)])
		_outlined(p, pts, Tuning.decor_ice_color, 2.0)
		p.disc(Vector2(x, h - 2.0), maxf(w * 0.18, 2.5), Tuning.decor_ice_color)
		p.stroke(PackedVector2Array([Vector2(x - w * 0.2, 2.0), Vector2(x - w * 0.05, h * 0.6)]), 2.0, Color(1.0, 1.0, 1.0, 0.7))


static func stalactite(p: Painter, rng: RandomNumberGenerator, size: Vector2, color: Color) -> void:
	var w := size.x
	var h := size.y
	var pts := PackedVector2Array([Vector2(-w * 0.5, -6.0), Vector2(w * 0.5, -6.0), Vector2(w * 0.3, h * 0.45), Vector2(w * 0.12, h * 0.9), Vector2(-w * 0.1, h * 0.88), Vector2(-w * 0.3, h * 0.4)])
	_outlined(p, pts, color)
	p.disc(Vector2(0.0, h * 0.86), maxf(w * 0.16, 3.0), color)
	if rng.randf() < 0.5:
		p.stroke(PackedVector2Array([Vector2(-w * 0.2, 2.0), Vector2(-w * 0.05, h * 0.6)]), 2.5, color.lightened(0.2))


## Wall pieces: side is 1 when the air is on the right of the face; the cut goes into the rock toward -side.
static func wall_piece(p: Painter, rng: RandomNumberGenerator, kind: StringName, side: float, theme: StringName) -> void:
	match kind:
		&"crack", &"glow_crack":
			var pts := PackedVector2Array([Vector2.ZERO])
			var at := Vector2.ZERO
			for k in rng.randi_range(3, 5):
				at += Vector2(-side * rng.randf_range(8.0, 16.0), rng.randf_range(-12.0, 12.0))
				pts.append(at)
			if kind == &"glow_crack":
				var old := p.feather
				p.feather = 6.0
				p.stroke(pts, 7.0, Color(Tuning.decor_glow_crack_color, 0.45), 2.0)
				p.feather = old
				p.stroke(pts, 4.0, Tuning.decor_glow_crack_color, 1.2)
				p.stroke(pts, 1.6, Color(1.0, 0.9, 0.6), 0.6)
			else:
				p.stroke(pts, 4.0, outline_color(), 1.0)
		&"vein":
			var color: Color = Tuning.decor_crystal_colors.get(theme, Color.WHITE)
			var pts := PackedVector2Array([Vector2(-side * 3.0, 0.0)])
			var at := Vector2(-side * 3.0, 0.0)
			for k in 4:
				at += Vector2(-side * rng.randf_range(4.0, 12.0), rng.randf_range(-14.0, 14.0))
				pts.append(at)
			p.stroke(pts, 6.0, color.darkened(0.4), 2.0)
			p.stroke(pts, 3.0, color, 1.0)
			for k in 2:
				p.disc(pts[1 + k * 2], 2.5, Color(1.0, 1.0, 1.0, 0.8))
		&"root_line":
			var pts := PackedVector2Array()
			var x := -side * rng.randf_range(6.0, 18.0)
			for k in 6:
				pts.append(Vector2(x + sin(k * 1.3 + rng.randf()) * 5.0, -30.0 + k * 12.0))
			p.stroke(pts, 5.0, Tuning.decor_root_color.darkened(0.2), 2.0)
			p.stroke(pts, 2.5, Tuning.decor_root_color.lightened(0.15), 1.0)
		&"soot":
			var old := p.feather
			p.feather = 10.0
			p.ellipse(Vector2(-side * 10.0, 0.0), Vector2(14.0, rng.randf_range(20.0, 34.0)), 0.0, Color(Tuning.decor_charred_color, 0.55))
			p.feather = old
		&"frost":
			var old := p.feather
			p.feather = 5.0
			p.ellipse(Vector2(-side * 5.0, 0.0), Vector2(8.0, rng.randf_range(14.0, 26.0)), 0.0, Color(Tuning.decor_frost_color, 0.55))
			p.feather = old
			for k in 3:
				var at := Vector2(-side * rng.randf_range(0.0, 8.0), rng.randf_range(-16.0, 16.0))
				p.stroke(PackedVector2Array([at, at + Vector2(side * 6.0, -4.0)]), 2.0, Tuning.decor_frost_color)
		&"shelf":
			var w := rng.randf_range(14.0, 24.0)
			var color := _pick(rng, Tuning.decor_cap_colors).lerp(Tuning.decor_stem_color, 0.45)
			var pts := PackedVector2Array([Vector2(-side * 4.0, -6.0), Vector2(side * w * 0.6, -7.0), Vector2(side * w, -3.0), Vector2(side * w * 0.8, 2.0), Vector2(-side * 4.0, 4.0)])
			_outlined(p, pts, color, 2.0)
			for k in rng.randi_range(1, 2):
				var tiny := Transform2D(0.0, Vector2(side * w * (0.3 + 0.35 * k), -6.0))
				var old := p.transform
				p.transform = old * tiny
				mushroom(p, rng, rng.randf_range(12.0, 18.0), _pick(rng, Tuning.decor_cap_colors))
				p.transform = old


## Details in the soil just under a floor lip, painted inside the rock.
static func soil_piece(p: Painter, rng: RandomNumberGenerator, kind: StringName, theme: StringName) -> void:
	match kind:
		&"soil_roots":
			for i in rng.randi_range(1, 3):
				var pts := PackedVector2Array()
				var x := rng.randf_range(-24.0, 24.0)
				for k in 5:
					pts.append(Vector2(x + sin(k * 1.4 + i) * 4.0 + k * rng.randf_range(-2.0, 2.0), k * rng.randf_range(6.0, 10.0)))
				p.stroke(pts, 4.0, Tuning.decor_root_color, 1.0)
		&"soil_vein":
			var color: Color = Tuning.decor_crystal_colors.get(theme, Color.WHITE)
			var at := Vector2(rng.randf_range(-20.0, 20.0), rng.randf_range(8.0, 30.0))
			for k in rng.randi_range(2, 4):
				var r := rng.randf_range(2.5, 5.0)
				var c := at + Vector2(rng.randf_range(-10.0, 10.0), rng.randf_range(-6.0, 6.0))
				p.polygon(PackedVector2Array([c + Vector2(0.0, -r * 1.6), c + Vector2(r, 0.0), c + Vector2(0.0, r * 1.6), c + Vector2(-r, 0.0)]), color)
		&"soil_glow":
			var pts := PackedVector2Array([Vector2(rng.randf_range(-26.0, -10.0), rng.randf_range(4.0, 10.0))])
			for k in 4:
				pts.append(pts[k] + Vector2(rng.randf_range(8.0, 14.0), rng.randf_range(-5.0, 7.0)))
			var old := p.feather
			p.feather = 6.0
			p.stroke(pts, 7.0, Color(Tuning.decor_glow_crack_color, 0.35), 3.0)
			p.feather = old
			p.stroke(pts, 3.0, Tuning.decor_glow_crack_color, 1.2)
			p.stroke(pts, 1.2, Color(1.0, 0.88, 0.6), 0.5)
		&"fossil":
			var c := Vector2(rng.randf_range(-16.0, 16.0), rng.randf_range(16.0, 30.0))
			var spiral := PackedVector2Array()
			for k in 14:
				var t := k * 0.55
				spiral.append(c + Vector2.from_angle(t) * (2.0 + t * 1.6))
			p.stroke(spiral, 2.0, Color(Tuning.decor_bone_color.darkened(0.45), 0.55))


## Far silhouettes: flat dark shapes with soft edges; they stand on (0, 0), or hang from it when hanging is true.
static func silhouette(p: Painter, rng: RandomNumberGenerator, height: float, color: Color, hanging: bool) -> void:
	var dir := 1.0 if hanging else -1.0
	var sink := 120.0
	if hanging:
		match rng.randi_range(0, 1):
			0:
				var w := height * rng.randf_range(0.25, 0.4)
				p.polygon(PackedVector2Array([Vector2(-w * 0.5, -sink), Vector2(w * 0.5, -sink), Vector2(w * 0.2, height * 0.6), Vector2(0.0, height), Vector2(-w * 0.2, height * 0.55)]), color)
			_:
				for k in rng.randi_range(4, 7):
					var x := rng.randf_range(-height * 0.3, height * 0.3)
					var length := height * rng.randf_range(0.4, 1.0)
					var pts := PackedVector2Array()
					for s in 6:
						pts.append(Vector2(x + sin(s * 1.1 + k) * 8.0, -sink * 0.3 + length * s / 5.0))
					p.stroke(pts, rng.randf_range(6.0, 12.0), color, 3.0)
		return
	match rng.randi_range(0, 3):
		0:
			var cap_w := height * rng.randf_range(0.6, 0.9)
			var stem_w := cap_w * 0.18
			p.polygon(PackedVector2Array([Vector2(-stem_w, sink), Vector2(stem_w, sink), Vector2(stem_w * 0.7, -height * 0.7), Vector2(-stem_w * 0.7, -height * 0.7)]), color)
			p.dome(Vector2(rng.randf_range(-6.0, 6.0), -height * 0.66), Vector2(cap_w * 0.5, height * 0.34), height * 0.04, color)
		1:
			var w := height * rng.randf_range(0.3, 0.45)
			p.polygon(PackedVector2Array([Vector2(-w * 0.5, sink), Vector2(w * 0.5, sink), Vector2(w * 0.22, -height * 0.7), Vector2(0.0, -height), Vector2(-w * 0.25, -height * 0.6)]), color)
		2:
			for k in rng.randi_range(2, 4):
				var lean := rng.randf_range(-0.35, 0.35)
				var h := height * rng.randf_range(0.5, 1.0)
				var w := height * 0.12
				var d := Vector2(sin(lean), -cos(lean))
				var s := d.orthogonal() * w * 0.5
				var base := Vector2(lean * 60.0, sink * 0.3)
				p.polygon(PackedVector2Array([base - s, base - s + d * h * 0.8, base + d * h, base + s + d * h * 0.8, base + s]), color)
		_:
			var w := height * rng.randf_range(0.5, 0.8)
			p.polygon(_wobbly_ellipse(rng, Vector2(0.0, 0.0), Vector2(w * 0.5, height * 0.45), 12, 0.12), color)
	if dir < 0.0 and rng.randf() < 0.35:
		p.disc(Vector2(rng.randf_range(-20.0, 20.0), -height * rng.randf_range(0.3, 0.7)), 3.0, Color(1.0, 0.8, 0.95, 0.25))


## Near shapes: dark clumps that hang at most reach below a ceiling, with a few root strands.
static func front_clump(p: Painter, rng: RandomNumberGenerator, reach: float) -> void:
	var color := Tuning.decor_front_color
	for k in rng.randi_range(3, 5):
		var w := rng.randf_range(50.0, 110.0)
		var radius_y := 70.0 + reach * 0.4
		var y := reach * rng.randf_range(0.2, 0.6) - 70.0
		p.ellipse(Vector2(rng.randf_range(-90.0, 90.0), y), Vector2(w, radius_y), 0.0, color)
	for k in rng.randi_range(2, 4):
		var x := rng.randf_range(-80.0, 80.0)
		var pts := PackedVector2Array()
		for s in 5:
			pts.append(Vector2(x + sin(s + k) * 6.0, s * reach * 0.3))
		p.stroke(pts, 8.0, color, 3.0)


## One segment of a hanging root, vine or glow-worm thread, from (0, 0) down to (0, length).
static func hanging_segment(p: Painter, rng: RandomNumberGenerator, kind: StringName, length: float, start_width: float, end_width: float) -> void:
	var bend := rng.randf_range(-4.0, 4.0)
	var line := PackedVector2Array([Vector2.ZERO, Vector2(bend, length * 0.5), Vector2(0.0, length)])
	match kind:
		&"glow_worm":
			p.stroke(line, 1.6, Color(0.85, 0.9, 1.0, 0.55))
		&"vine":
			p.stroke(line, start_width + 2.5, outline_color(), end_width + 2.5)
			p.stroke(line, start_width, Tuning.decor_root_color.lightened(0.2), end_width)
			for k in 2:
				var side := -1.0 if (k + rng.randi()) % 2 == 0 else 1.0
				var at := Vector2(bend * 0.5, length * (0.3 + 0.4 * k))
				var leaf := at + Vector2(side * 8.0, 3.0)
				p.ellipse(leaf, Vector2(8.0, 4.0), side * 0.5, outline_color())
				p.ellipse(leaf, Vector2(6.5, 2.8), side * 0.5, _pick(rng, Tuning.decor_vine_leaf_colors))
		&"charred_root":
			p.stroke(line, start_width + 2.0, outline_color(), end_width + 2.0)
			p.stroke(line, start_width, Tuning.decor_charred_color.lightened(0.12), end_width)
			if rng.randf() < 0.5:
				p.disc(Vector2(bend * 0.5, length * 0.5), 2.0, Tuning.decor_ember_color)
		_:
			var color := Tuning.decor_dead_root_color if kind == &"dead_root" else Tuning.decor_root_color
			p.stroke(line, start_width + 2.5, outline_color(), end_width + 2.5)
			p.stroke(line, start_width, color, end_width)
			if rng.randf() < 0.55:
				var side := -1.0 if rng.randf() < 0.5 else 1.0
				var twig := PackedVector2Array([Vector2(bend * 0.4, length * 0.45), Vector2(side * 10.0, length * 0.7), Vector2(side * 13.0, length * 0.85)])
				p.stroke(twig, maxf(end_width, 2.0), color, 1.0)


static func glow_bulb(p: Painter, color: Color, radius: float) -> void:
	var old := p.feather
	p.feather = radius * 1.6
	p.disc(Vector2.ZERO, radius * 2.2, Color(color, 0.16))
	p.feather = radius * 0.6
	p.disc(Vector2.ZERO, radius * 1.1, Color(color, 0.45))
	p.feather = old
	p.disc(Vector2.ZERO, radius * 0.6, color.lightened(0.5))


## A four-point sparkle of radius 1; the live layer scales it.
static func star(p: Painter, color: Color) -> void:
	p.polygon(PackedVector2Array([Vector2(0.0, -1.0), Vector2(0.18, -0.18), Vector2(1.0, 0.0), Vector2(0.18, 0.18), Vector2(0.0, 1.0), Vector2(-0.18, 0.18), Vector2(-1.0, 0.0), Vector2(-0.18, -0.18)]), color)


## A soft dot of radius 1 for drops, spores, embers and steam.
static func dot(p: Painter, color: Color, soft: bool) -> void:
	var old := p.feather
	p.feather = 0.8 if soft else 0.15
	p.disc(Vector2.ZERO, 1.0, color)
	p.feather = old
