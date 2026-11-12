extends Node
## Quality levels and the automatic quality. A level only changes what the player sees, never the gameplay.
## The automatic mode measures the real frame time during play and moves one step down the ladder when the game
## cannot hold Tuning.quality_target_fps; it moves one step up only after a long calm wait with a clear margin, then
## watches a probe window and goes back down (and never tries that step again on this GPU) if the probe fails.
## The mode, the render mode and the step of the automatic mode are saved in user://quality.cfg.
## Command line (after --): --quality=auto|high|medium|low, --render-scale=auto|full|base, --quality-log,
## --quality-governor (runs the automatic mode also headless or at a fixed rate, for tests),
## --user-settings (a scripted run reads and writes the saved quality.cfg), --quality-save=<file in user://> (also saves in a scripted run), --slow-frame=<ms per step, low to high>[@from-to]
## (a busy wait in each frame that emulates a slow PC; from and to are seconds after the level start),
## --slow-share=<share of frames per step, low to high> (only that share of frames gets the slow wait),
## --quality-phone (the phone rules on any device), --quality-fake-busy=<ms> (adds ms to the CPU busy reading and hides
## the GPU time, as a driver whose render time holds the wait for the display).
## Phone rules: a new install starts at Medium, the ladder can climb to High, and High reached by a climb must keep
## the frame time measured on Medium just before (not only the target rate). If High is slower, the mode measures the
## same scene at Medium: Medium clearly faster blocks High for the session; otherwise the scene is heavy for both, and
## the mode goes back to High with the reference raised to that Medium time.

signal changed

enum Level { LOW, MEDIUM, HIGH }
enum Mode { AUTO, LOW, MEDIUM, HIGH }
enum RenderMode { AUTO, FULL, BASE }

const SAVE_PATH := "user://quality.cfg"
const SECTION := "quality"
const LEVEL_NAMES: PackedStringArray = ["Low", "Medium", "High"]
const MODE_NAMES: PackedStringArray = ["Auto", "Low", "Medium", "High"]
const RENDER_NAMES: PackedStringArray = ["Auto", "Full", "Base"]
## The Tuning fields that a level owns. The performance panel can still flip them by hand (an override until the next
## level change); every other panel switch stays a plain diagnosis switch.
const LEVEL_FIELDS := {
	&"fx_fire_rich": [false, false, true],
	&"goo_gloss": [false, true, true],
	&"fx_decor_motion": [false, true, true],
	&"fx_bg_detail": [false, true, true],
}
## Frames of the boot warm-up that render the highest level, so a later step up compiles nothing.
const WARM_UP_FRAMES := 5

## Ladder of the automatic mode, lowest first: [level, base render resolution].
var _steps: Array = []
var _mode := Mode.AUTO
var _render_mode := RenderMode.AUTO
var _step := 0
var _max_step := 0
## Lowest step that failed a probe on this GPU; the automatic mode never climbs to it again.
var _ceiling := 1000
var _level := Level.HIGH
var _base_res := false
var _save_path := SAVE_PATH
var _save_enabled := true
var _log := false
var _force_governor := false
var _phone := false
var _fake_busy_ms := -1.0
var _slow_ms := PackedFloat32Array()
## Share of the frames that get the slow wait, per step (empty: every frame); a test of frames that miss now and then.
var _slow_share := PackedFloat32Array()
var _slow_acc := 0.0
var _slow_from := 0.0
var _slow_to := INF

var _governor_on := false
var _level_running := false
var _level_time := 0.0
var _settle := 0.0
var _last_usec := 0
var _focused := true
## Down window: frames, summed frame ms, frames over the miss limit.
var _win_n := 0
var _win_sum := 0.0
var _win_miss := 0
var _win_time := 0.0
var _first_window := false
## Calm time at this step, with the frames and the busy time summed over it.
var _calm := 0.0
var _calm_n := 0
var _calm_miss := 0
var _calm_busy := 0.0
var _calm_frame := 0.0
var _calm_gpu := 0.0
var _calm_script := 0.0
var _probe_left := 0.0
## Phone rules: mean frame ms of the step below, which the current climbed step must keep (0: no hold check).
var _hold_ref_ms := 0.0
var _win_hold_miss := 0
## Hold check: the High mean frame that failed (0: no check), the reference then, and the sums at Medium.
var _check_high_ms := 0.0
var _check_ref_ms := 0.0
var _check_sum := 0.0
var _check_n := 0
var _check_time := 0.0
var _check_miss := 0
## True when High failed by its share of slow frames (not only by its mean).
var _check_by_miss := false
## Hold checks of this session; past Tuning.quality_hold_check_max the check stops for the session.
var _hold_checks := 0
var _hold_off := false
## Ceiling from a High that failed its hold check; it lasts for this session only and is never saved.
var _session_ceiling := 1000
var _warm_left := 0
## Each step down after a climb doubles the calm wait before the next step up, so the level never swings back and forth.
var _up_wait_mult := 1.0
var _climbed := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -999000
	_parse_args()
	_phone = _phone or OS.has_feature("mobile")
	_steps = [[Level.LOW, true], [Level.LOW, false], [Level.MEDIUM, false], [Level.HIGH, false]]
	_max_step = 3
	# A phone starts one step below the top; only the governor climbs to the top, with the hold check.
	_step = 2 if _phone else _max_step
	var fresh := not _load()
	_first_window = fresh
	_governor_on = _force_governor or (DisplayServer.get_name() != "headless" and not _fixed_rate_run())
	_apply(false)
	if _governor_on:
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_log_line("boot", {"fresh": fresh, "governor": _governor_on})
	get_tree().root.size_changed.connect(_on_size_changed)
	_connect_game.call_deferred()


func _connect_game() -> void:
	Game.level_started.connect(_on_level_started)


## Current level (Level enum) and whether the render runs at the base resolution.
func level() -> int:
	return _level


func base_resolution() -> bool:
	return _base_res


func mode() -> int:
	return _mode


func render_mode() -> int:
	return _render_mode


## The value a level gives to a field it owns, or null for a field it does not own.
func level_value(field: StringName) -> Variant:
	if not LEVEL_FIELDS.has(field):
		return null
	return LEVEL_FIELDS[field][_level]


func owns(field: StringName) -> bool:
	return LEVEL_FIELDS.has(field)


## One line for the performance panel.
func describe() -> String:
	var text := "Quality %s: %s" % [MODE_NAMES[_mode], LEVEL_NAMES[_level]]
	if _mode == Mode.AUTO:
		text += " (step %d/%d)" % [_step + 1, _max_step + 1]
	var render := Vector2.ZERO
	if is_inside_tree():
		var root := get_tree().root
		# In canvas_items mode the texture size reports the stretch scale; the drawn size is the window size.
		render = root.get_texture().get_size() if root.content_scale_mode == Window.CONTENT_SCALE_MODE_VIEWPORT else Vector2(root.size)
	text += "   render %s %dx%d" % [RENDER_NAMES[_render_mode], roundi(render.x), roundi(render.y)]
	return text


func set_mode(value: int) -> void:
	_mode = clampi(value, Mode.AUTO, Mode.HIGH) as Mode
	if _mode == Mode.AUTO:
		_step = mini(_step, _top_step())
	_apply(true)
	_save()


func set_render_mode(value: int) -> void:
	_render_mode = clampi(value, RenderMode.AUTO, RenderMode.BASE) as RenderMode
	_apply(true)
	_save()


func cycle_mode() -> void:
	set_mode((_mode + 1) % MODE_NAMES.size())


func cycle_render_mode() -> void:
	set_render_mode((_render_mode + 1) % RENDER_NAMES.size())


## The render panel and Quality both need the measured render time of the root viewport.
func wants_render_time() -> bool:
	return _governor_on and _mode == Mode.AUTO


## Called during the boot warm-up behind the cover: renders the highest level for a few frames, so a later step up
## shows nothing that was never drawn (the heat shimmer, the gloss path, the moving decoration).
func warm_up() -> void:
	_warm_left = WARM_UP_FRAMES
	_apply_fields(Level.HIGH)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var frame_ms := (now - _last_usec) / 1000.0 if _last_usec > 0 else 0.0
	_last_usec = now
	if _warm_left > 0:
		_warm_left -= 1
		if _warm_left == 0:
			_apply_fields(_level)
	if _level_running:
		_level_time += frame_ms / 1000.0
		_slow_frame()
	if not _governor_on or _mode != Mode.AUTO or not _level_running or not _focused or frame_ms <= 0.0:
		return
	if frame_ms > Tuning.quality_spike_ms:
		# A stall (a window drag, a load, a system hiccup), not a sustained cost.
		_reset_windows()
		return
	if _settle > 0.0:
		_settle -= frame_ms / 1000.0
		return
	_sample(frame_ms)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_focused = false
		_reset_windows()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_focused = true
		_settle = Tuning.quality_settle_time


func _on_level_started() -> void:
	_level_running = true
	_level_time = 0.0
	_settle = Tuning.quality_settle_time
	_reset_windows()


func _on_size_changed() -> void:
	if _render_mode == RenderMode.AUTO and _steps[_step][1]:
		_apply_render()


func _budget_ms() -> float:
	var fps := Tuning.quality_target_fps
	var refresh := DisplayServer.screen_get_refresh_rate()
	if refresh > 1.0 and DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED:
		fps = minf(fps, roundf(refresh))
	return 1000.0 / maxf(fps, 1.0)


func _sample(frame_ms: float) -> void:
	var budget := _budget_ms()
	var miss := frame_ms > budget * Tuning.quality_miss_factor
	# High climbed on the phone rules must also keep the frame time of Medium, which can be far under the budget.
	var hold_limit := _hold_ref_ms * Tuning.quality_hold_factor
	_win_n += 1
	_win_sum += frame_ms
	_win_miss += int(miss)
	_win_hold_miss += int(_hold_ref_ms > 0.0 and frame_ms > hold_limit * Tuning.quality_miss_factor)
	_win_time += frame_ms / 1000.0
	_calm += frame_ms / 1000.0
	_calm_n += 1
	_calm_miss += int(miss)
	_calm_frame += frame_ms
	_calm_busy += _busy_ms()
	if _probe_left > 0.0:
		_probe_left -= frame_ms / 1000.0
	if _check_high_ms > 0.0:
		_check_sum += frame_ms
		_check_n += 1
		_check_time += frame_ms / 1000.0
		_check_miss += int(frame_ms > _check_ref_ms * Tuning.quality_hold_factor * Tuning.quality_miss_factor)
	var window := Tuning.quality_first_window if _first_window else Tuning.quality_down_window
	if _win_time >= window:
		var mean := _win_sum / _win_n
		var miss_share := float(_win_miss) / _win_n
		# The budget rule comes first, on every device.
		if mean > budget * Tuning.quality_down_mean or miss_share > Tuning.quality_miss_share:
			_step_down(mean, miss_share)
			return
		var hold_share := float(_win_hold_miss) / _win_n
		if _hold_ref_ms > 0.0 and not _hold_off and (mean > hold_limit or hold_share > Tuning.quality_miss_share):
			if _hold_checks >= Tuning.quality_hold_check_max:
				# The scene keeps both levels slow: keep High and stop the hold check; the budget rule stays.
				_hold_off = true
				_log_line("hold_off", {"checks": _hold_checks})
			else:
				_hold_failed(mean, hold_share)
				return
		_first_window = false
		_win_n = 0
		_win_sum = 0.0
		_win_miss = 0
		_win_hold_miss = 0
		_win_time = 0.0
	if _check_high_ms > 0.0 and _check_time >= Tuning.quality_check_window:
		_finish_check()
		return
	if _probe_left <= 0.0 and _calm >= Tuning.quality_up_wait * _up_wait_mult:
		_try_step_up(budget)


## CPU time of the frame (scripts, draw flush, render submit) or the GPU time when the driver reports it, whichever is
## larger. Also sums the script and draw time and the GPU time of the calm window.
func _busy_ms() -> float:
	var rid := get_viewport().get_viewport_rid()
	var script_draw := PerfPanel.last_script_and_draw_ms()
	var render_cpu := RenderingServer.viewport_get_measured_render_time_cpu(rid) + RenderingServer.get_frame_setup_time_cpu()
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(rid)
	if _fake_busy_ms >= 0.0:
		render_cpu += _fake_busy_ms
		gpu = 0.0
	_calm_script += script_draw
	_calm_gpu += gpu
	return maxf(script_draw + render_cpu, gpu)


func _step_down(mean: float, miss_share: float) -> void:
	var probing := _probe_left > 0.0
	if probing:
		# The step up did not hold the budget: never try it again on this GPU.
		_ceiling = _step
	_hold_ref_ms = 0.0
	_check_high_ms = 0.0
	if _step <= _bottom_step():
		_reset_windows()
		return
	_step -= 1
	_probe_left = 0.0
	# The first descent of a start is calibration; a fall after a climb makes the next climb wait longer.
	if _climbed:
		_up_wait_mult = minf(_up_wait_mult * 2.0, Tuning.quality_up_wait_max_mult)
	_log_line("down", {"mean_ms": snappedf(mean, 0.01), "miss": snappedf(miss_share, 0.001), "probe_failed": probing})
	_apply(true)
	_save()


## High (phone rules) is slower than the frame time of Medium: go to Medium and measure the same scene there, to see
## whether High is the cause or the scene is heavy for both levels.
func _hold_failed(mean: float, hold_share: float) -> void:
	_hold_checks += 1
	_check_high_ms = mean
	_check_ref_ms = _hold_ref_ms
	_check_by_miss = hold_share > Tuning.quality_miss_share
	_check_sum = 0.0
	_check_n = 0
	_check_miss = 0
	_check_time = 0.0
	_hold_ref_ms = 0.0
	_probe_left = 0.0
	_step -= 1
	_log_line("hold_check", {"high_ms": snappedf(mean, 0.01), "ref_ms": snappedf(_check_ref_ms, 0.01), "hold_miss": snappedf(hold_share, 0.001), "by_miss": _check_by_miss, "check": _hold_checks})
	_apply(true)
	_save()


## High is the cause when Medium is clearly faster in the same scene: by the mean, or, when High failed by its share of
## slow frames, by Medium keeping that share within the limit against the same reference. Then the mode stays at
## Medium for this session. Otherwise the scene is heavy for both: back to High at once, with the reference raised.
func _finish_check() -> void:
	var medium := _check_sum / maxf(_check_n, 1)
	var medium_miss := float(_check_miss) / maxf(_check_n, 1)
	var high := _check_high_ms
	_check_high_ms = 0.0
	if high > medium * Tuning.quality_hold_factor or (_check_by_miss and medium_miss <= Tuning.quality_miss_share):
		_session_ceiling = _step + 1
		_log_line("hold_result", {"medium_ms": snappedf(medium, 0.01), "medium_miss": snappedf(medium_miss, 0.001), "high_ms": snappedf(high, 0.01), "cause": "high"})
		return
	_step += 1
	_hold_ref_ms = maxf(_check_ref_ms, medium)
	_log_line("hold_result", {"medium_ms": snappedf(medium, 0.01), "high_ms": snappedf(high, 0.01), "medium_miss": snappedf(medium_miss, 0.001), "cause": "scene", "hold_ref_ms": snappedf(_hold_ref_ms, 0.01)})
	_apply(true)
	_save()


func _try_step_up(budget: float) -> void:
	var top := _top_step()
	if _step >= top:
		_reset_windows()
		return
	var n := maxf(_calm_n, 1)
	var busy := _calm_busy / n
	var miss_share := float(_calm_miss) / n
	var mean := _calm_frame / n
	var script_draw := _calm_script / n
	var calm := miss_share <= Tuning.quality_up_miss_share
	var margin := busy < budget * Tuning.quality_up_busy_share
	# With no GPU time, the CPU render time of some drivers holds the wait for the display, so the busy reading looks
	# full while the game has margin. Then the frames that hold the budget and a light script and draw time permit one
	# probe; a failed probe sets the ceiling, so this never swings.
	var unknown := not margin and _calm_gpu <= 0.0 and mean <= budget * Tuning.quality_down_mean and script_draw < budget * Tuning.quality_up_script_share
	if calm and (margin or unknown):
		var below_ms := mean
		_step += 1
		_climbed = true
		_probe_left = Tuning.quality_probe_time
		_hold_ref_ms = below_ms if _phone and _step == _max_step else 0.0
		_log_line("up", {"busy_ms": snappedf(busy, 0.01), "miss": snappedf(miss_share, 0.001), "busy_unknown": unknown and not margin, "hold_ref_ms": snappedf(_hold_ref_ms, 0.01)})
		_apply(true)
		_save()
		return
	_reset_windows()


## The base resolution step is skipped where it would not lower the pixel count enough (or a render mode is forced).
func _bottom_step() -> int:
	return 0 if _render_mode == RenderMode.AUTO and _base_res_pays() else 1


func _top_step() -> int:
	return mini(_max_step, mini(_ceiling, _session_ceiling) - 1)


func _reset_windows() -> void:
	_win_n = 0
	_win_sum = 0.0
	_win_miss = 0
	_win_hold_miss = 0
	_win_time = 0.0
	_calm = 0.0
	_calm_n = 0
	_calm_miss = 0
	_calm_busy = 0.0
	_calm_frame = 0.0
	_calm_gpu = 0.0
	_calm_script = 0.0


## Applies the level and the render resolution of the current mode and step.
func _apply(notify: bool) -> void:
	var level := _level
	match _mode:
		Mode.AUTO: level = _steps[_step][0]
		Mode.LOW: level = Level.LOW
		Mode.MEDIUM: level = Level.MEDIUM
		Mode.HIGH: level = Level.HIGH
	var level_changed := level != _level
	_level = level as Level
	if level_changed and is_instance_valid(PerfPanel) and PerfPanel.is_inside_tree():
		PerfPanel.clear_overrides()
	if _warm_left <= 0:
		_apply_fields(_level)
	_apply_render()
	_settle = Tuning.quality_settle_time
	_reset_windows()
	if notify:
		_log_line("level", {})
		changed.emit()


func _apply_fields(level: int) -> void:
	for field: StringName in LEVEL_FIELDS:
		Tuning.set(field, LEVEL_FIELDS[field][level])
	if level == _level and is_instance_valid(PerfPanel) and PerfPanel.is_inside_tree():
		PerfPanel.apply_overrides()


func _apply_render() -> void:
	var want := false
	match _render_mode:
		RenderMode.AUTO: want = _mode == Mode.AUTO and _steps[_step][1] and _base_res_pays()
		RenderMode.BASE: want = true
	_base_res = want
	var root := get_tree().root
	var target := Window.CONTENT_SCALE_MODE_VIEWPORT if want else Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	if root.content_scale_mode != target:
		root.content_scale_mode = target


## The base resolution step only exists when the window has clearly more pixels than the base layout.
func _base_res_pays() -> bool:
	var window := Vector2(DisplayServer.window_get_size())
	var base := Vector2(get_tree().root.content_scale_size)
	if base.x <= 0.0 or base.y <= 0.0:
		return false
	# With aspect expand the base keeps its height; the width follows the window.
	var base_pixels := base.y * base.y * window.x / maxf(window.y, 1.0)
	return window.x * window.y >= base_pixels * Tuning.quality_base_res_min_gain


func _slow_frame() -> void:
	if _slow_ms.is_empty() or _level_time < _slow_from or _level_time > _slow_to:
		return
	var level_step: int = _step if _mode == Mode.AUTO else [1, 1, 2, 3][_mode]
	var ms := _slow_ms[clampi(level_step, 0, _slow_ms.size() - 1)]
	if not _slow_share.is_empty():
		# A fixed pattern, so the share of slow frames is exact in each window.
		_slow_acc += _slow_share[clampi(level_step, 0, _slow_share.size() - 1)]
		if _slow_acc < 1.0:
			return
		_slow_acc -= 1.0
	if ms > 0.0:
		OS.delay_usec(int(ms * 1000.0))


func _fixed_rate_run() -> bool:
	var args := OS.get_cmdline_args()
	return args.has("--fixed-fps") or args.has("--write-movie") or Engine.get_write_movie_path() != ""


func _parse_args() -> void:
	var user := OS.get_cmdline_user_args()
	# A scripted run never writes the player's saved quality, unless it names its own file.
	_save_enabled = user.is_empty() or user.has("--user-settings")
	for raw: String in user:
		var eq := raw.find("=")
		var key := raw.substr(0, eq) if eq >= 0 else raw
		var value := raw.substr(eq + 1) if eq >= 0 else ""
		match key:
			"--quality":
				var i := MODE_NAMES.find(value.capitalize())
				if i >= 0:
					_mode = i as Mode
			"--render-scale":
				var i := RENDER_NAMES.find(value.capitalize())
				if i >= 0:
					_render_mode = i as RenderMode
			"--quality-log":
				_log = true
			"--quality-governor":
				_force_governor = true
			"--quality-phone":
				_phone = true
			"--slow-share":
				for share: String in value.split(","):
					_slow_share.append(clampf(share.to_float(), 0.0, 1.0))
			"--quality-fake-busy":
				_fake_busy_ms = maxf(value.to_float(), 0.0)
			"--quality-save":
				_save_path = "user://" + value.get_file()
				_save_enabled = true
			"--slow-frame":
				var parts := value.split("@")
				for ms: String in parts[0].split(","):
					_slow_ms.append(ms.to_float())
				if parts.size() > 1:
					var span := parts[1].split("-")
					_slow_from = span[0].to_float()
					if span.size() > 1:
						_slow_to = span[1].to_float()
	if not user.is_empty() and not user.has("--user-settings") and not _has_prefix(user, "--quality-save="):
		# Scripted runs start from the platform default, not from what this machine saved.
		_save_path = ""


static func _has_prefix(args: PackedStringArray, prefix: String) -> bool:
	for a: String in args:
		if a.begins_with(prefix):
			return true
	return false


## Returns false when there is no saved state (the first start).
func _load() -> bool:
	if _save_path == "":
		return false
	var config := ConfigFile.new()
	if config.load(_save_path) != OK:
		return false
	var adapter := RenderingServer.get_video_adapter_name()
	var mode_from_args := _mode != Mode.AUTO
	var render_from_args := _render_mode != RenderMode.AUTO
	if not mode_from_args:
		_mode = clampi(int(config.get_value(SECTION, "mode", Mode.AUTO)), Mode.AUTO, Mode.HIGH) as Mode
	if not render_from_args:
		_render_mode = clampi(int(config.get_value(SECTION, "render", RenderMode.AUTO)), RenderMode.AUTO, RenderMode.BASE) as RenderMode
	# The learned step and ceiling belong to one GPU; a new GPU learns again.
	if String(config.get_value(SECTION, "adapter", "")) != adapter:
		return false
	_ceiling = int(config.get_value(SECTION, "ceiling", 1000))
	_hold_ref_ms = float(config.get_value(SECTION, "hold_ref_ms", 0.0)) if _phone else 0.0
	_step = clampi(int(config.get_value(SECTION, "step", _step)), 0, _top_step())
	return true


func _save() -> void:
	if not _save_enabled or _save_path == "":
		return
	var config := ConfigFile.new()
	config.set_value(SECTION, "mode", _mode)
	config.set_value(SECTION, "render", _render_mode)
	config.set_value(SECTION, "step", _step)
	config.set_value(SECTION, "ceiling", _ceiling)
	config.set_value(SECTION, "hold_ref_ms", _hold_ref_ms)
	config.set_value(SECTION, "adapter", RenderingServer.get_video_adapter_name())
	var path := _save_path
	# Off the main thread, so a slow disk never stalls a frame.
	WorkerThreadPool.add_task(func() -> void:
		if config.save(path) != OK:
			push_warning.call_deferred("Quality: cannot save %s" % path))


func _log_line(event: String, data: Dictionary) -> void:
	if not _log:
		return
	data["event"] = event
	data["mode"] = MODE_NAMES[_mode]
	data["level"] = LEVEL_NAMES[_level]
	data["step"] = _step
	data["ceiling"] = _ceiling
	data["base_res"] = _base_res
	data["t"] = snappedf(_level_time, 0.01)
	data["frame"] = Engine.get_process_frames()
	print("QUALITY " + JSON.stringify(data))
