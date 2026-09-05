shader_type canvas_item;

// Ship renders are shipped as plain JPEGs on a solid black backdrop
// (JPEG has no alpha channel at all), so this keys near-black pixels
// out to transparent at render time instead -- no external image tool
// needed to pre-cut a texture. threshold is the luma level below which
// a pixel is treated as pure background; feather softens the cutoff
// over a small luma range so the ship's edge doesn't come out jagged.
uniform float threshold : hint_range(0.0, 1.0) = 0.045;
uniform float feather : hint_range(0.0, 0.2) = 0.03;

// The source renders came in underexposed -- rather than requiring a
// re-edited/re-uploaded photo, boost levels here so the same source
// file reads clearly in-game. gamma lifts shadow detail, contrast
// re-punches the midtones gamma flattens, brightness is a final linear
// gain. Tuned for daedalus_hull.jpg; a texture that comes in already
// well-exposed can just override these lower per-material.
uniform float gamma : hint_range(0.1, 3.0) = 1.6;
uniform float contrast : hint_range(0.0, 3.0) = 1.15;
uniform float brightness : hint_range(0.0, 3.0) = 1.6;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	// Keyed on the ORIGINAL luma, before the levels boost below -- so the
	// background cutoff doesn't shift as brightness/gamma are retuned.
	float luma = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
	float key = smoothstep(threshold, threshold + feather, luma);

	vec3 rgb = pow(max(tex.rgb, vec3(0.0)), vec3(1.0 / gamma));
	rgb = (rgb - 0.5) * contrast + 0.5;
	rgb *= brightness;
	rgb = clamp(rgb, 0.0, 1.0);

	// Incoming COLOR at this point is the vertex-stage modulate/
	// self_modulate tint (Player.modulate.a = 0.35 while cloaked, for
	// instance) -- multiplying it in rather than overwriting COLOR
	// outright keeps that working for this sprite exactly like it
	// already does for every other child node.
	COLOR = vec4(rgb, tex.a) * COLOR;
	COLOR.a *= key;
}
