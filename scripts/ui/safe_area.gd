extends RefCounted
## Safe rect of the screen in canvas units: no notch, cutout or system bar, plus the test insets that Harness can fake.


static func rect(viewport: Viewport) -> Rect2:
	var out := Rect2(Vector2.ZERO, viewport.get_visible_rect().size)
	var to_canvas := viewport.get_final_transform().affine_inverse()
	if OS.has_feature("mobile"):
		var window := Rect2(Vector2(DisplayServer.window_get_position()), Vector2(DisplayServer.window_get_size()))
		var safe := Rect2(DisplayServer.get_display_safe_area()).intersection(window)
		if safe.has_area():
			safe.position -= window.position
			out = out.intersection(to_canvas * safe)
	var insets: Vector4 = Harness.safe_insets
	if insets != Vector4.ZERO:
		var k := to_canvas.get_scale().x
		out = out.grow_individual(-insets.x * k, -insets.y * k, -insets.z * k, -insets.w * k)
	return out
