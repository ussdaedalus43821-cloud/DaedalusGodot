shader_type canvas_item;

// Ship renders are shipped as plain JPEGs on a solid black backdrop
// (JPEG has no alpha channel at all), so this keys near-black pixels
// out to transparent at render time instead -- no external image tool
// needed to pre-cut a texture. threshold is the luma level below which
// a pixel is treated as pure background; feather softens the cutoff
// over a small luma range so the ship's edge doesn't come out jagged.
uniform float threshold : hint_range(0.0, 1.0) = 0.045;
uniform float feather : hint_range(0.0, 0.2) = 0.03;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float luma = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
	float key = smoothstep(threshold, threshold + feather, luma);
	// Incoming COLOR at this point is the vertex-stage modulate/
	// self_modulate tint (Player.modulate.a = 0.35 while cloaked, for
	// instance) -- multiplying it in rather than overwriting COLOR
	// outright keeps that working for this sprite exactly like it
	// already does for every other child node.
	COLOR = tex * COLOR;
	COLOR.a *= key;
}
