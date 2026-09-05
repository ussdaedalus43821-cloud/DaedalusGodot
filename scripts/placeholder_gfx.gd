class_name PlaceholderGfx
extends RefCounted

## No art assets ship with this project (see assets/README inside each
## folder) -- every ship, projectile and particle is a procedural vector
## shape or a generated dot texture instead. This is the one place that
## generates the dot: GPUParticles2D needs *some* texture to render a
## visible point rather than depending on an unspecified engine default,
## so trails and impact bursts all pull from here.
##
## Built once per unique (size, color) pair and cached, since a shot fired
## every 0.073s has no business re-rasterising an image that often.

static var _cache: Dictionary = {}


static func dot_texture(size: int = 10, color: Color = Color.WHITE) -> ImageTexture:
	var key := "%d:%s" % [size, color.to_html(true)]
	if _cache.has(key):
		return _cache[key]

	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(size, size) * 0.5
	var radius := size * 0.5
	for y in range(size):
		for x in range(size):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(center)
			var falloff := clampf(1.0 - d / radius, 0.0, 1.0)
			image.set_pixel(x, y, Color(color.r, color.g, color.b, color.a * falloff))

	var tex := ImageTexture.create_from_image(image)
	_cache[key] = tex
	return tex


## Ported from the Python prototype's draw_shield_bubble(): three
## deliberately distinct states --
##   - a steady translucent ring, fainter as the shield drains
##   - a bright rim ripple centred on the impact side when a hit is
##     absorbed and the shield holds
##   - a white bubble-pop flare when the shield collapses
## Nothing is drawn for a raw hull hit (frac/flash/break_flash all ~0),
## matching the original.
##
## Call this from inside the ship's own _draw() (canvas = self), in ITS
## own local space -- hit_dir_local must already be the world-space hit
## direction rotated by -rotation, since a plain world-space angle would
## visibly spin along with a turning ship otherwise.
static func draw_shield_bubble(canvas: CanvasItem, radius: float, frac: float,
		flash: float, hit_dir_local: Vector2, base_col: Color, break_flash: float) -> void:
	if frac <= 0.001 and flash <= 0.001 and break_flash <= 0.001:
		return

	if frac > 0.001 or flash > 0.001:
		var ring_a := clampf((20.0 + 80.0 * frac + 150.0 * flash) / 255.0, 0.0, 200.0 / 255.0)
		canvas.draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48,
				Color(base_col.r, base_col.g, base_col.b, ring_a), 2.0)

	if flash > 0.001:
		var ctr := hit_dir_local.angle()
		var rip := Color(
				minf(base_col.r + 70.0 / 255.0, 1.0),
				minf(base_col.g + 70.0 / 255.0, 1.0),
				minf(base_col.b + 70.0 / 255.0, 1.0),
				(230.0 / 255.0) * minf(1.0, flash / 0.22))
		canvas.draw_arc(Vector2.ZERO, radius, ctr - PI / 5.0, ctr + PI / 5.0, 12, rip, 4.0)

	if break_flash > 0.001:
		var t := clampf(break_flash / 0.4, 0.0, 1.0)
		canvas.draw_arc(Vector2.ZERO, radius + (1.0 - t) * 16.0, 0.0, TAU, 48,
				Color(235.0 / 255.0, 245.0 / 255.0, 1.0, (220.0 / 255.0) * t),
				maxf(2.0, 1.0 + 4.0 * t))
