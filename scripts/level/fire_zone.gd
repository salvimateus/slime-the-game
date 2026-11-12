extends "res://scripts/level/temperature_zone.gd"
## Flames on the floor: a touch sets the slime on fire, and they thaw a frozen body fast. Its FirePatch child
## (scripts/fire/fire_patch.gd) draws the look; TemperatureArt draws nothing for it.

const FirePatch := preload("res://scripts/fire/fire_patch.gd")

## Group of every patch of flames, for the effects that look for the nearest fire (where a fire starts on the slime).
const FIRE_GROUP := &"fire_zones"

var _patch: Node2D


func _setup_look() -> void:
	thaw = Tuning.temp_fire_thaw_rate
	ignites = true
	kind = &"fire"
	if not is_in_group(FIRE_GROUP):
		add_to_group(FIRE_GROUP)
	if _patch == null:
		_patch = FirePatch.new()
		_patch.name = &"Look"
		add_child(_patch)
	_patch.call(&"setup", area.size)


## The region of the flames in global space.
func global_rect() -> Rect2:
	return Rect2(global_position, area.size)


## Called by the level warm-up behind the loading cover.
func warm_up() -> void:
	_patch.call(&"warm_up")
