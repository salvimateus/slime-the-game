extends RefCounted
## Every on-screen text. Keep glyphs inside the default font (no arrows, no emoji).
## A text names no key, button or touch control: hints that need one are input icons (scripts/ui/input_hints.gd).

const TEXT := {
	&"hint_swallow": "Roll into rocks to swallow them\nBigger slime, more room. Smaller slime, more speed",
	&"hint_mite": "Mites bite! Two hits pop them",
	&"hint_splash": "Big drops make you splash!",
	&"hint_slurp": "Roll over your goo to slurp it back",
	&"hint_spikes": "Spikes tear goo off you",
	&"hint_saw": "Saws shred loose goo",
	&"hint_shaft": "Hop down the ledges",
	&"hint_small": "Too small and you pop",
	&"hint_goal": "The pond!",
	&"toast_checkpoint": "Checkpoint!",
	&"hud_deaths": "Pops %d",
	&"complete_title": "Level complete!",
	&"complete_time": "Time  %s",
	&"complete_deaths": "Pops  %d",
	&"complete_lost": "Goo lost  %d",
	&"complete_recovered": "Goo slurped back  %d",
	# Short labels beside the input icons (scripts/ui/input_hints.gd).
	&"glyph_move": "Move",
	&"glyph_jump": "Jump",
	&"glyph_jump_higher": "Hold: jump higher",
	&"glyph_oneway": "Up through planks",
	&"glyph_spit": "Quick spit",
	&"glyph_aim": "Aim & spit",
	&"glyph_again": "Play again",
	&"glyph_run": "Run",
	&"glyph_run_cost": "Running drips goo",
	&"glyph_dodge": "Dodge back",
	&"glyph_roll": "Roll",
	&"glyph_skid": "Turn back: skid",
	&"glyph_double_jump": "Again in the air",
	&"glyph_crouch": "Crouch under low gaps",
	&"glyph_wall": "Stick to walls",
	&"glyph_climb": "Climb",
	&"glyph_let_go": "Let go",
	&"glyph_heat": "Heat melts you to goo",
	&"glyph_heat_flow": "Seep down grates",
	&"glyph_fire": "Fire burns your goo!",
	&"glyph_fire_spit": "Spit hot embers",
	&"glyph_cold": "Spikes can't hurt ice",
	&"glyph_cold_slide": "Slide, smash crystal",
	&"glyph_cold_locked": "No swallow, no spit",
}
## Replaces a TEXT entry while the touch controls are in use.
const TOUCH_TEXT := {
	&"glyph_aim": "Drag to aim, let go to spit",
}


static func text(key: StringName, touch := false) -> String:
	if touch and TOUCH_TEXT.has(key):
		return TOUCH_TEXT[key]
	return TEXT.get(key, String(key))
