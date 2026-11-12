extends Node
## Procedural sound effects: bakes every preset at boot and plays them from a voice pool.

const POOL_2D := 24
const POOL_UI := 6
const BUS_NAME := &"SFX"
const MIX_RATE_MIN := 8000
const MIX_RATE_MAX := 48000
const PEAK_TARGET := 0.9
const FADE_IN_SECONDS := 0.001
const FADE_OUT_SECONDS := 0.005
const MUFFLE_OPEN_HZ := 18000.0
const PITCH_MIN := 0.05
const PITCH_MAX := 8.0
const JITTER_MAX := 0.5
const VOLUME_DB_MIN := -80.0
const VOLUME_DB_MAX := 12.0
const LIMITER_CEILING_DB := -0.5
const SAW_LOOP_SECONDS := 0.5
const SAW_LOOP_CROSSFADE := 0.05
## The fire roar has no high content, so it is made at a low rate and costs little of the boot.
const FIRE_ROAR_SECONDS := 0.5
const FIRE_ROAR_CROSSFADE := 0.08
const FIRE_ROAR_RATE := 8000
const NOISE_COEFF_STRIDE := 8

var bake_ms := 0.0
var _bake_task := -1
var _rate := 32000
var _bank: Dictionary = {}
var _last_frame: Dictionary = {}
var _warned: Dictionary = {}
var _voices_2d: Array[AudioStreamPlayer2D] = []
var _voices_ui: Array[AudioStreamPlayer] = []
var _next_2d := 0
var _next_ui := 0
var _rng := RandomNumberGenerator.new()
var _bus_idx := -1
var _muffle_fx := -1
var _audible := true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_rate = clampi(Tuning.sfx_mix_rate, MIX_RATE_MIN, MIX_RATE_MAX)
	_rng.seed = 424242
	# A playback still active at quit leaks its stream (engine shutdown). Under the Dummy driver nothing is heard,
	# and with --headless --fixed-fps nothing mixes, so every playback would stay active; skip them there.
	_audible = AudioServer.get_driver_name() != "Dummy" or not Engine.get_write_movie_path().is_empty()
	_setup_bus()
	for _i in POOL_2D:
		var p := AudioStreamPlayer2D.new()
		p.bus = BUS_NAME
		p.max_distance = 2200.0
		p.attenuation = 1.2
		add_child(p)
		_voices_2d.append(p)
	for _i in POOL_UI:
		var u := AudioStreamPlayer.new()
		u.bus = BUS_NAME
		add_child(u)
		_voices_ui.append(u)
	# The bake runs on a worker thread while the level loads; the first play or stream waits for it.
	_bake_task = WorkerThreadPool.add_task(_bake_on_worker, false, "Sfx bake")


func _exit_tree() -> void:
	_wait_for_bake()


## True once every preset is baked (the bake never blocks the boot).
func is_baked() -> bool:
	return _bake_task < 0 or WorkerThreadPool.is_task_completed(_bake_task)


## Blocks until every preset is baked. The load calls it behind the cover, so the first play of the level never waits.
func finish_bake() -> void:
	_wait_for_bake()


func _bake_on_worker() -> void:
	var t0 := Time.get_ticks_usec()
	_bake_all()
	bake_ms = (Time.get_ticks_usec() - t0) / 1000.0
	print("SFX baked %d presets in %.1f ms" % [_bank.size(), bake_ms])


func _wait_for_bake() -> void:
	if _bake_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_bake_task)
		_bake_task = -1


## `at` is a world position for a positional voice; null (or any non-vector) plays it flat, like UI.
## `jitter` below 0 uses `Tuning.sfx_pitch_jitter`; 0 gives an exact pitch (absorb ladder).
func play(preset: StringName, at: Variant = null, pitch := 1.0, volume_db := 0.0, jitter := -1.0) -> void:
	_wait_for_bake()
	var variants: Array = _bank.get(preset, [])
	if variants.is_empty():
		if not _warned.has(preset):
			_warned[preset] = true
			push_warning("Unknown sfx: %s" % preset)
		return
	var frame := Engine.get_process_frames()
	var last: int = _last_frame.get(preset, -1000)
	if frame - last < Tuning.sfx_min_frames:
		return
	_last_frame[preset] = frame
	Harness.log_juice("sfx", {"preset": preset})
	var stream_v: AudioStreamWAV = variants[_rng.randi() % variants.size()]
	var j: float = Tuning.sfx_pitch_jitter if jitter < 0.0 else jitter
	j = clampf(j, 0.0, JITTER_MAX) if is_finite(j) else 0.0
	var safe_pitch := pitch if is_finite(pitch) else 1.0
	var final_pitch := clampf(safe_pitch * (1.0 + _rng.randf_range(-j, j)), PITCH_MIN, PITCH_MAX)
	var safe_volume := volume_db if is_finite(volume_db) else 0.0
	var final_volume := clampf(safe_volume + Tuning.sfx_volume_db, VOLUME_DB_MIN, VOLUME_DB_MAX)
	var world_pos: Variant = _as_position(at)
	if not _audible:
		return
	if world_pos is Vector2:
		var idx := _pick_voice(_voices_2d, _next_2d)
		_next_2d = (idx + 1) % POOL_2D
		var p := _voices_2d[idx]
		p.stream = stream_v
		p.global_position = world_pos
		p.pitch_scale = final_pitch
		p.volume_db = final_volume
		p.play()
	else:
		var idx := _pick_voice(_voices_ui, _next_ui)
		_next_ui = (idx + 1) % POOL_UI
		var u := _voices_ui[idx]
		u.stream = stream_v
		u.pitch_scale = final_pitch
		u.volume_db = final_volume
		u.play()


## First variant of a preset, for callers that own their own player (saw_loop). Null if unknown or if no
## output can be heard (Dummy driver without Movie Maker), so the caller skips its own player too.
func stream(preset: StringName) -> AudioStream:
	if not _audible:
		return null
	_wait_for_bake()
	var variants: Array = _bank.get(preset, [])
	return null if variants.is_empty() else variants[0]


## Stops every voice in the tree, the pool and the players that scenes own (saw loop), before a quit.
func stop_all() -> void:
	for node: Node in get_tree().root.find_children("*", "AudioStreamPlayer2D", true, false):
		(node as AudioStreamPlayer2D).stop()
	for node: Node in get_tree().root.find_children("*", "AudioStreamPlayer", true, false):
		(node as AudioStreamPlayer).stop()


## 0 is no muffle, 1 lowers the SFX bus cutoff to `Tuning.muffle_cutoff_hz`.
func set_muffle(amount: float) -> void:
	if _bus_idx < 0 or _muffle_fx < 0:
		return
	var a := clampf(amount, 0.0, 1.0) if is_finite(amount) else 0.0
	var on := a > 0.01
	AudioServer.set_bus_effect_enabled(_bus_idx, _muffle_fx, on)
	if on:
		var lp := AudioServer.get_bus_effect(_bus_idx, _muffle_fx) as AudioEffectLowPassFilter
		lp.cutoff_hz = lerpf(MUFFLE_OPEN_HZ, Tuning.muffle_cutoff_hz, a)


func _as_position(at: Variant) -> Variant:
	if at is Vector2:
		var v: Vector2 = at
		return v if v.is_finite() else null
	if at is Vector2i:
		var vi: Vector2i = at
		return Vector2(vi)
	return null


## A free voice from `start` on; when every voice plays, the oldest one in round-robin order is reused.
func _pick_voice(voices: Array, start: int) -> int:
	var count := voices.size()
	for k in count:
		var idx := (start + k) % count
		var voice: Node = voices[idx]
		if not bool(voice.get(&"playing")):
			return idx
	return start % count


func _setup_bus() -> void:
	_bus_idx = AudioServer.get_bus_index(BUS_NAME)
	if _bus_idx == -1:
		AudioServer.add_bus()
		_bus_idx = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(_bus_idx, BUS_NAME)
		AudioServer.set_bus_send(_bus_idx, &"Master")
		var lp := AudioEffectLowPassFilter.new()
		lp.cutoff_hz = MUFFLE_OPEN_HZ
		AudioServer.add_bus_effect(_bus_idx, lp)
		AudioServer.set_bus_effect_enabled(_bus_idx, 0, false)
		# Many voices can stack on one impact; the limiter keeps the sum from clipping.
		var limiter := AudioEffectHardLimiter.new()
		limiter.ceiling_db = LIMITER_CEILING_DB
		AudioServer.add_bus_effect(_bus_idx, limiter)
	for fx in AudioServer.get_bus_effect_count(_bus_idx):
		if AudioServer.get_bus_effect(_bus_idx, fx) is AudioEffectLowPassFilter:
			_muffle_fx = fx
			break


func _bake_all() -> void:
	var recipes := {
		&"jump": [3, _make_jump],
		&"land_soft": [3, _make_land_soft],
		&"land_heavy": [2, _make_land_heavy],
		&"splash": [3, _make_splash],
		&"step": [4, _make_step],
		&"drip": [3, _make_drip],
		&"absorb": [1, _make_absorb],
		&"hurt": [2, _make_hurt],
		&"death": [1, _make_death],
		&"respawn": [1, _make_respawn],
		&"checkpoint": [1, _make_checkpoint],
		&"goal": [1, _make_goal],
		&"heartbeat": [1, _make_heartbeat],
		&"wall_splat": [2, _make_wall_splat],
		&"bonk": [1, _make_bonk],
		&"shred": [1, _make_shred],
		&"saw_loop": [1, _make_saw_loop],
		&"ui_tick": [1, _make_ui_tick],
		&"swallow": [1, _make_swallow],
		&"spit": [2, _make_spit],
		&"spit_dry": [1, _make_spit_dry],
		&"clink": [3, _make_clink],
		&"thwack": [2, _make_thwack],
		&"pop": [1, _make_pop],
		&"shatter": [1, _make_shatter],
		&"double_jump": [1, _make_double_jump],
		&"skid": [1, _make_skid],
		&"dodge": [1, _make_dodge],
		&"roll": [1, _make_roll],
		&"wall_slide": [1, _make_wall_slide],
		&"crack": [1, _make_crack],
		&"sizzle": [1, _make_sizzle],
		&"ignite": [1, _make_ignite],
		&"fire_out": [1, _make_fire_out],
		&"fire_roar": [1, _make_fire_roar],
		&"fire_crackle": [1, _make_fire_crackle],
		&"freeze": [1, _make_freeze],
		&"ice_clink": [1, _make_ice_clink],
		&"melt": [1, _make_melt],
		&"gurgle": [1, _make_gurgle],
	}
	for preset: StringName in recipes:
		var spec: Array = recipes[preset]
		var count: int = spec[0]
		var maker: Callable = spec[1]
		var variants: Array[AudioStreamWAV] = []
		for v in count:
			var wav: AudioStreamWAV = maker.call(v)
			variants.append(wav)
		_bank[preset] = variants


# --- presets: `variant` nudges the numbers so repeats do not sound identical ---

func _make_jump(variant: int) -> AudioStreamWAV:
	var b := _buf(0.16)
	var f := 190.0 + 25.0 * variant
	_sweep(b, 0.0, 0.14, f, f * 2.6, 0.7)
	_noise(b, 0.0, 0.05, 0.35, 2500.0, 900.0, 3.0)
	_bloop(b, 0.0, 620.0 + 40.0 * variant, 0.035, 0.25)
	return _finish(b, 0.8)


func _make_land_soft(variant: int) -> AudioStreamWAV:
	var b := _buf(0.12)
	_sweep(b, 0.0, 0.09, 140.0 * (1.0 + 0.05 * variant), 60.0, 0.8)
	_noise(b, 0.0, 0.07, 0.4, 1800.0, 500.0)
	_bloop(b, 0.01, 420.0 + 50.0 * variant, 0.04, 0.3)
	return _finish(b, 0.6)


func _make_land_heavy(variant: int) -> AudioStreamWAV:
	var b := _buf(0.32)
	_sweep(b, 0.0, 0.28, 90.0 - 6.0 * variant, 35.0, 1.0, 0.004, 1.5)
	_noise(b, 0.0, 0.3, 0.6, 3000.0, 250.0, 1.5)
	_bloop(b, 0.04, 500.0 + 30.0 * variant, 0.05, 0.4)
	_bloop(b, 0.09, 380.0 + 20.0 * variant, 0.06, 0.35)
	return _finish(b, 1.0)


func _make_splash(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.45)
	_splash_layers(b, 1.0)
	return _finish(b, 1.0)


func _make_step(variant: int) -> AudioStreamWAV:
	var b := _buf(0.045)
	_noise(b, 0.0, 0.035, 0.5, 1600.0, 700.0, 3.0, 300.0)
	_bloop(b, 0.005, 520.0 + 60.0 * variant, 0.03, 0.25)
	return _finish(b, 0.35)


func _make_drip(variant: int) -> AudioStreamWAV:
	var b := _buf(0.05)
	_bloop(b, 0.0, 700.0 + 180.0 * variant, 0.045, 0.6)
	_noise(b, 0.0, 0.02, 0.15, 3000.0, 1500.0)
	return _finish(b, 0.4)


func _make_absorb(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.19)
	_sweep(b, 0.0, 0.17, 230.0, 760.0, 0.6, 0.01, 1.2, 0, 22.0, 0.06)
	_noise(b, 0.0, 0.14, 0.3, 600.0, 2400.0, 1.5)
	_bloop(b, 0.15, 1200.0, 0.035, 0.4)
	return _finish(b, 0.75)


func _make_hurt(variant: int) -> AudioStreamWAV:
	var b := _buf(0.19)
	_sweep(b, 0.0, 0.18, 560.0 - 40.0 * variant, 170.0, 0.6, 0.004, 1.8, 1)
	_noise(b, 0.0, 0.06, 0.5, 4000.0, 1500.0)
	return _finish(b, 0.7)


func _make_death(_variant: int) -> AudioStreamWAV:
	var b := _buf(1.2)
	_splash_layers(b, 0.6 / 0.42)
	_sweep(b, 0.05, 0.75, 440.0, 70.0, 0.6, 0.004, 1.2, 0, 9.0, 0.08)
	_echo(b, 0.12, 0.35)
	_echo(b, 0.24, 0.18)
	return _finish(b, 1.0)


func _make_respawn(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.36)
	_sweep(b, 0.0, 0.11, 400.0, 523.0, 0.5, 0.004, 1.5)
	_sweep(b, 0.07, 0.11, 523.0, 659.0, 0.5, 0.004, 1.5)
	_sweep(b, 0.14, 0.2, 659.0, 784.0, 0.5, 0.004, 1.5)
	_noise(b, 0.1, 0.15, 0.15, 9000.0, 6000.0, 2.0, 3000.0)
	return _finish(b, 0.7)


func _make_checkpoint(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.72)
	_bell(b, 0.0, 880.0, 0.6, 0.5)
	_bell(b, 0.09, 1320.0, 0.6, 0.45)
	_noise(b, 0.04, 0.35, 0.12, 9000.0, 5000.0, 2.5, 3000.0)
	return _finish(b, 0.7)


func _make_goal(_variant: int) -> AudioStreamWAV:
	var b := _buf(1.24)
	_bell(b, 0.0, 523.0, 0.4, 0.45)
	_bell(b, 0.1, 659.0, 0.4, 0.45)
	_bell(b, 0.2, 784.0, 0.45, 0.45)
	_bell(b, 0.3, 1046.0, 0.9, 0.5)
	return _finish(b, 0.8)


func _make_heartbeat(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.29)
	_sweep(b, 0.0, 0.1, 70.0, 45.0, 0.9)
	_sweep(b, 0.17, 0.1, 62.0, 40.0, 0.7)
	return _finish(b, 0.6)


func _make_wall_splat(variant: int) -> AudioStreamWAV:
	var b := _buf(0.1)
	_noise(b, 0.0, 0.1, 0.6, 2600.0 * (1.0 + 0.1 * variant), 600.0)
	_bloop(b, 0.01, 380.0 + 40.0 * variant, 0.05, 0.4)
	return _finish(b, 0.5)


func _make_bonk(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.08)
	_sweep(b, 0.0, 0.08, 180.0, 90.0, 0.7)
	_noise(b, 0.0, 0.05, 0.4, 2000.0, 600.0)
	return _finish(b, 0.5)


func _make_shred(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.25)
	_noise(b, 0.0, 0.25, 0.7, 7000.0, 2000.0, 1.0, 800.0)
	_sweep(b, 0.0, 0.25, 900.0, 300.0, 0.3, 0.004, 2.0, 2)
	_bloop(b, 0.05, 600.0, 0.05, 0.4)
	return _finish(b, 0.7)


## Loop of whole cycles (96 Hz, 192 Hz, 12 Hz AM). The noise bed is cross-faded over the seam.
func _make_saw_loop(_variant: int) -> AudioStreamWAV:
	var n := int(SAW_LOOP_SECONDS * _rate)
	var xf := int(SAW_LOOP_CROSSFADE * _rate)
	var bed := PackedFloat32Array()
	bed.resize(n + xf)
	bed.fill(0.0)
	_noise(bed, 0.0, float(n + xf) / _rate, 0.2, 1400.0, 1400.0, 0.0, 0.0, 0.0)
	var b := _buf(SAW_LOOP_SECONDS)
	for k in n:
		var t := float(k) / _rate
		var buzz := (fposmod(96.0 * t, 1.0) * 2.0 - 1.0) * 0.7 + (fposmod(192.0 * t, 1.0) * 2.0 - 1.0) * 0.35
		var noise_v := bed[k]
		if k < xf:
			var w := float(k) / xf
			noise_v = bed[k] * w + bed[n + k] * (1.0 - w)
		b[k] = buzz * (0.75 + 0.25 * sin(TAU * 12.0 * t)) + noise_v
	return _finish(b, 0.5, true)


func _make_ui_tick(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.03)
	_bloop(b, 0.0, 1400.0, 0.03, 0.5)
	return _finish(b, 0.4)


## Wet gulp with a muffled knock: a solid thing sinking into jelly.
func _make_swallow(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.2)
	_sweep(b, 0.0, 0.16, 320.0, 110.0, 0.7, 0.006, 1.4, 0, 18.0, 0.08)
	_noise(b, 0.0, 0.12, 0.3, 900.0, 300.0, 1.5)
	_bloop(b, 0.1, 190.0, 0.07, 0.6)
	return _finish(b, 0.8)


## Hard spit: a pressure burst, a deep thump and a wet crack.
func _make_spit(variant: int) -> AudioStreamWAV:
	var b := _buf(0.24)
	_noise(b, 0.0, 0.13, 0.9, 6500.0 - 600.0 * variant, 900.0, 1.8)
	_sweep(b, 0.0, 0.18, 170.0 + 15.0 * variant, 50.0, 1.0, 0.002, 1.5)
	_sweep(b, 0.0, 0.05, 1100.0, 320.0, 0.3, 0.001, 2.0, 2)
	_bloop(b, 0.015, 700.0 + 80.0 * variant, 0.05, 0.35)
	return _finish(b, 1.0)


func _make_spit_dry(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.09)
	_noise(b, 0.0, 0.08, 0.5, 2500.0, 600.0, 2.0)
	_bloop(b, 0.0, 420.0, 0.05, 0.3)
	return _finish(b, 0.5)


## Stone tick on rock: a short bright ring over a click. Pitch and volume carry the impact speed.
func _make_clink(variant: int) -> AudioStreamWAV:
	var b := _buf(0.07)
	var f := 2100.0 + 320.0 * variant
	_sweep(b, 0.0, 0.065, f, f * 0.97, 0.5, 0.001, 3.0)
	_sweep(b, 0.0, 0.04, f * 1.53, f * 1.5, 0.25, 0.001, 3.0)
	_noise(b, 0.0, 0.015, 0.6, 8000.0, 4000.0, 2.0)
	return _finish(b, 0.7)


## Body hit on the mite: a squashy punch.
func _make_thwack(variant: int) -> AudioStreamWAV:
	var b := _buf(0.14)
	_sweep(b, 0.0, 0.11, 280.0 - 30.0 * variant, 85.0, 0.8, 0.002, 1.6, 1)
	_noise(b, 0.0, 0.05, 0.6, 3200.0, 800.0, 2.0)
	_bloop(b, 0.02, 520.0 + 60.0 * variant, 0.05, 0.3)
	return _finish(b, 0.9)


## Mite death: an upward pop, a puff and a falling tail.
func _make_pop(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.32)
	_sweep(b, 0.0, 0.05, 420.0, 1500.0, 0.7, 0.001, 0.8)
	_noise(b, 0.03, 0.2, 0.7, 5000.0, 400.0, 1.6)
	_sweep(b, 0.05, 0.22, 240.0, 60.0, 0.7, 0.003, 1.5)
	_bloop(b, 0.08, 900.0, 0.06, 0.35)
	_bloop(b, 0.13, 650.0, 0.06, 0.3)
	return _finish(b, 1.0)


## Rock breaking on a trap: a dry snap, a short stone thump and a few gritty ticks of falling grit.
func _make_crack(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.24)
	_noise(b, 0.0, 0.03, 1.0, 7000.0, 2500.0, 2.0, 900.0, 0.0005)
	_sweep(b, 0.0, 0.1, 190.0, 60.0, 0.9, 0.001, 1.8, 1)
	_noise(b, 0.01, 0.2, 0.35, 3000.0, 600.0, 2.2)
	for i in 4:
		var f := 1100.0 + 380.0 * i
		_sweep(b, 0.03 + 0.04 * i, 0.03, f, f * 0.9, 0.22, 0.001, 3.0)
	return _finish(b, 1.0)


## Crystal wall breaking: a crash bed, a low thump and a spray of glassy tinkles.
func _make_shatter(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.42)
	_noise(b, 0.0, 0.4, 0.6, 9000.0, 3000.0, 2.5, 1500.0)
	_sweep(b, 0.0, 0.14, 130.0, 45.0, 0.9, 0.002, 1.5)
	for _i in 6:
		var f := _rng.randf_range(2400.0, 5200.0)
		_sweep(b, _rng.randf_range(0.0, 0.26), 0.09, f, f * 0.98, 0.35, 0.001, 3.0)
	return _finish(b, 1.0)


## Air jump: a squeezed bloop that pops upward, with a soft puff.
func _make_double_jump(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.2)
	_sweep(b, 0.0, 0.05, 260.0, 200.0, 0.5, 0.002, 1.0)
	_sweep(b, 0.04, 0.15, 330.0, 1050.0, 0.7, 0.003, 1.6)
	_bloop(b, 0.05, 1300.0, 0.04, 0.35)
	_noise(b, 0.03, 0.09, 0.3, 3200.0, 1200.0, 2.0)
	return _finish(b, 0.8)


## Wet skid: a friction squeal over a smeared hiss that dies with the slide.
func _make_skid(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.3)
	_noise(b, 0.0, 0.3, 0.6, 4200.0, 900.0, 1.3, 400.0)
	_sweep(b, 0.0, 0.26, 720.0, 430.0, 0.32, 0.01, 1.4, 2, 28.0, 0.05)
	return _finish(b, 0.85)


## Dodge: a short whoosh with a wet slap at the start.
func _make_dodge(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.16)
	_noise(b, 0.0, 0.15, 0.7, 900.0, 5200.0, 1.6, 300.0, 0.03)
	_bloop(b, 0.0, 380.0, 0.04, 0.35)
	return _finish(b, 0.7)


## Roll: a rolling squelch, three soft knocks under a sweep of air.
func _make_roll(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.32)
	_noise(b, 0.0, 0.3, 0.45, 700.0, 2600.0, 1.2, 200.0, 0.04)
	for k in 3:
		_bloop(b, 0.03 + 0.09 * k, 260.0 + 40.0 * k, 0.05, 0.45)
	return _finish(b, 0.75)


## Goo dragging down a wall: a soft rubbing hiss, replayed while the slime slides.
func _make_wall_slide(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.18)
	_noise(b, 0.0, 0.18, 0.5, 1500.0, 1100.0, 1.0, 250.0, 0.03)
	_sweep(b, 0.02, 0.12, 210.0, 170.0, 0.15, 0.02, 1.0)
	return _finish(b, 0.5)


## Burn pulse: a bright hiss with a few pops of crackle.
func _make_sizzle(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.2)
	_noise(b, 0.0, 0.2, 0.6, 9000.0, 5000.0, 1.6, 2500.0, 0.004)
	for i in 3:
		_sweep(b, 0.02 + 0.05 * i, 0.012, 2600.0 - 300.0 * i, 1800.0, 0.5, 0.0005, 3.0, 1)
	return _finish(b, 0.8)


## Catching fire: a rising whoosh over a low thump.
func _make_ignite(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.36)
	_noise(b, 0.0, 0.36, 0.9, 500.0, 6000.0, 1.2, 150.0, 0.05)
	_sweep(b, 0.0, 0.18, 90.0, 55.0, 0.8, 0.003, 1.6)
	return _finish(b, 1.0)


## Fire put out by the cold: a long steam hiss that fades.
func _make_fire_out(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.38)
	_noise(b, 0.0, 0.38, 0.8, 7000.0, 3500.0, 1.4, 1800.0, 0.01)
	return _finish(b, 0.85)


## Body of a fire, looped: a deep breathing rumble under an airy hiss. Both come from one noise through one-pole
## filters, and the seam is cross-faded.
func _make_fire_roar(_variant: int) -> AudioStreamWAV:
	var rate := FIRE_ROAR_RATE
	var n := int(FIRE_ROAR_SECONDS * rate)
	var xf := int(FIRE_ROAR_CROSSFADE * rate)
	var a_low := 1.0 - exp(-TAU * 150.0 / rate)
	var a_air := 1.0 - exp(-TAU * 1900.0 / rate)
	var a_cut := 1.0 - exp(-TAU * 520.0 / rate)
	var bed := PackedFloat32Array()
	bed.resize(n + xf)
	var low := 0.0
	var low2 := 0.0
	var air := 0.0
	var air_low := 0.0
	for k in n + xf:
		var white := _rng.randf() * 2.0 - 1.0
		low += a_low * (white - low)
		low2 += a_low * (low - low2)
		air += a_air * (white - air)
		air_low += a_cut * (air - air_low)
		bed[k] = low2 * 4.0 + (air - air_low) * 0.3
	var b := PackedFloat32Array()
	b.resize(n)
	for k in n:
		var v := bed[k]
		if k < xf:
			var w := float(k) / xf
			v = bed[k] * w + bed[n + k] * (1.0 - w)
		# Three whole breaths per loop, so the swell has no seam either.
		b[k] = v * (0.82 + 0.18 * sin(TAU * 3.0 * k / n))
	var wav := _finish(b, 0.75, true)
	wav.mix_rate = rate
	return wav


## One crackle of burning matter: a sharp snap and a tiny ring. Played at random pitch, many times a second.
func _make_fire_crackle(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.022)
	_noise(b, 0.0, 0.012, 1.0, 9000.0, 3000.0, 3.0, 1200.0, 0.0003)
	_sweep(b, 0.0, 0.012, 1900.0, 1300.0, 0.35, 0.0005, 3.0, 1)
	return _finish(b, 0.8)


## Freezing: a quick run of brittle ice crackles.
func _make_freeze(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.26)
	for i in 6:
		var f := 3200.0 + 450.0 * float(i % 3)
		_sweep(b, 0.035 * i, 0.03, f, f * 0.85, 0.45, 0.0005, 3.0, 1)
	_noise(b, 0.0, 0.24, 0.25, 8000.0, 4000.0, 2.0, 3000.0)
	return _finish(b, 0.75)


## Ice cube knock: a hard glassy tink.
func _make_ice_clink(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.14)
	_bell(b, 0.0, 1850.0, 0.13, 0.6)
	_sweep(b, 0.0, 0.03, 260.0, 180.0, 0.5, 0.0005, 2.0, 1)
	return _finish(b, 0.8)


## Melting goo: a soft sagging gloop.
func _make_melt(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.2)
	_sweep(b, 0.0, 0.18, 420.0, 150.0, 0.7, 0.01, 1.4)
	_bloop(b, 0.08, 520.0, 0.07, 0.35)
	return _finish(b, 0.7)


## Goo rushing through a pipe: a run of hollow bloops.
func _make_gurgle(_variant: int) -> AudioStreamWAV:
	var b := _buf(0.3)
	for i in 5:
		_bloop(b, 0.05 * i, 240.0 + 70.0 * float((i * 3) % 4), 0.06, 0.55)
	return _finish(b, 0.8)


func _splash_layers(b: PackedFloat32Array, stretch: float) -> void:
	_noise(b, 0.0, 0.42 * stretch, 0.8, 5200.0, 350.0, 1.6)
	_sweep(b, 0.0, 0.2 * stretch, 110.0, 40.0, 0.7)
	for _i in 5:
		var offset := _rng.randf_range(0.0, 0.25) * stretch
		_bloop(b, offset, _rng.randf_range(320.0, 950.0), _rng.randf_range(0.04, 0.08), 0.35)


# --- synthesis helpers: each one adds into a float buffer ---

func _buf(seconds: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(maxi(int(seconds * _rate), 1))
	b.fill(0.0)
	return b


## wave: 0 sine, 1 soft square, 2 saw. Exponential pitch glide, attack then (1 - t)^curve decay.
func _sweep(b: PackedFloat32Array, start: float, dur: float, f0: float, f1: float, amp: float, attack := 0.004, curve := 2.0, wave := 0, vib_hz := 0.0, vib_depth := 0.0) -> void:
	if f0 <= 0.0 or f1 <= 0.0:
		return
	var i0 := int(start * _rate)
	var n := int(dur * _rate)
	var phase := 0.0
	# The exponential glide advances by a constant ratio per sample, so no pow() runs inside the loop.
	var glide := pow(f1 / f0, 1.0 / maxf(n, 1))
	var base_f := f0
	var att := maxf(attack * _rate, 1.0)
	for k in n:
		var i := i0 + k
		if i >= b.size():
			break
		var t := float(k) / n
		var f := base_f
		base_f *= glide
		if vib_hz > 0.0:
			f *= 1.0 + vib_depth * sin(TAU * vib_hz * k / _rate)
		phase += f / _rate
		var s: float
		match wave:
			1:
				s = clampf(sin(TAU * phase) * 3.0, -1.0, 1.0) * 0.6
			2:
				s = (fposmod(phase, 1.0) * 2.0 - 1.0) * 0.7
			_:
				s = sin(TAU * phase)
		var env := minf(k / att, 1.0) * (pow(1.0 - t, curve) if curve > 0.0 else 1.0)
		b[i] += s * amp * env


## White noise through a one-pole low-pass whose cutoff glides; optional one-pole high-pass.
func _noise(b: PackedFloat32Array, start: float, dur: float, amp: float, cut0: float, cut1: float, curve := 2.0, highpass := 0.0, attack := 0.002) -> void:
	var i0 := int(start * _rate)
	var n := int(dur * _rate)
	var lp := 0.0
	var hp_state := 0.0
	var hp_a := 1.0 - exp(-TAU * highpass / _rate) if highpass > 0.0 else 0.0
	var att := maxf(attack * _rate, 1.0)
	var a := 0.0
	for k in n:
		var i := i0 + k
		if i >= b.size():
			break
		var t := float(k) / n
		# The cutoff glides slowly; refreshing the coefficient every few samples is inaudible and much cheaper.
		if k % NOISE_COEFF_STRIDE == 0:
			a = 1.0 - exp(-TAU * lerpf(cut0, cut1, t) / _rate)
		lp += a * ((_rng.randf() * 2.0 - 1.0) - lp)
		var s := lp
		if highpass > 0.0:
			hp_state += hp_a * (lp - hp_state)
			s = lp - hp_state
		var env := (minf(k / att, 1.0) if attack > 0.0 else 1.0) * (pow(1.0 - t, curve) if curve > 0.0 else 1.0)
		b[i] += s * amp * env


func _bloop(b: PackedFloat32Array, start: float, f: float, dur: float, amp: float) -> void:
	_sweep(b, start, dur, f, f * 0.55, amp, 0.002, 1.5)


func _bell(b: PackedFloat32Array, start: float, f: float, dur: float, amp: float) -> void:
	_sweep(b, start, dur, f, f, amp, 0.003, 2.5)
	_sweep(b, start, dur * 0.6, f * 2.76, f * 2.76, amp * 0.4, 0.002, 3.0)
	_sweep(b, start, dur * 0.35, f * 5.4, f * 5.4, amp * 0.2, 0.001, 3.0)


## Single-tap delay added in place; walking backward keeps each tap from feeding itself.
func _echo(b: PackedFloat32Array, delay: float, gain: float) -> void:
	var d := maxi(int(delay * _rate), 1)
	var i := b.size() - 1
	while i >= d:
		b[i] += b[i - d] * gain
		i -= 1


## Normalizes the peak to `PEAK_TARGET * gain` and encodes 16-bit mono. One-shots get a short fade at both ends.
func _finish(b: PackedFloat32Array, gain: float, loop := false) -> AudioStreamWAV:
	var peak := 0.0001
	for v: float in b:
		peak = maxf(peak, absf(v))
	var g := PEAK_TARGET * clampf(gain, 0.0, 1.0) / peak
	var size := b.size()
	var fade_in_n := maxf(FADE_IN_SECONDS * _rate, 1.0)
	var fade_out_n := maxf(FADE_OUT_SECONDS * _rate, 1.0)
	var bytes := PackedByteArray()
	bytes.resize(size * 2)
	for i in size:
		var fade := 1.0
		if not loop:
			fade = minf(minf(i / fade_in_n, 1.0), minf((size - 1 - i) / fade_out_n, 1.0))
		bytes.encode_s16(i * 2, int(clampf(b[i] * g * fade, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = _rate
	w.stereo = false
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = size
	return w
