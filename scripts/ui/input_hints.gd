extends RefCounted
## Hints shown as input icons (drawn by scripts/ui/input_glyphs.gd): hint key -> rows. A key that is not here shows
## its Strings text, so a new hint can start as plain text.
## A row has "steps", a "label" (a Strings key) and, when the touch controls need other steps, "touch" steps.
## A step has "actions" (InputMap actions), "press" (tap, hold, dir or drag) and, from the second step on, "join"
## (plus: at the same time, then: after the step before). The icons come from the bindings of the actions.
## "single": true shows only the main binding; "crossed": true crosses the input out (the state blocks it).
## A step can be a slime state instead: {"state": flame, snow, cube or drop}.

const HINTS := {
	&"hint_move": [
		{"steps": [{"actions": [&"move_left", &"move_right"], "press": &"dir"}], "label": &"glyph_move"},
	],
	&"hint_jump": [
		{"steps": [{"actions": [&"jump"], "press": &"tap"}], "label": &"glyph_jump"},
		{"steps": [{"actions": [&"jump"], "press": &"hold"}], "label": &"glyph_jump_higher"},
	],
	&"hint_oneway": [
		{"steps": [{"actions": [&"jump"], "press": &"tap"}], "label": &"glyph_oneway"},
	],
	&"hint_spit": [
		{"steps": [{"actions": [&"shoot"], "press": &"tap"}], "label": &"glyph_spit"},
	],
	&"hint_aim": [
		{
			"steps": [
				{"actions": [&"aim"], "press": &"hold"},
				{"actions": [&"aim_up", &"aim_right", &"aim_down", &"aim_left"], "press": &"dir", "join": &"plus"},
				{"actions": [&"fire"], "press": &"tap", "join": &"then"},
			],
			"touch": [{"actions": [&"aim"], "press": &"drag"}],
			"label": &"glyph_aim",
		},
	],
	&"hint_run": [
		{"steps": [{"actions": [&"run"], "press": &"hold"}], "label": &"glyph_run"},
	],
	&"hint_run_cost": [
		{"steps": [{"actions": [&"run"], "press": &"hold"}], "label": &"glyph_run_cost"},
	],
	&"hint_dodge": [
		{"steps": [{"actions": [&"dodge"], "press": &"tap"}], "label": &"glyph_dodge"},
		{
			"steps": [
				{"actions": [&"move_left", &"move_right"], "press": &"dir"},
				{"actions": [&"dodge"], "press": &"tap", "join": &"plus"},
			],
			"label": &"glyph_roll",
		},
	],
	&"hint_skid": [
		{
			"steps": [
				{"actions": [&"run"], "press": &"hold"},
				{"actions": [&"move_right"], "press": &"dir", "join": &"plus"},
				{"actions": [&"move_left"], "press": &"dir", "join": &"then"},
			],
			"touch": [
				{"actions": [&"run"], "press": &"hold"},
				{"actions": [&"move_left"], "press": &"dir", "join": &"then"},
			],
			"label": &"glyph_skid",
		},
	],
	&"hint_double_jump": [
		{
			"steps": [
				{"actions": [&"jump"], "press": &"tap"},
				{"actions": [&"jump"], "press": &"tap", "join": &"then"},
			],
			"label": &"glyph_double_jump",
		},
	],
	&"hint_crouch": [
		{"steps": [{"actions": [&"crouch"], "press": &"dir"}], "label": &"glyph_crouch"},
	],
	&"hint_wall": [
		{
			"steps": [
				{"actions": [&"jump"], "press": &"tap"},
				{"actions": [&"move_right"], "press": &"dir", "join": &"then"},
			],
			"label": &"glyph_wall",
		},
		{"steps": [{"actions": [&"jump"], "press": &"tap"}], "label": &"glyph_climb"},
		{"steps": [{"actions": [&"move_left"], "press": &"dir"}], "label": &"glyph_let_go"},
	],
	&"hint_heat": [
		{"steps": [{"state": &"flame"}, {"state": &"drop", "join": &"then"}], "label": &"glyph_heat"},
		{"steps": [{"actions": [&"move_left", &"move_right"], "press": &"dir", "single": true}], "label": &"glyph_heat_flow"},
	],
	&"hint_fire": [
		{"steps": [{"state": &"flame"}], "label": &"glyph_fire"},
		{"steps": [{"state": &"flame"}, {"actions": [&"shoot"], "press": &"tap", "join": &"plus"}], "label": &"glyph_fire_spit"},
	],
	&"hint_cold": [
		{"steps": [{"state": &"snow"}, {"state": &"cube", "join": &"then"}], "label": &"glyph_cold"},
		{"steps": [{"actions": [&"move_left", &"move_right"], "press": &"dir", "single": true}], "label": &"glyph_cold_slide"},
		{"steps": [{"actions": [&"shoot"], "press": &"tap", "crossed": true}], "label": &"glyph_cold_locked"},
	],
	&"complete_again": [
		{"steps": [{"actions": [&"jump"], "press": &"tap"}], "label": &"glyph_again"},
	],
}
