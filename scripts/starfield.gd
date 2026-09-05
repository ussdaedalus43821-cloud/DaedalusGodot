class_name Starfield
extends Node2D

## A multi-layer parallax starfield, ported from the Python prototype's
## draw_starfield(): three fixed-density star layers at different depths
## that tile seamlessly as the camera moves, plus a hyperdrive "warp
## streak" effect that stretches every star into a line pointing away
## from the ship's heading while the drive is charging or in transit.
##
## Built entirely in code (see game.gd's _setup_background()) rather
## than as a .tscn, matching every other UI piece in this project --
## this environment cannot open the Godot editor to check a hand-written
## scene layout, but a Node2D built by a few lines of GDScript can be
## checked by reading it.

const TILE_SIZE := Vector2(1600.0, 900.0)

## (parallax factor, star count, colour) -- identical to Python's
## STARFIELD_LAYERS, nearest layer last so it draws on top of the rest.
const LAYER_SPECS := [
	{"parallax": 0.30, "count": 90, "color": Color(80.0 / 255.0, 82.0 / 255.0, 110.0 / 255.0)},
	{"parallax": 0.55, "count": 70, "color": Color(140.0 / 255.0, 143.0 / 255.0, 175.0 / 255.0)},
	{"parallax": 0.85, "count": 46, "color": Color(205.0 / 255.0, 208.0 / 255.0, 235.0 / 255.0)},
]

var game: Game = null
var player: Player = null

var _layers: Array = []   # [{parallax: float, color: Color, stars: [[Vector2, float], ...]}]


func setup(g: Game, p: Player) -> void:
	game = g
	player = p
	_generate_stars()
	set_process(true)
	z_index = -10


func _generate_stars() -> void:
	_layers.clear()
	for spec in LAYER_SPECS:
		var stars: Array = []
		for i in range(int(spec["count"])):
			stars.append([
				Vector2(randf_range(0.0, TILE_SIZE.x), randf_range(0.0, TILE_SIZE.y)),
				randf_range(1.0, 2.2),
			])
		_layers.append({"parallax": spec["parallax"], "color": spec["color"], "stars": stars})


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if player == null or game == null:
		return

	var streak := 0.0
	if game.hyper_state == "charging":
		streak = game.hyper_progress
	elif game.hyper_state == "travel":
		streak = 1.0
	var travel_dir := -Vector2.RIGHT.rotated(player.rotation)

	var cam := player.global_position
	for layer in _layers:
		var parallax: float = layer["parallax"]
		var color: Color = layer["color"]
		var origin := cam * parallax
		var tile_origin := cam - TILE_SIZE * 0.5
		for star in layer["stars"]:
			var base: Vector2 = star[0]
			var size: float = star[1]
			var x := fposmod(base.x - origin.x, TILE_SIZE.x)
			var y := fposmod(base.y - origin.y, TILE_SIZE.y)
			var pos := tile_origin + Vector2(x, y)
			if streak > 0.05:
				var length := 4.0 + streak * 90.0 * parallax
				draw_line(pos, pos + travel_dir * length, color, maxf(1.0, size))
			elif size > 1.6:
				draw_circle(pos, size, color)
			else:
				draw_rect(Rect2(pos, Vector2.ONE), color)
