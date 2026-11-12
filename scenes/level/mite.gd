extends "res://scripts/level/hazard.gd"
## Spore mite: a one-eyed spotted shell on stubby legs. Patrols a floor span, bites the slime through the Hazard
## contract and pops after Tuning.mite_hp shots. Its Shell body is what props collide with.
## Each mite takes a colour palette by its order in the level (Tuning.mite_color_order) and, when it pops, bursts into
## goo of its palette colour that the slime can slurp for mass and colour.

const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")

const LEG_PAIRS := 3
const SPIKES := 5
const DOME_SEGMENTS := 18
const LAND_SQUASH_SPEED := 200.0
const SQUASH_STIFFNESS := 260.0
const SQUASH_DAMPING := 12.0
const DEATH_SWELL := 0.7
const LOOK_SMOOTH := 10.0
const GROUP := &"colored_mites"
const GooMath := preload("res://scripts/goo/goo_math.gd")
const FireTorch := preload("res://scripts/fire/fire_torch.gd")

var _a_x := 0.0
var _b_x := 0.0
var _floor_y := 0.0
var _x := 0.0
var _dir := 1.0
var _pause := 0.0
var _hop := 0.0
var _hop_vel := 0.0
var _knock_vel := 0.0
var _hp := 2
var _dead := false
var _death_left := 0.0
## Killed by fire (an ember shot or the ember trail): it chars and burns in its death.
var _burnt := false
var _flash := 0.0
var _hurt_face := 0.0
var _walk_phase := 0.0
var _squash := 0.0
var _squash_vel := 0.0
var _look := Vector2.RIGHT
var _configured := false
var _palette_set := false
var _shell_color := Tuning.mite_shell
var _shell_light := Tuning.mite_shell_light
var _shell_dark := Tuning.mite_shell_dark
var _belly := Tuning.mite_belly
var _spot := Tuning.mite_spot
var _leg := Tuning.mite_leg
var _goo := Tuning.mite_goo
var _batch := ShapeBatch.new()
## Look key of the last redraw: the mite redraws only when it changes and only near the screen.
var _drawn_key: Array = []

@onready var _shell: StaticBody2D = $Shell
@onready var _shell_shape: CollisionShape2D = $Shell/CollisionShape2D
@onready var _bite_shape: CollisionShape2D = $CollisionShape2D


func _ready() -> void:
	super()
	add_to_group(GROUP)


## Colour name of this mite: its rank by start position (left to right, then top to bottom) in the tuned order.
func color_name() -> StringName:
	var order: Array[StringName] = Tuning.mite_color_order
	if order.is_empty():
		return &"purple"
	var mites := get_tree().get_nodes_in_group(GROUP) if is_inside_tree() else []
	var rank := 0
	for other: Node in mites:
		if other == self or not (other is Node2D):
			continue
		var o := other as Node2D
		var mine := global_position
		if o.global_position.x < mine.x or (o.global_position.x == mine.x and o.global_position.y < mine.y):
			rank += 1
	return order[rank % order.size()]


func _apply_palette() -> void:
	_palette_set = true
	var palette_name := color_name()
	if not Tuning.mite_palettes.has(palette_name):
		return
	var pal: Dictionary = Tuning.mite_palettes[palette_name]
	_shell_color = pal.get("shell", _shell_color)
	_shell_light = pal.get("shell_light", _shell_light)
	_shell_dark = pal.get("shell_dark", _shell_dark)
	_belly = pal.get("belly", _belly)
	_spot = pal.get("spot", _spot)
	_leg = pal.get("leg", _leg)
	_goo = pal.get("goo", _shell_color)


func setup(a: Vector2, b: Vector2, start: Vector2) -> void:
	_a_x = minf(a.x, b.x)
	_b_x = maxf(a.x, b.x)
	_floor_y = start.y + Tuning.tile_size * 0.5
	_x = clampf(start.x, _a_x, _b_x)
	_hp = Tuning.mite_hp
	loss = Tuning.mite_loss
	source = &"mite"
	var bite := CircleShape2D.new()
	bite.radius = Tuning.mite_hit_radius
	_bite_shape.shape = bite
	_bite_shape.position = _body_center()
	var shell := CircleShape2D.new()
	shell.radius = Tuning.mite_body_radius
	_shell_shape.shape = shell
	_shell_shape.position = _body_center()
	_shell.collision_layer = Tuning.LAYER_ENEMIES
	_shell.collision_mask = 0
	global_position = Vector2(_x, _floor_y)
	reset_physics_interpolation()
	_configured = true


func hit_center() -> Vector2:
	return global_position + _body_center()


## A prop that hits the shell while hot. Returns {"hit": true} so the prop rebounds spent.
func shot_hit(hit: Dictionary) -> Dictionary:
	if _dead:
		return {}
	var at: Vector2 = hit.get("at", hit_center())
	var dir: Vector2 = hit.get("dir", Vector2.RIGHT)
	_hp -= maxi(int(hit.get("damage", 1)), 1)
	_burnt = bool(hit.get("ember", false)) or hit.get("source", &"") == &"ember_trail"
	var away := signf(dir.x) if dir.x != 0.0 else signf(global_position.x - at.x)
	_knock_vel = away * Tuning.mite_knockback
	_hop_vel = Tuning.mite_hop
	_flash = 1.0
	_hurt_face = Tuning.mite_flash_time * 2.0
	_squash_vel -= 6.0
	if is_instance_valid(Juice.sparks):
		Juice.sparks.call(&"sparks", at, -dir, Tuning.mite_hit_spark_count, Vector2(200.0, 560.0), 70.0, _spot)
		Juice.sparks.call(&"debris", at, -dir, 6, Vector2(160.0, 380.0), 60.0, Vector2(2.5, 4.5), PackedColorArray([_shell_light, _belly]), true)
	Sfx.play(&"thwack", at)
	Game.report_target_hit(&"mite", _hp, at)
	if _hp <= 0:
		_die(dir)
	else:
		Juice.hitstop(Tuning.mite_hit_hitstop)
		Juice.shake(Tuning.mite_hit_shake, &"mite_hit")
		Juice.punch(Tuning.mite_hit_punch, &"mite_hit")
	return {"hit": true}


func _die(dir: Vector2) -> void:
	_dead = true
	_death_left = Tuning.mite_death_time
	set_deferred(&"monitorable", false)
	_shell.collision_layer = 0
	var center := hit_center()
	Juice.hitstop(Tuning.mite_death_hitstop)
	Juice.slowmo(Tuning.mite_death_slowmo_scale, Tuning.mite_death_slowmo_time)
	Juice.shake(Tuning.mite_death_shake, &"mite_death")
	Juice.punch(Tuning.mite_death_punch, &"mite_death")
	Juice.flash(Tuning.mite_death_flash_color, Tuning.mite_death_flash_time)
	if is_instance_valid(Juice.sparks):
		var spores := PackedColorArray([_shell_color, _shell_light, _spot, _belly])
		Juice.sparks.call(&"debris", center, Vector2.UP, Tuning.mite_spore_count, Tuning.mite_spore_speed, 180.0, Tuning.mite_spore_size, spores, true)
		Juice.sparks.call(&"debris", center, dir, 8, Tuning.mite_spore_speed, 50.0, Vector2(6.0, 10.0), PackedColorArray([_shell_dark, _shell_color]), false)
		Juice.sparks.call(&"ring", center, Tuning.mite_ring_radius, _shell_light, 0.35)
		Juice.sparks.call(&"sparks", center, Vector2.UP, 18, Vector2(300.0, 800.0), 180.0, _spot, Vector2(2.0, 4.0))
	_drop_goo(center, dir)
	if _burnt:
		_burn(center, dir)
	Sfx.play(&"pop", center)
	Game.report_enemy_death(&"mite", center)


## Death by fire: a burst of flame and sparks, and a fire that burns on where the mite was, then dies down.
func _burn(center: Vector2, dir: Vector2) -> void:
	if is_instance_valid(Juice.sparks):
		Juice.sparks.call(&"sparks", center, Vector2.UP, Tuning.mite_burn_sparks, Vector2(240.0, 720.0), 120.0, Tuning.fire_yellow_color, Vector2(2.0, 4.5))
		Juice.sparks.call(&"sparks", center, -dir, 12, Vector2(200.0, 520.0), 60.0, Tuning.fire_orange_color, Vector2(2.0, 4.0))
	var parent := get_parent()
	if parent == null:
		return
	var torch := FireTorch.new(Tuning.mite_body_radius * Tuning.mite_burn_size, 0.73)
	torch.z_index = Tuning.fire_bed_z_index
	parent.add_child(torch)
	torch.global_position = center
	torch.call(&"burn_out", Tuning.mite_burn_time)
	Sfx.play(&"ignite", center, 1.3, -6.0)


## The pop bursts the mite into goo of its palette colour: new goo with mass, booked as gained, plus a droplet spray.
func _drop_goo(center: Vector2, dir: Vector2) -> void:
	var field := Game.field
	if not is_instance_valid(field) or Tuning.mite_goo_mass <= 0.0:
		return
	var total := Tuning.mite_goo_mass
	Game.report_gained(total, &"mite")
	var spread := deg_to_rad(Tuning.piece_eject_spread_deg)
	var up := (Vector2.UP + Vector2(dir.x, 0.0) * 0.5).normalized()
	for m: float in GooMath.split_mass(total, Game.rng):
		var a := up.angle() + Game.rng.randf_range(-spread, spread)
		var speed := Game.rng.randf_range(Tuning.piece_eject_speed.x, Tuning.piece_eject_speed.y)
		speed *= lerpf(Tuning.piece_eject_size_speed.x, Tuning.piece_eject_size_speed.y, clampf(m / Tuning.piece_eject_size_ref, 0.0, 1.0))
		field.call(&"spawn_piece", center, m, Vector2.from_angle(a) * speed, false, _goo)
	field.call(&"burst", center, Tuning.mite_goo_droplets, Tuning.mite_goo_droplet_speed, Tuning.mite_goo_droplet_radius, _goo)


func _on_hit_landed(_amount: float, _at: Vector2) -> void:
	_squash_vel += Tuning.mite_bite_squash * 20.0
	_hop_vel = maxf(_hop_vel, Tuning.mite_hop * 0.4)


func _physics_process(delta: float) -> void:
	if not _configured:
		return
	if not _palette_set:
		_apply_palette()
	if _dead:
		_death_left -= delta
		if _death_left <= 0.0:
			queue_free()
		return
	_knock_vel = move_toward(_knock_vel, 0.0, absf(_knock_vel) * Tuning.mite_knock_decay * delta + 1.0)
	var walking := _pause <= 0.0 and _hop <= 0.0 and absf(_knock_vel) < 1.0
	if _pause > 0.0:
		_pause -= delta
	elif walking:
		_x += _dir * Tuning.mite_speed * delta
		_walk_phase += delta * Tuning.mite_walk_hz
	_x += _knock_vel * delta
	if _x <= _a_x or _x >= _b_x:
		_x = clampf(_x, _a_x, _b_x)
		var inward := 1.0 if _x <= _a_x else -1.0
		if _dir != inward:
			_dir = inward
			_pause = Tuning.mite_turn_pause
		_knock_vel = 0.0
	_hop_vel -= Tuning.mite_gravity * delta
	_hop += _hop_vel * delta
	if _hop <= 0.0:
		if _hop_vel < -LAND_SQUASH_SPEED:
			_squash_vel += absf(_hop_vel) * 0.01
		_hop = 0.0
		_hop_vel = 0.0
	global_position = Vector2(_x, _floor_y - _hop)


func _process(delta: float) -> void:
	_flash = maxf(_flash - delta / maxf(Tuning.mite_flash_time, 0.01), 0.0)
	_hurt_face = maxf(_hurt_face - delta, 0.0)
	_squash_vel += (-_squash * SQUASH_STIFFNESS - _squash_vel * SQUASH_DAMPING) * delta
	_squash = clampf(_squash + _squash_vel * delta, -0.4, 0.4)
	var target := Vector2(_dir, 0.0)
	if is_instance_valid(Game.player):
		var to_player := Game.player.global_position - hit_center()
		if to_player.length() < 420.0:
			target = to_player.normalized()
	_look = _look.lerp(target, 1.0 - exp(-delta * LOOK_SMOOTH))
	if visible != Tuning.fx_enemies:
		visible = Tuning.fx_enemies
	if not visible or not _is_near_screen():
		return
	var key := [_dead, _death_left if _dead else 0.0, _flash, _hurt_face > 0.0, snappedf(_squash, 0.001), _look.snapped(Vector2(0.01, 0.01)),
		_walk_phase, _hop, _dir, _shell_color]
	if key != _drawn_key:
		_drawn_key = key
		queue_redraw()


## The mite redraws only when it is within two tiles of the view; the world moves it by its transform.
func _is_near_screen() -> bool:
	var viewport := get_viewport()
	var view := viewport.get_canvas_transform().affine_inverse() * viewport.get_visible_rect()
	return view.grow(Tuning.tile_size * 2.0).has_point(global_position)


func _body_center() -> Vector2:
	return Vector2(0.0, -Tuning.mite_body_radius * 1.2)


func _draw() -> void:
	_batch.clear()
	var r := Tuning.mite_body_radius
	var swell := 1.0
	var fade := 1.0
	if _dead:
		var t := 1.0 - clampf(_death_left / maxf(Tuning.mite_death_time, 0.001), 0.0, 1.0)
		swell = 1.0 + DEATH_SWELL * t
		fade = 1.0 - t
	var white := 1.0 if _dead and not _burnt else _flash
	var shadow_scale := clampf(1.0 - _hop / 160.0, 0.4, 1.0)
	_batch.transform = Transform2D(0.0, Vector2(shadow_scale, shadow_scale * 0.28), 0.0, Vector2(0.0, _hop))
	_batch.disc(Vector2.ZERO, r * 1.05, Color(0.0, 0.0, 0.0, 0.3 * fade))
	var sx := (1.0 + _squash) * swell
	var sy := (1.0 - _squash) * swell
	_batch.transform = Transform2D(0.0, Vector2(sx, sy), 0.0, Vector2.ZERO)
	if not _dead:
		_draw_legs(r)
	var c := _body_center()
	var shell := _tone(_shell_color, white, fade)
	var shell_light := _tone(_shell_light, white, fade)
	var shell_dark := _tone(_shell_dark, white, fade)
	var belly := _tone(_belly, white, fade)
	var ink := _tone(Tuning.ground_outline_color, white * 0.5, fade)
	_batch.disc(c + Vector2(0.0, r * 0.15), r * 0.9, ink)
	_batch.disc(c + Vector2(0.0, r * 0.15), r * 0.8, belly)
	var dome := _dome(c, r)
	for i: int in SPIKES:
		var a := lerpf(PI + 0.55, TAU - 0.55, float(i) / float(SPIKES - 1))
		var base := c + Vector2.from_angle(a) * r * 0.92
		var tip := c + Vector2.from_angle(a) * r * 1.38
		var side := Vector2.from_angle(a).orthogonal() * r * 0.16
		_batch.feather = 0.0
		_batch.polygon(PackedVector2Array([base - side, tip, base + side]), shell_dark)
	_batch.polygon(_grow(dome, c, 1.08), ink)
	_batch.polygon(dome, shell)
	_batch.polygon(_grow(dome, c + Vector2(-r * 0.25, -r * 0.35), 0.5), shell_light)
	_batch.feather = ShapeBatch.SOFT_EDGE
	for spot: Vector2 in [Vector2(-0.5, -0.35), Vector2(0.15, -0.62), Vector2(0.55, -0.2)]:
		_batch.disc(c + spot * r, r * 0.13, _tone(_spot, white, fade))
	_draw_eye(c, r, white, fade)
	_batch.commit(get_canvas_item())


func _draw_legs(r: float) -> void:
	var leg := _tone(_leg, _flash, 1.0)
	for i: int in LEG_PAIRS:
		var x := lerpf(-0.6, 0.6, float(i) / float(LEG_PAIRS - 1)) * r
		var swing := sin(TAU * _walk_phase + float(i) * 2.1) * r * 0.18
		var hip := Vector2(x, -r * 0.5)
		_batch.stroke(PackedVector2Array([hip, Vector2(x + swing, 0.0)]), r * 0.16, leg, false, false)
		_batch.disc(Vector2(x + swing, -r * 0.03), r * 0.1, leg)


func _draw_eye(c: Vector2, r: float, white: float, fade: float) -> void:
	var eye_at := c + Vector2(_dir * r * 0.32, -r * 0.18)
	var eye_r := r * 0.38
	var ink := _tone(Tuning.ground_outline_color, white * 0.5, fade)
	if _dead or _hurt_face > 0.0:
		var s := eye_r * 0.6
		_batch.stroke(PackedVector2Array([eye_at + Vector2(-s, -s), eye_at + Vector2(s, s)]), eye_r * 0.3, ink, false, false)
		_batch.stroke(PackedVector2Array([eye_at + Vector2(-s, s), eye_at + Vector2(s, -s)]), eye_r * 0.3, ink, false, false)
		return
	_batch.disc(eye_at, eye_r + 1.5, ink)
	_batch.disc(eye_at, eye_r, _tone(Tuning.mite_eye, white, fade))
	var pupil := eye_at + _look * eye_r * 0.4
	_batch.disc(pupil, eye_r * 0.5, _tone(Tuning.mite_pupil, white, fade))
	_batch.disc(pupil + Vector2(-0.3, -0.35) * eye_r * 0.6, eye_r * 0.16, Color(1.0, 1.0, 1.0, fade))
	var brow_in := eye_at + Vector2(-_dir * eye_r * 0.8, -eye_r * 1.0)
	var brow_out := eye_at + Vector2(_dir * eye_r * 0.9, -eye_r * 1.4)
	_batch.stroke(PackedVector2Array([brow_in, brow_out]), eye_r * 0.28, ink, false, false)


func _dome(c: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i: int in DOME_SEGMENTS + 1:
		var a := PI + PI * float(i) / float(DOME_SEGMENTS)
		pts.append(c + Vector2(cos(a) * r, sin(a) * r * 0.95))
	pts.append(c + Vector2(r * 0.9, r * 0.3))
	pts.append(c + Vector2(-r * 0.9, r * 0.3))
	return pts


func _grow(pts: PackedVector2Array, center: Vector2, scale_by: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(pts.size())
	for i: int in pts.size():
		out[i] = center + (pts[i] - center) * scale_by
	return out


## Colour of the shell parts; a mite that dies in fire chars toward a glowing black as it goes.
func _tone(color: Color, white: float, alpha: float) -> Color:
	if _burnt and _dead:
		var t := 1.0 - clampf(_death_left / maxf(Tuning.mite_death_time, 0.001), 0.0, 1.0)
		color = color.lerp(Tuning.mite_char_color, minf(0.5 + t, 1.0))
	var c := color.lerp(Color.WHITE, clampf(white, 0.0, 1.0))
	c.a *= alpha
	return c
