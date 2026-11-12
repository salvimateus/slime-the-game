extends Node2D
## Cosmetic goo droplets with no mass. They stick to solid ground, stay for goo_ground_life, then sink into the soil
## (thin, dark, a damp stain under them). Drawn into the goo field.

const GooMath := preload("res://scripts/goo/goo_math.gd")

const RNG_SEED_OFFSET := 7
const FLOOR_ANGLE := -PI * 0.5
const RELEASE_SPEED := 40.0
## Random slots compared when the pool is full; the one nearest its end gives way.
const VICTIM_SAMPLES := 8
const FLOOR_NORMAL_Y := -0.65
const CEILING_NORMAL_Y := 0.65
## Values of _stuck: in the air, on a surface, pulled into the slime.
const FREE := 0
const STUCK := 1
const PULLED := 2

var _pos := PackedVector2Array()
var _prev := PackedVector2Array()
var _vel := PackedVector2Array()
var _radius := PackedFloat32Array()
var _life := PackedFloat32Array()
var _angle := PackedFloat32Array()
var _stuck := PackedByteArray()
## Seconds since the sink started; below zero while the droplet has not started to sink.
var _soak := PackedFloat32Array()
## Field colour of each droplet (GooMath.source_color of its goo colour), so the draw does no colour math.
var _code := PackedColorArray()
## Pool clock at the add of each droplet: its age is _clock - _born, so no loop has to count it up.
var _born := PackedFloat32Array()
var _clock := 0.0
var _trail := PackedByteArray()
## Coarse grid of stuck droplets (count per cell of CELL px), so the pull skips the pool when no goo is near the slime.
## _cx and _cy hold the cell a stuck droplet is counted in; _in_cell says whether it is counted.
const CELL := 128.0
## Droplets farther than this outside the view are not drawn.
const CULL_MARGIN := 256.0
var _drawn_view := Rect2()
## Last attract scan that took nothing: where the slime was, when the next droplet comes of age, and the stick count.
const SCAN_MOVE := 4.0
var _scan_valid := false
var _scan_center := Vector2.ZERO
var _scan_wake := 0.0
var _scan_serial := -1
var _stick_serial := 0
var _cells := {}
var _cx := PackedInt32Array()
var _cy := PackedInt32Array()
var _in_cell := PackedByteArray()
# Pull: start point, elapsed time and flight time of each pulled droplet.
var _from := PackedVector2Array()
var _pull_t := PackedFloat32Array()
var _pull_dur := PackedFloat32Array()
# Pull target of this tick (set by attract) and what reached it since the last take_arrivals.
var _target := Vector2.ZERO
var _target_entry := 0.0
var _target_ticks := 0
var _arrived := 0
var _arrived_size := 0.0
var _arrived_at := Vector2.ZERO
var _count := 0
var _last := 0
var _dirty := false
var _animating := false
var _query := PhysicsPointQueryParameters2D.new()
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	var cap: int = maxi(Tuning.droplet_max, 1)
	_pos.resize(cap)
	_prev.resize(cap)
	_vel.resize(cap)
	_radius.resize(cap)
	_life.resize(cap)
	_angle.resize(cap)
	_stuck.resize(cap)
	_soak.resize(cap)
	_code.resize(cap)
	_born.resize(cap)
	_trail.resize(cap)
	_cx.resize(cap)
	_cy.resize(cap)
	_in_cell.resize(cap)
	_from.resize(cap)
	_pull_t.resize(cap)
	_pull_dur.resize(cap)
	# Only solid world: one-way planks live on the platform layer and would catch droplets from below.
	_query.collision_mask = Tuning.LAYER_WORLD
	_query.collide_with_areas = false
	_query.collide_with_bodies = true
	_rng.seed = Game.seed_value + RNG_SEED_OFFSET


func spray(origin: Vector2, dir: Vector2, count: int, speed: Vector2, spread_deg: float, radius: Vector2, inherit := Vector2.ZERO, color := Color(0.0, 0.0, 0.0, 0.0)) -> void:
	var code := _code_of(color)
	var base := dir.angle() if dir != Vector2.ZERO else -PI * 0.5
	for i: int in maxi(count, 0):
		var a := base + deg_to_rad(_rng.randf_range(-spread_deg, spread_deg))
		var v := Vector2.from_angle(a) * _rng.randf_range(speed.x, speed.y) + inherit
		_add(origin, v, _rng.randf_range(radius.x, radius.y), _rng.randf_range(Tuning.droplet_fly_life.x, Tuning.droplet_fly_life.y), false, code)


func burst(origin: Vector2, count: int, speed: Vector2, radius: Vector2, color := Color(0.0, 0.0, 0.0, 0.0)) -> void:
	spray(origin, Vector2.UP, count, speed, 180.0, radius, Vector2.ZERO, color)


## A droplet already stuck to a surface (wet trails and streaks); life is its time before it sinks, normal orients its flat side.
func drip(origin: Vector2, radius: float, life: float, normal := Vector2.UP, color := Color(0.0, 0.0, 0.0, 0.0)) -> void:
	_add(origin, Vector2.ZERO, radius, life, true, _code_of(color))
	if _count > 0 and radius > 0.0 and life > 0.0:
		_trail[_last] = 1
		if normal != Vector2.ZERO:
			_angle[_last] = normal.angle()


## Unsticks every droplet inside rect so it falls, for a surface that just vanished (a broken barrier).
func release(rect: Rect2) -> void:
	for i: int in _count:
		if _stuck[i] == STUCK and rect.has_point(_pos[i]):
			_cell_drop(i)
			_stuck[i] = 0
			_soak[i] = -1.0
			_vel[i] = Vector2(_rng.randf_range(-RELEASE_SPEED, RELEASE_SPEED), 0.0)
			_life[i] = minf(_life[i], Tuning.droplet_fly_life.y)
	_dirty = true


func clear() -> void:
	_count = 0
	_cells.clear()
	_dirty = true


func count() -> int:
	return _count


func _code_of(color: Color) -> Color:
	return GooMath.source_color(color if color.a > 0.0 else GooMath.base_color())


func _add(p: Vector2, v: Vector2, r: float, life: float, stuck: bool, code: Color) -> void:
	if r <= 0.0 or life <= 0.0:
		return
	var i := _count
	if _count >= _pos.size():
		i = _victim()
		_cell_drop(i)
	else:
		_count += 1
	_pos[i] = p
	_prev[i] = p
	_vel[i] = v
	_radius[i] = r
	_life[i] = life
	_angle[i] = FLOOR_ANGLE
	_stuck[i] = 1 if stuck else 0
	_soak[i] = -1.0
	_code[i] = code
	_born[i] = _clock
	_trail[i] = 0
	_in_cell[i] = 0
	_last = i
	if stuck:
		_cell_add(i)
	_dirty = true


## A full pool replaces the droplet nearest its end among a few random ones: the oldest goo goes first.
func _victim() -> int:
	var best := _rng.randi() % _count
	var best_left := _time_left(best)
	for k: int in VICTIM_SAMPLES - 1:
		var j := _rng.randi() % _count
		var left := _time_left(j)
		if left < best_left:
			best = j
			best_left = left
	return best


func _time_left(i: int) -> float:
	if _stuck[i] == PULLED:
		return 0.0
	if _stuck[i] == FREE:
		return _life[i]
	if _soak[i] < 0.0:
		return _life[i] + Tuning.droplet_soak_time
	return Tuning.droplet_soak_time - _soak[i]


func _remove(i: int) -> void:
	_cell_drop(i)
	_count -= 1
	_pos[i] = _pos[_count]
	_prev[i] = _prev[_count]
	_vel[i] = _vel[_count]
	_radius[i] = _radius[_count]
	_life[i] = _life[_count]
	_angle[i] = _angle[_count]
	_stuck[i] = _stuck[_count]
	_soak[i] = _soak[_count]
	_code[i] = _code[_count]
	_born[i] = _born[_count]
	_trail[i] = _trail[_count]
	_cx[i] = _cx[_count]
	_cy[i] = _cy[_count]
	_in_cell[i] = _in_cell[_count]
	_from[i] = _from[_count]
	_pull_t[i] = _pull_t[_count]
	_pull_dur[i] = _pull_dur[_count]
	_dirty = true


func _physics_process(delta: float) -> void:
	_clock += delta
	if _count == 0:
		_animating = false
		return
	var space := get_world_2d().direct_space_state
	var g: float = Tuning.droplet_gravity
	var soak_time: float = maxf(Tuning.droplet_soak_time, 0.01)
	var waiting := 0
	var animating := false
	var pulling := _target_ticks > 0
	var i := 0
	while i < _count:
		_prev[i] = _pos[i]
		if _stuck[i] == PULLED:
			if not pulling:
				# The slime is gone (dead, frozen): the droplet drops where it is.
				_stuck[i] = FREE
				_vel[i] = Vector2.ZERO
				_life[i] = Tuning.droplet_fly_life.y
			elif _step_pull(i, delta):
				_remove(i)
				continue
			animating = true
			i += 1
			continue
		if _stuck[i] == FREE:
			_life[i] -= delta
			if _life[i] <= 0.0:
				_remove(i)
				continue
			animating = true
			var v := _vel[i]
			v.y += g * delta
			_vel[i] = v
			var p := _pos[i]
			var next := p + v * delta
			if not _solid(space, next):
				_pos[i] = next
			else:
				_stick(i, space, p, v * delta)
		elif _soak[i] < 0.0:
			_life[i] -= delta
			if _life[i] <= 0.0:
				_start_soak(i)
			else:
				waiting += 1
		else:
			_soak[i] += delta
			if _soak[i] >= soak_time:
				_remove(i)
				continue
			animating = true
			var normal_y := sin(_angle[i])
			if normal_y > FLOOR_NORMAL_Y and normal_y < CEILING_NORMAL_Y:
				# On a wall the sinking droplet creeps down as it drains.
				_pos[i] += Vector2(0.0, Tuning.droplet_soak_drip_speed * delta)
		i += 1
	var excess := mini(waiting - Tuning.droplet_soak_cap, Tuning.droplet_soak_per_tick)
	if excess > 0:
		for oldest: int in _oldest_waiting(excess):
			_start_soak(oldest)
	_animating = animating
	if animating:
		_dirty = true
	_target_ticks = maxi(_target_ticks - 1, 0)


## The n waiting droplets nearest their sink, in one pass, oldest first (ties keep the lower index first).
func _oldest_waiting(n: int) -> PackedInt32Array:
	var picked := PackedInt32Array()
	var lives := PackedFloat32Array()
	for i: int in _count:
		if _stuck[i] != STUCK or _soak[i] >= 0.0:
			continue
		var life := _life[i]
		if picked.size() == n and life >= lives[n - 1]:
			continue
		var at := picked.size()
		while at > 0 and life < lives[at - 1]:
			at -= 1
		picked.insert(at, i)
		lives.insert(at, life)
		if picked.size() > n:
			picked.resize(n)
			lives.resize(n)
	return picked


func _start_soak(i: int) -> void:
	_soak[i] = 0.0
	_dirty = true
	var field := get_parent()
	if field != null and field.has_method(&"stain"):
		field.call(&"stain", _pos[i], _radius[i] * Tuning.goo_stain_size, Vector2.from_angle(_angle[i]), Tuning.droplet_soak_time)


func _solid(space: PhysicsDirectSpaceState2D, at: Vector2) -> bool:
	_query.position = at
	return not space.intersect_point(_query, 1).is_empty()


## Splats droplet i flat against the surface it ran into; the blocked axis tells which surface it was.
func _stick(i: int, space: PhysicsDirectSpaceState2D, p: Vector2, motion: Vector2) -> void:
	var normal: Vector2
	if motion.x != 0.0 and _solid(space, p + Vector2(motion.x, 0.0)):
		normal = Vector2(-signf(motion.x), 0.0)
	elif motion.y != 0.0 and _solid(space, p + Vector2(0.0, motion.y)):
		normal = Vector2(0.0, -signf(motion.y))
	else:
		normal = -motion.normalized() if motion != Vector2.ZERO else Vector2.UP
	_stuck[i] = STUCK
	_soak[i] = -1.0
	_vel[i] = Vector2.ZERO
	_angle[i] = normal.angle()
	_cell_add(i)
	_life[i] = Tuning.goo_ground_life * _rng.randf_range(Tuning.goo_ground_life_jitter.x, Tuning.goo_ground_life_jitter.y)
	_radius[i] *= Tuning.droplet_stick_grow


func _process(_delta: float) -> void:
	visible = Tuning.fx_droplets
	# Droplets that only wait on a surface do not change, so the pool redraws only when something moves or sinks.
	# The draw skips droplets off view, so a camera pan past half the margin redraws once.
	var view := _view_rect()
	if _dirty or _animating or absf(view.position.x - _drawn_view.position.x) > CULL_MARGIN * 0.5 or absf(view.position.y - _drawn_view.position.y) > CULL_MARGIN * 0.5:
		_dirty = false
		queue_redraw()


func _view_rect() -> Rect2:
	var inv := get_viewport().get_canvas_transform().affine_inverse()
	return inv * get_viewport_rect()


func _draw() -> void:
	if _count == 0:
		return
	var f := Engine.get_physics_interpolation_fraction()
	var to_local_xf := get_global_transform().affine_inverse()
	var tex := GooMath.kernel_texture()
	var ks := GooMath.kernel_scale()
	var soak_time: float = maxf(Tuning.droplet_soak_time, 0.01)
	var flat: Vector2 = Tuning.droplet_stick_flat
	_drawn_view = _view_rect()
	var cull := _drawn_view.grow(CULL_MARGIN)
	for i: int in _count:
		if not cull.has_point(_pos[i]):
			continue
		var p := to_local_xf * _prev[i].lerp(_pos[i], f)
		var kr := _radius[i] * ks
		if _stuck[i] == PULLED:
			var k := _pull_t[i] / maxf(Tuning.droplet_pull_stretch_time, 0.001)
			var s := 1.0 + Tuning.piece_absorb_stretch * clampf(k, 0.0, 1.0) + minf(_vel[i].length() * Tuning.droplet_stretch_per_speed, Tuning.droplet_stretch_max)
			draw_set_transform(p, _vel[i].angle() if _vel[i] != Vector2.ZERO else (_target - _pos[i]).angle(), Vector2(s, 1.0 / s))
			draw_texture_rect(tex, Rect2(-kr, -kr, kr * 2.0, kr * 2.0), false, _code[i])
		elif _stuck[i] == FREE:
			kr *= clampf(_life[i] / Tuning.droplet_fade_time, 0.0, 1.0)
			if kr <= 0.0:
				continue
			var v := _vel[i]
			var s := 1.0 + minf(v.length() * Tuning.droplet_stretch_per_speed, Tuning.droplet_stretch_max)
			draw_set_transform(p, v.angle(), Vector2(s, 1.0 / s))
			draw_texture_rect(tex, Rect2(-kr, -kr, kr * 2.0, kr * 2.0), false, _code[i])
		elif _soak[i] < 0.0:
			draw_set_transform(p, _angle[i], flat)
			draw_texture_rect(tex, Rect2(-kr, -kr, kr * 2.0, kr * 2.0), false, _code[i])
		else:
			var t := _soak[i] / soak_time
			var sink := 1.0 - (1.0 - t) * (1.0 - t)
			draw_set_transform(p, _angle[i], Vector2(flat.x * lerpf(1.0, 0.55, sink), flat.y * lerpf(1.0, 1.25, sink)))
			draw_texture_rect(tex, Rect2(-kr, -kr, kr * 2.0, kr * 2.0), false, _scaled(_code[i], GooMath.soak_strength(t)))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


static func _scaled(code: Color, strength: float) -> Color:
	return Color(code.r * strength, code.g * strength, code.b * strength, 1.0)


## The slime pulls droplets this tick. center and half give its core (a capsule of half length half), body_r its
## radius, reach the pull range outside the edge, entry the depth where the flight ends. clear holds the free distance
## along goo_pull_rays rays from center; a droplet farther than both neighbouring rays (plus a tolerance) is behind a
## surface. Droplets on a surface are taken once they are old enough; a trail drop waits longer, so the slime does not
## drink its fresh trail. Call near() first: it skips the whole pool when no stuck droplet is close. With clear_ready
## false the fan is not cast yet: the call returns -1 as soon as a droplet off the body needs the path test.
func attract(center: Vector2, half: float, body_r: float, reach: float, entry: float, clear: PackedFloat32Array, clear_ready: bool) -> int:
	follow(center, entry)
	# A scan that took nothing stays valid while the slime holds still, no droplet lands and none comes of age.
	if _scan_valid and _clock < _scan_wake and _stick_serial == _scan_serial and center.distance_squared_to(_scan_center) < SCAN_MOVE * SCAN_MOVE:
		return 0
	var started := 0
	var wake := INF
	var rays := clear.size() if clear_ready else 0
	var tolerance: float = Tuning.goo_pull_ray_tolerance
	var delay: float = Tuning.droplet_pull_delay
	var trail_delay: float = Tuning.droplet_trail_pull_delay
	for i: int in _count:
		if _stuck[i] != STUCK:
			continue
		var p := _pos[i]
		var edge := GooMath.edge_distance(p, center, half, body_r) - _radius[i]
		if edge > reach:
			continue
		var ready_at := _born[i] + (trail_delay if _trail[i] == 1 else delay)
		if _clock < ready_at:
			wake = minf(wake, ready_at)
			continue
		if edge > 0.0 and not clear_ready:
			# The path test needs the ray fan: the caller casts it and calls again.
			_scan_valid = false
			return -1
		if edge > 0.0 and rays > 0:
			var d := p - center
			var f := fposmod(d.angle() / TAU * float(rays), float(rays))
			var a := int(f) % rays
			var free := maxf(clear[a], clear[(a + 1) % rays])
			if d.length() > free + tolerance:
				continue
		_cell_drop(i)
		_stuck[i] = PULLED
		_soak[i] = -1.0
		_from[i] = p
		_pull_t[i] = 0.0
		var length := p.distance_to(center)
		_pull_dur[i] = clampf(length / maxf(Tuning.goo_pull_speed, 1.0), Tuning.droplet_pull_flight_time.x, Tuning.droplet_pull_flight_time.y) * _rng.randf_range(0.85, 1.15)
		started += 1
	if started > 0:
		_dirty = true
	_scan_valid = started == 0
	_scan_center = center
	_scan_wake = wake
	_scan_serial = _stick_serial
	return started


## The slime can still take goo this tick: droplets in flight keep homing on center (entry deep inside it).
func follow(center: Vector2, entry: float) -> void:
	_target = center
	_target_entry = entry
	_target_ticks = 2


## Droplets that reached the slime since the last call: count, summed radius and their mean arrival point.
func take_arrivals() -> Vector4:
	if _arrived == 0:
		return Vector4.ZERO
	var at := _arrived_at / float(_arrived)
	var out := Vector4(float(_arrived), _arrived_size, at.x, at.y)
	_arrived = 0
	_arrived_size = 0.0
	_arrived_at = Vector2.ZERO
	return out


## Returns true when the droplet reached the body.
func _step_pull(i: int, delta: float) -> bool:
	_pull_t[i] += delta
	var stretch: float = Tuning.droplet_pull_stretch_time
	var before := _pos[i]
	var side := (_from[i] - _target).normalized()
	if side == Vector2.ZERO:
		side = Vector2.UP
	var entry := _target + side * _target_entry
	if _pull_t[i] >= stretch:
		var u := clampf((_pull_t[i] - stretch) / maxf(_pull_dur[i], 0.001), 0.0, 1.0)
		_pos[i] = GooMath.pull_point(_from[i], entry, GooMath.pull_arc(_from[i].distance_to(entry)), u * u)
		if u >= 1.0:
			_arrived += 1
			_arrived_size += _radius[i]
			_arrived_at += _pos[i]
			return true
	_vel[i] = (_pos[i] - before) / maxf(delta, 0.0001)
	return false


## True when a stuck droplet may lie within radius of center; reads only the few grid cells around it.
func near(center: Vector2, radius: float) -> bool:
	if _cells.is_empty():
		return false
	var x0 := int(floorf((center.x - radius) / CELL))
	var x1 := int(floorf((center.x + radius) / CELL))
	var y0 := int(floorf((center.y - radius) / CELL))
	var y1 := int(floorf((center.y + radius) / CELL))
	for x: int in range(x0, x1 + 1):
		for y: int in range(y0, y1 + 1):
			if _cells.has(Vector2i(x, y)):
				return true
	return false


func _cell_add(i: int) -> void:
	if _in_cell[i] == 1:
		return
	_stick_serial += 1
	var c := Vector2i(int(floorf(_pos[i].x / CELL)), int(floorf(_pos[i].y / CELL)))
	_cx[i] = c.x
	_cy[i] = c.y
	_in_cell[i] = 1
	_cells[c] = int(_cells.get(c, 0)) + 1


func _cell_drop(i: int) -> void:
	if _in_cell[i] == 0:
		return
	_in_cell[i] = 0
	var c := Vector2i(_cx[i], _cy[i])
	var n := int(_cells.get(c, 0)) - 1
	if n > 0:
		_cells[c] = n
	else:
		_cells.erase(c)
