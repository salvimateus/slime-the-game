extends RefCounted
## Mass, radius and goo-field helpers shared by the player, pieces and droplets.

const MIN_KERNEL_SIZE := 8
const SPLIT_EPSILON := 0.0001
## Share of the field that the hue code (G, B) can use; the surface shader divides by the same number.
const HUE_CODE_SCALE := 0.4

static var _kernel: ImageTexture
static var _additive: CanvasItemMaterial


static func visual_radius(mass: float) -> float:
	if mass <= 0.0:
		return 0.0
	return maxf(Tuning.radius_min_visual, Tuning.radius_full * sqrt(mass / maxf(Tuning.mass_max, SPLIT_EPSILON)))


## Kernel radius divided by visual radius. The kernel is I * (1 - t^2)^2, and the surface sits where it equals the threshold.
static func kernel_scale() -> float:
	var ratio := clampf(Tuning.goo_threshold / maxf(Tuning.goo_intensity, SPLIT_EPSILON), 0.01, 0.99)
	return 1.0 / sqrt(1.0 - sqrt(ratio))


static func kernel_texture() -> ImageTexture:
	if _kernel == null:
		var size: int = maxi(Tuning.goo_kernel_size, MIN_KERNEL_SIZE)
		var data := PackedByteArray()
		data.resize(size * size)
		var half := size * 0.5
		for y: int in size:
			for x: int in size:
				var t := Vector2(x + 0.5 - half, y + 0.5 - half).length() / half
				var v := 0.0
				if t < 1.0:
					var s := 1.0 - t * t
					v = s * s
				data[y * size + x] = int(round(v * 255.0))
		var img := Image.create_from_data(size, size, false, Image.FORMAT_L8, data)
		_kernel = ImageTexture.create_from_image(img)
	return _kernel


static func additive_material() -> CanvasItemMaterial:
	if _additive == null:
		_additive = CanvasItemMaterial.new()
		_additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	return _additive


## Colour of the slime body as the goo field shows it. GooField sets it; the body draws with it.
static var body_color := Color(0.0, 0.0, 0.0, 0.0)
## Hit flash and danger share of the body at its last draw; GooField hands them to the surface shader.
static var body_flash := 0.0
static var body_warn := 0.0
static var _body_code := Color(0.0, 0.0, 0.0, 0.0)


## Field colour of the slime body: R carries the field, G and B the hue of body_color (see source_color).
## The flash and warning shares no longer travel in the field; they go to the shader as body uniforms.
static func field_color(flash := 0.0, warn := 0.0, strength := 1.0) -> Color:
	body_flash = clampf(flash, 0.0, 1.0)
	body_warn = clampf(warn, 0.0, 1.0)
	if _body_code.a <= 0.0:
		_body_code = source_color(base_color())
	var i := strength
	return Color(_body_code.r * i, _body_code.g * i, _body_code.b * i, 1.0)


static func set_body_color(color: Color) -> void:
	body_color = color
	_body_code = source_color(color)


## The original green, the base of every mix.
static func base_color() -> Color:
	return Tuning.goo_body_color


## Field colour of a goo source of the given colour. R is the field. The hue offset from the base green, cut open at
## goo_hue_cut and spread over 0 to 2 PI, is divided by 4 into an angle phi of the first quadrant, and G, B hold
## HUE_CODE_SCALE * I * k * (cos phi, sin phi), where k is the chroma scale of the colour over goo_chroma_scale.y. The shader reads
## phi from the direction of (G, B) alone, so the clipping of R in thick overlaps never moves the hue, and G, B only clip
## where the field passes 1 / HUE_CODE_SCALE. Overlaps blend the hue of their sources. Lightness comes from the tuned palette and the
## chroma stays in goo_chroma_scale, so no mix is mud.
static func source_color(color: Color, strength := 1.0) -> Color:
	var i: float = Tuning.goo_intensity * strength
	var phi := fposmod(hue_offset(color) - Tuning.goo_hue_cut, TAU) * 0.25
	var k := chroma_scale(color) / maxf(Tuning.goo_chroma_scale.y, SPLIT_EPSILON)
	return Color(i, i * HUE_CODE_SCALE * k * cos(phi), i * HUE_CODE_SCALE * k * sin(phi), 1.0)


## Chroma of the colour over the chroma of the base green, in the YCoCg plane, kept in goo_chroma_scale.
static func chroma_scale(color: Color) -> float:
	var base := _ycocg_chroma(base_color())
	return clampf(_ycocg_chroma(color) / maxf(base, SPLIT_EPSILON), Tuning.goo_chroma_scale.x, Tuning.goo_chroma_scale.y)


static func _ycocg_chroma(color: Color) -> float:
	return Vector2(0.5 * (color.r - color.b), -0.25 * color.r + 0.5 * color.g - 0.25 * color.b).length()


## Hue angle of a colour in the YCoCg chroma plane, the plane in which the surface shader turns the palette.
static func ycocg_hue(color: Color) -> float:
	var co := 0.5 * (color.r - color.b)
	var cg := -0.25 * color.r + 0.5 * color.g - 0.25 * color.b
	if absf(co) + absf(cg) < 0.0001:
		return ycocg_hue(base_color()) if color != base_color() else 0.0
	return atan2(cg, co)


## Hue of the colour minus the hue of the base green.
static func hue_offset(color: Color) -> float:
	return angle_difference(ycocg_hue(base_color()), ycocg_hue(color))


## The turn the shader gives to the green palette to show this colour: (cos, sin) of hue_offset times chroma_scale.
static func hue_turn(color: Color) -> Vector2:
	return Vector2.from_angle(hue_offset(color)) * chroma_scale(color)


## True when two goo colours are different enough to show (a null or clear colour means the base green).
static func differs(a: Variant, b: Variant) -> bool:
	var ca: Color = a if a is Color and (a as Color).a > 0.0 else base_color()
	var cb: Color = b if b is Color and (b as Color).a > 0.0 else base_color()
	return absf(angle_difference(ycocg_hue(ca), ycocg_hue(cb))) > Tuning.goo_color_same_hue


## Mixes `amount` of goo of colour `added` into `mass` of goo of colour `current`. The blend runs in Oklab LCh along
## the short hue arc, weighted by the amounts, with lightness and chroma kept in their tuned ranges.
static func mix_goo(current: Color, mass: float, added: Color, amount: float) -> Color:
	if amount <= 0.0:
		return current
	var w := clampf(amount / maxf(mass + amount, SPLIT_EPSILON), 0.0, 1.0)
	var a := _to_lch(current)
	var b := _to_lch(added)
	var hue := a.z + angle_difference(a.z, b.z) * w
	var lightness := clampf(lerpf(a.x, b.x, w), Tuning.goo_mix_lightness.x, Tuning.goo_mix_lightness.y)
	var chroma := clampf(lerpf(a.y, b.y, w), Tuning.goo_mix_chroma.x, Tuning.goo_mix_chroma.y)
	return _from_lch(Vector3(lightness, chroma, hue))


static func color_hex(color: Color) -> String:
	return "#" + color.to_html(false)


static func _to_lch(c: Color) -> Vector3:
	var lab := _to_oklab(c)
	return Vector3(lab.x, Vector2(lab.y, lab.z).length(), atan2(lab.z, lab.y))


static func _from_lch(lch: Vector3) -> Color:
	return _from_oklab(Vector3(lch.x, lch.y * cos(lch.z), lch.y * sin(lch.z)))


static func _lin(v: float) -> float:
	return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)


static func _gam(v: float) -> float:
	var x := maxf(v, 0.0)
	return 12.92 * x if x <= 0.0031308 else 1.055 * pow(x, 1.0 / 2.4) - 0.055


static func _to_oklab(c: Color) -> Vector3:
	var r := _lin(c.r)
	var g := _lin(c.g)
	var b := _lin(c.b)
	var l := pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1.0 / 3.0)
	var m := pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1.0 / 3.0)
	var s := pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1.0 / 3.0)
	return Vector3(
		0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


static func _from_oklab(lab: Vector3) -> Color:
	var l := lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
	var m := lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
	var s := lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
	l = l * l * l
	m = m * m * m
	s = s * s * s
	return Color(
		clampf(_gam(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s), 0.0, 1.0),
		clampf(_gam(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s), 0.0, 1.0),
		clampf(_gam(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), 0.0, 1.0))


## Field strength of goo that is t (0 to 1) through its sink into the soil: it thins and darkens fast at first,
## holds near piece_soak_strength, then drops to the threshold so it vanishes with no pop.
static func soak_strength(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	var ease_out := 1.0 - (1.0 - x) * (1.0 - x)
	var gone := Tuning.goo_threshold / maxf(Tuning.goo_intensity, SPLIT_EPSILON)
	var hold := lerpf(1.0, Tuning.piece_soak_strength, ease_out)
	return lerpf(hold, gone, smoothstep(0.75, 1.0, x))


## Piece masses that sum exactly to amount: one big piece when the loss is large, then medium and small pieces.
static func split_mass(amount: float, rng: RandomNumberGenerator) -> Array[float]:
	var out: Array[float] = []
	if amount <= 0.0:
		return out
	var max_count: int = maxi(Tuning.piece_max_per_event, 1)
	if max_count == 1 or rng == null:
		out.append(amount)
		return out
	var rest := amount
	if amount >= Tuning.piece_big_threshold:
		var big := minf(amount * Tuning.piece_big_ratio * rng.randf_range(0.85, 1.15), amount)
		out.append(big)
		rest -= big
	while rest > SPLIT_EPSILON and out.size() < max_count - 1:
		var range_v: Vector2 = Tuning.piece_medium_mass if rng.randf() < 0.45 else Tuning.piece_small_mass
		var m := minf(rng.randf_range(range_v.x, range_v.y), rest)
		if rest - m < Tuning.piece_min_mass:
			m = rest
		out.append(m)
		rest -= m
	if rest > SPLIT_EPSILON:
		out.append(rest)
	elif rest != 0.0:
		out[out.size() - 1] += rest
	return out


## Point u (0 to 1) of the pull flight from `from` to `to`: a quadratic arc that rises by arc above the middle.
static func pull_point(from: Vector2, to: Vector2, arc: float, u: float) -> Vector2:
	var mid := (from + to) * 0.5 + Vector2(0.0, -arc)
	var a := from.lerp(mid, u)
	var b := mid.lerp(to, u)
	return a.lerp(b, u)


## Arc height of a pull flight of this length.
static func pull_arc(length: float) -> float:
	return length * Tuning.goo_pull_arc + Tuning.goo_pull_arc_min


## Distance from p to the edge of a body: a circle of radius r around center, stretched sideways into a capsule by half.
static func edge_distance(p: Vector2, center: Vector2, half: float, r: float) -> float:
	var d := p - center
	d.x = signf(d.x) * maxf(absf(d.x) - half, 0.0)
	return d.length() - r
