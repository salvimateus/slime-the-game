extends CharacterBody2D
## Rock or crystal with no goo mass: rests in the level, is swallowed by the slime, flies as a ricochet shot that
## damages what it hits, then tumbles to rest and can be swallowed again. A hot shot breaks on a trap that
## breaks_props() into smaller props of the same material, until the smallest size, which only bounces.
## A collider (or its parent) with shot_hit(hit: Dictionary) -> Dictionary is a target; see _hit_target().
## The prop layer draws every prop in one batch through draw_into(); the prop itself draws nothing.

const PropArt := preload("res://scripts/props/prop_art.gd")
const ShapeBatch := preload("res://scripts/fx/shape_batch.gd")
const FireTorch := preload("res://scripts/fire/fire_torch.gd")
const Hazard := preload("res://scripts/level/hazard.gd")

enum State { LOOSE, SHOT, TUMBLE, RETURNING }

const FLOOR_NORMAL_Y := -0.65
const CEILING_NORMAL_Y := 0.65
const MAX_SLIDES := 3
const SUPPORT_PROBE := 2.0
const HAZARD_COOLDOWN_TICKS := 5
const TARGET_REBOUND := 0.4
const TARGET_HOP := 260.0
const GLINT_SIZE := 9.0
const GLINT_TIME := 0.35
const RETURN_RING_RADIUS := 40.0

var kind: StringName = &"rock"
var shape_seed := 0
var home := Vector2.ZERO
var state: State = State.LOOSE
## Bounces of the current throw, hot and spent; a new throw starts again at zero.
var bounces := 0
## Spawn order in the prop layer; the oldest resting piece is the first to go when the layer is full.
var serial := 0

var _radius := 10.0
var _angle := 0.0
var _spin := 0.0
var _absorb_wait := 0.0
var _reject_wait := 0.0
var _return_wait := 0.0
var _glint_wait := 0.0
var _flash := 0.0
var _on_floor := false
var _hot_time := 0.0
## A thrown prop keeps the shot gravity for its whole flight; a dropped one falls with prop_gravity.
var _thrown := false
var _rest_time := 0.0
var _thrown_from := Vector2.ZERO
var _trail := PackedVector2Array()
var _hazard_ticks := {}
## A fresh piece passes through the trap it broke on for a moment, so it leaves the trap instead of bouncing inside it.
var _grace_hazard := 0
var _grace_time := 0.0
## True only for a piece that a break made and that the slime never swallowed; only such a piece can be evicted.
var _from_break := false
## A shot spat by a burning slime: it glows, hits harder and sheds burning embers while it flies hot.
var ember := false
## 1 while the ember shot flies hot, then it cools down to 0 (look only).
var _ember_heat := 0.0
var _ember_travel := 0.0
## Heat step the layer last drew the rock with; the rock redraws only when it changes.
var _ember_drawn_step := -1
## The fire the ember carries (scripts/fire/fire_torch.gd), freed when it has cooled.
var _torch: Node2D
var _draw_prev := Vector2.ZERO
var _draw_prev_angle := 0.0
var _hazard_query := PhysicsShapeQueryParameters2D.new()
var _hazard_shape := CircleShape2D.new()
## Trap contacts since the prop last came to rest; see _count_trap_contact().
var _trap_contacts := 0
## Time in the current tumble; a tumble that never ends is rescued (Tuning.prop_tumble_max_time).
var _tumble_time := 0.0
var _return_target := Vector2.ZERO
var _trap_query := PhysicsShapeQueryParameters2D.new()
var _trap_shape := CircleShape2D.new()
var _rng := RandomNumberGenerator.new()
var _support_hit := KinematicCollision2D.new()
var _support_at := Vector2.INF
var _support_body: Node

@onready var _shape: CollisionShape2D = $CollisionShape2D


func setup(identity: Dictionary, at: Vector2, initial_velocity: Vector2, mode: State) -> void:
	kind = identity.get("kind", &"rock")
	shape_seed = int(identity.get("seed", 0))
	home = identity.get("home", at)
	ember = bool(identity.get("ember", false))
	_ember_heat = 1.0 if ember else 0.0
	_ember_travel = 0.0
	if ember and _torch == null:
		_torch = FireTorch.new(PropArt.radius_of(kind), fposmod(float(shape_seed) * 0.618, 1.0))
		add_child(_torch)
	_radius = PropArt.radius_of(kind)
	_rng.seed = shape_seed
	_glint_wait = _rng.randf_range(Tuning.prop_idle_glint_interval.x, Tuning.prop_idle_glint_interval.y)
	var circle := CircleShape2D.new()
	circle.radius = _radius
	_shape.shape = circle
	_hazard_shape.radius = _radius
	_hazard_query.shape = _hazard_shape
	_hazard_query.collision_mask = Tuning.LAYER_HAZARDS
	_hazard_query.collide_with_areas = true
	_hazard_query.collide_with_bodies = false
	collision_layer = Tuning.LAYER_PROPS
	collision_mask = Tuning.LAYER_WORLD | Tuning.LAYER_PLATFORMS | Tuning.LAYER_ENEMIES | Tuning.LAYER_GRATES
	global_position = at
	_teleported()
	_thrown_from = at
	_thrown = false
	velocity = initial_velocity
	# A home inside a trap's reach would send the prop back into the trap on every way home.
	if Game.level_running and _trap_reach_at(home, _radius + Tuning.prop_safe_margin) != null:
		home = _safe_point(home, 1.0)
	_enter(mode)


## Where a prop of this radius thrown from center along dir starts. "contact" is true when a wall or target is closer
## than half the spawn distance; then "collider", "normal" and "point" describe the hit the prop takes at once.
## Shared with the aim preview, so the preview starts exactly where the shot does.
static func spawn_point(space: PhysicsDirectSpaceState2D, center: Vector2, dir: Vector2, spawn_dist: float, radius: float) -> Dictionary:
	var ray := PhysicsRayQueryParameters2D.create(center, center + dir * (spawn_dist + radius + 1.0), Tuning.LAYER_WORLD | Tuning.LAYER_ENEMIES | Tuning.LAYER_GRATES)
	var hit := space.intersect_ray(ray)
	if hit.is_empty():
		return {"at": center + dir * spawn_dist, "contact": false}
	var hit_at: Vector2 = hit.position
	var room := center.distance_to(hit_at) - radius - 1.0
	return {"at": center + dir * maxf(room, 0.0), "contact": room < spawn_dist * 0.5, "collider": hit.collider, "normal": hit.normal, "point": hit_at}


## One physics step of a thrown prop: [motion, new velocity] on the exact parabola of constant gravity,
## so any tick length (slow motion included) follows the same path.
static func flight_step(velocity_in: Vector2, gravity: float, delta: float) -> Array[Vector2]:
	return [velocity_in * delta + Vector2(0.0, 0.5 * gravity * delta * delta), velocity_in + Vector2(0.0, gravity * delta)]


## Velocity after a hot bounce off a surface with this normal.
static func hot_bounce(velocity_in: Vector2, normal: Vector2) -> Vector2:
	var vn := normal * velocity_in.dot(normal)
	return (velocity_in - vn) * Tuning.shot_friction - vn * Tuning.shot_restitution


## Throws the prop from the slime centre along dir. A wall or target closer than the spawn distance takes the hit at once.
func launch(center: Vector2, dir: Vector2, spawn_dist: float, initial_velocity: Vector2) -> void:
	velocity = initial_velocity
	_thrown_from = center
	_thrown = true
	_enter(State.SHOT)
	_absorb_wait = Tuning.shot_catch_delay
	var start := spawn_point(get_world_2d().direct_space_state, center, dir, spawn_dist, _radius)
	global_position = start.at
	_teleported()
	if bool(start.contact):
		_resolve_contact(start.collider, start.normal, start.point)


## A piece just made by a break: it flashes, spins and ignores the trap it broke on for a moment.
func burst_out(trap_id: int) -> void:
	_flash = 1.0
	_angle = _rng.randf_range(0.0, TAU)
	_draw_prev_angle = _angle
	_spin = _rng.randf_range(-Tuning.prop_shatter_spin, Tuning.prop_shatter_spin)
	_grace_hazard = trap_id
	_grace_time = Tuning.prop_shatter_trap_grace
	_from_break = true


func identity() -> Dictionary:
	return {"kind": kind, "seed": shape_seed, "home": home}


func can_be_absorbed() -> bool:
	return state != State.RETURNING and _absorb_wait <= 0.0 and not is_queued_for_deletion()


## A break piece that the slime never swallowed (never a full prop, never a prop the slime dropped) and that rests out
## of sight; the prop layer removes these first when it is full.
func can_evict() -> bool:
	return _from_break and PropArt.size_of(kind) > 0 and state == State.LOOSE and not is_queued_for_deletion() and not _on_screen()


## Hands the prop to whoever swallows it; the node is gone after this call.
func take() -> Dictionary:
	var data := identity()
	_remove()
	return data


## Removes a surplus piece with a small puff, to keep the number of loose props under Tuning.prop_loose_max.
func evict() -> void:
	if is_instance_valid(Juice.sparks):
		Juice.sparks.call(&"glint", global_position, GLINT_SIZE, Color.WHITE, GLINT_TIME)
		Juice.sparks.call(&"ring", global_position, _radius * 2.0, PropArt.spark_color_of(kind), GLINT_TIME)
	Game.report_prop_dropped(kind, global_position, &"limit")
	_remove()


## A full slime bumps a loose prop away instead of swallowing it.
func reject(from: Vector2) -> bool:
	if _reject_wait > 0.0 or state != State.LOOSE:
		return false
	_reject_wait = Tuning.prop_reject_cooldown
	var away := signf(global_position.x - from.x)
	if away == 0.0:
		away = 1.0
	velocity = Vector2(away * Tuning.prop_reject_speed.x, -Tuning.prop_reject_speed.y)
	_thrown_from = global_position
	_thrown = false
	bounces = 0
	_enter(State.TUMBLE)
	_absorb_wait = 0.0
	return true


## {"kind", "at", "state", "safe"} for the run log; safe means at rest on support, outside every trap and above the kill line.
func audit() -> Dictionary:
	var resting := state == State.LOOSE and test_move(global_transform, Vector2(0.0, SUPPORT_PROBE))
	var safe := resting and _trap_reach_at(global_position, _radius) == null and global_position.y < Game.kill_y
	return {"kind": String(kind), "at": [snappedf(global_position.x, 0.1), snappedf(global_position.y, 0.1)], "state": String(State.keys()[state]), "safe": safe}


## True while the prop moves or fades a flash, so the layer redraws only then.
func is_animating() -> bool:
	return (state == State.SHOT or state == State.TUMBLE) or _flash > 0.0 or _draw_prev != global_position


## Adds the prop, and its trail while hot, to the layer batch at its interpolated position.
func draw_into(batch: ShapeBatch, to_layer: Transform2D, fraction: float) -> void:
	if not visible or is_queued_for_deletion():
		return
	var at := to_layer * _draw_prev.lerp(global_position, fraction)
	var heat := float(maxi(_ember_drawn_step, 0)) / Tuning.ember_heat_steps
	var trail_color := Tuning.ember_trail_color if heat > 0.0 else Tuning.shot_trail_color
	var trail_width := Tuning.ember_trail_width if heat > 0.0 else Tuning.shot_trail_width
	if _trail.size() >= 2:
		var count := _trail.size()
		for i: int in count - 1:
			var share := float(i + 1) / count
			var a := to_layer * _trail[i]
			var b := to_layer * _trail[i + 1] if i + 1 < count - 1 else at
			batch.stroke(PackedVector2Array([a, b]), _radius * 2.0 * trail_width * share, Color(trail_color, trail_color.a * share), false, false)
	# A hot ember is a dark warm rock: its glow and flame are the torch, drawn over it by the fire shader.
	var tint := Tuning.ember_rock_hot.lerp(Tuning.ember_rock_warm, 1.0 - heat) if heat > 0.0 else Color.WHITE
	PropArt.draw_prop(batch, kind, shape_seed, at, lerpf(_draw_prev_angle, _angle, fraction), _radius, tint, Tuning.ember_rock_tint * minf(heat * 3.0, 1.0), 1.0, _flash * 0.6)


func _enter(next: State) -> void:
	state = next
	_trail.clear()
	match next:
		State.SHOT:
			bounces = 0
			_hot_time = 0.0
			_hazard_ticks.clear()
		State.TUMBLE:
			_absorb_wait = Tuning.prop_absorb_delay
			_tumble_time = 0.0
		State.LOOSE:
			velocity = Vector2.ZERO
			_spin = 0.0
			_rest_time = 0.0
	_mark_dirty()


func _physics_process(delta: float) -> void:
	_draw_prev = global_position
	_draw_prev_angle = _angle
	_absorb_wait = maxf(_absorb_wait - delta, 0.0)
	_reject_wait = maxf(_reject_wait - delta, 0.0)
	_grace_time = maxf(_grace_time - delta, 0.0)
	_flash = maxf(_flash - delta * 6.0, 0.0)
	if _ember_heat > 0.0 and state != State.SHOT:
		_ember_heat = maxf(_ember_heat - delta / Tuning.ember_cool_time, 0.0)
	if _torch != null:
		_carry_fire(delta)
	match state:
		State.LOOSE:
			_idle(delta)
		State.SHOT, State.TUMBLE:
			_fly(delta)
		State.RETURNING:
			_return_wait -= delta
			if _return_wait <= 0.0:
				_arrive_home()
			return
	if is_queued_for_deletion() or state == State.RETURNING:
		return
	if global_position.y > Game.kill_y:
		_send_home(&"fell")


## True while something holds the resting prop up. A hit on the level's own solids (plain StaticBody2D, which never
## move or go away while the level lives) stays valid until the prop moves, so a resting prop skips the motion test.
func _supported() -> bool:
	if global_position == _support_at and is_instance_valid(_support_body) and _support_body.is_inside_tree():
		return true
	var held := test_move(global_transform, Vector2(0.0, SUPPORT_PROBE), _support_hit)
	var body := _support_hit.get_collider() as Node if held else null
	if body is StaticBody2D and body.get_script() == null:
		_support_at = global_position
		_support_body = body
	else:
		_support_at = Vector2.INF
		_support_body = null
	return held


func _idle(delta: float) -> void:
	if not _supported():
		_enter(State.TUMBLE)
		_absorb_wait = 0.0
		return
	_rest_time += delta
	if _rest_time >= Tuning.prop_home_wait and global_position.distance_to(home) > Tuning.prop_home_min_distance and not _on_screen():
		_send_home(&"stray")
		return
	if PropArt.material_of(kind) == &"crystal":
		_glint_wait -= delta
		if _glint_wait <= 0.0:
			_glint_wait = _rng.randf_range(Tuning.prop_idle_glint_interval.x, Tuning.prop_idle_glint_interval.y)
			if is_instance_valid(Juice.sparks):
				Juice.sparks.call(&"glint", global_position + Vector2(_rng.randf_range(-0.4, 0.4), -0.6) * _radius, GLINT_SIZE, Tuning.prop_crystal_light, GLINT_TIME)


func _fly(delta: float) -> void:
	var hot := state == State.SHOT
	if hot:
		_hot_time += delta
	else:
		_tumble_time += delta
		if _tumble_time > Tuning.prop_tumble_max_time and Game.level_running:
			_rescue(&"stuck")
			return
	var step := flight_step(velocity, Tuning.shot_gravity if _thrown else Tuning.prop_gravity, delta)
	var motion := step[0]
	velocity = step[1]
	if not hot:
		velocity *= maxf(1.0 - Tuning.prop_air_drag * delta, 0.0)
	_on_floor = false
	for i: int in MAX_SLIDES:
		if motion.length_squared() < 0.0001:
			break
		var hit := move_and_collide(motion)
		if hit == null:
			break
		var pierced := _resolve_contact(hit.get_collider(), hit.get_normal(), hit.get_position())
		if state == State.RETURNING or is_queued_for_deletion():
			return
		var rest_len := hit.get_remainder().length()
		motion = hit.get_remainder() if pierced else velocity.normalized() * rest_len
	_check_hazards()
	if is_queued_for_deletion():
		return
	if _on_floor:
		velocity.x = move_toward(velocity.x, 0.0, Tuning.prop_roll_decel * delta)
		_spin = velocity.x / maxf(_radius, 1.0)
		if state == State.TUMBLE and velocity.length() < Tuning.prop_rest_speed:
			_come_to_rest()
			if state == State.RETURNING:
				return
	else:
		_spin *= maxf(1.0 - delta * 0.5, 0.0)
	_angle += _spin * delta
	if state == State.SHOT and ember:
		_shed_embers(step[0].length())
	if state == State.SHOT:
		_trail.append(global_position)
		if _trail.size() > Tuning.shot_trail_points:
			_trail.remove_at(0)
		if _hot_time >= Tuning.shot_hot_time:
			_enter(State.TUMBLE)
	_mark_dirty()


## The fire of an ember: it burns with a flame while the shot flies fast, sinks to a glow as it slows and cools, then
## leaves a dark warm rock that turns back into a plain one. The rock redraws only when its heat step changes.
func _carry_fire(delta: float) -> void:
	var step := ceili(_ember_heat * Tuning.ember_heat_steps)
	if step != _ember_drawn_step:
		_ember_drawn_step = step
		_mark_dirty()
	if _ember_heat <= 0.0:
		_torch.queue_free()
		_torch = null
		return
	var speed := clampf(velocity.length() / Tuning.ember_flame_speed, 0.0, 1.0)
	var flame := smoothstep(Tuning.ember_glow_heat, 1.0, _ember_heat) * (1.0 if state == State.SHOT else speed)
	_torch.call(&"carry", delta, velocity, _ember_heat, flame)


## Drops a burning ember every Tuning.ember_shed_step of flight.
func _shed_embers(travel: float) -> void:
	_ember_travel += travel
	while _ember_travel >= Tuning.ember_shed_step:
		_ember_travel -= Tuning.ember_shed_step
		_shed_one()


func _shed_one() -> void:
	var layer := get_parent()
	if layer != null and layer.has_method(&"shed_ember"):
		layer.call(&"shed_ember", global_position, velocity)


## An ember shot that strikes: a burst of fire, a ring and a burst of embers on the spot.
func _ember_burst(at: Vector2, normal: Vector2) -> void:
	if _torch != null:
		_torch.call(&"flare")
	if is_instance_valid(Juice.sparks):
		Juice.sparks.call(&"sparks", at, normal, 18, Vector2(200.0, 620.0), 70.0, Tuning.fire_orange_color, Vector2(2.0, 4.0))
		Juice.sparks.call(&"sparks", at, normal, 10, Vector2(260.0, 700.0), 40.0, Tuning.fire_core_color, Vector2(1.5, 3.0))
		Juice.sparks.call(&"ring", at, _radius * 5.0, Tuning.fire_orange_color, 0.3)
	for k: int in 3:
		_shed_one()
	Sfx.play(&"sizzle", at, 1.1, -2.0)


## Returns true when the prop smashed through the collider and keeps its motion.
func _resolve_contact(collider: Object, normal: Vector2, at: Vector2) -> bool:
	var target := _target_of(collider)
	if state == State.SHOT and target != null:
		var damage := Tuning.ember_damage if ember else 1
		var result: Dictionary = target.call(&"shot_hit", {"at": at, "dir": velocity.normalized(), "speed": velocity.length(), "kind": kind, "prop": self, "damage": damage, "ember": ember})
		if ember and bool(result.get("hit", false)):
			_ember_burst(at, -velocity.normalized())
			Game.report_temperature(&"ember_hit", {"source": &"shot", "damage": damage, "kind": kind, "at": at})
		if bool(result.get("pierce", false)):
			velocity *= Tuning.barrier_pass_keep
			return true
		if bool(result.get("hit", false)):
			velocity = velocity.bounce(normal) * TARGET_REBOUND + Vector2(0.0, -TARGET_HOP)
			_flash = 1.0
			_enter(State.TUMBLE)
			return false
	_bounce(normal, at, &"enemy" if target != null else _surface_of(normal))
	return false


func _bounce(normal: Vector2, at: Vector2, surface: StringName) -> void:
	var into := velocity.dot(normal)
	if into >= 0.0:
		return
	var vn := normal * into
	var vt := velocity - vn
	var impact := -into
	if normal.y < FLOOR_NORMAL_Y:
		_on_floor = true
	if impact < Tuning.prop_bounce_min_speed:
		velocity = vt
		return
	if state == State.SHOT:
		velocity = hot_bounce(velocity, normal)
	else:
		velocity = vt * Tuning.prop_friction - vn * PropArt.restitution_of(kind)
	_spin += vt.dot(normal.orthogonal()) / maxf(_radius, 1.0) * 0.5
	_on_bounce(at, normal, impact, surface)


func _on_bounce(at: Vector2, normal: Vector2, impact: float, surface: StringName) -> void:
	var hot := state == State.SHOT
	bounces += 1
	var t := clampf(impact / Tuning.bounce_speed_ref, 0.0, 1.0)
	var burning := _torch != null and _ember_heat > Tuning.ember_glow_heat
	if is_instance_valid(Juice.sparks):
		var count := int(lerpf(Tuning.bounce_spark_count.x, Tuning.bounce_spark_count.y, t) * (1.0 if hot else 0.5))
		Juice.sparks.call(&"sparks", at, normal, count, Tuning.bounce_spark_speed * lerpf(0.5, 1.0, t), Tuning.bounce_spark_spread, PropArt.spark_color_of(kind))
		if burning:
			# The ember flares on the contact: a spray of fire sparks out of the hit.
			Juice.sparks.call(&"sparks", at, normal, Tuning.ember_bounce_sparks, Tuning.bounce_spark_speed * lerpf(0.6, 1.1, t), Tuning.bounce_spark_spread * 1.3, Tuning.fire_yellow_color, Vector2(1.5, 3.5))
	if burning:
		_torch.call(&"flare")
	Sfx.play(&"clink", at, lerpf(Tuning.bounce_pitch.x, Tuning.bounce_pitch.y, t), lerpf(Tuning.bounce_volume_db.x, Tuning.bounce_volume_db.y, t))
	if hot:
		Juice.shake(lerpf(Tuning.bounce_shake.x, Tuning.bounce_shake.y, t), &"bounce")
		if impact > Tuning.bounce_flash_speed:
			Juice.flash(Tuning.bounce_flash_color, Tuning.bounce_flash_time)
	_flash = maxf(_flash, t)
	if hot and ember:
		_shed_one()
		_shed_one()
	Game.report_prop_bounce(kind, bounces, impact, at, surface, hot, _thrown_from.distance_to(at))
	if hot and (bounces >= Tuning.shot_max_bounces or velocity.length() < Tuning.shot_hot_speed):
		_enter(State.TUMBLE)


## Spikes and saws are areas, so the body motion passes through them; they deflect the prop instead, or break it.
func _check_hazards() -> void:
	_hazard_query.transform = global_transform
	var tick := Engine.get_physics_frames()
	for hit: Dictionary in get_world_2d().direct_space_state.intersect_shape(_hazard_query, 4):
		var area: Object = hit.collider
		if area == null or not area.has_method(&"deflect"):
			continue
		var id := area.get_instance_id()
		if id == _grace_hazard and _grace_time > 0.0:
			continue
		if tick - int(_hazard_ticks.get(id, -1000)) < HAZARD_COOLDOWN_TICKS:
			continue
		var deflected: Variant = area.call(&"deflect", global_position, velocity)
		if not deflected is Vector2:
			continue
		_hazard_ticks[id] = tick
		var before := velocity
		var out: Vector2 = deflected
		var normal := (out - before).normalized()
		if _try_shatter(area, normal, out):
			return
		if state == State.SHOT:
			_trap_rebound(area, before.length())
			return
		if _count_trap_contact():
			return
		velocity = out
		if state == State.LOOSE:
			_enter(State.TUMBLE)
		_on_bounce(global_position, normal, maxf(before.length(), Tuning.deflect_min_speed), StringName(area.get(&"source")))


## A hot shot that a trap cannot break (the smallest size, or no room for pieces) ends its throw on the trap: a light
## "tink" with a few sparks and no break effect, then a short spent hop back toward the thrower, onto the open floor
## the shot came over. A full-speed ricochet would carry the piece out of sight and out of reach.
func _trap_rebound(area: Object, impact: float) -> void:
	var back := signf(_thrown_from.x - global_position.x)
	if back == 0.0:
		back = -signf(velocity.x) if velocity.x != 0.0 else 1.0
	var at := global_position
	velocity = Vector2(back * Tuning.prop_trap_rebound.x, -Tuning.prop_trap_rebound.y)
	_spin = back * Tuning.prop_shatter_spin * 0.5
	bounces += 1
	_flash = 0.6
	if is_instance_valid(Juice.sparks):
		Juice.sparks.call(&"sparks", at, velocity.normalized(), Tuning.prop_trap_tink_sparks, Tuning.bounce_spark_speed * 0.6, Tuning.bounce_spark_spread, Color.WHITE, Vector2(1.0, 2.0))
	Sfx.play(&"clink", at, Tuning.prop_trap_tink_pitch, Tuning.prop_trap_tink_volume_db)
	Game.report_prop_bounce(kind, bounces, impact, at, StringName(area.get(&"source")), true, _thrown_from.distance_to(at))
	_enter(State.TUMBLE)
	_trap_contacts = 1
	_grace_hazard = area.get_instance_id()
	_grace_time = Tuning.prop_shatter_trap_grace


## A tumbling prop comes to rest here. Inside the reach of a trap (a saw's whole patrol, a spike strip) it never rests:
## it moves to the nearest safe floor with the return effect, so it rests once, where the slime can take it unharmed.
func _come_to_rest() -> void:
	if Game.level_running and _trap_reach_at(global_position, _radius) != null:
		_rescue(&"trap")
		return
	_trap_contacts = 0
	_enter(State.LOOSE)


## Counts one trap contact of a prop that is not resting; past Tuning.prop_trap_contact_max contacts since its last
## rest (a piece that keeps bouncing between spikes and a wall) it is rescued. Returns true when it was.
func _count_trap_contact() -> bool:
	_trap_contacts += 1
	if _trap_contacts <= Tuning.prop_trap_contact_max:
		return false
	_rescue(&"trap")
	return true


## Moves the prop to the nearest safe floor with the return effect.
func _rescue(reason: StringName) -> void:
	var prefer := signf(_thrown_from.x - global_position.x)
	_return_to(_safe_point(global_position, prefer if prefer != 0.0 else 1.0), reason)


## The trap whose reach_rect(), grown by `clearance`, holds `at`, or null.
func _trap_reach_at(at: Vector2, clearance: float) -> Node:
	for trap: Node in get_tree().get_nodes_in_group(Hazard.PROP_TRAPS_GROUP):
		if (trap.call(&"reach_rect") as Rect2).grow(clearance).has_point(at):
			return trap
	return null


## Nearest point on the floor, searched sideways from `from` in both directions at once (first toward `prefer` on a
## tie), where this prop rests clear of walls and of the reach of every trap by Tuning.prop_safe_margin. A side that
## starts in a wall finds no floor there and the other side wins. Falls back to `home` when nothing is found.
func _safe_point(from: Vector2, prefer: float) -> Vector2:
	var space := get_world_2d().direct_space_state
	var step := Tuning.prop_safe_search_step
	for k: int in Tuning.prop_safe_search_steps + 1:
		for side: float in [prefer, -prefer]:
			if k == 0 and side != prefer:
				continue
			var x := from.x + side * step * k
			var ray := PhysicsRayQueryParameters2D.create(Vector2(x, from.y - Tuning.tile_size), Vector2(x, from.y + Tuning.tile_size * 3.0), Tuning.LAYER_WORLD | Tuning.LAYER_PLATFORMS)
			var hit := space.intersect_ray(ray)
			if hit.is_empty() or Vector2(hit.normal).y > FLOOR_NORMAL_Y:
				continue
			var spot: Vector2 = Vector2(hit.position) - Vector2(0.0, _radius + 1.0)
			if _trap_reach_at(spot, _radius + Tuning.prop_safe_margin) != null or _blocked(space, spot):
				continue
			return spot
	return home


func _blocked(space: PhysicsDirectSpaceState2D, at: Vector2) -> bool:
	_trap_shape.radius = _radius
	_trap_query.shape = _trap_shape
	_trap_query.transform = Transform2D(0.0, at)
	_trap_query.collision_mask = Tuning.LAYER_WORLD
	_trap_query.collide_with_areas = false
	_trap_query.collide_with_bodies = true
	return not space.intersect_shape(_trap_query, 1).is_empty()


## Breaks a hot shot on a trap into smaller props of the same material that fly away from the trap.
## Returns false, and the prop bounces as usual, when the prop or the trap cannot break or the layer has no room.
func _try_shatter(area: Object, normal: Vector2, out_velocity: Vector2) -> bool:
	# Warm-up props fly before the level runs; they must never break, or the boot would spawn pieces.
	if not Game.level_running or state != State.SHOT or not area.has_method(&"breaks_props") or not bool(area.call(&"breaks_props")):
		return false
	var planned := PropArt.shatter_pieces(kind)
	if planned <= 0 or not is_instance_valid(Game.props):
		return false
	# A break into a single smaller prop would only cost ammunition, so it needs room for two pieces at least.
	var minimum := mini(planned, 2)
	var room: Dictionary = Game.props.call(&"make_room", planned, minimum, self)
	var count := mini(planned, int(room.room))
	if count < minimum:
		return false
	var size := PropArt.size_of(kind)
	var strength := 1.0 - float(size) / float(maxi(PropArt.size_levels() - 2, 1))
	var piece_kind := PropArt.kind_of(PropArt.material_of(kind), size + 1)
	var escape := out_velocity.normalized() if out_velocity != Vector2.ZERO else normal
	if escape == Vector2.ZERO:
		escape = Vector2.UP
	# The spray leans back toward the thrower, so most of the new ammunition lands on the player's side of the trap.
	var back := signf(_thrown_from.x - global_position.x)
	escape = (escape + Vector2(back * Tuning.prop_shatter_back_bias, -Tuning.prop_shatter_lift)).normalized()
	var spread := deg_to_rad(Tuning.prop_shatter_spread_deg)
	var jitter := deg_to_rad(Tuning.prop_shatter_jitter_deg)
	var at := global_position
	var trap_id := area.get_instance_id()
	# The way home of a piece must never lead back into the trap it broke on.
	var piece_home := _safe_point(at, back if back != 0.0 else 1.0)
	for i: int in count:
		var share := 0.5 if count == 1 else float(i) / float(count - 1)
		var a := escape.angle() + lerpf(-spread, spread, share) + Game.rng.randf_range(-jitter, jitter)
		var v := Vector2.from_angle(a) * Game.rng.randf_range(Tuning.prop_shatter_speed.x, Tuning.prop_shatter_speed.y) + out_velocity * Tuning.prop_shatter_keep
		v = v.limit_length(Tuning.prop_shatter_max_speed)
		var piece_identity := {"kind": piece_kind, "seed": shape_seed * 7 + (size + 1) * 131 + i * 17 + 1, "home": piece_home}
		var piece: Node2D = Game.props.call(&"drop", piece_identity, at, v)
		piece.call(&"burst_out", trap_id)
	_shatter_feedback(area, at, escape, strength)
	_remove()
	Game.report_prop_shatter(PropArt.material_of(kind), size, count, StringName(area.get(&"source")), at, int(room.evicted))
	return true


func _shatter_feedback(area: Object, at: Vector2, escape: Vector2, strength: float) -> void:
	var size := PropArt.size_of(kind)
	var palette := PropArt.palette_of(kind)
	var spark_color := PropArt.spark_color_of(kind)
	if is_instance_valid(Juice.sparks):
		var fx_scale := lerpf(Tuning.prop_shatter_small_scale, 1.0, strength)
		var shards := int(lerpf(Tuning.prop_shatter_shard_count.x, Tuning.prop_shatter_shard_count.y, strength))
		Juice.sparks.call(&"debris", at, escape, shards, Tuning.prop_shatter_shard_speed, Tuning.prop_shatter_shard_spread_deg, Tuning.prop_shatter_shard_size * fx_scale, palette, false)
		# A colored spray in the material's spark color, then a tighter, faster white core.
		var sparks := int(lerpf(Tuning.prop_shatter_spark_count.x, Tuning.prop_shatter_spark_count.y, strength))
		Juice.sparks.call(&"sparks", at, escape, sparks, Tuning.prop_shatter_spark_speed, Tuning.prop_shatter_spark_spread_deg, spark_color, Tuning.prop_shatter_spark_size)
		Juice.sparks.call(&"sparks", at, escape, sparks / 2, Tuning.prop_shatter_spark_speed * 1.2, Tuning.prop_shatter_spark_spread_deg * 0.6, Color.WHITE, Tuning.prop_shatter_spark_size * 0.8)
		Juice.sparks.call(&"ring", at, Tuning.prop_shatter_ring_radius * fx_scale, spark_color, Tuning.prop_shatter_ring_time)
		Juice.sparks.call(&"glint", at, Tuning.prop_shatter_glint_size * fx_scale, Color.WHITE, Tuning.prop_shatter_ring_time)
	var pitch := Tuning.prop_shatter_pitch[mini(size, Tuning.prop_shatter_pitch.size() - 1)]
	var volume := lerpf(Tuning.prop_shatter_volume_db.x, Tuning.prop_shatter_volume_db.y, strength)
	Sfx.play(&"shatter" if PropArt.material_of(kind) == &"crystal" else &"crack", at, pitch, volume)
	Sfx.play(&"clink", at, Tuning.bounce_pitch.y * pitch, volume - 4.0)
	Juice.hitstop(lerpf(Tuning.prop_shatter_hitstop.x, Tuning.prop_shatter_hitstop.y, strength))
	Juice.shake(lerpf(Tuning.prop_shatter_shake.x, Tuning.prop_shatter_shake.y, strength), &"prop_shatter")
	Juice.punch(Tuning.prop_shatter_punch * lerpf(0.5, 1.0, strength), &"prop_shatter")
	Juice.flash(Color(Tuning.prop_shatter_flash_color, Tuning.prop_shatter_flash_color.a * strength), Tuning.prop_shatter_flash_time)
	if area.has_method(&"on_prop_shattered"):
		area.call(&"on_prop_shattered", at, strength)


func _target_of(collider: Object) -> Object:
	if collider == null:
		return null
	if collider.has_method(&"shot_hit"):
		return collider
	var parent := (collider as Node).get_parent() if collider is Node else null
	if parent != null and parent.has_method(&"shot_hit"):
		return parent
	return null


func _on_screen() -> bool:
	var viewport := get_viewport()
	var visible_world := viewport.get_canvas_transform().affine_inverse() * viewport.get_visible_rect()
	return visible_world.grow(Tuning.prop_home_screen_margin).has_point(global_position)




func _surface_of(normal: Vector2) -> StringName:
	if normal.y < FLOOR_NORMAL_Y:
		return &"floor"
	if normal.y > CEILING_NORMAL_Y:
		return &"ceiling"
	return &"wall"


## A prop that leaves the level, or rests out of reach and out of sight, pops back at the spot where the level placed it
## (a piece goes back to safe floor beside the trap it broke on), so ammunition is never lost.
func _send_home(reason: StringName) -> void:
	_return_to(home, reason)


## Vanishes with a glint and reappears at `target` with a ring a moment later; every relocation of a prop goes here,
## so no prop ever leaves the level without a visible trace.
func _return_to(target: Vector2, reason: StringName) -> void:
	_return_target = target
	state = State.RETURNING
	velocity = Vector2.ZERO
	visible = false
	collision_layer = 0
	_return_wait = Tuning.prop_home_return_time
	if is_instance_valid(Juice.sparks):
		Juice.sparks.call(&"glint", global_position, GLINT_SIZE, Color.WHITE, GLINT_TIME)
	Game.report_prop_dropped(kind, global_position, reason)
	_mark_dirty()


func _arrive_home() -> void:
	var arrive := _return_target
	global_position = arrive
	_teleported()
	_thrown_from = arrive
	_thrown = false
	bounces = 0
	visible = true
	collision_layer = Tuning.LAYER_PROPS
	_enter(State.TUMBLE)
	_absorb_wait = 0.0
	if is_instance_valid(Juice.sparks):
		Juice.sparks.call(&"ring", arrive, RETURN_RING_RADIUS, PropArt.spark_color_of(kind), GLINT_TIME)
		Juice.sparks.call(&"glint", arrive, GLINT_SIZE * 1.5, Color.WHITE, GLINT_TIME)
	Sfx.play(&"clink", arrive, Tuning.bounce_pitch.y * 1.3, Tuning.bounce_volume_db.x)


func _teleported() -> void:
	reset_physics_interpolation()
	_draw_prev = global_position
	_draw_prev_angle = _angle
	_mark_dirty()


func _remove() -> void:
	collision_layer = 0
	collision_mask = 0
	visible = false
	queue_free()
	_mark_dirty()


func _mark_dirty() -> void:
	var layer := get_parent()
	if layer != null and layer.has_method(&"mark_dirty"):
		layer.call(&"mark_dirty", self)
