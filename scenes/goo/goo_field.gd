extends CanvasGroup
## Renders every goo source as one gooey surface and owns the pool of detached pieces.

const GooMath := preload("res://scripts/goo/goo_math.gd")
const PieceScene := preload("res://scenes/goo/goo_piece.tscn")
const PieceScript := preload("res://scenes/goo/goo_piece.gd")
const StainsScript := preload("res://scripts/goo/goo_stains.gd")
## Above the player node (z 0), so the carried props draw under the gelatin; the face (z 1, later in the tree) stays on top.
const SURFACE_Z := 1

@onready var pieces: Node2D = $Pieces
@onready var droplets: Node2D = $Droplets

## Mirrors the gloss uniform of the surface shader, which starts on.
var _gloss := true
var _bubble_time := 0.0
var _body_radius := 0.0
## Damp stains on the soil; a sibling drawn under the goo, outside this group so the threshold pass skips it.
var _stains: Node2D
## Colour swirl of the body: the colour it shows when settled, the turn it starts from, contact point and progress.
var _mix_to := Color(0.0, 0.0, 0.0, 0.0)
var _mix_from_turn := Vector2.RIGHT
var _mix_center := Vector2.ZERO
var _mix_t := 1.0
var _status_amount := 0.0
var _status_glow := 0.0
var _sent_flash := -1.0
var _sent_warn := -1.0
var _clear := 0.0
## Gulp wave: a brighter band that runs through the body from the entry point; progress 1 means none.
var _gulp_t := 1.0
var _gulp_strength := 0.0


func _ready() -> void:
	var mat := material as ShaderMaterial
	if mat:
		mat.set_shader_parameter(&"threshold", Tuning.goo_threshold)
		mat.set_shader_parameter(&"lime_color", Tuning.goo_lime_color)
		mat.set_shader_parameter(&"body_color", Tuning.goo_body_color)
		mat.set_shader_parameter(&"spec_color", Tuning.goo_spec_color)
		mat.set_shader_parameter(&"tone_steps", Tuning.goo_tone_steps)
		mat.set_shader_parameter(&"lower_shade", Tuning.goo_lower_shade)
		mat.set_shader_parameter(&"deep_color", Tuning.goo_deep_color)
		mat.set_shader_parameter(&"rim_color", Tuning.goo_rim_color)
		mat.set_shader_parameter(&"warn_color", Tuning.goo_warn_color)
		mat.set_shader_parameter(&"flash_color", Tuning.goo_flash_color)
		mat.set_shader_parameter(&"light_dir", Tuning.goo_light_dir)
		mat.set_shader_parameter(&"rim_width", Tuning.goo_rim_width)
		mat.set_shader_parameter(&"spec_power", Tuning.goo_spec_power)
		mat.set_shader_parameter(&"spec_strength", Tuning.goo_spec_strength)
		mat.set_shader_parameter(&"sheen_power", Tuning.goo_sheen_power)
		mat.set_shader_parameter(&"sheen_strength", Tuning.goo_sheen_strength)
		mat.set_shader_parameter(&"edge_light_strength", Tuning.goo_edge_light_strength)
		mat.set_shader_parameter(&"alpha_range", Tuning.goo_alpha)
		mat.set_shader_parameter(&"density_depth", Tuning.goo_density_depth)
		mat.set_shader_parameter(&"center_color", Tuning.goo_center_color)
		mat.set_shader_parameter(&"glow", Tuning.goo_glow)
		mat.set_shader_parameter(&"bubble_cells", Tuning.goo_bubble_cells)
		mat.set_shader_parameter(&"bubble_rise", Tuning.goo_bubble_rise)
		mat.set_shader_parameter(&"bubble_density", Tuning.goo_bubble_density)
		mat.set_shader_parameter(&"bubble_size", Tuning.goo_bubble_size)
		mat.set_shader_parameter(&"bubble_wobble", Tuning.goo_bubble_wobble)
		mat.set_shader_parameter(&"bubble_wobble_hz", Tuning.goo_bubble_wobble_hz)
		mat.set_shader_parameter(&"bubble_alpha", Tuning.goo_bubble_alpha)
		mat.set_shader_parameter(&"bubble_inner", Tuning.goo_bubble_inner)
		mat.set_shader_parameter(&"mix_swirl", Tuning.goo_mix_swirl)
		mat.set_shader_parameter(&"hue_cut", Vector2.from_angle(Tuning.goo_hue_cut))
		mat.set_shader_parameter(&"chroma_range", Tuning.goo_chroma_scale)
		mat.set_shader_parameter(&"clear_zone", Vector4(Tuning.carry_zone_center.x, Tuning.carry_zone_center.y, Tuning.goo_cargo_clear_half.x, Tuning.goo_cargo_clear_half.y))
		mat.set_shader_parameter(&"clear_alpha", Tuning.goo_cargo_clear_alpha)
		mat.set_shader_parameter(&"status_pulse_hz", Tuning.goo_status_pulse_hz)
	_mix_to = GooMath.base_color()
	GooMath.set_body_color(_mix_to)
	z_index = SURFACE_Z
	fit_margin = Tuning.goo_fit_margin
	clear_margin = Tuning.goo_fit_margin
	droplets.material = GooMath.additive_material()
	for child: Node in get_children():
		_make_additive(child)
	child_entered_tree.connect(_make_additive)
	GooMath.kernel_texture()
	_stains = StainsScript.new()
	_stains.name = &"GooStains"
	_add_stains.call_deferred()
	Game.field = self


func _add_stains() -> void:
	var parent := get_parent()
	if parent == null or not is_instance_valid(_stains):
		return
	parent.add_child(_stains)
	parent.move_child(_stains, get_index())


## A stain layer that never reached the tree has no owner to free it.
func _exit_tree() -> void:
	if is_instance_valid(_stains) and _stains.get_parent() == null:
		_stains.free()


func _process(delta: float) -> void:
	var mat := material as ShaderMaterial
	if mat == null:
		return
	if _gloss != Tuning.goo_gloss:
		_gloss = Tuning.goo_gloss
		mat.set_shader_parameter(&"gloss", _gloss)
	_update_body_frame(mat, delta)
	_update_body_color(mat, delta)
	_update_cargo_clear(mat, delta)
	if _gulp_t < 1.0:
		_gulp_t = minf(_gulp_t + delta / maxf(Tuning.goo_gulp_wave_time, 0.01), 1.0)
		mat.set_shader_parameter(&"gulp_t", _gulp_t)
	if GooMath.body_flash != _sent_flash:
		_sent_flash = GooMath.body_flash
		mat.set_shader_parameter(&"body_flash", _sent_flash)
	if GooMath.body_warn != _sent_warn:
		_sent_warn = GooMath.body_warn
		mat.set_shader_parameter(&"body_warn", _sent_warn)


## The gelatin in front of the carried props turns clearer while the slime carries any.
func _update_cargo_clear(mat: ShaderMaterial, delta: float) -> void:
	var carrying := false
	var player := Game.player
	if is_instance_valid(player) and player.has_method(&"load_count"):
		carrying = int(player.call(&"load_count")) > 0
	var target := 1.0 if carrying else 0.0
	if _clear == target:
		return
	_clear = move_toward(_clear, target, delta / maxf(Tuning.goo_cargo_clear_fade, 0.01))
	mat.set_shader_parameter(&"clear_amount", _clear)


## Tints the slime body (not the loose goo) toward color by amount (0 to 1), with a pulsing light of strength glow.
## Used for the ember look of a burning body and the frost look of a frozen one. Zero amount and glow cost nothing.
func set_body_status(color: Color, amount: float, glow: float) -> void:
	var mat := material as ShaderMaterial
	if mat == null:
		return
	var a := clampf(amount, 0.0, 1.0)
	var g := clampf(glow, 0.0, 1.0)
	if a > 0.0 or g > 0.0:
		mat.set_shader_parameter(&"status_color", color)
	if a != _status_amount:
		_status_amount = a
		mat.set_shader_parameter(&"status_amount", a)
	if g != _status_glow:
		_status_glow = g
		mat.set_shader_parameter(&"status_glow", g)


## Goo entered the body at the global point `from`: a brighter wave runs from there through the body.
func gulp_wave(from: Vector2, strength: float) -> void:
	var mat := material as ShaderMaterial
	if mat == null:
		return
	var center := _body_center_global()
	var at := Vector2(0.0, -1.0)
	if _body_radius > 1.0:
		at = ((from - center) / _body_radius).limit_length(1.0)
	# A wave still running keeps the stronger of the two.
	var left := (1.0 - _gulp_t) * _gulp_strength
	_gulp_t = 0.0
	_gulp_strength = maxf(clampf(strength, 0.0, 1.0), left)
	mat.set_shader_parameter(&"gulp_center", at)
	mat.set_shader_parameter(&"gulp_strength", _gulp_strength)
	mat.set_shader_parameter(&"gulp_t", 0.0)


## The body takes a new colour: it swirls in from the global point `from` and fills the body over goo_mix_time.
func mix_body_color(from: Vector2, color: Color) -> void:
	var mat := material as ShaderMaterial
	if mat == null:
		return
	# A swirl still running starts the next one from the turn it shows now.
	var shown := GooMath.hue_turn(_mix_to)
	if _mix_t < 1.0:
		var blend := _mix_from_turn.lerp(shown, _mix_t)
		shown = blend.normalized() * lerpf(_mix_from_turn.length(), shown.length(), _mix_t)
	_mix_from_turn = shown if shown.length() > 0.001 else Vector2.RIGHT
	_mix_to = color
	GooMath.set_body_color(color)
	_mix_t = 0.0
	var center := _body_center_global()
	if _body_radius > 1.0:
		_mix_center = ((from - center) / _body_radius).limit_length(1.0)
	mat.set_shader_parameter(&"mix_from", _mix_from_turn)
	mat.set_shader_parameter(&"mix_center", _mix_center)
	mat.set_shader_parameter(&"mix_t", 0.0)


## Follows the colour of the player: a change with no mix call (a respawn) shows at once.
func _update_body_color(mat: ShaderMaterial, delta: float) -> void:
	var player := Game.player
	if is_instance_valid(player):
		var goo: Variant = player.get(&"goo_color")
		if goo is Color and not (goo as Color).is_equal_approx(_mix_to):
			_mix_to = goo
			GooMath.set_body_color(_mix_to)
			if _mix_t < 1.0:
				_mix_t = 1.0
				mat.set_shader_parameter(&"mix_t", 1.0)
	if _mix_t < 1.0:
		_mix_t = minf(_mix_t + delta / maxf(Tuning.goo_mix_time, 0.01), 1.0)
		mat.set_shader_parameter(&"mix_t", _mix_t)


func _body_center_global() -> Vector2:
	var player := Game.player
	if not is_instance_valid(player) or not player.has_method(&"visual_position"):
		return Vector2.ZERO
	var center: Vector2 = player.call(&"visual_position")
	var body := player.get(&"body_visual") as Node2D
	if is_instance_valid(body) and body.has_method(&"deform_point"):
		center += body.call(&"deform_point", Vector2.ZERO)
	return center


## Colour of goo that leaves the slime now; a clear colour argument means this one.
func body_goo_color() -> Color:
	var player := Game.player
	if is_instance_valid(player):
		var goo: Variant = player.get(&"goo_color")
		if goo is Color:
			return goo
	return GooMath.base_color()


func _resolve(color: Color) -> Color:
	return color if color.a > 0.0 else body_goo_color()


## Shade and bubbles live in the body frame: centre and radius of the drawn slime, at its interpolated position.
func _update_body_frame(mat: ShaderMaterial, delta: float) -> void:
	_bubble_time += delta
	var radius := 0.0
	var center := Vector2.ZERO
	var player := Game.player
	if is_instance_valid(player) and player.has_method(&"visual_position"):
		var body := player.get(&"body_visual") as Node2D
		if is_instance_valid(body) and body.has_method(&"radius"):
			radius = float(body.call(&"radius"))
			center = player.call(&"visual_position")
			if body.has_method(&"deform_point"):
				center += body.call(&"deform_point", Vector2.ZERO)
	if radius > 1.0:
		mat.set_shader_parameter(&"body_center", center)
		mat.set_shader_parameter(&"bubble_time", _bubble_time)
	if radius != _body_radius:
		_body_radius = radius
		mat.set_shader_parameter(&"body_radius", radius if radius > 1.0 else 0.0)


## Every extra goo source (the SlimeBody) adds into the field instead of covering it.
func _make_additive(child: Node) -> void:
	if child == pieces or child.get_parent() != self:
		return
	if child is CanvasItem and (child as CanvasItem).material == null:
		(child as CanvasItem).material = GooMath.additive_material()


## color: the goo colour; a clear colour (the default) means the current colour of the slime.
func spawn_piece(at: Vector2, mass: float, velocity: Vector2, decorative: bool, color := Color(0.0, 0.0, 0.0, 0.0)) -> Node2D:
	if mass <= 0.0:
		return null
	var live := _live_piece_count()
	if live >= Tuning.piece_cap:
		_evict_one()
	elif live >= Tuning.piece_soak_cap:
		_soak_oldest()
	var piece := PieceScene.instantiate() as Node2D
	piece.material = GooMath.additive_material()
	piece.position = pieces.to_local(at)
	pieces.add_child(piece)
	piece.call(&"setup", at, mass, velocity, decorative, _resolve(color))
	return piece


func clear_pieces(report_lost: bool) -> void:
	for piece: Node in pieces.get_children():
		if piece.is_queued_for_deletion():
			continue
		var mass: float = piece.get(&"mass")
		if report_lost and not piece.get(&"decorative") and mass > 0.0:
			Game.report_lost(mass, &"cleared")
		piece.set(&"mass", 0.0)
		piece.queue_free()


func release_droplets(rect: Rect2) -> void:
	droplets.call(&"release", rect)


func clear_droplets() -> void:
	droplets.call(&"clear")
	if is_instance_valid(_stains):
		_stains.call(&"clear")


## A damp mark on the soil where goo sank: half size along the surface (x) and across it (y), grown over grow_time.
func stain(at: Vector2, half_size: Vector2, normal: Vector2, grow_time: float) -> void:
	if is_instance_valid(_stains) and _stains.is_inside_tree():
		_stains.call(&"add", at, half_size, normal, grow_time)


func total_piece_mass() -> float:
	var total := 0.0
	for piece: Node in pieces.get_children():
		if not piece.is_queued_for_deletion() and not piece.get(&"decorative"):
			total += float(piece.get(&"mass"))
	return total


## Live pieces, decorative ones included; pieces that are already freed this frame do not count.
func piece_count() -> int:
	return _live_piece_count()


func droplet_count() -> int:
	return int(droplets.call(&"count"))


## Global position of the nearest piece that can still be slurped, or null.
func nearest_piece(from: Vector2, max_dist: float) -> Variant:
	var best: Variant = null
	var best_d := max_dist * max_dist
	# Distance first: the flags are read only for a piece that would be nearer.
	for k: int in pieces.get_child_count():
		var piece := pieces.get_child(k) as PieceScript
		var d := from.distance_squared_to(piece.global_position)
		if d >= best_d or piece.decorative or piece.absorbing or piece.is_queued_for_deletion():
			continue
		best_d = d
		best = piece.global_position
	return best


## In spray, burst and drip a clear colour (the default) means the current colour of the slime.
func spray(origin: Vector2, dir: Vector2, count: int, speed: Vector2, spread_deg: float, radius: Vector2, inherit := Vector2.ZERO, color := Color(0.0, 0.0, 0.0, 0.0)) -> void:
	droplets.call(&"spray", origin, dir, count, speed, spread_deg, radius, inherit, _resolve(color))


func burst(origin: Vector2, count: int, speed: Vector2, radius: Vector2, color := Color(0.0, 0.0, 0.0, 0.0)) -> void:
	droplets.call(&"burst", origin, count, speed, radius, _resolve(color))


func drip(origin: Vector2, radius: float, life: float, normal := Vector2.UP, color := Color(0.0, 0.0, 0.0, 0.0)) -> void:
	droplets.call(&"drip", origin, radius, life, normal, _resolve(color))


func _live_piece_count() -> int:
	var n := 0
	for piece: Node in pieces.get_children():
		if not piece.is_queued_for_deletion():
			n += 1
	return n


## The oldest piece that is not already sinking or being slurped starts to sink.
func _soak_oldest() -> void:
	for piece: Node in pieces.get_children():
		if piece.is_queued_for_deletion() or piece.get(&"absorbing") or piece.get(&"soaking"):
			continue
		piece.call(&"start_soak")
		return


## Frees a decorative piece first; otherwise the oldest piece that is not being slurped, and books its mass as lost.
func _evict_one() -> void:
	var oldest: Node = null
	for piece: Node in pieces.get_children():
		if piece.is_queued_for_deletion() or piece.get(&"absorbing"):
			continue
		if piece.get(&"decorative"):
			piece.queue_free()
			return
		if oldest == null:
			oldest = piece
	if oldest == null:
		return
	Game.report_lost(float(oldest.get(&"mass")), &"evicted")
	oldest.set(&"mass", 0.0)
	oldest.queue_free()
