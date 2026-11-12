extends Node
## Every gameplay, feel and GPU-cost number. Change values here, not in the scripts.

# Physics layers (bit values)
const LAYER_WORLD := 1
const LAYER_PLAYER := 2
const LAYER_PIECES := 4
const LAYER_HAZARDS := 8
const LAYER_TRIGGERS := 16
const LAYER_PLATFORMS := 32
const LAYER_PROPS := 64
const LAYER_ENEMIES := 128
## Temperature zones and pipe mouths that the player hurtbox polls.
const LAYER_ZONES := 256
## Grates: solid for the solid slime and for props, open for the melted slime and for goo.
const LAYER_GRATES := 512

var juice_enabled := true
var tile_size := 64.0
## Size of the slime and the monsters against the level. Every body, goo and mite size below derives from it.
var character_scale := 2.0
## Speed and reach grow a little with the size, so a larger body does not feel slow.
var character_speed_scale := 1.0 + 0.18 * (character_scale - 1.0)

# Mass
var mass_max := 100.0
var mass_start := 100.0
var mass_death := 20.0
var mass_danger := 35.0
var radius_full := 30.0 * character_scale
var radius_min_visual := 3.0 * character_scale
var collision_radius_ratio := 0.86
## A larger body keeps a smaller hurt share, so spike strips and saws stay as fair to jump as at scale 1.
var hurtbox_ratio := 0.8 - 0.2 * (character_scale - 1.0)
var radius_step_max := 1.5 * character_scale
var checkpoint_refill := true

# Movement
var run_speed := 340.0 * character_speed_scale
var accel_ground := 2600.0 * character_speed_scale
var decel_ground := 3000.0 * character_speed_scale
var accel_air := 1700.0 * character_speed_scale
var decel_air := 700.0
var turn_multiplier := 1.6
## Agility: 0 at mass_max, 1 at mass_death, along agility_share^agility_curve (below 1, half mass already feels lighter).
## Each value below is the gain at agility 1: a light slime is faster, snappier and springier; full mass keeps the base values.
var agility_curve := 0.8
var agility_speed := 0.3
var agility_accel := 0.6
var agility_jump := 0.07
## Gravity while rising: with the jump gain the small jump goes a little higher and rises faster.
var agility_rise := 0.05
## Evade times shrink by this gain (same distance, so faster), and so does the chain cooldown.
var agility_evade := 0.35
var agility_wall := 0.15
var agility_crawl := 0.35
## Body spring stiffness gain; damping grows with its square root, so a light body wobbles faster, smaller and settles quicker.
var agility_body := 1.2
var agility_pitch := 0.22
## Jump height grows less than the body, so the level jumps keep their challenge.
var jump_velocity := 880.0 * (1.0 + 0.1 * (character_scale - 1.0))
var gravity_up := 2200.0
var gravity_down := 3400.0
var gravity_apex := 1100.0
var apex_threshold := 140.0
var jump_cut := 0.45
var max_fall_speed := 1500.0
var coyote_time := 0.10
var jump_buffer := 0.12
var hurt_stun_time := 0.25
var spawn_freeze_time := 0.35
var spawn_invulnerable_time := 1.0
var wall_splat_speed := 260.0
var bonk_speed := 300.0

# Fall damage (ground drop between takeoff and landing)
var fall_safe_height := 320.0
var fall_loss_per_tile := 8.0
var fall_loss_max := 70.0
var heavy_land_height := 160.0
var heavy_land_speed := 1100.0

# Player feedback (sound, spray and face per event)
## Heartbeat period at the danger threshold (x) and at the death threshold (y). The vignette pulse uses the same range.
var player_heartbeat_interval := Vector2(0.9, 0.45)
var player_heartbeat_volume_db := Vector2(-10.0, -2.0)
var player_jump_spray_count := 5
var player_jump_spray_speed := Vector2(120.0, 260.0)
var player_jump_spray_spread := 70.0
var player_jump_spray_radius := Vector2(2.0, 4.0) * character_scale
var player_land_heavy_volume_db := Vector2(-6.0, 0.0)
var player_land_heavy_shake := Vector2(0.1, 0.35)
var player_land_heavy_spray_count := 10
var player_land_heavy_spray_speed := Vector2(150.0, 380.0)
var player_land_heavy_spray_spread := 80.0
var player_land_heavy_spray_radius := Vector2(2.0, 5.0) * character_scale
var player_land_heavy_spray_inherit := 0.2
var player_land_soft_speed := 200.0
var player_land_soft_speed_ref := 900.0
var player_land_soft_volume_db := Vector2(-14.0, -6.0)
var player_step_volume_db := -16.0
var player_step_drip_jitter := 6.0
var player_wall_splat_strength_min := 0.2
var player_wall_splat_volume_db := Vector2(-12.0, -4.0)
var player_wall_splat_spray_count := 4
var player_wall_splat_spray_speed := Vector2(80.0, 200.0)
var player_wall_splat_spray_spread := 50.0
var player_wall_splat_spray_radius := Vector2(2.0, 3.5) * character_scale
var player_bonk_strength_min := 0.2
var player_hurt_strength_ref := 40.0
var player_hurt_strength_min := 0.15
var player_hurt_spray_count := 8
var player_hurt_spray_per_mass := 0.8
var player_hurt_spray_speed := Vector2(200.0, 620.0)
var player_hurt_spray_spread := 75.0
var player_hurt_spray_radius := Vector2(2.0, 6.0) * character_scale
var player_hurt_spray_inherit := 0.3
var player_hurt_splash_pitch := Vector2(1.15, 0.85)
var player_hurt_face_time := 0.45
var player_death_piece_spread := 1.3
var player_death_piece_speed := Vector2(300.0, 800.0)
var player_death_burst_count := 40
var player_death_burst_speed := Vector2(250.0, 900.0)
var player_death_burst_radius := Vector2(2.0, 7.0) * character_scale
var player_gulp_mass_ref := 10.0
var player_gulp_strength_min := 0.2
var player_absorb_face_time := 0.3
var player_absorb_spray_radius := Vector2(1.5, 3.0) * character_scale
var player_refill_pitch := 1.5
var player_refill_face_time := 0.6

# Slug crawl
## Crawl stride in visual radii: one reach plus gather cycle covers this distance, so a small slime crawls with the same shape.
var crawl_stride_ratio := 4.0
var crawl_min_speed := 60.0
## Horizontal speed, as a share of run_speed, at which the crawl shape reaches full strength.
var crawl_full_speed_share := 0.6
# Reach (longer and lower, front goes ahead) then gather (shorter and taller, rear catches up under a travelling hump).
var crawl_stretch := 0.2
var crawl_hump := 0.15
## Angular half-width of the gather hump in radians; a wide raised-cosine bump keeps the top round.
var crawl_hump_width := 1.2
var crawl_smooth := 12.0
## Gather contracts less than reach stretches: the travelling hump already adds the height.
var crawl_gather_share := 0.55

# Moves: run, skid, crouch, wall, double jump, dodge and roll
## Run (RB / R1, Shift, touch stick at the rim): top speed, and the share of the walk acceleration above the walk speed.
var sprint_speed := 580.0 * character_speed_scale
var sprint_accel_share := 0.58
## Crawl stride in visual radii while running (shorter steps at a higher speed give the faster rhythm) and while crouched.
var sprint_stride_ratio := 3.3
var crouch_stride_ratio := 2.4
## Run feedback: extra trail drips and a kick-up spray at each step.
var sprint_step_drips := 2
var sprint_step_spray_count := 3
var sprint_step_spray_speed := Vector2(90.0, 220.0)
var sprint_step_spray_spread := 30.0
var sprint_step_spray_radius := Vector2(1.5, 2.8) * character_scale
var sprint_step_volume_db := -11.0
## Skid: a fast reversal while running above skid_min_speed slides to a stop, flips and launches the other way.
var skid_min_speed := 410.0 * character_speed_scale
var skid_slide_time := 0.3
## Slide speed is entry speed * (1 - t)^curve.
var skid_slide_curve := 1.4
var skid_hold_time := 0.14
var skid_launch_time := 0.14
var skid_spray_interval := 0.035
var skid_spray_count := 3
var skid_spray_speed := Vector2(160.0, 380.0)
var skid_spray_spread := 30.0
var skid_spray_radius := Vector2(1.5, 3.2) * character_scale
var skid_stop_spray_count := 10
var skid_stop_spray_speed := Vector2(120.0, 320.0)
var skid_stop_shake := 0.14
var skid_stop_squash := 0.45
var skid_volume_db := -2.0
## Crouch: the stick within crouch_cone_deg of down and pushed crouch_enter crouches; crouch_keep holds it.
var crouch_enter := 0.35
var crouch_keep := 0.15
var crouch_cone_deg := 65.0
var crouch_release_grace := 0.22
## Crouched collider: a lying capsule, height and width as shares of the standing diameter, anchored at the feet.
var crouch_height_ratio := 0.5
var crouch_width_ratio := 1.25
var crawl_speed := 120.0 * character_speed_scale
var crawl_accel := 1500.0
## Walking into a gap that only the crouched collider fits crouches by itself.
var crouch_auto_probe := 12.0 * character_scale
var crouch_auto_min_speed := 40.0
## Crouch + jump on a one-way plank drops through it.
var drop_through_time := 0.3
var drop_through_speed := 120.0
## Wall: push into a wall in the air to stick, hold for wall_cling_time, then slide with friction.
var wall_cling_time := 0.4
var wall_upward_damp := 5200.0
var wall_slide_speed := 150.0
var wall_slide_gravity_scale := 0.35
## Stick down past wall_fast_down slides fast with full gravity.
var wall_slide_fast_speed := 520.0
var wall_fast_down := 0.5
var wall_release_delay := 0.12
var wall_release_push := 120.0
var wall_coyote_time := 0.08
var wall_probe := 6.0
## Body height of the wall probes, in collision radii above the centre (head) and at the centre (mid body).
var wall_probe_head := 0.7
var wall_contact_push := 40.0
## Stick away from the wall: wall jump. Stick toward the wall or neutral: wall kick, a climb up the same wall.
var wall_jump_velocity := Vector2(360.0 * character_speed_scale, 830.0)
var wall_jump_lock := 0.14
var wall_kick_velocity := Vector2(170.0 * character_speed_scale, 760.0)
var wall_kick_lock := 0.05
## Air acceleration after a wall jump or kick, until the next landing or grab: it brings the slime back to the wall.
var wall_flight_accel := 5000.0 * character_speed_scale
## Slide distance between two drops of the wet streak, and the period of the slide sound and of the goo drips.
var wall_streak_step := 9.0 * character_scale
var wall_streak_radius := Vector2(2.5, 4.0) * character_scale
var wall_streak_life := 2.2
var wall_slide_sound_interval := 0.16
var wall_slide_volume_db := Vector2(-18.0, -6.0)
var wall_drip_interval := 0.3
var wall_grab_spray_count := 5
var wall_grab_spray_speed := Vector2(60.0, 180.0)
var wall_grab_spray_spread := 60.0
var wall_grab_spray_radius := Vector2(1.5, 3.0) * character_scale
var wall_grab_volume_db := -5.0
## Double jump: one jump in the air, refilled on the floor and on a wall grab.
var air_jumps := 1
var double_jump_velocity := jump_velocity * 0.95
## The second jump always adds at least this much rise on top of the current one.
var double_jump_min_add := 90.0
## With a direction held the slime keeps at least this speed that way; with none it keeps this share of its speed.
var double_jump_boost := 440.0 * character_speed_scale
var double_jump_neutral_keep := 0.4
## Air deceleration is off for this long after a double jump, so the boost carries.
var double_jump_carry_time := 0.35
var double_jump_puff_count := 14
var double_jump_puff_speed := Vector2(140.0, 360.0)
var double_jump_puff_spread := 75.0
var double_jump_puff_radius := Vector2(2.0, 4.5) * character_scale
var double_jump_ring_radius := 34.0 * character_scale
var double_jump_ring_time := 0.28
var double_jump_ring_color := Color(0.62, 1.0, 0.45, 0.85)
var double_jump_punch := 0.015
var double_jump_face_time := 0.4
## Dodge and roll (B / Circle, K / C): on the floor only, never under a low ceiling.
## A new evade can start evade_chain_after seconds after the last start; it gets i-frames only evade_iframe_rearm after the last ones.
var evade_chain_after := 0.15
var evade_iframe_rearm := 0.45
## Dodge with no direction: a fast squash and slide backward.
var dodge_distance := 45.0 * character_scale
var dodge_motion_time := 0.12
var dodge_time := 0.26
var dodge_iframes := 0.13
var dodge_spray_count := 6
var dodge_spray_speed := Vector2(120.0, 300.0)
var dodge_spray_spread := 40.0
var dodge_spray_radius := Vector2(1.5, 3.0) * character_scale
var dodge_volume_db := -3.0
## Roll with a direction: one full turn of a gelatin ball over roll_distance; a jump can cancel its last share.
var roll_distance := 130.0 * character_scale
var roll_time := 0.44
var roll_iframes := 0.345
var roll_jump_cancel := 0.6
var roll_trail_step := 14.0 * character_scale
var roll_exit_squash := 520.0
var roll_volume_db := -2.0
## A roll cut short spins on to the next whole turn at this speed (rad/s).
var roll_unwind_speed := 14.0
## Run cost: goo drips off while running, as real pieces on the ground. A 5 second run costs about 12 mass.
var run_cost_per_second := 2.4
## The cost leaves in pulses: one drop, one body twitch and one light vibration per beat.
var run_pulse_interval := 0.28
## Drop mass that gives a full-strength pulse.
var run_pulse_mass_ref := 0.8
var run_piece_speed := Vector2(70.0, 90.0)
## The run never drains the slime below this mass: it stops, tired, until the run button is pressed again.
var run_min_mass := 40.0
var run_tired_face_time := 0.9
## Something that falls into the slime: the splash strength comes from the entry speed against these speeds.
var absorb_splash_speed := Vector2(80.0, 900.0)
var absorb_splash_min := 0.15
var absorb_splash_spray_count := Vector2i(3, 14)
var absorb_splash_spray_speed := Vector2(120.0, 420.0)
var absorb_splash_spray_spread := 55.0
var absorb_splash_spray_radius := Vector2(1.5, 3.5) * character_scale
## A strong entry (strength above absorb_splash_strong) adds a hitstop, a camera kick and a surprised face.
var absorb_splash_strong := 0.55
var absorb_splash_hitstop := 0.04
var absorb_splash_punch := 0.03
var absorb_splash_face_time := 0.35
# Move poses of the soft body (shares are of the visual radius unless noted)
var body_pose_smooth := 14.0
## Run: crawl stretch, hump and lean multipliers at full run, and the lean limit while running.
var body_run_stretch := 1.6
var body_run_hump := 1.35
var body_run_lean := 1.8
var body_run_lean_max := 0.45
## Skid: the top keeps going (lean toward the old travel), the body stretches low and the front of the foot smears ahead.
var body_skid_lean := 0.55
var body_skid_stretch := 0.14
var body_skid_flare := 1.4
var body_skid_foot_shift := 0.18
## Crouch: a low, wide puddle. The pose rides a spring, so it settles with a jelly overshoot.
var body_crouch_sx := 1.3
var body_crouch_sy := 0.5
var body_crouch_stiffness := 360.0
var body_crouch_damping := 17.0
## Wall: points past the wall plane flatten onto it, and the wall side spreads along the wall.
var body_wall_flare := 0.45
var body_wall_flare_width := 0.7
## Roll: a tight ball, with little foot sag and flare.
var body_ball_sag := 0.25
var body_ball_flare := 0.2
## Double jump: a squeeze, then a pop after a short delay.
var body_double_squeeze := 5.0
var body_double_pop_delay := 0.05
var body_double_pop := 11.0
var body_double_pop_swell := 140.0
var body_double_pop_ripple := 0.35
## Dodge: a flat squash, the front bulges and the top trails behind.
var body_dodge_squash := 6.0
var body_dodge_ripple := 0.4
var body_dodge_lean := 3.0
## Something falls in: the entry side dents in (narrow, so the ripple travels around the ring), the body squashes and swells.
var body_splash_dent := 0.55
var body_splash_width := 0.25
var body_splash_squash := 5.0
var body_splash_swell := 60.0
## Run cost beat: the side that loses the drop pinches in and the body twitches.
var body_drain_pinch := 0.2
var body_drain_twitch := 1.6
## Ceiling hit: dent share at full strength, its depth and side bulge (visual radii), and an underdamped spring back.
var body_ceiling_kick := 1.0
var body_ceiling_depth := 0.32
var body_ceiling_bulge := 0.22
var body_ceiling_ripple := 0.25
var body_ceiling_stiffness := 240.0
var body_ceiling_damping := 8.0
## Push against a wall on the floor: narrower and taller at full push, with a slow breath, and the face shifts away.
var body_press_narrow := 0.24
var body_press_tall := 0.18
var body_press_stiffness := 160.0
var body_press_damping := 11.0
var body_press_breath := 0.07
var body_press_breath_hz := 1.1
var body_press_face_shift := 0.14
## Press spring speed per unit strength of a splat, so a fast hit flattens the wall side before the push squash.
var body_splat_press_kick := 9.0
## Seconds of push for the full wall press.
var press_build_time := 1.0
## Ceiling and wall hit feedback: a light touch above ceiling_touch_speed flattens the head with no sound.
var ceiling_touch_speed := 60.0
var ceiling_hit_speed_ref := 900.0
var ceiling_drip_count := 4
var ceiling_drip_life := 1.4
var ceiling_punch := 0.035
var ceiling_shake := 0.12
var ceiling_face_time := 0.35
var wall_splat_drip_count := 4
var wall_splat_punch := 0.03
var wall_splat_shake := 0.1
# Touch controls for the moves (same units as the touch controls section)
var touch_dodge_offset := Vector2(330.0, 285.0)
var touch_dodge_radius := 50.0
var touch_accent_dodge := Color(0.98, 0.6, 0.95)
## Knob length, as a share of the stick radius, that starts the run and the one that stops it.
var touch_run_at := 0.93
var touch_run_release := 0.82
## Stick colours: the rim brightens toward touch_run_at, turns hot lime while running, and goes dim when the run is blocked.
var touch_run_color := Color(0.85, 1.0, 0.25)
var touch_run_tired_color := Color(0.5, 0.55, 0.5)
var touch_run_hint_from := 0.5
var touch_run_pop_time := 0.3

# Hazards
var spike_loss := 18.0
var spike_hitbox_inset := 8.0
var spike_hitbox_height := 26.0
var saw_loss := 24.0
var saw_radius := 44.0
var saw_hit_radius := 36.0
var saw_speed := 170.0
var saw_end_pause := 0.35
var saw_spin_speed := 14.0
var knockback_speed := Vector2(420.0, 620.0)
var invulnerable_time := 0.9
## Horizontal share of the direction the pieces fly when a hazard hits (the vertical share is -1).
var hazard_piece_dir_x := 0.45

# Spikes
var spike_twang_pixels := 11.0
var spike_twang_spread := 70.0
var spike_twang_freq := 38.0
var spike_twang_decay := 6.5
var spike_twang_time := 0.7
var spike_stain_count_base := 2.0
var spike_stain_per_loss := 0.12
var spike_stain_count_range := Vector2i(2, 5)
var spike_stain_life := 6.0
var spike_stain_fade := 1.5
var spike_stain_slide_speed := 4.0
var spike_bone_lit := Color(0.95, 0.90, 0.80)
var spike_bone_shade := Color(0.72, 0.64, 0.60)
var spike_bone_highlight := Color(1.0, 0.98, 0.92)
var spike_tip_lit := Color(0.90, 0.20, 0.22)
var spike_tip_shade := Color(0.62, 0.10, 0.16)
var spike_base_color := Color(0.18, 0.11, 0.15)
var spike_base_top := Color(0.34, 0.22, 0.26)

# Saw
var saw_bite_decay := 3.5
var saw_bite_spin_boost := 26.0
var saw_bite_scale := 0.16
var saw_bite_jitter := 3.0
var saw_bite_pitch := 0.3
var saw_shred_bite := 0.45
var saw_shred_coat := 0.5
var saw_goo_coat_decay := 0.7
var saw_hit_pitch := 0.75
var saw_hit_volume_db := -4.0
var saw_ghost_angle := 0.2
var saw_ghost_alpha := 0.3
var saw_steel_light := Color(0.86, 0.89, 0.93)
var saw_steel_mid := Color(0.62, 0.66, 0.73)
var saw_steel_dark := Color(0.33, 0.35, 0.42)
var saw_ring_orange := Color(0.98, 0.55, 0.12)
var saw_ring_dark := Color(0.16, 0.10, 0.12)
var saw_hub_color := Color(0.12, 0.10, 0.13)
var saw_track_color := Color(0.07, 0.05, 0.08, 0.85)
var saw_track_edge := Color(0.32, 0.24, 0.28)

# Checkpoint
var checkpoint_idle_fill := 0.16
var checkpoint_fill_time := 0.6
var checkpoint_shock_time := 0.5
var checkpoint_shock_radius := Vector2(22.0, 150.0)
var checkpoint_near_distance := 240.0
var checkpoint_near_wobble := 0.07
var checkpoint_near_wobble_speed := 22.0
var checkpoint_halo_scale := 1.6
var checkpoint_halo_start := 0.2
var checkpoint_halo_pop_time := 0.45
var checkpoint_halo_idle_alpha := 0.35
var checkpoint_halo_fade_time := 0.4
var checkpoint_activate_squash := Vector2(1.25, 0.8)
var checkpoint_activate_settle_time := 0.55
var checkpoint_respawn_halo := 1.4
var checkpoint_respawn_halo_time := 0.4
var checkpoint_respawn_squash := Vector2(0.85, 1.2)
var checkpoint_respawn_settle_time := 0.5
var checkpoint_shake := 0.15
var checkpoint_punch := 0.03
var checkpoint_flash_color := Color(0.7, 1.0, 0.9, 0.16)
var checkpoint_flash_time := 0.18
var checkpoint_stream_count := 22
var checkpoint_stream_speed := Vector2(260.0, 540.0)
var checkpoint_stream_spread := 14.0
var checkpoint_stream_radius := Vector2(2.5, 5.0)
var checkpoint_stone := Color(0.36, 0.30, 0.38)
var checkpoint_stone_light := Color(0.52, 0.45, 0.52)
var checkpoint_metal := Color(0.70, 0.66, 0.62)
var checkpoint_glass := Color(0.78, 0.92, 1.0, 0.16)
var checkpoint_glass_edge := Color(0.86, 0.95, 1.0, 0.85)
var checkpoint_empty_goo := Color(0.42, 0.42, 0.48)
var checkpoint_shock_color := Color(0.6, 1.0, 0.85)

# Goal
var goal_near_distance := 420.0
var goal_ripple_count := 3
var goal_ripple_time := 1.1
var goal_surge_decay := 1.4
var goal_surge_lift := 14.0
var goal_flag_wave_speed := 5.0
var goal_flag_surge_speed := 9.0
var goal_sparkle_boost := 2.5
var goal_sparkle_settle_time := 2.0
var goal_confetti_count := 44
var goal_confetti_speed := Vector2(320.0, 760.0)
var goal_confetti_radius := Vector2(3.0, 6.5)
var goal_gold := Color(1.0, 0.84, 0.32)
var goal_gold_deep := Color(0.86, 0.52, 0.14)
var goal_gold_light := Color(1.0, 0.97, 0.75)
var goal_basin := Color(0.30, 0.22, 0.28)
var goal_basin_light := Color(0.55, 0.44, 0.48)
var goal_pole := Color(0.82, 0.78, 0.72)
var goal_flag_color := Color(1.0, 0.66, 0.2)
var goal_flag_shade := Color(0.88, 0.42, 0.14)

# Pieces
var piece_max_per_event := 9
var piece_big_threshold := 8.0
var piece_big_ratio := 0.4
var piece_medium_mass := Vector2(4.0, 8.0)
var piece_small_mass := Vector2(1.2, 2.6)
var piece_min_mass := 1.0
var piece_eject_speed := Vector2(320.0, 760.0)
var piece_eject_spread_deg := 70.0
var piece_inherit_velocity := 0.35
## Eject speed multiplier for the smallest (x) and the largest (y) piece; piece_eject_size_ref is the mass of the largest.
var piece_eject_size_speed := Vector2(1.1, 0.75)
var piece_eject_size_ref := 12.0
var piece_gravity := 2000.0
var piece_air_drag := 0.6
var piece_collision_ratio := 0.8
var piece_cling_time := Vector2(0.35, 1.1)
var piece_drip_speed := 55.0
## Age before the slime can pull a piece back: on a surface, and still in the air.
var piece_absorb_delay := 0.35
var piece_absorb_delay_flying := 0.7
var piece_absorb_margin := 8.0 * character_scale
# Goo magnet: goo near the slime stretches toward the body, lifts, flies in on a short arc and splashes into it.
## Reach of the pull outside the body edge (to the near edge of the goo).
var goo_pull_reach := 26.0 * character_scale
## Pull phases of a piece: the stretch on the spot, then a flight of distance / goo_pull_speed within goo_pull_flight_time.
var goo_pull_stretch_time := 0.07
var goo_pull_speed := 900.0 * character_scale
var goo_pull_flight_time := Vector2(0.1, 0.26)
## The flight follows u^goo_pull_accel_power: slow off the ground, faster and faster near the body, as iron to a magnet.
var goo_pull_accel_power := 2.4
## Sense: goo up to goo_sense_reach beyond the pull reach leans (goo_sense_lean radii) and trembles toward the slime.
var goo_sense_reach := 34.0 * character_scale
var goo_sense_rate := 6.0
var goo_sense_lean := 0.5
var goo_sense_tremble := 0.09
var goo_sense_tremble_hz := 9.0
var goo_sense_redraw_hz := 30.0
## Thin string of goo between a flying piece and the body: bead radius, spacing in bead radii, most beads.
var goo_string_radius := 2.4 * character_scale
var goo_string_spacing := 1.1
var goo_string_beads := 10
## Pieces enter the body one by one: the gap between two entries shrinks from x to y along a chain, so the player
## feels a train of separate pulses that speeds up. A chain ends goo_entry_chain_break seconds after its last entry.
var goo_entry_gap := Vector2(0.12, 0.07)
var goo_entry_chain_max := 6
var goo_entry_chain_break := 0.5
## Brighter wave that runs through the body from the entry point: seconds, and strength at a full share.
var goo_gulp_wave_time := 0.42
var goo_gulp_wave_strength := Vector2(0.25, 0.7)
## Arc height of the flight as a share of its length, plus a fixed lift; the stretch lifts the goo by goo_pull_lift radii.
var goo_pull_arc := 0.3
var goo_pull_arc_min := 6.0 * character_scale
var goo_pull_lift := 0.35
var goo_pull_head_stretch := 0.9
## Flight end inside the body, as a share of its visual radius from the centre.
var goo_pull_entry_depth := 0.55
## A blocked piece retests its path after this many ticks; the droplet path test uses goo_pull_rays rays from the centre.
var goo_pull_block_retest := 6
var goo_pull_rays := 16
var goo_pull_ray_tolerance := 6.0 * character_scale
## Ticks a still slime reuses its droplet ray fan.
var goo_pull_ray_reuse := 30
## Droplets with no mass: age before a pull, and their faster pull phases.
var droplet_pull_delay := 0.9
## Trail drops (wet steps, roll and wall streaks) wait longer, so the slime does not drink the trail it is leaving.
var droplet_trail_pull_delay := 2.0
## Ticks between two droplet pull scans (droplets are visual, so a pull that starts a few ticks late does not show).
var droplet_pull_interval := 3
var droplet_pull_stretch_time := 0.04
var droplet_pull_flight_time := Vector2(0.06, 0.16)
## Feedback of a swallow scales with mass / goo_feedback_mass_ref: a tick for a run drop, a strong gulp for a large piece.
var goo_feedback_mass_ref := 8.0
var goo_feedback_dent := Vector2(0.18, 0.75)
var goo_feedback_spray := Vector2i(2, 9)
var goo_feedback_spray_speed := Vector2(70.0, 240.0)
var goo_feedback_volume_db := Vector2(-7.0, 1.0)
## Above this share a swallow adds a pad or phone thump, a camera punch and a low gulp sound.
var goo_feedback_strong := 0.55
var goo_feedback_punch := 0.025
var goo_feedback_gulp_pitch := 0.75
var goo_feedback_gulp_volume_db := -6.0
## Grow pulse: a jelly overshoot of the body radius after a swallow with mass.
var body_grow_kick := 3.2
var body_grow_min := 0.18
var body_grow_stiffness := 320.0
var body_grow_damping := 12.0
## A body at rest only breathes: its outline is rebuilt at this rate instead of in every frame.
var body_rest_redraw_hz := 20.0
## Face redraw: anchor and size steps in pixels, and the clock of the faces that move on their own.
var face_redraw_step := 0.5
var face_anim_hz := 30.0
## Droplets swallowed in one tick: a sip dent and a drip tick, at most once per droplet_sip_interval.
var droplet_sip_dent := 0.1
var droplet_sip_interval := 0.07
var droplet_sip_pitch := Vector2(1.5, 2.1)
var droplet_sip_volume_db := -16.0
## A full slime does not pull goo of its own colour with mass: the goo shivers toward it and a soft bonk plays.
var goo_full_shiver := 5.0
var goo_full_pitch := 1.75
var goo_full_volume_db := -14.0
var goo_full_sound_interval := 0.35
## Seconds before a piece with mass starts to sink into the soil; 0 or less keeps pieces forever.
var piece_lifetime := 16.0
## Seconds a piece takes to sink: its mass drains to zero over this time and it can still be slurped.
var piece_soak_time := 5.0
## Thickness of a resting piece at the end of the sink (piece_rest_flat at the start).
var piece_soak_flat := 0.38
## Field strength at the end of the sink; close to goo_threshold / goo_intensity the goo reads thin and dark.
var piece_soak_strength := 0.56
## How far the piece centre sinks toward the surface, in piece radii, at the end of the sink.
var piece_soak_sink := 0.4
## Wobble kick when the sink starts, so the change reads at once.
var piece_soak_kick := 3.0
## Live pieces above this count make the oldest piece start to sink.
var piece_soak_cap := 48
var piece_cap := 64
var piece_splat_wobble := 6.0
var piece_splat_speed_ref := 700.0
var piece_splat_wobble_range := Vector2(0.5, 1.6)
var piece_rest_wobble_share := 0.6
var piece_wobble_stiffness := 300.0
var piece_wobble_damping := 12.0
var piece_wobble_squash := 0.2
var piece_fly_stretch := 0.0007
var piece_fly_stretch_max := 0.6
var piece_absorb_stretch := 0.6
var piece_rest_flat := 0.75
var piece_slide_sag := 0.55
var piece_slide_sag_rate := 2.0
var piece_trail_step := 4.0
var piece_trail_radius_ratio := 0.5
var piece_trail_min_radius := 2.5 * character_scale
var piece_trail_radius_jitter := Vector2(0.8, 1.15)
var piece_splat_spray_mass := 2.0
var piece_splat_spray_count := 3
var piece_splat_spray_speed := Vector2(80.0, 220.0)
var piece_splat_spray_spread := 60.0
var piece_splat_spray_radius := Vector2(1.5, 3.0) * character_scale
var piece_drip_size_ref := 10.0
var piece_drip_pitch := Vector2(1.4, 0.8)
var piece_drip_volume_db := Vector2(-14.0, -6.0)
var piece_shred_burst_count := 10
var piece_shred_burst_speed := Vector2(200.0, 520.0)
var piece_shred_burst_radius := Vector2(2.5, 5.0) * character_scale

# Props: rocks and crystals the slime swallows, carries and spits
var prop_rock_radius := 14.0 + 3.0 * (character_scale - 1.0)
var prop_crystal_radius := 12.0 + 3.0 * (character_scale - 1.0)
## Restitution of a spent or dropped prop; a hot shot uses shot_restitution.
var prop_rock_restitution := 0.32
var prop_crystal_restitution := 0.36
## Share of the tangential speed a bounce keeps.
var prop_friction := 0.75
var prop_gravity := 1900.0
var prop_air_drag := 0.2
var prop_rest_speed := 90.0
var prop_bounce_min_speed := 160.0
var prop_roll_decel := 1100.0
## A dropped or spent prop cannot be swallowed for this long.
var prop_absorb_delay := 0.45
var prop_reject_cooldown := 0.6
var prop_reject_speed := Vector2(170.0, 240.0)
var prop_idle_glint_interval := Vector2(1.4, 3.0)
var prop_home_return_time := 0.35
## A prop at rest this long, this far from its home and off screen goes home, so ammunition is never out of reach.
var prop_home_wait := 8.0
var prop_home_min_distance := 256.0
var prop_home_screen_margin := 96.0

# Prop shatter: a hot shot that hits a trap that deflects props breaks into smaller props
## Radius share of each size level: full prop, chunk, chip. The last level never breaks.
var prop_size_scale := PackedFloat32Array([1.0, 0.68, 0.46])
## Pieces of one break, by the size level of the prop that breaks.
var prop_shatter_pieces := PackedInt32Array([3, 2])
## Loose props at which a break first removes old pieces. Every prop draws in one batch; the cost is physics, about
## 5 us per prop on desktop, so 48 stays near 2 ms on a phone. It leaves room for a full load of 20 dropped at once.
## Only break pieces that the slime never touched can go; dropped props and full props always stay.
var prop_loose_max := 48
var prop_shatter_speed := Vector2(420.0, 700.0)
## Share of the trap's deflected velocity that every piece keeps.
var prop_shatter_keep := 0.12
var prop_shatter_max_speed := 1100.0
var prop_shatter_spread_deg := 55.0
var prop_shatter_jitter_deg := 9.0
## Upward pull of the escape direction, so the pieces arc up and land around the trap.
var prop_shatter_lift := 0.6
## Lean of the escape direction toward the side the shot came from.
var prop_shatter_back_bias := 0.7
var prop_shatter_spin := 22.0
## A fresh piece passes through the trap it broke on for this long.
var prop_shatter_trap_grace := 0.22
## A hot shot that a trap cannot break (the smallest size) hops back toward the thrower at this (x, up) speed, spent.
var prop_trap_rebound := Vector2(260.0, 520.0)
## The light "tink" of that hop: a high clink and a few white sparks, so it never reads as a break.
var prop_trap_tink_pitch := 1.9
var prop_trap_tink_volume_db := -7.0
var prop_trap_tink_sparks := 4
## A prop that touches traps this many times without coming to rest moves to the nearest safe floor.
var prop_trap_contact_max := 4
## A tumble that lasts longer than this (seconds) without coming to rest moves the prop to the nearest safe floor.
var prop_tumble_max_time := 6.0
## A safe floor point keeps this clearance from every trap; the search walks sideways in steps up to the step count.
var prop_safe_margin := 24.0
var prop_safe_search_step := 32.0
var prop_safe_search_steps := 64
var saw_deflect_bite := 0.2
var prop_shatter_hitstop := Vector2(0.05, 0.09)
var prop_shatter_shake := Vector2(0.22, 0.42)
var prop_shatter_punch := 0.045
var prop_shatter_flash_color := Color(1.0, 0.95, 0.85, 0.12)
var prop_shatter_flash_time := 0.07
## Sound pitch by the size level of the prop that breaks: smaller props crack higher.
var prop_shatter_pitch := PackedFloat32Array([0.95, 1.3, 1.6])
var prop_shatter_volume_db := Vector2(-5.0, 0.0)
var prop_shatter_shard_count := Vector2(7.0, 14.0)
var prop_shatter_shard_speed := Vector2(260.0, 720.0)
var prop_shatter_shard_size := Vector2(3.0, 6.5) * character_scale
var prop_shatter_spark_count := Vector2(10.0, 22.0)
var prop_shatter_spark_speed := Vector2(260.0, 820.0)
var prop_shatter_spark_size := Vector2(2.0, 4.0)
var prop_shatter_shard_spread_deg := 80.0
var prop_shatter_spark_spread_deg := 80.0
## Share of the shards, ring and glint that the last breakable size gets; a full prop gets all of it.
var prop_shatter_small_scale := 0.6
var prop_shatter_ring_radius := 46.0 * character_scale
var prop_shatter_ring_time := 0.28
var prop_shatter_glint_size := 13.0 * character_scale
## Over-bright modulate of a trap the moment a prop breaks on it, fading to normal.
var prop_shatter_trap_flash := Color(2.4, 2.2, 1.9)
var prop_shatter_trap_flash_time := 0.16
var saw_shatter_spark_count := Vector2(14.0, 26.0)
var saw_shatter_spark_speed := Vector2(320.0, 900.0)
var saw_shatter_spark_spread := 35.0
var saw_shatter_spark_size := Vector2(1.5, 3.5)
var saw_shatter_spark_color := Color(1.0, 0.72, 0.3)
var spike_shatter_twang_gain := 2.2
var aim_preview_shatter_color := Color(1.0, 0.55, 0.32)
var aim_preview_shatter_rays := 8
var aim_preview_shatter_radius := 26.0
## An aim held still predicts again after this many ticks, so the marker follows a moving trap.
var aim_preview_refresh_ticks := 6
var aim_preview_shatter_pip_radius := 3.6
var aim_preview_shatter_pip_gap := 13.0
var prop_rock_light := Color(0.66, 0.62, 0.66)
var prop_rock_mid := Color(0.46, 0.42, 0.48)
var prop_rock_dark := Color(0.27, 0.24, 0.30)
var prop_crystal_light := Color(0.78, 0.98, 1.0)
var prop_crystal_mid := Color(0.36, 0.78, 0.96)
var prop_crystal_dark := Color(0.16, 0.38, 0.72)
var prop_outline_color := Color(0.10, 0.07, 0.12)

# Carry (props floating inside the slime, positions in body radii around the body centre)
## Capacity grows with the mass: carry_capacity_min props at carry_capacity_min_mass, up to carry_capacity_max at mass_max.
var carry_capacity_min_mass := 22.0
var carry_capacity_min := 1
var carry_capacity_max := 20
var carry_capacity_curve := 1.0
## A hit that shrinks the slime below its load drops at most this many props at once; the rest follow one by one.
var carry_drop_max_per_hit := 5
var carry_drop_interval := 0.08
## Above four props the slots fill this ellipse (half sizes, body radii) around the zone centre, below the face.
var carry_zone_half := Vector2(0.5, 0.36)
## Props shrink as the load grows: scale is carry_item_scale_crowded * sqrt(carry_crowd_ref / load) past the ref.
var carry_crowd_ref := 3.0
var carry_item_scale_min := 0.42
## The prop the next shot takes is drawn this much larger.
var carry_next_scale := 1.3
## Sink of a swallowed prop from its entry point to its slot: time, spring share, extra drag and bubble period.
var carry_sink_time := 0.6
var carry_sink_spring := 0.45
var carry_sink_drag := 2.2
var carry_sink_bubble_interval := 0.07
## Inward speed of the entry, in body radii per second, for a slow and for a fast prop.
var carry_sink_speed := Vector2(0.6, 3.2)
var carry_zone_center := Vector2(0.0, 0.35)
## Slow wander of each prop around its slot, in body radii, at its own frequencies (Hz, min and max).
var carry_drift := 0.07
var carry_drift_hz := Vector2(0.08, 0.22)
## Soft wall: a prop past this distance from the body centre is pushed back in.
var carry_wall := 0.62
var carry_wall_stiffness := 120.0
## A load that moved less than this since its last shader write (body radii; radians for the turn) counts as still and
## writes no new data.
var carry_still_move := 0.0005
var carry_still_turn := 0.0005
## Boot check of the cargo shader mirror of SlimeBody._deform (cargo.gd check_deform): sample states in the
## SlimeBody.DeformState layout (radius, r, sx, sy, ex, ey, crawl dx, press, press side, feet, ceiling, lean, frost,
## aim pull, aim x, aim y, roll, pivot x, pivot y), sample points in body radii, and the largest gap in pixels.
var carry_deform_check_states: Array[PackedFloat32Array] = [
	PackedFloat32Array([60, 60, 1, 1, 1, 1, 0, 0, 1, 52, 0, 0, 0, 0, 1, 0, 0, 0, 0]),
	PackedFloat32Array([60, 63, 1.2, 0.83, 1.1, 0.909, 4, 0, 1, 52, 0, 0.15, 0, 0, 1, 0, 0.3, 0, 5]),
	PackedFloat32Array([60, 60, 1, 1, 1, 1, 0, 0.5, -1, 52, 0.4, -0.1, 0.2, 0, 1, 0, 0, 0, 0]),
	PackedFloat32Array([40, 41, 0.9, 1.1, 1, 1, -2, 0, 1, 35, 0, 0.05, 0, 0.8, 0.6, -0.8, -0.7, 1, 2]),
]
var carry_deform_check_points := PackedVector2Array([Vector2(0, 0), Vector2(0.5, 0.5), Vector2(-0.7, 0.2), Vector2(0.3, -0.9), Vector2(0.9, 0.1), Vector2(-0.2, -0.6), Vector2(0, 1)])
var carry_deform_check_limit := 0.01
## A soft spring and strong damping: the props move like solid things in thick gelatin.
var carry_spring := 12.0
var carry_damping := 4.0
## Unit-disk acceleration per px/s^2 of body acceleration: the props lag when the slime speeds up, lands or turns.
var carry_inertia := 0.00045
var carry_inertia_max := 14.0
var carry_separation := 0.5
var carry_separation_stiffness := 60.0
## Own slow turn of each prop (rad/s, min and max; the direction is random), plus roll from a sideways swing.
var carry_turn_speed := Vector2(0.15, 0.55)
var carry_spin_from_swing := 1.5
var carry_spin_drag := 1.2
var carry_item_scale := 0.95
var carry_item_scale_crowded := 0.82
## Jelly surface reflection drawn over each carried prop.
var carry_gloss_alpha := 0.35
## Carried props in each temperature: burning heats them red and speeds up their bubbles; frozen locks them; a puddle
## lays them on its bottom (slot y in body radii, x spread).
var carry_ember_glow := 0.6
var carry_ember_tint := 0.9
var carry_ember_bubble_boost := 4.0
var carry_ember_rise_boost := 1.5
var carry_frost_tint := 0.45
var carry_melt_floor := 0.45
var carry_melt_spread := 1.3
## Carried props under the gelatin: lighten share, a thin light edge (alpha, width in prop radii), and the next prop to
## shoot: brighter, a stronger edge and a soft pulse (scale amount and rate).
var carry_lighten := 0.22
var carry_edge_color := Color(0.92, 1.0, 0.75)
var carry_edge_alpha := 0.45
var carry_edge_width := 0.14
var carry_next_lighten := 0.5
var carry_next_edge_alpha := 0.95
var carry_next_pulse := 0.08
var carry_next_pulse_hz := 2.2
var carry_alpha := 1.0
# Bubbles: positions in body radii; sizes in pixels on a full body.
var carry_bubble_max := 28
var carry_bubble_interval := Vector2(1.2, 3.4)
var carry_bubble_per_release := Vector2i(1, 3)
var carry_bubble_on_swallow := 3
var carry_bubble_life := Vector2(1.2, 2.2)
var carry_bubble_size := Vector2(1.6, 3.2) * character_scale
var carry_bubble_rise := 0.2
var carry_bubble_wobble := 0.06
var carry_bubble_wobble_hz := 1.3
## Bubbles pop before they reach the face (above this height) or the outline (past this distance).
var carry_bubble_ceiling := -0.08
var carry_bubble_limit := 0.78
var carry_bubble_alpha := 0.85
var carry_bubble_inertia_share := 0.6
## A velocity change above this speed shakes bubbles loose; jolt_ref gives the most, jolt_max bubbles.
var carry_bubble_jolt_speed := 300.0
var carry_bubble_jolt_ref := 1100.0
var carry_bubble_jolt_max := 9
var carry_drop_speed := Vector2(260.0, 460.0)
var carry_drop_spread_deg := 55.0
var carry_scatter_speed := Vector2(320.0, 680.0)
var carry_swallow_volume_db := -2.0
var carry_swallow_pitch_step := 0.06
var carry_swallow_punch := 0.015
var carry_gulp_strength := 0.7
var carry_full_volume_db := -8.0

# Shot (spitting a prop)
## Throw speed at the lowest (x) and the full (y) aim force; a quick shot uses full force.
var shot_speed := Vector2(520.0, 1800.0)
var shot_inherit := 0.3
## One constant gravity for the whole flight of a thrown prop, so the arc is learnable and the preview is exact.
var shot_gravity := 900.0
## A hot bounce keeps most of the speed and reflects cleanly.
var shot_restitution := 0.9
var shot_friction := 0.97
## The hot phase ends after this long even with no bounce.
var shot_hot_time := 2.5
## Quick shot (no aim): full force, this many degrees above the facing direction.
var quick_shot_angle_deg := 7.0
var shot_cooldown := 0.22
var shot_buffer := 0.1
var shot_max_bounces := 6
## Below this speed a shot is spent: it stops doing damage and tumbles like a dropped prop.
var shot_hot_speed := 320.0
var shot_catch_delay := 0.35
## Spawn distance from the slime centre, in collision radii.
var shot_spawn_offset := 0.6
var shot_recoil_ground := 240.0
var shot_recoil_air := 320.0
var shot_recoil_up_max := 460.0
var shot_trail_points := 8
var shot_trail_width := 0.9
var shot_trail_color := Color(1.0, 0.95, 0.8, 0.5)
var shot_spray_count := 10
var shot_spray_speed := Vector2(220.0, 560.0)
var shot_spray_spread := 22.0
var shot_spray_radius := Vector2(2.0, 4.5) * character_scale
var shot_spray_inherit := 0.4
var shot_shake := 0.22
var shot_punch := 0.03
var shot_volume_db := 0.0
var shot_face_time := 0.18
var shot_squash := 1.0
var shot_dry_cooldown := 0.3
var shot_dry_spray_count := 4
var shot_dry_volume_db := -6.0
## Spit pitch at the lowest (x) and the full (y) force.
var shot_pitch := Vector2(0.85, 1.15)
## Shake, punch and recoil scale from this share at the lowest force up to 1 at full force.
var shot_force_feedback_min := 0.35

# Aim mode (hold LT / L2 or the right mouse button)
## Trigger strength that opens the aim or fires, and the lower strength that lets go, so a half-pressed trigger does not flicker.
var trigger_press := 0.55
var trigger_release := 0.3
var aim_stick_deadzone := 0.2
## Stick deflection maps to force with this exponent (above 1 gives finer control of soft lobs).
var aim_force_curve := 1.3
var aim_default_force := 0.5
var aim_default_angle_deg := 25.0
## Mouse distance from the slime, in world pixels, that gives full force.
var aim_mouse_range := 360.0
## Off: the stick points at the target. On: pull the stick away from the target, like a slingshot.
var aim_invert_slingshot := false
## Game speed while the aim is open, and how long (real seconds) it takes to ease in and out.
var aim_time_scale := 0.72
var aim_slowmo_ease := 0.18
var aim_preview_time := 2.2
var aim_preview_bounce_time := 0.3
## Arc length between preview dots, in pixels, and the longest arc the preview draws.
var aim_preview_dot_spacing := 26.0
var aim_preview_max_length := 1500.0
var aim_preview_dot_radius := Vector2(8.5, 4.0)
var aim_preview_bounce_dot_radius := 4.6
var aim_preview_marker_radius := 18.0
var aim_preview_marker_dots := 10
var aim_preview_alpha := 0.95
var aim_preview_empty_alpha := 0.3
var aim_preview_marker_color := Color(1.0, 0.92, 0.6)
## Aim preview of a burning slime: the next shot is an ember, so the arc takes the colours of fire.
var aim_preview_hot_fill := Color(1.0, 0.52, 0.12)
var aim_preview_hot_rim := Color(0.5, 0.08, 0.03)
var aim_preview_hot_marker := Color(1.0, 0.86, 0.4)
var aim_cargo_front := 0.42

# Bounce feedback (scales with impact speed up to bounce_speed_ref)
var bounce_speed_ref := 1300.0
var bounce_spark_count := Vector2i(3, 12)
var bounce_spark_speed := Vector2(140.0, 520.0)
var bounce_spark_spread := 60.0
var bounce_shake := Vector2(0.03, 0.14)
var bounce_pitch := Vector2(0.8, 1.35)
var bounce_volume_db := Vector2(-18.0, -1.0)
## Impacts above this speed also flash the screen.
var bounce_flash_speed := 1000.0
var bounce_flash_color := Color(1.0, 0.95, 0.8, 0.08)
var bounce_flash_time := 0.06
var bounce_spark_color := Color(1.0, 0.86, 0.45)
var bounce_spark_color_crystal := Color(0.6, 0.95, 1.0)
## Spikes and saws throw a prop back at least this fast.
var deflect_min_speed := 380.0
var deflect_spike_push := 160.0

# Mite (patrolling enemy)
var mite_loss := 14.0
var mite_hp := 2
var mite_speed := 80.0
var mite_turn_pause := 0.45
var mite_body_radius := 22.0 * character_scale
var mite_hit_radius := 21.0 * character_scale
var mite_knockback := 300.0 * sqrt(character_scale)
var mite_knock_decay := 5.0
var mite_hop := 300.0 * sqrt(character_scale)
var mite_gravity := 1700.0
var mite_walk_hz := 6.0
var mite_flash_time := 0.16
var mite_hit_hitstop := 0.06
var mite_hit_shake := 0.35
var mite_hit_punch := 0.03
var mite_hit_spark_count := 14
var mite_bite_squash := 0.35
var mite_death_hitstop := 0.11
var mite_death_slowmo_scale := 0.45
var mite_death_slowmo_time := 0.3
var mite_death_shake := 0.75
var mite_death_punch := 0.07
var mite_death_flash_color := Color(1.0, 0.8, 0.95, 0.3)
var mite_death_flash_time := 0.16
var mite_death_time := 0.18
var mite_spore_count := 34
var mite_spore_speed := Vector2(200.0, 640.0)
var mite_spore_size := Vector2(3.0, 7.0) * character_scale
var mite_ring_radius := 90.0 * character_scale
## Death by fire: fire sparks, the size of the fire in body radii, how long it burns on, and the char of the shell.
var mite_burn_sparks := 26
var mite_burn_size := 0.35
var mite_burn_time := 1.1
var mite_char_color := Color(0.16, 0.07, 0.05)
var mite_shell := Color(0.62, 0.24, 0.52)
var mite_shell_light := Color(0.85, 0.42, 0.70)
var mite_shell_dark := Color(0.36, 0.11, 0.32)
var mite_belly := Color(0.98, 0.78, 0.55)
var mite_spot := Color(1.0, 0.86, 0.38)
var mite_leg := Color(0.20, 0.08, 0.18)
var mite_eye := Color(1.0, 0.98, 0.9)
var mite_pupil := Color(0.08, 0.04, 0.06)
## Mite colours, given by the order of each mite in the level (left to right), and repeated. The purple palette is the
## mite_* colours plus mite_goo. Each palette: shell, shell_light, shell_dark, belly, spot, leg, and goo, the colour of the
## goo it drops (its main colour, nudged so the blend with the green takes a pleasant path round the hue circle).
var mite_goo := Color(0.52, 0.32, 0.86)
var mite_color_order: Array[StringName] = [&"purple", &"orange", &"blue", &"pink"]
var mite_palettes := {
	&"orange": {"shell": Color(0.93, 0.48, 0.13), "shell_light": Color(1.0, 0.70, 0.36), "shell_dark": Color(0.56, 0.22, 0.05), "belly": Color(1.0, 0.92, 0.70), "spot": Color(1.0, 0.98, 0.62), "leg": Color(0.26, 0.11, 0.04), "goo": Color(0.95, 0.52, 0.12)},
	&"blue": {"shell": Color(0.20, 0.47, 0.88), "shell_light": Color(0.45, 0.72, 1.0), "shell_dark": Color(0.09, 0.21, 0.50), "belly": Color(0.85, 0.93, 1.0), "spot": Color(0.62, 1.0, 0.95), "leg": Color(0.06, 0.09, 0.22), "goo": Color(0.22, 0.50, 0.92)},
	&"pink": {"shell": Color(0.95, 0.38, 0.60), "shell_light": Color(1.0, 0.66, 0.80), "shell_dark": Color(0.58, 0.14, 0.32), "belly": Color(1.0, 0.88, 0.84), "spot": Color(1.0, 0.95, 0.55), "leg": Color(0.28, 0.07, 0.15), "goo": Color(0.96, 0.36, 0.62)},
}
## Goo a mite drops when it pops: total mass (new goo, booked as gained), droplet count, droplet speed and radius.
var mite_goo_mass := 12.0
var mite_goo_droplets := 22
var mite_goo_droplet_speed := Vector2(220.0, 620.0)
var mite_goo_droplet_radius := Vector2(2.5, 5.5) * character_scale

# Crystal barrier
var barrier_hitstop := 0.08
var barrier_shake := 0.55
var barrier_punch := 0.05
var barrier_flash_color := Color(0.7, 0.95, 1.0, 0.22)
var barrier_flash_time := 0.16
var barrier_shards_per_tile := 14
var barrier_shard_speed := Vector2(260.0, 860.0)
var barrier_shard_size := Vector2(7.0, 17.0)
## Share of its speed a shot keeps after it smashes through a barrier.
var barrier_pass_keep := 0.7
var barrier_light := Color(0.80, 0.97, 1.0)
var barrier_mid := Color(0.42, 0.78, 0.98)
var barrier_dark := Color(0.18, 0.36, 0.70)
var barrier_core := Color(0.92, 1.0, 1.0)

# Sparks and debris (cosmetic, no gameplay effect)
## Draw layer of the loose and thrown props, the sparks and shards and the aim dots: above the goo surface (z 1),
## so they never look buried in a goo puddle or in the slime body.
var over_goo_z_index := 2
var sparks_max := 384
var spark_life := Vector2(0.12, 0.32)
var spark_gravity := 900.0
var spark_drag := 3.0
var spark_stretch := 0.035
var debris_life := Vector2(0.9, 1.6)
var debris_gravity := 2000.0
var debris_bounce := 0.45
var debris_fade_time := 0.3

# Goo field rendering
var goo_threshold := 0.35
var goo_intensity := 0.7
var goo_kernel_size := 256
var goo_fit_margin := 24.0
# Goo palette: lime where the light hits, moss in the shade, the lower part and the dense edge.
## Lit parts and the wet band inside the rim (#A6D63E).
var goo_lime_color := Color(0.65, 0.84, 0.24)
## Mid tone between lime and moss; also the goo accent of hazards, touch controls and panels (#6E9E2A).
var goo_body_color := Color(0.43, 0.62, 0.165)
## Moss: shade side and lower part of the gelatin (#4F5E24).
var goo_deep_color := Color(0.31, 0.37, 0.14)
## Darkest moss at the dense outline (#2C3614).
var goo_rim_color := Color(0.17, 0.21, 0.08)
## Small soft highlight and the bubble glints, lime tinted, never white (#D6F07A).
var goo_spec_color := Color(0.84, 0.94, 0.48)
var goo_warn_color := Color(0.95, 0.33, 0.28)
var goo_flash_color := Color(1.0, 1.0, 1.0, 1.0)
var goo_light_dir := Vector3(-0.5, -0.7, 0.6)
var goo_rim_width := 0.05
var goo_spec_power := 40.0
var goo_spec_strength := 0.45
var goo_sheen_power := 6.0
var goo_sheen_strength := 0.06
var goo_edge_light_strength := 0.3
## Lit share (0 to 1) where moss turns to mid (x) and mid turns to lime (y): narrow ranges give clear tone areas.
var goo_tone_steps := Vector2(0.3, 0.62)
## How much the lower half of the slime body darkens toward moss.
var goo_lower_shade := 0.55
# Translucent gelatin: alpha at the outline (x) and in the thick centre (y); the field rise above the threshold that goes from one to the other.
var goo_alpha := Vector2(0.97, 0.64)
var goo_density_depth := 0.3
## Clear centre tint (#82B832) and its lime emission share, which keeps the gelatin visible over a dark cave.
var goo_center_color := Color(0.51, 0.72, 0.2)
var goo_glow := 0.16
# Slow bubbles inside the slime body, drawn in the surface shader (only with goo_gloss).
## Bubble cells across one body radius, rise speed in body radii per second, share of cells with a bubble.
var goo_bubble_cells := 4.0
var goo_bubble_rise := 0.11
var goo_bubble_density := 0.65
## Bubble radius range in cell units, side wobble in cell units and its rate in cycles per second.
var goo_bubble_size := Vector2(0.1, 0.32)
var goo_bubble_wobble := 0.12
var goo_bubble_wobble_hz := 0.3
var goo_bubble_alpha := 0.75
## Body radius share where the bubbles fade out, so they stay inside the outline.
var goo_bubble_inner := 0.78
# Goo colour mix (colours of mite goo blend into the slime).
## Hue difference, in radians, below which two goo colours count as the same.
var goo_color_same_hue := 0.06
## Hue offset from the green (radians) where the field hue code is cut open; keep it in a gap between goo colours.
var goo_hue_cut := deg_to_rad(-145.0)
## Chroma of any goo colour, as a multiple of the green chroma (YCoCg); vivid oranges and blues need about 2.
var goo_chroma_scale := Vector2(0.8, 2.0)
## Clearer gelatin in front of carried props: half size of the zone in body radii (centre: carry_zone_center), the
## alpha there and the fade time when the load starts or ends.
var goo_cargo_clear_half := Vector2(0.66, 0.56)
var goo_cargo_clear_alpha := 0.5
var goo_cargo_clear_fade := 0.3
## Oklab lightness and chroma range of a mixed body colour.
var goo_mix_lightness := Vector2(0.5, 0.78)
var goo_mix_chroma := Vector2(0.1, 0.2)
## Seconds the new colour takes to swirl in from the contact point and fill the body; swirl strength.
var goo_mix_time := 1.6
var goo_mix_swirl := 1.4
## Pulse rate of the body status light (ember, frost).
var goo_status_pulse_hz := 1.4
# Damp stains that soaked goo leaves on the soil.
var goo_stain_max := 160
var goo_stain_color := Color(0.05, 0.12, 0.03, 0.6)
var goo_stain_fade_time := 6.0
## Redraw rate of the stains while they grow or fade; a new stain redraws at once.
var goo_stain_redraw_hz := 30.0
## Stain half size along the surface and across it, in goo radii.
var goo_stain_size := Vector2(2.0, 0.7)

# Soft body
var body_points := 48
var body_radius_stiffness := 260.0
var body_radius_damping := 14.0
var body_squash_stiffness := 320.0
var body_squash_damping := 16.0
var body_wobble_stiffness := 260.0
var body_wobble_coupling := 120.0
var body_wobble_damping := 9.0
var body_kick_scale := 6.0
var body_land_squash := 0.0004
var body_land_squash_max := 0.55
var body_land_kick := 9.0
var body_land_ripple := 0.4
var body_jump_kick := 5.0
var body_hit_ripple := 0.35
var body_hit_squash := 4.0
var body_gulp_ripple := 0.35
var body_gulp_swell := 40.0
var body_wall_splat_ripple := 0.3
var body_bonk_squash := 5.0
var body_spit_ripple := 0.5
var body_spit_back := 0.25
var body_spit_squash := 3.0
var body_spit_lean := 2.5
## Slingshot pull while aiming: the back of the body stretches away from the target in proportion to the force.
var body_aim_stretch := 0.5
var body_aim_shift := 0.12
var body_aim_stiffness := 420.0
var body_aim_damping := 11.0
## Pull the body springs to at the moment of a shot; below zero it snaps forward past rest.
var body_aim_release_kick := -9.0
var body_pop_in_speed := 14.0
var body_air_stretch := 0.00012
var body_air_stretch_max := 0.18
var body_lean := 0.0006
var body_floor_sink := 2.0 * character_scale
var body_breath_amp := 0.025
var body_breath_hz := 1.3
var body_flash_decay := 6.0
var body_pulse_decay := 3.0
var body_pulse_swell := 0.06
var body_danger_tint_base := 0.35
var body_danger_tint_pulse := 0.65
## Radial push per px/s of horizontal velocity change per tick: the goo lags behind when the slime starts, stops or turns.
var body_inertia_kick := 0.001
var body_inertia_min_change := 4.0
# Gelatin walk: the top of the body is a slow, lightly damped spring that trails the base.
var body_lean_stiffness := 300.0
var body_lean_damping := 5.0
var body_lean_max := 0.32
## Lean velocity per px/s of horizontal velocity change: the top lags when the base speeds up and overshoots when it stops.
var body_lean_accel_impulse := 0.002
var body_turn_min_speed := 120.0
var body_turn_ripple := 0.22
var body_turn_squash_kick := 2.2
var body_step_squash_kick := 0.6
var body_step_ripple := 0.08
# Slug foot on the floor, in visual radii: the lower body sags past the floor, then a soft clamp flattens it with round corners and a flared skirt.
var body_foot_sag := 0.35
var body_foot_round := 0.14
var body_foot_flare := 0.5
var body_foot_flare_height := 0.7

# Face
var face_blink_time := 0.09
var face_blink_interval := Vector2(2.2, 5.0)
var face_dead_eyes_time := 0.4
var face_fall_fast_speed := 900.0
var face_look_speed_min := 80.0
var face_look_piece_distance := 320.0
var face_look_smooth := 10.0
var face_appear_radius := 10.0
## Body radius the face is drawn for. A larger body keeps this face size; a smaller body shrinks the face to fit.
var face_radius := 30.0
## Height of the face centre above the body centre, in body radii: the upper centre of the body.
var body_face_height := 0.4
var face_sweat_cycle := 1.1
## The face rides the body on a stiffer spring, so the eyes jiggle a beat after the goo.
var face_lag_stiffness := 900.0
var face_lag_damping := 22.0
var face_lag_max := 12.0
var face_sclera_color := Color(0.98, 1.0, 0.95)
var face_ink_color := Color(0.04, 0.16, 0.06)
## Value (HSV) of the face ink, which takes the hue of the body colour.
var face_ink_value := 0.17
var face_pupil_color := Color(0.05, 0.07, 0.09)
var face_shine_color := Color(1.0, 1.0, 1.0, 0.95)
var face_mouth_color := Color(0.22, 0.05, 0.08)
var face_tongue_color := Color(0.95, 0.45, 0.5)
var face_sweat_color := Color(0.5, 0.8, 1.0, 0.95)

# Droplets
var droplet_max := 256
var droplet_gravity := 1900.0
var droplet_fly_life := Vector2(0.35, 0.8)
## Seconds that goo with no mass (stuck droplets, wet trails, decorative pieces) stays on a surface before the soil takes it.
var goo_ground_life := 8.0
var goo_ground_life_jitter := Vector2(1.0, 1.2)
## Seconds a stuck droplet takes to sink; droplets on a wall creep down at droplet_soak_drip_speed meanwhile.
var droplet_soak_time := 2.5
var droplet_soak_drip_speed := 7.0
## Stuck droplets above this count make the oldest ones start to sink (at most droplet_soak_per_tick per tick).
var droplet_soak_cap := 190
var droplet_soak_per_tick := 4
var droplet_stick_grow := 1.25
var droplet_stick_flat := Vector2(0.75, 1.35)
var droplet_fade_time := 0.25
var droplet_stretch_per_speed := 0.0012
var droplet_stretch_max := 0.8
var trail_radius := Vector2(3.0, 5.0) * character_scale
var trail_life := goo_ground_life

# Camera and screen feedback
var camera_zoom := 1.0
var camera_smooth_x := 0.12
var camera_smooth_y := 0.22
var camera_deadzone_y := 90.0
var camera_vertical_bias := -60.0 - 20.0 * (character_scale - 1.0)
var camera_look_ahead_time := 0.35
var camera_look_ahead_max := 140.0 * character_speed_scale
var camera_look_response := 3.0
var camera_fall_look_speed := 700.0
var camera_fall_look_max := 160.0
var camera_fall_look_gain := 0.25
## Closest the target gets to each screen edge (x, y) in world pixels at zoom 1.
var camera_edge_margin := Vector2(230.0, 140.0) + Vector2.ONE * radius_full
var camera_punch_stiffness := 220.0
var camera_punch_damping := 14.0
var camera_punch_kick := 30.0
var shake_scale := 1.3
var shake_decay := 1.6
var shake_speed := 60.0
# Noise samples per shake_speed unit: 60 units/s * 0.25 gives about 15 bumps per second.
var shake_noise_frequency := 0.25
var shake_max_offset := Vector2(26.0, 20.0) * (1.0 + 0.15 * (character_scale - 1.0))
var shake_max_roll := 0.05
var hitstop_min := 0.04
var hitstop_max := 0.10
var hitstop_time_scale := 0.03
var death_hitstop := 0.15
var death_slowmo_scale := 0.35
var death_slowmo_time := 0.6
var death_sequence_time := 1.1
var goal_slowmo_scale := 0.4
var goal_slowmo_time := 0.8
var flash_hurt_color := Color(1.0, 0.85, 0.85, 0.35)
var iris_close_time := 0.35
var iris_open_time := 0.45
var muffle_cutoff_hz := 600.0
var vignette_danger_floor := 0.45
var vignette_danger_response := 4.0
var vignette_heartbeat_dip := 0.35

# Juice presets (strength 0..1 maps x to y)
var juice_slowmo_ease_back_time := 0.2
var juice_muffle_rate := 3.0
var juice_impact_shake := Vector2(0.25, 0.7)
var juice_impact_punch := Vector2(0.02, 0.06)
var juice_impact_flash_time := 0.12
var juice_death_shake := 1.0
var juice_death_punch := 0.12
var juice_death_flash_color := Color(1.0, 1.0, 1.0, 0.6)
var juice_death_flash_time := 0.2
## Extra seconds the audio muffle holds after the death slow motion ends.
var juice_death_muffle_tail := 0.6
var juice_goal_shake := 0.3
var juice_goal_punch := 0.08
var juice_goal_flash_color := Color(1.0, 0.95, 0.6, 0.35)
var juice_goal_flash_time := 0.3
## Calls of one source closer than this (real seconds) to the previous one merge into one burst: the burst moves the
## camera only as much as its strongest call, so a feedback that repeats in each tick cannot stack.
var juice_merge_gap := 0.15
## Largest zoom punch and shake trauma of one call; the strongest event (death) uses 0.12 and 1.0.
var juice_punch_max := 0.15
var juice_shake_max := 1.0

# Haptics: controller rumble and phone vibration, sent only to the device in use (haptics_enabled is saved by the performance panel)
var haptics_enabled := true
## Scales every vibration amplitude, 0..1.
var haptics_strength := 1.0
## A new vibration this soon after the last start is dropped, unless its prio is higher.
var haptics_min_gap_ms := 40.0
## When the active vibration has less than this share of its time left, an event of any prio can replace it.
var haptics_yield_share := 0.35
## A fading vibration is sent again at this interval with the lower level.
var haptics_fade_step_ms := 50.0
## Event amounts that give strength 1.
var haptics_damage_full := 30.0
var haptics_fall_damage_full := 50.0
var haptics_goo_full := 8.0
## low: strong low motor, high: weak high motor (0..1). ms: pulse length; pulses and gap_ms make a pattern.
## fade: the level falls to 0 over the whole pattern. phone_ms, phone_amp: one phone pulse (amp 0..1).
## prio: a higher prio replaces a lower one. cooldown_ms: least time between two starts of the preset.
## floor: share of the amplitude at strength 0 (strength 1 gives the full amplitude).
var haptics_presets := {
	&"jump": {"low": 0.0, "high": 0.35, "ms": 45.0, "phone_ms": 16.0, "phone_amp": 0.35, "prio": 2, "cooldown_ms": 60.0, "floor": 0.6},
	&"double_jump": {"low": 0.1, "high": 0.5, "ms": 55.0, "phone_ms": 22.0, "phone_amp": 0.45, "prio": 2, "cooldown_ms": 60.0, "floor": 0.6},
	&"land": {"low": 0.6, "high": 0.1, "ms": 70.0, "phone_ms": 30.0, "phone_amp": 0.55, "prio": 3, "cooldown_ms": 80.0, "floor": 0.25},
	&"roll": {"low": 0.3, "high": 0.2, "ms": 90.0, "fade": true, "phone_ms": 30.0, "phone_amp": 0.35, "prio": 2, "cooldown_ms": 120.0, "floor": 0.5},
	&"dodge": {"low": 0.05, "high": 0.55, "ms": 40.0, "phone_ms": 16.0, "phone_amp": 0.5, "prio": 2, "cooldown_ms": 80.0, "floor": 0.6},
	&"wall_cling": {"low": 0.25, "high": 0.25, "ms": 50.0, "phone_ms": 20.0, "phone_amp": 0.35, "prio": 2, "cooldown_ms": 150.0, "floor": 0.5},
	&"skid": {"low": 0.0, "high": 0.3, "ms": 100.0, "fade": true, "phone_ms": 24.0, "phone_amp": 0.25, "prio": 1, "cooldown_ms": 200.0, "floor": 0.5},
	&"crouch": {"low": 0.18, "high": 0.0, "ms": 35.0, "phone_ms": 12.0, "phone_amp": 0.2, "prio": 1, "cooldown_ms": 150.0, "floor": 0.6},
	&"run_tired": {"low": 0.22, "high": 0.08, "ms": 60.0, "pulses": 2, "gap_ms": 90.0, "phone_ms": 24.0, "phone_amp": 0.25, "prio": 1, "cooldown_ms": 400.0, "floor": 0.6},
	&"bonk": {"low": 0.55, "high": 0.05, "ms": 55.0, "phone_ms": 26.0, "phone_amp": 0.45, "prio": 2, "cooldown_ms": 90.0, "floor": 0.35},
	&"wall_splat": {"low": 0.45, "high": 0.3, "ms": 50.0, "phone_ms": 24.0, "phone_amp": 0.5, "prio": 2, "cooldown_ms": 90.0, "floor": 0.35},
	&"drain": {"low": 0.7, "high": 0.15, "ms": 30.0, "phone_ms": 18.0, "phone_amp": 0.6, "prio": 4, "cooldown_ms": 150.0, "floor": 0.3},
	&"run_start": {"low": 0.1, "high": 0.45, "ms": 50.0, "phone_ms": 20.0, "phone_amp": 0.45, "prio": 2, "cooldown_ms": 200.0, "floor": 0.8},
	&"absorb_object": {"low": 0.4, "high": 0.25, "ms": 65.0, "fade": true, "phone_ms": 28.0, "phone_amp": 0.45, "prio": 2, "cooldown_ms": 60.0, "floor": 0.4},
	&"aim_open": {"low": 0.0, "high": 0.2, "ms": 30.0, "phone_ms": 12.0, "phone_amp": 0.25, "prio": 1, "cooldown_ms": 120.0, "floor": 1.0},
	&"absorb_goo": {"low": 0.3, "high": 0.55, "ms": 34.0, "phone_ms": 18.0, "phone_amp": 0.55, "prio": 2, "cooldown_ms": 45.0, "floor": 0.45},
	&"damage": {"low": 0.85, "high": 0.6, "ms": 120.0, "phone_ms": 70.0, "phone_amp": 0.85, "prio": 4, "cooldown_ms": 0.0, "floor": 0.45},
	&"damage_fall": {"low": 1.0, "high": 0.7, "ms": 170.0, "phone_ms": 110.0, "phone_amp": 1.0, "prio": 4, "cooldown_ms": 0.0, "floor": 0.6},
	&"death": {"low": 1.0, "high": 0.5, "ms": 900.0, "fade": true, "phone_ms": 600.0, "phone_amp": 1.0, "prio": 5, "cooldown_ms": 0.0, "floor": 1.0},
	&"respawn": {"low": 0.15, "high": 0.25, "ms": 55.0, "pulses": 2, "gap_ms": 80.0, "phone_ms": 28.0, "phone_amp": 0.35, "prio": 2, "cooldown_ms": 0.0, "floor": 1.0},
	&"checkpoint": {"low": 0.2, "high": 0.4, "ms": 50.0, "pulses": 2, "gap_ms": 70.0, "phone_ms": 30.0, "phone_amp": 0.45, "prio": 3, "cooldown_ms": 0.0, "floor": 1.0},
	&"goal": {"low": 0.3, "high": 0.45, "ms": 70.0, "pulses": 3, "gap_ms": 90.0, "phone_ms": 40.0, "phone_amp": 0.55, "prio": 4, "cooldown_ms": 0.0, "floor": 1.0},
	&"shot": {"low": 0.45, "high": 0.75, "ms": 60.0, "phone_ms": 30.0, "phone_amp": 0.75, "prio": 3, "cooldown_ms": 50.0, "floor": 0.35},
	&"target_hit": {"low": 0.5, "high": 0.55, "ms": 75.0, "phone_ms": 40.0, "phone_amp": 0.6, "prio": 3, "cooldown_ms": 50.0, "floor": 1.0},
	&"enemy_death": {"low": 0.8, "high": 0.4, "ms": 70.0, "pulses": 2, "gap_ms": 50.0, "phone_ms": 45.0, "phone_amp": 0.8, "prio": 4, "cooldown_ms": 0.0, "floor": 1.0},
	&"barrier_break": {"low": 0.95, "high": 0.5, "ms": 220.0, "fade": true, "phone_ms": 120.0, "phone_amp": 0.9, "prio": 4, "cooldown_ms": 0.0, "floor": 1.0},
	&"trap_break": {"low": 0.25, "high": 0.7, "ms": 80.0, "phone_ms": 35.0, "phone_amp": 0.6, "prio": 3, "cooldown_ms": 60.0, "floor": 1.0},
	&"ui_press": {"low": 0.0, "high": 0.2, "ms": 18.0, "phone_ms": 18.0, "phone_amp": 0.5, "prio": 1, "cooldown_ms": 0.0, "floor": 1.0},
	&"ui_stick": {"low": 0.0, "high": 0.12, "ms": 10.0, "phone_ms": 10.0, "phone_amp": 0.25, "prio": 1, "cooldown_ms": 0.0, "floor": 1.0},
	&"ui_fire": {"low": 0.0, "high": 0.35, "ms": 28.0, "phone_ms": 28.0, "phone_amp": 0.8, "prio": 1, "cooldown_ms": 0.0, "floor": 1.0},
	&"ui_cancel": {"low": 0.0, "high": 0.15, "ms": 14.0, "phone_ms": 14.0, "phone_amp": 0.3, "prio": 1, "cooldown_ms": 0.0, "floor": 1.0},
}

# HUD
var hud_death_pop_scale := 1.45
var hud_pop_time := 0.45
var hud_toast_start_scale := 0.4
var hud_toast_pop_time := 0.3
var hud_toast_hold := 1.2
var hud_toast_fade := 0.35
var hud_panel_start_scale := 0.6
var hud_panel_pop_time := 0.6
var hud_panel_fade_share := 0.4
var hud_count_delay := 0.3
var hud_count_time := 1.0
var hud_count_steps := 20
var hud_count_pitch_rise := 0.6
var hud_again_blink_time := 0.55
var hud_again_blink_alpha := 0.35

# Hints
var hint_fade_distance := Vector2(260.0, 520.0)
var hint_bob_speed := 2.2
var hint_bob_pixels := 4.0
var hint_min_alpha := 0.15
var hint_pop_alpha := 0.6
var hint_reset_alpha := 0.35
var hint_pop_scale := 1.18
var hint_pop_time := 0.35

# Input icons (scripts/ui/input_glyphs.gd); sizes in shares of the icon height unless named in pixels
## Seconds the input mode holds after a change; the last input in that time takes the mode at its end.
var input_mode_hold := 0.25
## Device id of the events that Harness injects in a scripted run; the input map then matches only this id, so real
## keyboards, mice and pads (other ids) do not reach the game.
var harness_device := 64
## Every legend and label uses the label font size, so the text of a hint shares one font cache texture.
var glyph_size := 40.0
var hud_glyph_size := 38.0
var glyph_label_font_size := 22
var hud_glyph_label_font_size := 22
## Labels longer than this (pixels) end with an ellipsis.
var glyph_label_max_width := 420.0
var glyph_font_embolden := 0.5
var glyph_label_outline := 6
var glyph_gap := 0.14
var glyph_label_gap := 0.3
var glyph_row_gap := 0.4
var glyph_bar_offset := 0.3
var glyph_bar_height := 0.1
var glyph_outline_width := 2.0
var glyph_key_depth := 0.17
var glyph_press_sink := 0.9
var glyph_glow_alpha := 0.35
var glyph_key_min_width := 0.95
var glyph_key_padding := 0.55
var glyph_space_width := 2.2
var glyph_mouse_width := 0.68
var glyph_mouse_move_width := 1.25
var glyph_bumper_width := 1.4
var glyph_trigger_width := 0.8
var glyph_stick_width := 1.45
var glyph_touch_radius := 0.5
var glyph_touch_drag_width := 1.7
var glyph_touch_drag_reach := 1.5
var glyph_touch_stick_radius := 0.6
var glyph_touch_knob_share := 0.44
var glyph_touch_stick_reach := 0.85
# Loop of each row: a lead, one slot per step, then a rest. A held step stays down until the row ends.
var glyph_lead_time := 0.3
var glyph_tap_time := 0.5
var glyph_tap_hold := 0.12
var glyph_hold_time := 1.3
var glyph_step_time := 0.45
var glyph_dir_time := 0.55
var glyph_dir_share := 0.85
var glyph_drag_time := 1.2
var glyph_drag_share := 0.8
var glyph_rest_time := 0.8
var glyph_press_in := 0.08
var glyph_release_time := 0.14
var glyph_ripple_time := 0.35
var glyph_then_nudge_hz := 1.2
## Redraw rate of the continuous hint decorations (the "then" nudge, the state marks); the presses redraw on change.
var glyph_idle_motion_hz := 30.0
var glyph_pop_time := 0.35
var glyph_pop_stagger := 0.045
var glyph_pop_from := 0.4
var glyph_key_top := Color(0.92, 0.92, 0.88)
var glyph_key_side := Color(0.6, 0.6, 0.63)
var glyph_key_legend := Color(0.14, 0.13, 0.18)
var glyph_key_lit := Color(1.0, 0.95, 0.72)
var glyph_key_lit_share := 0.45
var glyph_mouse_lit := Color(0.95, 0.72, 0.28)
var glyph_pad_body := Color(0.34, 0.35, 0.4)
var glyph_pad_side := Color(0.15, 0.15, 0.19)
var glyph_pad_legend := Color(0.97, 0.97, 1.0)
var glyph_xbox_colors: Array[Color] = [Color(0.4, 0.75, 0.2), Color(0.88, 0.22, 0.2), Color(0.16, 0.46, 0.92), Color(0.97, 0.75, 0.12)]
var glyph_ps_body := Color(0.2, 0.21, 0.25)
var glyph_ps_colors: Array[Color] = [Color(0.5, 0.7, 1.0), Color(1.0, 0.42, 0.45), Color(0.95, 0.55, 0.85), Color(0.3, 0.88, 0.72)]
var glyph_lit_color := Color(1.0, 0.93, 0.6)
var glyph_arrow_dim := Color(0.8, 0.84, 0.92, 0.55)
var glyph_outline_color := Color(0.06, 0.05, 0.09)
var glyph_shadow_color := Color(0.0, 0.0, 0.0, 0.35)
var glyph_separator_color := Color(0.88, 0.9, 0.96, 0.85)
var glyph_label_color := Color(1.0, 1.0, 1.0)
var glyph_bar_track := Color(0.2, 0.2, 0.26)
var glyph_state_hz := 0.6
var glyph_flame_outer := Color(1.0, 0.5, 0.15)
var glyph_flame_inner := Color(1.0, 0.9, 0.45)
var glyph_drop_color := Color(0.55, 0.78, 0.25)
var glyph_snow_color := Color(0.82, 0.94, 1.0)
var glyph_ice_color := Color(0.6, 0.85, 1.0)
var glyph_cross_color := Color(0.95, 0.25, 0.22)

# Touch controls (canvas pixels at touch_layout_reference; offsets are from the safe area corner of each control)
## Short side of the canvas that gives scale 1; the controls scale with the short side inside touch_scale_range.
var touch_layout_reference := 720.0
var touch_scale_range := Vector2(0.75, 1.4)
var touch_fade_time := 0.2
## Alpha of the whole overlay while the slime is dead, spawning or behind the iris.
var touch_down_alpha := 0.4
## Taps can be shorter than a physics tick, so each action stays held this long and for touch_min_hold_ticks physics ticks.
var touch_min_hold := 0.07
var touch_min_hold_ticks := 2
## The stick spawns under a finger left of this share of the safe width and below this share of its height.
var touch_left_zone := 0.45
var touch_top_band := 0.22
## Stick home from the bottom-left safe corner (x right, y up), base and knob radii.
var touch_stick_home := Vector2(215.0, 185.0)
var touch_stick_radius := 104.0
var touch_stick_knob_radius := 42.0
## Horizontal deflection (share of the radius) where the slime starts to move, and where it reaches full speed.
var touch_stick_deadzone := 0.16
var touch_stick_full_at := 0.62
var touch_stick_return_time := 0.22
var touch_stick_ghost_alpha := 0.28
## The idle stick fades to this share of its ghost alpha when the slime is under it; it starts to fade when the
## slime comes within touch_stick_veil_band (layout pixels) of its rim. A finger on the stick shows it in full.
var touch_stick_veil_alpha := 0.15
var touch_stick_veil_band := 60.0
var touch_stick_knob_stiffness := 520.0
var touch_stick_knob_damping := 16.0
var touch_stick_stretch := 0.2
## Button centres from the bottom-right safe corner (x left, y up) and radii. Jump sits where the right thumb rests.
var touch_jump_offset := Vector2(165.0, 150.0)
var touch_jump_radius := 76.0
var touch_shoot_offset := Vector2(340.0, 112.0)
var touch_shoot_radius := 56.0
var touch_aim_offset := Vector2(190.0, 350.0)
var touch_aim_radius := 58.0
## Small buttons from the top-right safe corner (x left, y down), under the clock of the HUD.
var touch_restart_offset := Vector2(62.0, 128.0)
var touch_restart_radius := 30.0
var touch_perf_offset := Vector2(142.0, 128.0)
var touch_perf_radius := 22.0
var touch_hit_slop := 1.18
## Width of the edge fade that stands in for antialiasing, in canvas pixels at scale 1.
var touch_feather := 1.2
## Aim drag: full force at this many aim button radii from its centre. A release inside the cancel share closes the aim with no shot.
var touch_aim_range := 1.9
var touch_aim_cancel_radius := 0.22
## Off: drag toward the target. On: pull away from the target, like a slingshot.
var touch_aim_slingshot := false
## After the release, fire is pressed again every retry seconds until a shot leaves, and given up after give_up seconds.
var touch_fire_retry := 0.12
var touch_fire_give_up := 0.6
var touch_button_idle_alpha := 0.62
var touch_button_pressed_alpha := 0.92
var touch_press_squash := 0.84
var touch_spring_stiffness := 620.0
var touch_spring_damping := 15.0
var touch_release_kick := 7.0
var touch_wobble_amount := 0.07
var touch_wobble_decay := 5.0
var touch_wobble_lobes := 5.0
var touch_ripple_time := 0.42
var touch_appear_time := 0.16
var touch_splash_count := 6
var touch_splash_speed := Vector2(120.0, 260.0)
var touch_splash_life := 0.35
var touch_splash_gravity := 700.0
var touch_goal_pulse_hz := 1.4
var touch_accent_jump := Color(0.49, 0.91, 0.29)
var touch_accent_shoot := Color(1.0, 0.82, 0.45)
var touch_accent_aim := Color(0.45, 0.85, 1.0)
var touch_accent_cancel := Color(1.0, 0.42, 0.38)
var touch_accent_neutral := Color(0.86, 0.9, 0.95)
var touch_fill_color := Color(0.03, 0.09, 0.05)
var touch_cancel_volume_db := -12.0

# Performance panel and the costly systems it can switch off (saved in user://perf.cfg)
var perf_refresh_time := 0.25
var perf_font_size := 18
var perf_row_height := 44.0
var perf_panel_width := 640.0
var fx_sparks := true
var fx_droplets := true
var fx_background := true
var fx_vignette := true
## Diagnosis switches: off hides the tutorial hints, hides the enemies (they still act), freezes the touch controls
## look (they still work) and hides the temperature zone art.
var fx_hints := true
var fx_enemies := true
var fx_touch_redraw := true
var fx_temperature_art := true
## Redraw rate of the moving temperature looks (snow, mist, haze, steam).
var temperature_art_hz := 30.0
## Off: the cheap fire (no heat shimmer, which copies a part of the screen, no inner flame, fewer sparks).
## The quality level sets it at boot and on each level change (autoload/quality.gd); the performance panel can flip it.
var fx_fire_rich := true
## Off: the goo surface skips its four normal taps and its bubbles, a cheaper pass on slow GPUs. The quality level sets it.
var goo_gloss := true
## Off: the background drops its silhouette layer and its spores (quality level Low).
var fx_bg_detail := true
## Rows of bg_mid.png that are fully clear; the layer draws only the bands above and below them.
var bg_mid_clear_rows := Vector2i(352, 768)

# Quality levels and the automatic quality (autoload/quality.gd, saved in user://quality.cfg)
var quality_target_fps := 60.0
## Seconds of frames in one down window, and the shorter window of the first start.
var quality_down_window := 3.0
var quality_first_window := 1.5
## A window steps down when its mean frame is above budget * this, or when more than quality_miss_share of its frames
## are above budget * quality_miss_factor.
var quality_down_mean := 1.08
var quality_miss_factor := 1.25
var quality_miss_share := 0.2
## Frames left out after a level start, a step, or a return of focus.
var quality_settle_time := 1.0
## A frame longer than this is a stall (load, window drag), not a cost; it restarts the windows.
var quality_spike_ms := 200.0
## Calm seconds before a step up, the busy share of the budget it needs, the miss share it allows, and the probe
## window after it. Each step down doubles the wait, up to quality_up_wait_max_mult times.
var quality_up_wait := 45.0
var quality_up_busy_share := 0.5
var quality_up_miss_share := 0.01
## With no GPU time reported, a step up may also pass when the script and draw time stays below this share of the budget.
var quality_up_script_share := 0.35
## Phone rules: High reached by a climb fails its hold check when its mean frame is above this many times the mean
## frame of Medium (measured just before the climb); the same margin tells, in the check, whether Medium is clearly faster.
var quality_hold_factor := 1.15
## Seconds of frames that the hold check measures at Medium, in the scene where High failed.
var quality_check_window := 3.0
## Hold checks in one session; past this count High stays and the hold check stops until the next session.
var quality_hold_check_max := 3
var quality_probe_time := 8.0
var quality_up_wait_max_mult := 8.0
## The base resolution step exists only when the window has this many times the pixels of the base layout.
var quality_base_res_min_gain := 1.3

# Audio
var sfx_mix_rate := 32000
var sfx_volume_db := -4.0
var sfx_pitch_jitter := 0.06
var sfx_min_frames := 2
var absorb_ladder_window := 0.8
var absorb_ladder_max := 12

# Ground art
var ground_texture_world_size := 1024.0
var ground_tint := Color(0.78, 0.62, 0.70)
var ground_lip_color := Color(0.85, 0.70, 0.55)
var ground_lip_shadow := Color(0.23, 0.15, 0.20)
var ground_outline_color := Color(0.10, 0.07, 0.12)
var plank_color := Color(0.62, 0.46, 0.36)
var ground_shade_step := 0.8
var ground_shade_min := 0.52
var ground_outline_width := 3.0
var ground_lip_depth := 10.0
var ground_lip_wave := 3.0
var ground_lip_wave_freq := 0.11
var ground_lip_shadow_size := 2.0
var ground_corner_radius := 6.0
var ground_drip_chance := 0.18
## Share of warm and ice floor cells with a surface mark (glowing crack, ice streak).
var ground_surface_mark_chance := 0.3
var ground_plank_shadow_size := 6.0

# Decoration (scripts/level/decor_*.gd). Sizes in px; the slime stands about 120 px tall and its face is about 50 px wide.
# Decoration has no collision and draws no green: the slime stays the only green thing on screen.
var decor_seed := 7331
## Per theme: chance for each free floor, ceiling and wall cell, for an extra low piece on a floor cell (scatter), for a
## soil detail under a floor, and the spacing in cells of the far silhouettes and of the near (foreground) shapes;
## 0 spacing turns a layer off.
var decor_density := {
	&"cave": {"floor": 0.75, "scatter": 0.45, "ceiling": 0.45, "wall": 0.16, "soil": 0.22, "back": 5.0, "front": 12.0},
	&"hot": {"floor": 0.65, "scatter": 0.45, "ceiling": 0.4, "wall": 0.22, "soil": 0.25, "back": 5.5, "front": 0.0},
	&"fire": {"floor": 0.7, "scatter": 0.5, "ceiling": 0.4, "wall": 0.2, "soil": 0.2, "back": 5.5, "front": 0.0},
	&"cold": {"floor": 0.7, "scatter": 0.35, "ceiling": 0.55, "wall": 0.2, "soil": 0.15, "back": 5.5, "front": 0.0},
	&"goal": {"floor": 0.9, "scatter": 0.6, "ceiling": 0.65, "wall": 0.25, "soil": 0.3, "back": 4.5, "front": 9.0},
}
## Weighted picks for each theme. Floor kinds marked low in decor_low_kinds may also grow on mite paths and under hints.
var decor_floor_kinds := {
	&"cave": {&"mushroom": 4.0, &"mushroom_group": 2.5, &"rock": 1.2, &"pebbles": 1.2, &"crystal": 1.0, &"bones": 0.4, &"roots": 0.8, &"stalagmite": 0.7, &"puddle": 0.5, &"moss": 1.4},
	&"hot": {&"dead_roots": 2.0, &"rock": 1.6, &"pebbles": 1.4, &"vent": 1.6, &"bones": 0.8, &"stalagmite": 1.0, &"crystal": 0.6},
	&"fire": {&"ash": 2.4, &"stump": 1.6, &"rock": 1.2, &"bones": 0.8, &"pebbles": 1.0, &"embers": 1.4},
	&"cold": {&"frozen_mushroom": 2.6, &"frost_rock": 2.0, &"crystal": 1.6, &"pebbles": 0.8, &"stalagmite": 1.0, &"puddle": 0.8},
	&"goal": {&"mushroom": 5.0, &"mushroom_group": 3.0, &"crystal": 2.2, &"moss": 2.0, &"rock": 0.6, &"pebbles": 0.8},
}
var decor_low_kinds: Array[StringName] = [&"pebbles", &"moss", &"puddle", &"roots", &"dead_roots", &"ash", &"embers"]
var decor_ceiling_kinds := {
	&"cave": {&"stalactite": 1.6, &"root": 2.0, &"vine": 1.6, &"glow_worm": 1.6, &"drip": 0.8},
	&"hot": {&"stalactite": 2.0, &"dead_root": 2.4, &"drip": 0.3},
	&"fire": {&"stalactite": 1.6, &"charred_root": 2.4},
	&"cold": {&"icicle": 3.0, &"stalactite": 0.8, &"drip": 0.8},
	&"goal": {&"glow_worm": 3.0, &"vine": 2.0, &"root": 1.0, &"stalactite": 0.8},
}
var decor_wall_kinds := {
	&"cave": {&"crack": 2.0, &"vein": 1.2, &"root_line": 1.4, &"shelf": 1.6},
	&"hot": {&"glow_crack": 3.0, &"crack": 1.0, &"root_line": 0.8},
	&"fire": {&"glow_crack": 1.0, &"crack": 2.0, &"soot": 2.0},
	&"cold": {&"frost": 2.4, &"vein": 1.6, &"crack": 1.0},
	&"goal": {&"vein": 2.0, &"shelf": 2.0, &"root_line": 1.0},
}
var decor_soil_kinds := {
	&"cave": {&"soil_roots": 3.0, &"fossil": 0.6, &"soil_vein": 1.0},
	&"hot": {&"soil_glow": 3.0, &"soil_roots": 1.0},
	&"fire": {&"soil_glow": 1.5, &"fossil": 1.0},
	&"cold": {&"soil_vein": 2.0, &"fossil": 0.5},
	&"goal": {&"soil_roots": 2.0, &"soil_vein": 2.0},
}
## Mushroom heights: small groups, face size, and as tall as the slime; the mix picks one of the three.
var decor_mushroom_small := Vector2(26.0, 40.0)
var decor_mushroom_face := Vector2(48.0, 72.0)
var decor_mushroom_large := Vector2(100.0, 135.0)
var decor_mushroom_mix := Vector3(0.22, 0.5, 0.28)
## Cap width over mushroom height.
var decor_mushroom_cap_ratio := Vector2(0.62, 1.05)
var decor_mushroom_group := Vector2i(2, 4)
var decor_mushroom_glow_chance := 0.3
var decor_cap_colors: Array[Color] = [Color(0.95, 0.42, 0.42), Color(0.86, 0.36, 0.72), Color(0.62, 0.44, 0.92), Color(0.98, 0.62, 0.28), Color(0.99, 0.78, 0.62), Color(0.52, 0.68, 0.98)]
var decor_goal_cap_colors: Array[Color] = [Color(1.0, 0.78, 0.30), Color(0.98, 0.52, 0.66), Color(0.78, 0.52, 1.0), Color(1.0, 0.62, 0.36)]
var decor_frozen_cap_colors: Array[Color] = [Color(0.70, 0.84, 1.0), Color(0.82, 0.78, 1.0), Color(0.62, 0.74, 0.96)]
var decor_stem_color := Color(0.95, 0.89, 0.80)
var decor_spot_color := Color(1.0, 0.97, 0.90)
var decor_glow_colors: Array[Color] = [Color(1.0, 0.55, 0.92, 0.16), Color(0.55, 0.82, 1.0, 0.16), Color(1.0, 0.78, 0.45, 0.16)]
var decor_rock_size := Vector2(26.0, 64.0)
var decor_pebble_size := Vector2(5.0, 13.0)
var decor_rock_colors: Array[Color] = [Color(0.42, 0.27, 0.36), Color(0.50, 0.33, 0.40), Color(0.36, 0.24, 0.33)]
var decor_crystal_size := Vector2(30.0, 78.0)
var decor_crystal_colors := {&"cave": Color(0.92, 0.50, 0.86), &"hot": Color(1.0, 0.68, 0.30), &"fire": Color(1.0, 0.48, 0.30), &"cold": Color(0.66, 0.86, 1.0), &"goal": Color(1.0, 0.80, 0.50)}
var decor_bone_color := Color(0.90, 0.86, 0.76)
var decor_root_color := Color(0.42, 0.26, 0.24)
var decor_dead_root_color := Color(0.66, 0.52, 0.38)
var decor_charred_color := Color(0.16, 0.12, 0.13)
var decor_vine_leaf_colors: Array[Color] = [Color(0.66, 0.40, 0.78), Color(0.84, 0.46, 0.70)]
var decor_moss_colors: Array[Color] = [Color(0.56, 0.32, 0.60), Color(0.68, 0.38, 0.56), Color(0.48, 0.30, 0.52)]
var decor_puddle_color := Color(0.20, 0.18, 0.40, 0.85)
var decor_ice_color := Color(0.78, 0.90, 1.0, 0.85)
var decor_frost_color := Color(0.94, 0.97, 1.0, 0.9)
var decor_ash_color := Color(0.42, 0.40, 0.42)
var decor_ember_color := Color(1.0, 0.56, 0.18)
var decor_glow_crack_color := Color(1.0, 0.52, 0.16)
var decor_stalagmite_size := Vector2(22.0, 44.0)
var decor_stalactite_size := Vector2(18.0, 48.0)
var decor_icicle_size := Vector2(18.0, 46.0)
## Hanging roots, vines and glow worms: length range, never more than this share of the free height below.
var decor_hang_length := Vector2(70.0, 190.0)
var decor_hang_max_share := 0.42
var decor_glow_worm_colors: Array[Color] = [Color(0.55, 0.88, 1.0), Color(1.0, 0.62, 0.92), Color(1.0, 0.86, 0.50)]
var decor_glow_pulse_hz := 0.35
## Far silhouettes behind the play layer, with their own parallax (share of the camera travel).
## Opaque, so the far shapes cost no blending at full phone resolution.
var decor_back_colors := {&"cave": Color(0.16, 0.13, 0.30), &"hot": Color(0.24, 0.13, 0.18), &"fire": Color(0.14, 0.10, 0.13), &"cold": Color(0.12, 0.16, 0.30), &"goal": Color(0.21, 0.14, 0.31)}
var decor_back_height := Vector2(150.0, 330.0)
var decor_back_feather := 2.0
var decor_back_parallax := Vector2(0.035, 0.015)
## Near shapes over the play layer: only at the ceiling of rooms at least decor_front_min_room cells tall.
var decor_front_color := Color(0.05, 0.03, 0.07)
var decor_front_feather := 3.0
var decor_front_min_room := 6
var decor_front_hang := Vector2(26.0, 60.0)
## Reactions: a spring per mushroom (squash) and per hanging piece (sway).
var decor_squash_stiffness := 210.0
var decor_squash_damping := 9.0
var decor_squash_max := 0.5
var decor_squash_touch := 0.22
var decor_squash_speed_gain := 0.00045
var decor_land_radius := 230.0
var decor_land_speed := 320.0
var decor_land_kick := 0.38
var decor_fast_speed := 430.0
var decor_sway_stiffness := 26.0
var decor_sway_damping := 2.6
var decor_sway_gain := 0.0011
var decor_sway_max := 0.7
var decor_spore_count := Vector2i(5, 9)
var decor_spore_life := 1.7
var decor_spore_max := 72
var decor_glint_period := Vector2(2.5, 5.5)
## Drops from the ceiling: seconds of one drop cycle and the fall acceleration.
var decor_drop_period := 2.8
var decor_drop_gravity := 1500.0
var decor_drop_color := Color(0.72, 0.78, 1.0, 0.85)
## Idle sway of hanging pieces (radians) and the width of a mesh section of the static layers, in cells.
var decor_idle_sway := 0.035
var decor_section_cells := 32
## Keeps the painted decoration layout in user:// for the next start of the same game build and level.
var decor_cache := true
## Performance panel switch: off freezes every decoration motion (idle and reactive) and stops its scripts.
var fx_decor_motion := true

# Temperature: one value per slime, -1 (ice cube) through 0 (gelatin) to +1 (melted liquid), plus the fuel of a fire.
# Zones push the value at their rate per second; with no push it relaxes back to 0 after a delay.
var temp_heat_rate := 1.0 / 1.3
var temp_cold_rate := 1.0 / 2.2
## A hot zone or flames on a frozen body thaw it this much faster than the hot zone melts gelatin.
var temp_thaw_boost := 3.0
## Flames and a burning body push a frozen body up to 0 at this rate (fire alone never melts the slime).
var temp_fire_thaw_rate := 1.0 / 0.45
var temp_melt_recover_delay := 0.35
var temp_melt_recover_rate := 1.0 / 0.9
var temp_frost_recover_delay := 0.5
var temp_frost_recover_rate := 1.0 / 3.0
## Hysteresis of the liquid and cube flags, on melt and frost (0..1).
var temp_liquid_enter := 0.85
var temp_liquid_exit := 0.5
var temp_cube_enter := 0.9
var temp_cube_exit := 0.7
## Below this |temperature| the phase is SOLID.
var temp_phase_epsilon := 0.03
## Flames ignite a frozen body only when its frost is at most this.
var temp_ignite_max_frost := 0.3
## How fast the drawn body follows the temperature (per second).
var temp_body_smooth := 9.0

# Melted slime: flat, wide and runny; it seeps through grates and flows through pipes.
var melt_speed_share := 0.82
var melt_jump_share := 0.55
var melt_body_sx := 1.8
var melt_body_sy := 0.4
var melt_wobble_stiffness := 0.45
## Puddle collider: height and width in shares of the body diameter.
var melt_collider_height := 0.4
var melt_collider_width := 1.75
## Goo per second that the melt trail costs at full melt; it leaves in real pieces, like the run cost.
var melt_trail_per_second := 3.0
var melt_trail_interval := 0.22
var melt_trail_start := 0.3
var melt_trail_min_mass := 40.0
var melt_trail_piece_speed := Vector2(30.0, 40.0)
var melt_trail_pulse_ref := 0.66
var melt_drip_interval := 0.07
var melt_drip_radius := Vector2(2.5, 4.5) * character_scale
var melt_drip_life := 3.5
var melt_step_volume_db := -4.0
var melt_body_color := Color(0.82, 0.98, 0.35)
var melt_body_tint := 0.22
var melt_body_glow := 0.25

# Ice cube: slow and rigid on rock, fast on ice; smashes crystal by a slide or a fall; spikes cannot pierce it.
var cube_speed_share := 0.42
var cube_jump_share := 0.6
var cube_accel_share := 0.55
var cube_ice_top_speed := 560.0 * character_speed_scale
var cube_ice_accel := 640.0
var cube_ice_decel := 110.0
var cube_break_speed := 300.0
var cube_pound_speed := 650.0
## Share of the speed that the cube keeps after it smashes a crystal.
var cube_break_keep := 0.82
var cube_immune_sources: Array[StringName] = [&"spikes"]
var cube_immune_feedback_interval := 0.3
var cube_lock_feedback_interval := 0.3
## Goo or a prop that touches the cube: one soft sign, at most once in this time, and never a camera move.
var cube_refuse_feedback_interval := 1.2
var cube_refuse_volume_db := -12.0
var cube_freeze_shake := 0.25
var cube_freeze_punch := 0.04
var cube_superellipse := 7.0
var cube_half_size := 0.9
var cube_land_shake := 0.35
var cube_land_punch := 0.05
var cube_land_volume_db := -2.0
var cube_slide_sound_interval := 0.16
var frost_body_color := Color(0.74, 0.92, 1.0)
var frost_body_tint := 0.78
var frost_body_glow := 0.18
var frost_crust_color := Color(0.92, 0.98, 1.0, 0.85)
var frost_crack_color := Color(1.0, 1.0, 1.0, 0.55)
var frost_glint_color := Color(0.85, 0.98, 1.0)
var frost_breath_color := Color(0.9, 0.97, 1.0, 0.35)
var frost_shard_colors: Array[Color] = [Color(0.85, 0.96, 1.0), Color(0.62, 0.84, 0.98), Color(1.0, 1.0, 1.0)]

# Fire: burns fire_fuel goo in fire_duration seconds, in pulses; the burned goo evaporates (lost, reason "burned").
var fire_fuel := 0.5 * mass_max
var fire_duration := 8.0
var fire_pulse_interval := 0.4
var fire_haptic_strength := 0.9
var fire_body_color := Color(1.0, 0.34, 0.06)
var fire_body_tint := 0.22
var fire_body_glow := 1.0
var fire_pulse_glow := 0.35
# Fire look (scripts/fire): one shader for flames, smoke, glows and embers, animated on TIME; geometry made once.
## Temperature colours of fire, hot to cool: the white-yellow core, the yellow body, the orange and the deep red tips.
var fire_core_color := Color(1.0, 0.95, 0.78)
var fire_yellow_color := Color(1.0, 0.76, 0.24)
var fire_orange_color := Color(1.0, 0.4, 0.07)
var fire_red_color := Color(0.6, 0.07, 0.03)
## Light a fire throws, as soft additive shapes: a warm wash in the air and a pool on the floor.
var fire_glow_color := Color(1.0, 0.42, 0.1, 0.2)
var fire_floor_light_color := Color(1.0, 0.5, 0.18, 0.3)
## Noise texture made at load: seed and the feature frequency (per texel of a 128 texel tile) of each channel.
var fire_noise_seed := 1709
var fire_noise_coarse_frequency := 0.03
var fire_noise_fine_frequency := 0.06
## Shader: rise of the tongues (px/s), tongue size and height swell size along the fire (px), swell speed, inner
## flame speed against the outer one, how hard the noise tears the upper flame, brightness, and the share of a flame
## that hides what is behind it.
var fire_rise_speed := 150.0
var fire_tongue_px := 30.0
var fire_swell_px := 80.0
var fire_swell_speed := 0.35
var fire_inner_speed := 1.6
var fire_erosion := 1.0
var fire_flame_gain := 1.2
var fire_flame_cover := 0.1
var fire_glow_noise := 0.5
## Thin smoke over the flame tips (rgb colour, a strength) and how far over the flames it rises, in flame heights.
var fire_smoke_color := Color(0.34, 0.3, 0.32, 0.22)
var fire_smoke_reach := 1.6
## Heat of the outer flames from a weak to a strong fire; the cheap fire (one layer) burns a bit hotter.
var fire_outer_heat := Vector2(0.55, 0.82)
var fire_single_layer_heat := 1.15
## Air: lean per px/s of motion (in flame heights), its limit, the spring and its damping ratio, and how much the
## air streaming along a flame stretches or squeezes it, with the length range.
var fire_lean_per_speed := 1.0 / 420.0
var fire_lean_max := 1.5
var fire_lean_stiffness := 90.0
var fire_lean_damping := 0.55
var fire_lean_stretch := 0.45
var fire_lean_length_range := Vector2(0.6, 1.6)
## Slime fire: flame height at full size, how far below the sides the flames reach (share of the radius), and the
## size clamp of a small or large body.
var fire_body_flame_height := 50.0 * character_scale
var fire_body_side_reach := 0.35
var fire_body_size_range := Vector2(0.3, 1.6)
## Glow inside the burning gelatin, the warm rim in the air over it, and the light radius in body radii.
var fire_body_glow_color := Color(1.0, 0.5, 0.12, 0.4)
var fire_body_halo := 0.35
var fire_body_light_radius := 3.0
## Visual strength of a fire with its fuel nearly gone, and how fast the strength follows the fuel.
var fire_min_power := 0.3
var fire_power_rise := 6.0
var fire_power_fall := 1.5
## Strength of the fire while the slime flows through a pipe (no air in there).
var fire_flow_power := 0.15
## Flicker amplitude of a fire near its end and of a new, wild fire.
var fire_flicker_calm := 0.15
var fire_flicker_wild := 0.42
## Seconds for a new fire to run from the touch point over the body, and the width of its front (radians).
var fire_spread_time := 0.32
var fire_spread_soft := 0.9
## The end of a fire: burned out (a last flare, then the flames sink), and put out or killed (fast).
var fire_die_time := 0.7
var fire_die_flare := 0.9
var fire_quench_time := 0.14
## Sparks (CPUParticles2D): pool of a slime fire and per tile of floor flames, life, spread (degrees), speed, lift of
## the hot air (px/s²), drag, swirl (tangential px/s²), size scale of the streak texture, and the fire strength below
## which a fire sheds none.
var fire_body_spark_amount := 24
var fire_bed_sparks_per_tile := 10
var fire_spark_life := 0.9
var fire_spark_spread := 28.0
var fire_spark_speed := Vector2(90.0, 260.0)
var fire_spark_lift := 160.0
var fire_spark_drag := Vector2(40.0, 120.0)
var fire_spark_swirl := 260.0
var fire_spark_scale := Vector2(0.6, 1.2)
var fire_spark_min_power := 0.12
## Puffs (one-shot CPUParticles2D): the white steam of a quenched fire and the dark smoke of a death. Count, life,
## speed, lift, drag, size range in body radii, colours.
var fire_quench_steam := 30
var fire_puff_life := 1.3
var fire_puff_speed := Vector2(60.0, 200.0)
var fire_puff_lift := 120.0
var fire_puff_drag := 90.0
var fire_puff_size := Vector2(1.1, 2.0)
var fire_steam_color := Color(0.95, 0.97, 1.0, 0.75)
var fire_death_smoke_color := Color(0.25, 0.22, 0.24, 0.6)
## Carried fire (FireTorch): flame size and glow size in object radii, spark pool and spark size, and the flare of a
## bounce (extra flame share and seconds to fade).
var fire_torch_core := 0.9
var fire_torch_glow_size := 3.5
var fire_torch_spark_amount := 10
var fire_torch_spark_scale := 0.8
var fire_torch_flare := 0.5
var fire_torch_flare_time := 0.25
## Heat shimmer: the largest bend in screen pixels, the rise speed, its strength, and its height in body radii.
var fire_haze_bend_px := 4.0
var fire_haze_rise_speed := 0.9
var fire_haze_strength := 0.85
var fire_haze_height := 2.8
## Draw layer of the shimmer: over the goo, the props and the sparks.
var fire_haze_z_index := 3
## Share of the sparks the cheap fire keeps (Tuning.fx_fire_rich off: no shimmer, no inner flame).
var fire_cheap_spark_share := 0.5
## Sound: roar loop volume and pitch from a weak to a strong fire, the extra rush when moving fast, the hearing range,
## and the crackle one-shots (seconds between them at full strength, volume range).
var fire_roar_db := Vector2(-22.0, -9.0)
var fire_roar_pitch := Vector2(0.8, 1.05)
var fire_roar_rush_db := 4.0
var fire_roar_rush_speed := 700.0
var fire_roar_distance := 1600.0
var fire_crackle_interval := Vector2(0.05, 0.28)
var fire_crackle_db := Vector2(-16.0, -7.0)
var fire_ignite_flash := Color(1.0, 0.55, 0.15, 0.3)
var fire_ignite_shake := 0.35
var fire_ignite_punch := 0.05
var fire_out_volume_db := -2.0

# Ember shots: a shot spat while burning is a hot ember that hits harder and leaves burning embers on the ground.
var ember_damage := 2
var ember_core := Color(1.0, 0.93, 0.6)
var ember_hot := Color(1.0, 0.42, 0.1)
var ember_pulse_hz := 7.0
## Seconds an ember prop takes to cool once its shot is spent (look only): flame, then glow, then a dark warm rock.
var ember_cool_time := 2.6
## Look of an ember prop: heat steps of the rock drawing, the tint of the hot and of the cooling rock and its share,
## the speed at which its flame is full after the shot, the heat below which only a glow is left, the fire sparks of a
## bounce, and how many embers burn with a flame at one time (the oldest past it keeps the glow only).
var ember_heat_steps := 8
var ember_rock_hot := Color(0.95, 0.42, 0.16)
var ember_rock_warm := Color(0.36, 0.17, 0.12)
var ember_rock_tint := 0.75
var ember_flame_speed := 520.0
var ember_glow_heat := 0.45
var ember_bounce_sparks := 10
var ember_flame_max := 4
var ember_trail_color := Color(1.0, 0.36, 0.06, 0.85)
var ember_trail_width := 1.25
var ember_shed_step := 22.0 * character_scale
var ember_shed_speed := Vector2(40.0, 140.0)
var ember_ground_life := Vector2(2.2, 3.0)
var ember_radius := 3.0 * character_scale
var ember_hit_radius := 14.0 * character_scale
var ember_hit_interval := 0.5
var ember_check_ticks := 3
var ember_max := 96
var ember_gravity := 1400.0
## Look of an ember on the ground: share of life above which it has a tiny flame and a thread of smoke.
var ember_flame_share := 0.5
## Physics ticks between two heat updates of a resting ember.
var ember_view_ticks := 6

# Pipes: a liquid slime on a drain flows through the pipe by itself and comes out at the other end.
var pipe_radius := 13.0 * character_scale
var pipe_rim := 4.0 * character_scale
var pipe_flow_speed := 820.0
var pipe_enter_time := 0.2
var pipe_exit_speed := 380.0
var pipe_exit_cooldown := 0.6
var pipe_exit_punch := 0.03
var pipe_body_radius := 11.0 * character_scale
var pipe_color := Color(0.26, 0.24, 0.3)
var pipe_rim_color := Color(0.55, 0.5, 0.56)
var pipe_glass_color := Color(1.0, 1.0, 1.0, 0.16)
var pipe_glow_color := Color(0.75, 1.0, 0.4, 0.5)
var pipe_drip_interval := 0.05
var grate_bar_width := 5.0 * character_scale
var grate_bar_gap := 9.0 * character_scale
var grate_color := Color(0.42, 0.38, 0.44)
var grate_light := Color(0.72, 0.66, 0.68)

# Zone art: heat haze and vents, cold mist and snow, flames. Each zone is one batched draw.
var heat_rock_tint := Color(1.0, 0.62, 0.42)
## Warm and ice rock tints blend into the plain rock over this many cells on each side of a grid corner, and fade
## from full at depth x to none at depth y (cells below the surface).
var surface_tint_blend_cells := 2
var surface_tint_depth := Vector2(1.0, 3.0)
## Zone looks (heat glow, cold tint) fade out over this many tiles at their open left and right ends.
var zone_edge_fade_tiles := 2.0
var heat_lip_color := Color(1.0, 0.55, 0.25)
var heat_glow_color := Color(1.0, 0.45, 0.15, 0.2)
var heat_haze_color := Color(1.0, 0.85, 0.65, 0.1)
var heat_haze_count := 9
var heat_haze_speed := 60.0
var heat_vent_spacing := 4
var heat_vent_color := Color(0.2, 0.1, 0.08)
var heat_vent_glow := Color(1.0, 0.5, 0.15, 0.85)
var heat_steam_color := Color(1.0, 0.95, 0.9, 0.16)
var heat_steam_interval := Vector2(0.6, 1.3)
var ice_rock_tint := Color(0.66, 0.86, 1.0)
var ice_lip_color := Color(0.88, 0.97, 1.0)
var cold_mist_color := Color(0.85, 0.94, 1.0, 0.09)
var cold_mist_count := 7
var cold_snow_count := 28
var cold_snow_color := Color(1.0, 1.0, 1.0, 0.55)
var cold_tint_color := Color(0.55, 0.8, 1.0, 0.06)
## Floor flames (scripts/fire/fire_bed.gd): bed height in tiles.
var fire_bed_height := 2.0
## Draw layer of the floor flames: over the goo, so a slime in the flames is inside the fire.
var fire_bed_z_index := 2
## Light: strength of the warm wash against a slime fire, and its reach past the bed ends in tiles.
var fire_bed_light := 1.3
var fire_bed_light_reach := 2.5
## Shimmer height in bed heights.
var fire_bed_haze_height := 1.9
## Wake of the slime: how far it reaches (px) and how hard it bends the flames.
var fire_bed_wake_reach := 220.0
var fire_bed_wake := 0.9
## Roar of the bed and the screen margin within which it plays.
var fire_bed_roar_db := -10.0
var fire_bed_roar_pitch := 0.9
var fire_bed_listen_margin := 500.0

# Haptics of the temperature (merged into haptics_presets at load)
var temperature_haptic_presets := {
	&"ignite": {"low": 0.9, "high": 0.6, "ms": 160.0, "fade": true, "phone_ms": 90.0, "phone_amp": 0.85, "prio": 4, "cooldown_ms": 0.0, "floor": 1.0},
	&"fire_out": {"low": 0.2, "high": 0.5, "ms": 120.0, "fade": true, "phone_ms": 50.0, "phone_amp": 0.5, "prio": 3, "cooldown_ms": 0.0, "floor": 1.0},
	&"freeze": {"low": 0.5, "high": 0.2, "ms": 60.0, "pulses": 2, "gap_ms": 60.0, "phone_ms": 30.0, "phone_amp": 0.55, "prio": 3, "cooldown_ms": 300.0, "floor": 1.0},
	&"melt": {"low": 0.25, "high": 0.0, "ms": 140.0, "fade": true, "phone_ms": 40.0, "phone_amp": 0.3, "prio": 2, "cooldown_ms": 300.0, "floor": 1.0},
	&"ice_lock": {"low": 0.0, "high": 0.6, "ms": 30.0, "pulses": 2, "gap_ms": 40.0, "phone_ms": 14.0, "phone_amp": 0.55, "prio": 2, "cooldown_ms": 200.0, "floor": 1.0},
	&"cube_smash": {"low": 1.0, "high": 0.4, "ms": 180.0, "fade": true, "phone_ms": 100.0, "phone_amp": 1.0, "prio": 4, "cooldown_ms": 0.0, "floor": 1.0},
	&"pipe_flow": {"low": 0.15, "high": 0.2, "ms": 40.0, "pulses": 4, "gap_ms": 50.0, "phone_ms": 20.0, "phone_amp": 0.3, "prio": 2, "cooldown_ms": 300.0, "floor": 1.0},
}


func _init() -> void:
	haptics_presets.merge(temperature_haptic_presets)
