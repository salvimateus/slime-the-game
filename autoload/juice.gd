extends Node
## Global feedback: hitstop, slow motion, shake, zoom punch, flash, audio muffle and vibration.

const Haptics := preload("res://autoload/haptics.gd")

var camera: Node
var screen_fx: Node
## World-space impact effects (scripts/fx/sparks.gd); callers check is_instance_valid before use.
var sparks: Node
var _hitstop := 0.0
var _slowmo := 0.0
var _slowmo_scale := 1.0
var _muffle := 0.0
var _muffle_time := 0.0
# Time scale that scaled the deltas of the current main loop iteration.
var _delta_scale := 1.0
var _target_scale := 1.0
var _commit_pending := false
## Aim slow motion: held while the aim is open, eased in real time; 0 is off, 1 is Tuning.aim_time_scale.
var _aim_hold := false
var _aim_blend := 0.0
## Vibration engine; other scripts call haptic() and never the Input vibration API.
var haptics: Node
## Real seconds since boot; the burst merge of shake() and punch() runs on it.
var _clock := 0.0
## Per source: Vector2(time of its last call, strongest amount of its current burst).
var _shake_bursts := {}
var _punch_bursts := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -1000
	_delta_scale = Engine.time_scale
	_target_scale = Engine.time_scale
	haptics = Haptics.new()
	haptics.name = "Haptics"
	add_child(haptics)
	_connect_haptic_events()


## Starts the vibration preset `preset` of Tuning.haptics_presets on the device in use; strength 0..1 scales it.
func haptic(preset: StringName, strength: float = 1.0) -> void:
	if haptics != null:
		haptics.call(&"play", preset, strength)


## Converts a delta scaled by Engine.time_scale back to real seconds.
func real_delta(scaled_delta: float) -> float:
	return scaled_delta / maxf(_delta_scale, 0.0001)


func hitstop(seconds: float) -> void:
	Harness.log_juice("juice", {"kind": "hitstop", "amount": seconds})
	if Tuning.juice_enabled and seconds > 0.0:
		_hitstop = maxf(_hitstop, seconds)


func slowmo(scale: float, seconds: float) -> void:
	Harness.log_juice("juice", {"kind": "slowmo", "amount": seconds, "scale": scale})
	if not Tuning.juice_enabled or seconds <= 0.0:
		return
	scale = clampf(scale, Tuning.hitstop_time_scale, 1.0)
	_slowmo_scale = scale if _slowmo <= 0.0 else minf(_slowmo_scale, scale)
	_slowmo = maxf(_slowmo, seconds)


## Holds a gentle slow motion while the player aims; it stacks with slowmo() (the lower scale wins) and hitstop.
func aim_slowmo(active: bool) -> void:
	_aim_hold = active and Tuning.juice_enabled


## `source` names the event kind; repeated calls of one source merge into one burst (see Tuning.juice_merge_gap).
func shake(trauma: float, source: StringName) -> void:
	var add := _burst_share(_shake_bursts, source, minf(trauma, Tuning.juice_shake_max))
	Harness.log_juice("juice", {"kind": "shake", "amount": trauma, "source": source, "applied": add})
	if add > 0.0 and _valid(camera) and Tuning.juice_enabled:
		camera.call(&"add_trauma", add * Tuning.shake_scale)


func punch(amount: float, source: StringName) -> void:
	var add := _burst_share(_punch_bursts, source, minf(amount, Tuning.juice_punch_max))
	Harness.log_juice("juice", {"kind": "punch", "amount": amount, "source": source, "applied": add})
	if add > 0.0 and _valid(camera) and Tuning.juice_enabled:
		camera.call(&"punch", add)


## Part of `amount` that this call adds: all of it for a new burst, only the excess over the strongest call so far
## while the calls of the source keep coming less than juice_merge_gap apart.
func _burst_share(bursts: Dictionary, source: StringName, amount: float) -> float:
	if amount <= 0.0:
		return 0.0
	var burst: Vector2 = bursts.get(source, Vector2(-INF, 0.0))
	if _clock - burst.x > Tuning.juice_merge_gap:
		bursts[source] = Vector2(_clock, amount)
		return amount
	bursts[source] = Vector2(_clock, maxf(burst.y, amount))
	return maxf(amount - burst.y, 0.0)


func flash(color: Color, seconds: float) -> void:
	if _valid(screen_fx) and Tuning.juice_enabled:
		screen_fx.call(&"flash", color, seconds)


func muffle(seconds: float) -> void:
	_muffle_time = maxf(_muffle_time, seconds)


func impact(strength: float) -> void:
	strength = clampf(strength, 0.0, 1.0)
	hitstop(lerpf(Tuning.hitstop_min, Tuning.hitstop_max, strength))
	shake(lerpf(Tuning.juice_impact_shake.x, Tuning.juice_impact_shake.y, strength), &"impact")
	punch(lerpf(Tuning.juice_impact_punch.x, Tuning.juice_impact_punch.y, strength), &"impact")
	flash(Tuning.flash_hurt_color, Tuning.juice_impact_flash_time)


func death() -> void:
	hitstop(Tuning.death_hitstop)
	slowmo(Tuning.death_slowmo_scale, Tuning.death_slowmo_time)
	shake(Tuning.juice_death_shake, &"death")
	punch(Tuning.juice_death_punch, &"death")
	flash(Tuning.juice_death_flash_color, Tuning.juice_death_flash_time)
	muffle(Tuning.death_slowmo_time + Tuning.juice_death_muffle_tail)


func celebrate() -> void:
	slowmo(Tuning.goal_slowmo_scale, Tuning.goal_slowmo_time)
	shake(Tuning.juice_goal_shake, &"goal")
	punch(Tuning.juice_goal_punch, &"goal")
	flash(Tuning.juice_goal_flash_color, Tuning.juice_goal_flash_time)


func reset() -> void:
	_hitstop = 0.0
	_slowmo = 0.0
	_slowmo_scale = 1.0
	_muffle_time = 0.0
	_muffle = 0.0
	_aim_hold = false
	_aim_blend = 0.0
	_target_scale = 1.0
	_shake_bursts.clear()
	_punch_bursts.clear()
	_request_commit()
	Sfx.set_muffle(0.0)


func _process(delta: float) -> void:
	# Runs first in the frame (lowest priority value), so Engine.time_scale still holds the scale of this iteration.
	_delta_scale = Engine.time_scale
	var real := real_delta(delta)
	_clock += real
	_hitstop = maxf(_hitstop - real, 0.0)
	# Slow motion runs out only after the freeze, so a hitstop never eats it.
	if _hitstop <= 0.0:
		_slowmo = maxf(_slowmo - real, 0.0)
	var scale := 1.0
	if _slowmo > 0.0:
		var ease_back := clampf(_slowmo / Tuning.juice_slowmo_ease_back_time, 0.0, 1.0)
		scale = lerpf(1.0, _slowmo_scale, ease_back)
	_aim_blend = move_toward(_aim_blend, 1.0 if _aim_hold else 0.0, real / maxf(Tuning.aim_slowmo_ease, 0.001))
	scale = minf(scale, lerpf(1.0, Tuning.aim_time_scale, _aim_blend))
	if _hitstop > 0.0:
		scale = Tuning.hitstop_time_scale
	_target_scale = scale
	_request_commit()
	_muffle_time = maxf(_muffle_time - real, 0.0)
	_muffle = move_toward(_muffle, 1.0 if _muffle_time > 0.0 else 0.0, real * Tuning.juice_muffle_rate)
	Sfx.set_muffle(_muffle)


## The new scale applies at the end of the frame, so every delta of this iteration converts with the scale that made it.
func _request_commit() -> void:
	if not _commit_pending and not is_equal_approx(Engine.time_scale, _target_scale):
		_commit_pending = true
		_commit_time_scale.call_deferred()


func _commit_time_scale() -> void:
	_commit_pending = false
	Engine.time_scale = _target_scale
	_delta_scale = _target_scale


func _valid(node: Node) -> bool:
	return node != null and is_instance_valid(node) and node.is_inside_tree()


func _connect_haptic_events() -> void:
	Game.player_damaged.connect(_on_player_damaged)
	Game.player_died.connect(func(_source: StringName, _at: Vector2) -> void: haptic(&"death"))
	Game.player_respawned.connect(func(_at: Vector2) -> void: haptic(&"respawn"))
	Game.goo_absorbed.connect(func(amount: float, _at: Vector2) -> void: haptic(&"absorb_goo", amount / maxf(Tuning.haptics_goo_full, 0.001)))
	Game.prop_shot.connect(func(_kind: StringName, _at: Vector2, _dir: Vector2, _carried: int, force: float, _predicted: Variant) -> void: haptic(&"shot", force))
	Game.target_hit.connect(func(_target: StringName, _hp: int, _at: Vector2) -> void: haptic(&"target_hit"))
	Game.enemy_died.connect(func(_enemy: StringName, _at: Vector2) -> void: haptic(&"enemy_death"))
	Game.barrier_broken.connect(func(_at: Vector2) -> void: haptic(&"barrier_break"))
	Game.prop_shattered.connect(_on_prop_shattered)
	Game.checkpoint_reached.connect(func(_id: StringName, _at: Vector2) -> void: haptic(&"checkpoint"))
	Game.goal_reached.connect(func(_summary: Dictionary) -> void: haptic(&"goal"))


func _on_player_damaged(amount: float, source: StringName, _at: Vector2) -> void:
	if source == &"fall":
		haptic(&"damage_fall", amount / maxf(Tuning.haptics_fall_damage_full, 0.001))
	else:
		haptic(&"damage", amount / maxf(Tuning.haptics_damage_full, 0.001))


## Only a break on a trap vibrates; size 0 is a full prop, each smaller level is weaker.
func _on_prop_shattered(_material: StringName, size: int, _pieces: int, trap: StringName, _at: Vector2, _evicted: int) -> void:
	if trap != &"":
		haptic(&"trap_break", 1.0 / (1.0 + maxf(size, 0)))
