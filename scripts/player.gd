class_name Player
extends CharacterBody2D

## The player's ship. All six hulls run this one script -- everything that
## makes an F-302 handle differently from Atlantis (shield, hull, speed,
## turn, every weapon's damage) comes from Daedalus.get_ship_stats(ship_key)
## at _ready(), never from a per-ship script or scene.
##
## Movement is keyboard rotation (A/D or arrow keys turn directly; the
## touch joystick does the same on a touchscreen) plus forward/reverse
## thrust with exponential damping for inertia -- both rate-limited by
## the ship's own `turn` and `speed` stats, so a Daedalus and an F-302
## feel like different ships without a line of ship-specific movement
## code. There is no mouse-aim: the ship never reacts to cursor
## position, only to an actively held turn key or joystick direction.
##
## Every shot -- guns, rockets, homing, beam -- asks Daedalus "how much
## damage lands" and never computes that itself; this script only decides
## *when* a shot is allowed (cooldowns, ammo, power, range/lock) and hands
## the rest to Projectile / the beam raycast. Atlantis fires guns through
## its omni-broadside array instead of a forward gun (same key, different
## weapon_type -- see daedalus_weapons.nova's own note that omni is the
## primary gun through eight ports); Destiny's five auto-turrets are not
## player-triggered at all, matching their "automated" doctrine -- they
## fire on their own cooldown at the nearest hostile in range.

signal died
signal wingman_requested
signal ship_changed(key: String)
signal power_changed(power: float, power_max: float)
signal shield_changed(shield: float, shield_max: float)
signal hull_changed(hull: float, hull_max: float)
signal cloak_changed(active: bool)
signal beam_state_changed(active: bool, from_pos: Vector2, to_pos: Vector2)

const ACCEL_TIME := 1.4          # seconds to reach max speed from a standstill
const REVERSE_FACTOR := 0.4      # reverse thrust is weaker than forward
const DAMPING := 1.6             # exponential drag per second while idle
const SHIELD_REGEN_FRAC := 0.07  # fraction of shield_max restored per second while charging
const ROCKETS_START := 12
const HOMING_START := 8
const HOMING_SPREAD_DEG := 7.0
const CLOAK_MIN_POWER := 15.0    # cannot engage the cloak below this reserve

## Shield bubble, ported from the Python prototype's draw_shield_bubble()
## and its collision note: "a shot is stopped at the bubble surface
## while shields hold, at the hull once they're down." HULL_HURTBOX_RADIUS
## matches player.tscn's own hurtbox_shape; SHIELD_BUBBLE_RADIUS is that
## + the original's +10 bubble_pad. The Hurtbox's actual CollisionShape2D
## is resized between the two live, in _tick_shield_visual() -- see its
## own comment for why that needs a duplicated (not shared) shape.
const HULL_HURTBOX_RADIUS := 22.0
const SHIELD_BUBBLE_RADIUS := 32.0
const SHIELD_COL := Color(90.0 / 255.0, 170.0 / 255.0, 255.0 / 255.0)

## Replicator infestation, ported from the Python prototype's tick_common():
## a hit only ever KICKSTARTS it (see add_infestation()) -- once started it
## grows toward catastrophic failure on its own over INFEST_DURATION,
## draining hull faster and faster (INFEST_DPS_START -> INFEST_DPS_END,
## plus INFEST_FAILURE_DPS once it reaches 100%), regardless of further
## hits landing. The original also lets repair drones claw a partial cure
## back below a 50% ceiling; this port has no repair-drone system for
## either side at all yet, so that half is deliberately not ported --
## once infested here, there is currently no way to stop it short of
## dying, ending the run, or (per game.gd's _arrive()) jumping sectors.
const INFEST_DURATION := 15.0
const INFEST_DPS_START := 6.0
const INFEST_DPS_END := 55.0
const INFEST_FAILURE_DPS := 160.0

var ship_key := "daedalus"

var stats: Dictionary = {}
var ship_class_name := "battlecruiser"
var hardened := false

var shield := 0.0
var shield_max := 0.0
var shield_flash := 0.0      # rim ripple where a hit was just absorbed
var shield_break := 0.0      # full-bubble flare where the shield just collapsed
var shield_hit_dir := Vector2.RIGHT   # world-space unit vector: ship -> impact
var hull := 0.0
var hull_max := 0.0
var power := 0.0
var power_max := 0.0
var turn_rate := 0.0        # rad/s
var max_speed := 0.0

var rockets := 0
var homing := 0

var cloaked := false
var infested := 0.0
var alive := true

var infinite_ammo := false
var cloak_available := true

var _primary_cd := 0.0
var _rocket_cd := 0.0
var _homing_cd := 0.0
var _turret_cd := 0.0
var _beam_elapsed := 0.0
var _beam_active := false

var projectile_scene: PackedScene = preload("res://scenes/projectile.tscn")
var projectiles_root: Node = null   # assigned by game.gd

@onready var _hurtbox: Area2D = $Hurtbox
@onready var _hurtbox_shape: CollisionShape2D = $Hurtbox/Shape
@onready var _muzzle: Marker2D = $Muzzle
var _hull_poly: Polygon2D = null
var _hull_sprite: Sprite2D = null
var _beam_line: Line2D = null
var _engine_trail: GPUParticles2D = null


func _ready() -> void:
	_hurtbox.add_to_group("player_hull")
	# player.tscn's hurtbox_shape sub-resource is shared across every
	# scene load; duplicating it here means resizing it in
	# _tick_shield_visual() only ever affects this one ship.
	_hurtbox_shape.shape = _hurtbox_shape.shape.duplicate()
	load_ship(ship_key)


## The single choke point for "this player is now flying ship `key`" --
## called from _ready() (initial spawn), game.gd's _cycle_ship() (TAB
## mid-run), and restore() (resuming a saved run). Rebuilding the visual
## and re-emitting every stat signal here, rather than leaving callers to
## remember it, is what keeps a ship switch from leaving stale state
## behind -- previously _cycle_ship() called this alone, which changed
## the ship's stats but left the hull sprite/shape AND the HUD's name
## label and bars showing the ship flown before the switch, including
## through to the death screen.
func load_ship(key: String) -> void:
	ship_key = key
	stats = Daedalus.get_ship_stats(key)
	ship_class_name = String(stats.get("class", "battlecruiser"))
	hardened = bool(stats.get("hardened", false))

	shield_max = float(stats.get("shield", 500.0))
	hull_max = float(stats.get("hull", 300.0))
	max_speed = float(stats.get("speed", 800.0))
	turn_rate = deg_to_rad(float(stats.get("turn", 200.0)))

	shield = shield_max
	hull = hull_max
	power_max = Daedalus.max_power()
	power = power_max
	rockets = ROCKETS_START
	homing = HOMING_START
	alive = true

	_build_visual()
	ship_changed.emit(ship_key)
	power_changed.emit(power, power_max)
	shield_changed.emit(shield, shield_max)
	hull_changed.emit(hull, hull_max)


func get_ship_class() -> String:
	return ship_class_name


## Public so an attacker can stop a beam/line visual at this ship's
## current hurtbox surface -- shield bubble while shields hold, hull once
## they're down -- instead of drawing straight through to its center.
## Same radii _tick_shield_visual() already resizes the collision shape to.
func hurtbox_radius() -> float:
	return SHIELD_BUBBLE_RADIUS if shield > 0.0 else HULL_HURTBOX_RADIUS


func is_hardened() -> bool:
	return hardened


## Everything a resumed run needs back, plus everything a fresh run needs
## from settings -- GameState holds the Dictionary, this script never talks
## to GameState directly beyond that (and the difficulty multiplier in
## take_damage()), so a save format change stays a one-file problem.
func snapshot() -> Dictionary:
	return {
		"ship_key": ship_key, "shield": shield, "hull": hull, "power": power,
		"rockets": rockets, "homing": homing, "infested": infested,
		"position": global_position,
	}


func restore(data: Dictionary) -> void:
	load_ship(String(data.get("ship_key", ship_key)))
	shield = float(data.get("shield", shield))
	hull = float(data.get("hull", hull))
	power = float(data.get("power", power))
	rockets = int(data.get("rockets", rockets))
	homing = int(data.get("homing", homing))
	infested = float(data.get("infested", infested))
	global_position = data.get("position", global_position)


# ==========================================================================
# Visuals -- placeholder colored polygons, no art assets required
# ==========================================================================

const HULL_COLORS := {
	"x302": Color(0.55, 0.85, 1.0),
	"daedalus": Color(0.65, 0.75, 0.95),
	"phoenix": Color(0.75, 0.65, 0.95),
	"aurora": Color(0.55, 0.95, 0.75),
	"destiny": Color(0.85, 0.75, 0.55),
	"atlantis": Color(0.95, 0.85, 0.55),
}

## Real hull art, keyed by ship_key -- a ship not listed here still gets
## the procedural Polygon2D below. path: a plain JPEG (no alpha) shot
## top-down with the nose pointing up the frame; hull_length_px is that
## image's nose-to-tail extent in pixels, used to scale it down to
## HULL_TARGET_LENGTH world units so a real hull matches the size the
## placeholder shapes already fly at.
const HULL_TEXTURES := {
	"daedalus": {"path": "res://assets/ships/daedalus_hull.jpg", "hull_length_px": 892.0},
}
const HULL_TARGET_LENGTH := 46.0   # nose-to-tail span of the default hull shape below
const HULL_KEY_SHADER := preload("res://assets/ships/hull_luma_key.gdshader")

func _build_visual() -> void:
	if _hull_poly != null:
		_hull_poly.queue_free()
		_hull_poly = null
	if _hull_sprite != null:
		_hull_sprite.queue_free()
		_hull_sprite = null

	if HULL_TEXTURES.has(ship_key):
		var spec: Dictionary = HULL_TEXTURES[ship_key]
		_hull_sprite = Sprite2D.new()
		_hull_sprite.texture = load(String(spec["path"]))
		var mat := ShaderMaterial.new()
		mat.shader = HULL_KEY_SHADER
		_hull_sprite.material = mat
		# The source render's nose points up the frame (-Y); this
		# project's forward is local +X (Vector2.RIGHT.rotated(rotation)
		# everywhere else in this file), so the sprite itself needs a
		# fixed +90 degree offset -- independent of the ship's own
		# steering rotation, which still drives the whole Player node.
		_hull_sprite.rotation = deg_to_rad(90.0)
		var scale_factor := HULL_TARGET_LENGTH / float(spec["hull_length_px"])
		_hull_sprite.scale = Vector2(scale_factor, scale_factor)
		add_child(_hull_sprite)
		move_child(_hull_sprite, 0)
		# Sprite2D is centered by default, so the nose sits at roughly
		# half the hull's own nose-to-tail span -- see the muzzle note
		# below for why this needs to track the hull at all.
		_muzzle.position = Vector2(HULL_TARGET_LENGTH * 0.5, 0.0)
	else:
		var hull_shape := _hull_shape_for(ship_class_name)
		_hull_poly = Polygon2D.new()
		_hull_poly.polygon = hull_shape
		_hull_poly.color = HULL_COLORS.get(ship_key, Color.WHITE)
		add_child(_hull_poly)
		move_child(_hull_poly, 0)
		# hull_shape[0] is that shape's own nose vertex (see
		# _hull_shape_for()) -- weapons fire from the ship's actual hull
		# edge this way, rather than the Muzzle's old fixed (32, 0) in
		# player.tscn, which happened to sit almost exactly on
		# SHIELD_BUBBLE_RADIUS (32.0) and made every shot -- and the
		# beam's raycast origin, which also reads _muzzle.global_position
		# -- look like it was firing from the shield surface instead of
		# the hull, on every ship.
		_muzzle.position = Vector2(hull_shape[0].x, 0.0)

	_beam_line = Line2D.new()
	_beam_line.width = 4.0
	_beam_line.default_color = Color(0.5, 0.9, 1.0, 0.9)
	_beam_line.visible = false
	add_child(_beam_line)

	_engine_trail = GPUParticles2D.new()
	_engine_trail.amount = 20
	_engine_trail.lifetime = 0.4
	_engine_trail.local_coords = false
	_engine_trail.emitting = false
	_engine_trail.texture = PlaceholderGfx.dot_texture(5, Color(0.6, 0.8, 1.0, 0.6))
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(-1, 0, 0)
	mat.spread = 10.0
	mat.gravity = Vector3.ZERO
	mat.initial_velocity_min = 30.0
	mat.initial_velocity_max = 70.0
	mat.scale_min = 0.5
	mat.scale_max = 1.1
	_engine_trail.process_material = mat
	add_child(_engine_trail)
	move_child(_engine_trail, 0)


static func _hull_shape_for(cls: String) -> PackedVector2Array:
	match cls:
		"fighter":
			return PackedVector2Array([Vector2(22, 0), Vector2(-14, 12), Vector2(-6, 0), Vector2(-14, -12)])
		"capital":
			return PackedVector2Array([Vector2(30, 0), Vector2(10, 18), Vector2(-26, 22),
					Vector2(-30, 0), Vector2(-26, -22), Vector2(10, -18)])
	return PackedVector2Array([Vector2(26, 0), Vector2(6, 14), Vector2(-20, 16),
			Vector2(-20, -16), Vector2(6, -14)])


# ==========================================================================
# Movement
# ==========================================================================

func _physics_process(delta: float) -> void:
	if not alive:
		return

	_handle_rotation(delta)
	_handle_thrust(delta)
	move_and_slide()

	_tick_cooldowns(delta)
	_handle_weapon_input(delta)
	_handle_cloak_input()
	_handle_wingman_input()
	_regen(delta)
	_tick_infestation(delta)
	if not alive:
		return
	_auto_turret(delta)
	_tick_shield_visual(delta)

	if cloaked:
		modulate.a = 0.35
	else:
		modulate.a = 1.0


func _tick_shield_visual(delta: float) -> void:
	shield_flash = maxf(0.0, shield_flash - delta)
	shield_break = maxf(0.0, shield_break - delta)
	var target_radius := SHIELD_BUBBLE_RADIUS if shield > 0.0 else HULL_HURTBOX_RADIUS
	var shape := _hurtbox_shape.shape as CircleShape2D
	if shape.radius != target_radius:
		shape.radius = target_radius
	queue_redraw()


func _draw() -> void:
	var hit_dir_local := shield_hit_dir.rotated(-rotation)
	PlaceholderGfx.draw_shield_bubble(self, SHIELD_BUBBLE_RADIUS,
			shield / maxf(shield_max, 0.001), shield_flash, hit_dir_local,
			SHIELD_COL, shield_break)


func _handle_rotation(delta: float) -> void:
	var kb := Input.get_axis("turn_left", "turn_right")
	if absf(kb) > 0.01:
		rotation += kb * turn_rate * delta
		return

	var touch := _touch_joystick()
	if touch != null and touch.active:
		var target: float = touch.direction.angle()
		var diff := wrapf(target - rotation, -PI, PI)
		var max_delta := turn_rate * delta
		rotation += clampf(diff, -max_delta, max_delta)
	# Neither a turn key nor the touch joystick is active: hold heading.
	# (No mouse-aim -- the ship no longer reacts to cursor position at all.)


## Touch input has no equivalent of "mouse position" to aim with, so the
## on-screen joystick (touch_controls.gd) publishes a direction/magnitude
## instead; this is a lazy, cached lookup rather than a hard reference,
## since TouchControls only exists at all on an actual touchscreen.
var _touch_joystick_node: Node = null
var _touch_joystick_checked := false

func _touch_joystick() -> Node:
	if not _touch_joystick_checked:
		_touch_joystick_checked = true
		_touch_joystick_node = get_tree().get_first_node_in_group("touch_joystick")
	return _touch_joystick_node


func _handle_thrust(delta: float) -> void:
	var touch := _touch_joystick()
	var touch_thrusting: bool = touch != null and touch.active and touch.magnitude > 0.2
	var forward := Input.is_action_pressed("thrust_forward") or touch_thrusting
	var reverse := Input.is_action_pressed("thrust_reverse")
	var accel := max_speed / ACCEL_TIME

	if forward:
		velocity += Vector2.RIGHT.rotated(rotation) * accel * delta
		_engine_trail.emitting = true
		_engine_trail.global_position = global_position - Vector2.RIGHT.rotated(rotation) * 22.0
		_engine_trail.rotation = rotation
	elif reverse:
		velocity -= Vector2.RIGHT.rotated(rotation) * accel * REVERSE_FACTOR * delta
		_engine_trail.emitting = false
	else:
		velocity = velocity.lerp(Vector2.ZERO, clampf(DAMPING * delta, 0.0, 1.0))
		_engine_trail.emitting = false

	AudioBus.set_thrust(forward)

	var cap := max_speed if not reverse else max_speed * REVERSE_FACTOR
	if velocity.length() > cap:
		velocity = velocity.normalized() * cap


# ==========================================================================
# Power / shields
# ==========================================================================

func _regen(delta: float) -> void:
	var thrusting := Input.is_action_pressed("thrust_forward")
	var shields_charging := shield < shield_max and power > 0.0
	var net := Daedalus.power_balance(thrusting, cloaked, shields_charging)
	power = clampf(power + net * delta, 0.0, power_max)

	if shields_charging:
		shield = clampf(shield + shield_max * SHIELD_REGEN_FRAC * delta, 0.0, shield_max)

	if cloaked and power <= 0.0:
		_set_cloak(false)

	power_changed.emit(power, power_max)
	shield_changed.emit(shield, shield_max)


func take_damage(amount: float, from_dir: Vector2 = Vector2.ZERO) -> void:
	# A gun round fired at the player is intercepted and redirected long
	# before it could ever call this (see projectile.gd's god-mode
	# interception) -- this guard is what's left of "invincible" for the
	# hostile attacks that never go through a Projectile at all: an Ori's
	# beam and a Dive-Bomber's ram both call take_damage() directly.
	if not alive or GameState.god_mode or amount <= 0.0:
		return
	if from_dir.length_squared() > 1e-9:
		shield_hit_dir = from_dir.normalized()
	var had_shield := shield > 0.0
	var remaining := amount * GameState.difficulty_multiplier()
	if shield > 0.0:
		var absorbed := minf(shield, remaining)
		shield -= absorbed
		remaining -= absorbed
	if remaining > 0.0:
		hull -= remaining
	if had_shield:
		if shield <= 0.0:
			shield_break = 0.4       # collapsed on this hit
		else:
			shield_flash = 0.22      # absorbed, shield holds
	hull_changed.emit(hull, hull_max)
	shield_changed.emit(shield, shield_max)
	if hull <= 0.0:
		_die()


## Matches the Python original's infect(): a hit only ever kickstarts
## infestation from zero -- once infested > 0, _tick_infestation() below
## grows it and drains hull on its own every frame regardless of how many
## further infection hits land, so there's nothing for a magnitude
## argument to do here.
func add_infestation() -> void:
	# Same reasoning as take_damage()'s guard -- a Replicator's infection
	# bolt has no Projectile to intercept, so this stays a direct block.
	if hardened or GameState.god_mode:
		return
	if infested <= 0.0:
		infested = 0.02


## Growth is unconditional (matches the original: infestation keeps
## climbing even while otherwise invincible), only the resulting hull
## drain is gated by god mode -- consistent with take_damage()'s guard
## being what stands in for "invincible" against every attack type that
## has no Projectile of its own to redirect instead.
func _tick_infestation(delta: float) -> void:
	if infested <= 0.0:
		return
	infested = minf(1.6, infested + delta / INFEST_DURATION)
	var frac := clampf(infested, 0.0, 1.0)
	var dps := INFEST_DPS_START + (INFEST_DPS_END - INFEST_DPS_START) * frac
	if infested >= 1.0:
		dps += INFEST_FAILURE_DPS
	if GameState.god_mode:
		return
	hull -= dps * delta * GameState.difficulty_multiplier()
	hull_changed.emit(hull, hull_max)
	if hull <= 0.0:
		_die()


func _die() -> void:
	if not alive:
		return
	alive = false
	died.emit()


# ==========================================================================
# Weapons
# ==========================================================================

func _tick_cooldowns(delta: float) -> void:
	_primary_cd = maxf(0.0, _primary_cd - delta)
	_rocket_cd = maxf(0.0, _rocket_cd - delta)
	_homing_cd = maxf(0.0, _homing_cd - delta)
	_turret_cd = maxf(0.0, _turret_cd - delta)


func _handle_weapon_input(delta: float) -> void:
	if Input.is_action_pressed("fire_guns") and _primary_cd <= 0.0:
		_fire_primary()
	if Input.is_action_just_pressed("fire_rockets") and _rocket_cd <= 0.0:
		_fire_rocket()
	if Input.is_action_just_pressed("fire_homing") and _homing_cd <= 0.0:
		_fire_homing()

	if Input.is_action_pressed("fire_beam") and float(stats.get("beam_dmg", 0.0)) > 0.0:
		_fire_beam(delta)
	else:
		_stop_beam()


func _spend_power(cost: float) -> bool:
	if cost <= 0.0:
		return true
	if power < cost:
		return false
	power -= cost
	return true


func _fire_primary() -> void:
	var weapon_type := "omni" if ship_key == "atlantis" else "primary"
	var cost := Daedalus.weapon_cost("primary")
	if not _spend_power(cost):
		return
	_primary_cd = Daedalus.weapon_stat(weapon_type, "cooldown", 0.1)
	_spawn_shot(weapon_type)


func _fire_rocket() -> void:
	if rockets <= 0 and not infinite_ammo:
		return
	var cost := Daedalus.weapon_cost("rocket")
	if not _spend_power(cost):
		return
	if not infinite_ammo:
		rockets -= 1
	_rocket_cd = Daedalus.weapon_stat("rocket", "cooldown", 0.8)
	_spawn_shot("rocket")


## Ported to match daedalus.py's try_fire_homing(): "tgt = targets[i %
## len(targets)] # fan the salvo across targets" -- every drone in the
## salvo gets its OWN lock, cycling through up to `salvo` distinct
## nearby hostiles (nearest first, same _nearest_enemies() Destiny's
## turrets already use, wrapping back through the same ones if fewer
## hostiles exist) instead of every drone chasing one shared lock and
## converging on top of each other in flight.
##
## Ammo also matches the original exactly now: "n = min(n, self.homing)"
## caps the salvo to whatever's left rather than always launching the
## full salvo regardless, and "self.homing -= 1" inside the per-drone
## loop spends one unit per drone actually launched, not one flat unit
## per trigger pull.
func _fire_homing() -> void:
	if homing <= 0 and not infinite_ammo:
		return
	var acquire_range := Daedalus.effective_range("homing")
	var salvo := Daedalus.homing_salvo_size(ship_key)
	if not infinite_ammo:
		salvo = mini(salvo, homing)
	var targets := _nearest_enemies(acquire_range, salvo)
	if targets.is_empty():
		return
	var cost := Daedalus.weapon_cost("homing")
	if not _spend_power(cost):
		return
	_homing_cd = Daedalus.weapon_stat("homing", "cooldown", 1.1)

	for i in range(salvo):
		if not infinite_ammo:
			homing -= 1
		var spread := 0.0
		if salvo > 1:
			spread = deg_to_rad(lerp(-HOMING_SPREAD_DEG, HOMING_SPREAD_DEG,
					float(i) / float(salvo - 1)))
		var lock: Node2D = targets[i % targets.size()]
		_spawn_shot("homing", spread, lock)


func _spawn_shot(weapon_type: String, angle_offset: float = 0.0, lock: Node2D = null) -> void:
	if projectiles_root == null:
		return
	var shot := projectile_scene.instantiate() as Projectile
	projectiles_root.add_child(shot)
	shot.setup({
		"weapon_type": weapon_type,
		"attacker_key": ship_key,
		"friendly": true,
		"position": _muzzle.global_position,
		"direction": Vector2.RIGHT.rotated(rotation + angle_offset),
		"ship_velocity": velocity,
		"target": lock,
	})
	AudioBus.play_fire(weapon_type)


func _fire_beam(delta: float) -> void:
	var drain := Daedalus.weapon_stat("beam", "energy_drain", 0.0)
	var min_energy := Daedalus.weapon_stat("beam", "min_energy", 0.0)
	if power < min_energy:
		_stop_beam()
		return
	if not _spend_power(drain * delta):
		_stop_beam()
		return

	_beam_active = true
	AudioBus.set_beam(true)
	_beam_elapsed += delta
	var max_range := Daedalus.effective_range("beam")
	var from := _muzzle.global_position
	var dir := Vector2.RIGHT.rotated(rotation)
	var to := from + dir * max_range

	var space := get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(from, to)
	query.collision_mask = Projectile.LAYER_ENEMY_HULL
	# Hurtboxes are Area2D nodes, not PhysicsBody2D -- intersect_ray()
	# ignores areas by default, so this has to be turned on explicitly or
	# the beam would never register a hit against anything.
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var hit := space.intersect_ray(query)

	var end_point := to
	var base_dps := float(stats.get("beam_dmg", 0.0))
	if not hit.is_empty():
		end_point = hit.position
		var victim = hit.collider.get_parent()
		if victim != null and is_instance_valid(victim) and victim.has_method("take_damage"):
			var target_class: String = victim.get_ship_class() if victim.has_method("get_ship_class") else "fighter"
			var dps := Daedalus.beam_dps(base_dps, _beam_elapsed, target_class)
			victim.take_damage(dps * delta, global_position - victim.global_position)

	_beam_line.visible = true
	_beam_line.points = PackedVector2Array([to_local(from), to_local(end_point)])
	beam_state_changed.emit(true, from, end_point)


func _stop_beam() -> void:
	if _beam_active:
		_beam_active = false
		AudioBus.set_beam(false)
		_beam_elapsed = 0.0
		_beam_line.visible = false
		beam_state_changed.emit(false, Vector2.ZERO, Vector2.ZERO)


## Destiny's five point-defense turrets: automatic, never player-triggered
## -- the same doctrine daedalus_weapons.nova documents for the "turret"
## weapon type ("Point Defense (automated)"). Matches daedalus.py's
## auto_turrets() and the .nova file's own comment on turret_count:
## "five turrets firing independently means an effective five-round
## burst roughly every 0.47s, not one round" -- every cooldown tick
## fires turret_count shots at once, spread across up to turret_count
## distinct nearby hostiles (cycling back through the same targets if
## fewer exist), each from its own point along the dorsal hull rather
## than a single shot from one muzzle at one target.
func _auto_turret(_delta: float) -> void:
	if ship_key != "destiny" or _turret_cd > 0.0:
		return
	var turret_range := Daedalus.effective_range("turret")
	var turret_count := int(Daedalus.weapon_stat("turret", "turret_count", 5.0))
	var targets := _nearest_enemies(turret_range, turret_count)
	if targets.is_empty():
		return
	_turret_cd = Daedalus.weapon_stat("turret", "cooldown", 0.47)
	var spread_span := 44.0
	for i in range(turret_count):
		var t: Node2D = targets[i % targets.size()]
		var frac := float(i) / float(maxi(turret_count - 1, 1))
		var mount := global_position + Vector2(-spread_span * 0.5 + spread_span * frac, -3.0).rotated(rotation)
		var dir := (t.global_position - mount).normalized()
		_spawn_shot_at_target("turret", dir, mount)


func _spawn_shot_at_target(weapon_type: String, dir: Vector2, origin: Vector2) -> void:
	if projectiles_root == null:
		return
	var shot := projectile_scene.instantiate() as Projectile
	projectiles_root.add_child(shot)
	shot.setup({
		"weapon_type": weapon_type,
		"attacker_key": ship_key,
		"friendly": true,
		"position": origin,
		"direction": dir,
		"ship_velocity": Vector2.ZERO,
	})


func _find_nearest_enemy(max_range: float) -> Node2D:
	var best: Node2D = null
	var best_dist := max_range
	for hb in get_tree().get_nodes_in_group("enemy_hull"):
		if not is_instance_valid(hb):
			continue
		var victim = hb.get_parent()
		if victim == null or not is_instance_valid(victim):
			continue
		var d := global_position.distance_to(victim.global_position)
		if d <= best_dist:
			best_dist = d
			best = victim
	return best


## Same search as _find_nearest_enemy(), but for _auto_turret(): collects
## up to `count` hostiles in range, nearest first, instead of stopping at
## just the one closest.
func _nearest_enemies(max_range: float, count: int) -> Array:
	var candidates: Array = []
	for hb in get_tree().get_nodes_in_group("enemy_hull"):
		if not is_instance_valid(hb):
			continue
		var victim = hb.get_parent()
		if victim == null or not is_instance_valid(victim):
			continue
		var d := global_position.distance_to(victim.global_position)
		if d <= max_range:
			candidates.append([d, victim])
	candidates.sort_custom(func(a, b): return a[0] < b[0])
	var result: Array = []
	for i in range(mini(count, candidates.size())):
		result.append(candidates[i][1])
	return result


# ==========================================================================
# Cloak / wingmen
# ==========================================================================

func _handle_cloak_input() -> void:
	if Input.is_action_just_pressed("toggle_cloak"):
		if not cloak_available:
			return
		if not cloaked and power < CLOAK_MIN_POWER:
			return
		_set_cloak(not cloaked)


func _set_cloak(active: bool) -> void:
	cloaked = active
	cloak_changed.emit(cloaked)


func _handle_wingman_input() -> void:
	if Input.is_action_just_pressed("spawn_wingman"):
		wingman_requested.emit()
