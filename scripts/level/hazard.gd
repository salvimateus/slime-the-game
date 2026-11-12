extends Area2D
## Base for anything that takes goo off the player on contact. The player polls it every physics tick.

@export var loss := 18.0
@export var source: StringName = &"hazard"
@export var kills := false
## A hot shot that this hazard deflects breaks into smaller props on it. A trap type that keeps props whole sets it false.
@export var shatters_props := true

var _queried_frame := -1
var _flash_tween: Tween


## Every hazard that deflects props is in this group, so a prop can find each trap's reach_rect().
const PROP_TRAPS_GROUP := &"prop_traps"


func _ready() -> void:
	collision_layer = Tuning.LAYER_HAZARDS
	monitorable = true
	Game.player_damaged.connect(_on_player_damaged)
	if deflects_props():
		add_to_group(PROP_TRAPS_GROUP)


## Returns what the hit does. dir is where the pieces fly; knockback is the new player velocity.
func hazard_hit(player: Node2D) -> Dictionary:
	_queried_frame = Engine.get_physics_frames()
	var away := 1.0
	if is_instance_valid(player):
		away = signf(player.global_position.x - hit_center().x)
	if away == 0.0:
		away = 1.0
	return {
		"loss": loss,
		"dir": Vector2(away * Tuning.hazard_piece_dir_x, -1.0).normalized(),
		"knockback": Vector2(away * Tuning.knockback_speed.x, -Tuning.knockback_speed.y),
		"source": source,
		"kills": kills,
	}


func hit_center() -> Vector2:
	return global_position


## New velocity for a prop that flies into this hazard, or null when props pass through it.
## Subclasses that are solid to props override it and add their own feedback.
func deflect(_at: Vector2, _velocity: Vector2) -> Variant:
	return null


## True when deflect() turns props back; the aim preview stops its arc at such a hazard. Side-effect free.
func deflects_props() -> bool:
	return false


## Global rectangle of everything this hazard can touch over time; a prop never rests inside it. The base uses the
## bounds of its collision shape; a moving trap returns its whole path. Side-effect free.
func reach_rect() -> Rect2:
	var shape_node := get_node_or_null(^"CollisionShape2D") as CollisionShape2D
	if shape_node == null or shape_node.shape == null:
		return Rect2(global_position, Vector2.ZERO)
	return shape_node.global_transform * shape_node.shape.get_rect()


## True when a hot shot that hits this hazard breaks; the prop decides if its own size can still break. Side-effect free.
func breaks_props() -> bool:
	return shatters_props and deflects_props()


## Called after a prop broke on this hazard. strength is 1 for a full prop and 0 for the last size that breaks.
## The base flashes the whole hazard; subclasses call super() and add their own reaction.
func on_prop_shattered(_at: Vector2, strength: float) -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	modulate = Color.WHITE.lerp(Tuning.prop_shatter_trap_flash, lerpf(0.6, 1.0, strength))
	_flash_tween = create_tween()
	_flash_tween.tween_property(self, "modulate", Color.WHITE, Tuning.prop_shatter_trap_flash_time).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)


## Called when the damage that this hazard returned really landed on the player. Subclasses add their feedback.
func _on_hit_landed(_amount: float, _at: Vector2) -> void:
	pass


# The player queries one hazard and takes the damage in the same physics tick, so the frame match names the hazard that hit.
func _on_player_damaged(amount: float, damage_source: StringName, at: Vector2) -> void:
	if damage_source == source and _queried_frame == Engine.get_physics_frames():
		_on_hit_landed(amount, at)
