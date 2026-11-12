extends RefCounted
## Temperature of the slime: one value from -1 (solid ice cube) through 0 (gelatin) to +1 (melted liquid), plus the
## fuel of a fire. Zones push the value each tick through push(); with no push it relaxes back to 0 after a delay.
## The liquid and cube flags switch with hysteresis, so a value near a threshold does not flicker.
## Contract: push() any number of times, then step() once per physics tick; step() returns the events of the tick.

enum Phase { SOLID, MELTING, LIQUID, FREEZING, CUBE }

## A calm time longer than any recover delay.
const LONG_CALM := 99.0

var value := 0.0
## Goo the fire still has to burn; above 0 the slime burns.
var fuel := 0.0
## Goo the current fire has burned.
var burned := 0.0
var liquid := false
var cube := false
var phase: Phase = Phase.SOLID

## Strongest push of this tick toward each end, in value per second.
var _hot := 0.0
var _cold := 0.0
## Push that only thaws (target 0 from below): flames.
var _thaw := 0.0
var _ignite := false
var _extinguish := false
var _calm := LONG_CALM


func reset(start_value := 0.0, burning := false) -> void:
	value = clampf(start_value, -1.0, 1.0)
	fuel = Tuning.fire_fuel if burning else 0.0
	burned = 0.0
	_clear_pushes()
	_calm = LONG_CALM
	liquid = melt() >= Tuning.temp_liquid_enter
	cube = frost() >= Tuning.temp_cube_enter and not burning
	phase = _phase_now()


func melt() -> float:
	return maxf(value, 0.0)


func frost() -> float:
	return maxf(-value, 0.0)


func burning() -> bool:
	return fuel > 0.0


## Share of the fire fuel that is left, 0 when not burning.
func fire_share() -> float:
	return clampf(fuel / maxf(Tuning.fire_fuel, 0.001), 0.0, 1.0)


func phase_name() -> String:
	return Phase.keys()[phase]


## One zone this tick. heat is its rate per second: above 0 it melts, below 0 it freezes.
## thaw is a rate that only lifts a frozen body back to 0. ignite starts or refuels a fire; extinguish puts it out.
func push(heat: float, thaw := 0.0, ignite := false, extinguish := false) -> void:
	if heat > 0.0:
		_hot = maxf(_hot, heat)
	elif heat < 0.0:
		_cold = maxf(_cold, -heat)
	_thaw = maxf(_thaw, thaw)
	_ignite = _ignite or ignite
	_extinguish = _extinguish or extinguish


## Burns up to `amount` of fuel and returns what it really burned; the fire ends when the fuel is gone.
func burn(amount: float) -> float:
	var used := minf(amount, fuel)
	fuel -= used
	burned += used
	return used


## Puts the fire out with no event; the caller reports why.
func put_out() -> void:
	fuel = 0.0


## Advances the value by delta with the pushes of this tick. hold keeps every value as it is (inside a pipe).
## Returns events as {"name": StringName, "data": Dictionary}: temp_state, fire_start, fire_end (reason cold).
func step(delta: float, hold := false) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	if hold:
		_clear_pushes()
		return events
	if _extinguish and burning():
		events.append({"name": &"fire_end", "data": {"reason": &"cold", "burned": burned}})
		fuel = 0.0
	if _ignite and not _extinguish and frost() <= Tuning.temp_ignite_max_frost:
		if not burning():
			burned = 0.0
			events.append({"name": &"fire_start", "data": {}})
		fuel = Tuning.fire_fuel
	var pushed := _hot > 0.0 or _cold > 0.0 or _thaw > 0.0
	if _hot > 0.0:
		value = move_toward(value, 1.0, _hot * (Tuning.temp_thaw_boost if value < 0.0 else 1.0) * delta)
	if _cold > 0.0:
		value = move_toward(value, -1.0, _cold * delta)
	var thaw := maxf(_thaw, Tuning.temp_fire_thaw_rate if burning() else 0.0)
	if thaw > 0.0 and value < 0.0:
		value = minf(value + thaw * delta, 0.0)
	if pushed:
		_calm = 0.0
	else:
		_calm += delta
		if value > 0.0 and _calm >= Tuning.temp_melt_recover_delay:
			value = maxf(value - Tuning.temp_melt_recover_rate * delta, 0.0)
		elif value < 0.0 and _calm >= Tuning.temp_frost_recover_delay and not burning():
			value = minf(value + Tuning.temp_frost_recover_rate * delta, 0.0)
	_clear_pushes()
	if liquid:
		liquid = melt() >= Tuning.temp_liquid_exit
	else:
		liquid = melt() >= Tuning.temp_liquid_enter
	if cube:
		cube = frost() >= Tuning.temp_cube_exit
	else:
		cube = frost() >= Tuning.temp_cube_enter
	var next := _phase_now()
	if next != phase:
		events.append({"name": &"temp_state", "data": {"from": StringName(Phase.keys()[phase]), "to": StringName(Phase.keys()[next]), "temperature": value}})
		phase = next
	return events


func _phase_now() -> Phase:
	if cube:
		return Phase.CUBE
	if liquid:
		return Phase.LIQUID
	if value <= -Tuning.temp_phase_epsilon:
		return Phase.FREEZING
	if value >= Tuning.temp_phase_epsilon:
		return Phase.MELTING
	return Phase.SOLID


func _clear_pushes() -> void:
	_hot = 0.0
	_cold = 0.0
	_thaw = 0.0
	_ignite = false
	_extinguish = false
