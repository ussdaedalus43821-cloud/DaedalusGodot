class_name Enemy
extends CharacterBody2D

## One instance of this script plays all six hostile archetypes AND the
## player's wingmen -- the behavior itself is entirely data from
## Daedalus.get_enemy_behavior(kind, player_key) (daedalus_ai.nova,
## composed with the player's actual class and hardened flag through
## daedalus_rules.nova), resolved once at spawn, never once a frame. This
## script only turns that Dictionary into movement and firing.
##
## A wingman is not a special case in the data: it is the "fighter"
## (Skirmisher) profile from the SAME table, `faction` set to "player"
## instead of "hostile" so it hunts the enemy_hull group instead of
## player_hull and its shots land on the friendly_shot/enemy_hull side of
## Projectile's layers instead of the reverse. Nothing about
## daedalus_ai.nova changes for that -- the Skirmisher's standoff, burst
## and strafe timing apply exactly as tuned, just pointed the other way.
##
## Every hit this script deals is resolved the same way projectile.gd
## resolves a player shot: gun damage goes through
## Daedalus.effective_damage(raw, attacker_class, target_class) (the same
## class-scaling matrix, generalised to any target rather than assuming a
## player SHIPS key -- see projectile.gd's own note), a Dive-Bomber's ram
## goes through Daedalus.dart_ram_damage() (deliberately never scaled by
## class, per daedalus_ai.nova), and an Ori's beam applies its own
## pre-resolved beam_dps from the behavior Dictionary directly (already
## carries its player-class reaction baked in -- see daedalus_ai.nova's
## _ori_behavior(), which is its own documented exception to the general
## matrix, the same way Stage 3's Asgard beam is).

signal died(kind: String, score: int, is_wingman: bool)

const KIND_COLORS := {
	"fighter": Color(0.85, 0.35, 0.35),
	"capital": Color(0.75, 0.2, 0.2),
	"dart": Color(0.9, 0.55, 0.25),
	"hive": Color(0.55, 0.2, 0.6),
	"replicator": Color(0.3, 0.8, 0.45),
	"ori": Color(0.9, 0.85, 0.3),
}
const WINGMAN_COLOR := Color(0.4, 0.7, 1.0)

const BURST_ROUND_INTERVAL := 0.15
const DIVE_TIMEOUT := 3.0
const RAM_HIT_RADIUS := 30.0

## God mode's "fear": a hostile's orbit standoff (_keep_dist) is inflated by
## this factor while it's engaging the player side, so it hangs back much
## farther than it normally would rather than closing to a fight it can
## never actually win. Applies to every kind via _move_orbit() -- fighter,
## capital, an un-diving dart, hive, ori -- everything except a dart mid-
## dive or a fleeing replicator, which already have their own movement.
const FEAR_KEEP_DIST_MULT := 3.0

## panic() is god mode's other "psychological weapon" beat: a hostile
## that's just been on either end of a redirected friendly-fire hit
## (see the panic() calls in projectile.gd's _direct_hit() and this
## file's ram/beam/infection redirects) spends PANIC_DURATION_* seconds
## visibly rattled -- firing/dive/spawn/beam timers frozen entirely
## (_tick_timers() is skipped outright), movement cut to
## PANIC_SPEED_MULT of normal, and a Skirmisher ("fighter") or Dart
## breaking off to flee instead of orbiting. The very next gun round
## fired once panic wears off goes wild (PANIC_WILD_SPREAD_DEG either
## side of the real aim) rather than aimed, rather than modeling an
## ongoing "spray and pray" mode.
const PANIC_DURATION_MIN := 0.5
const PANIC_DURATION_MAX := 1.0
const PANIC_SPEED_MULT := 0.35
const PANIC_WILD_SPREAD_DEG := 60.0

## Shield bubble, ported from the Python prototype's draw_shield_bubble()
## and its collision note: "a shot is stopped at the bubble surface
## while shields hold, at the hull once they're down." HULL_HURTBOX_RADIUS
## matches enemy.tscn's own hurtbox_shape; SHIELD_BUBBLE_RADIUS is that
## + the original's +10 bubble_pad. Tinted per-kind using the same
## KIND_COLORS a wingman's own hull color already draws from.
const HULL_HURTBOX_RADIUS := 20.0
const SHIELD_BUBBLE_RADIUS := 30.0

## Wingman-only (faction == "player"; hostiles never dock): once shield
## drops below DOCK_TRIGGER_FRAC, a wingman breaks off combat -- however
## far from the player it currently is, since it's out fighting its own
## targets and is often nowhere near you by the time its shield is
## actually critical -- and flies flat-out back to the player, then
## recharges at DOCK_REGEN_FRAC/sec once close enough, far faster than
## anything a hostile ever gets since it's standing inside the player's
## own shield bubble to do it, until full, resuming its normal behavior
## either way.
const DOCK_TRIGGER_FRAC := 0.3
const DOCK_HOLD_RANGE := 40.0
const DOCK_REGEN_FRAC := 0.5

var kind := "fighter"
var faction := "hostile"       # "hostile" or "player" (wingman)
var player_key := "daedalus"

var behavior: Dictionary = {}
var ship_class_name := "fighter"

var shield := 0.0
var shield_max := 0.0
var shield_flash := 0.0      # rim ripple where a hit was just absorbed
var shield_break := 0.0      # full-bubble flare where the shield just collapsed
var shield_hit_dir := Vector2.RIGHT   # world-space unit vector: this ship -> impact
var hull := 0.0
var hull_max := 0.0
var max_speed := 0.0
var turn_rate := 0.0    # rad/s
var alive := true
var infested := 0.0     # see add_infestation()/_tick_infestation() below

var _keep_dist := 300.0
var _strafe_dir := 1.0

var _fire_timer := 1.0
var _burst_remaining := 0
var _burst_shot_timer := 0.0
var _flak_timer := 1.0

var _dive_timer := 3.0
var _diving := false
var _dive_elapsed := 0.0

var _spawn_timer := 5.0
var _stored_darts := 0

var _fleeing := false
var docking := false

var _panic_timer := 0.0
var _panic_wild_shot := false

var _charging := false
var _charge_timer := 1.0
var _beam_firing := false
var _beam_fire_timer := 0.0
var _beam_recharge_timer := 1.0

var projectiles_root: Node = null
var combatants_root: Node = null   # where a Hive's launched Darts (or a wingman's own spawns) are added
var projectile_scene: PackedScene = preload("res://scenes/projectile.tscn")

## load(), not preload(): this script is enemy.tscn's own attached script,
## so a compile-time preload() of enemy.tscn here would try to load that
## scene again while it's already mid-load compiling this exact script --
## a circular resource dependency, which is what "Parse Error: Busy" on
## enemy.tscn actually was. load() instead runs when an instance is
## constructed, well after this script has finished compiling, at which
## point enemy.tscn is already sitting in the resource cache.
var enemy_scene: PackedScene = load("res://scenes/enemy.tscn")

@onready var _hurtbox: Area2D = $Hurtbox
@onready var _hurtbox_shape: CollisionShape2D = $Hurtbox/Shape
@onready var _muzzle: Marker2D = $Muzzle
var _hull_poly: Polygon2D = null
var _beam_line: Line2D = null


func setup(cfg: Dictionary) -> void:
	kind = String(cfg.get("kind", "fighter"))
	faction = String(cfg.get("faction", "hostile"))
	player_key = String(cfg.get("player_key", "daedalus"))
	global_position = cfg.get("position", Vector2.ZERO)

	behavior = Daedalus.get_enemy_behavior(kind, player_key)
	ship_class_name = String(behavior.get("class", "fighter"))
	shield_max = float(behavior.get("shield", 100.0))
	hull_max = float(behavior.get("hull", 100.0))
	max_speed = float(behavior.get("max_speed", 200.0))
	turn_rate = deg_to_rad(float(behavior.get("turn_rate", 100.0)))
	shield = shield_max
	hull = hull_max
	alive = true

	var kd: Array = behavior.get("keep_dist", [200.0, 300.0])
	_keep_dist = randf_range(float(kd[0]), float(kd[1]))
	_strafe_dir = 1.0 if randf() < 0.5 else -1.0

	var fc: Array = behavior.get("fire_cd", [1.0, 2.0])
	_fire_timer = randf_range(float(fc[0]), float(fc[1]))

	if kind == "dart" and bool(behavior.get("dive_enabled", false)):
		var dc: Array = behavior.get("dive_cd", [3.0, 5.0])
		_dive_timer = randf_range(float(dc[0]), float(dc[1]))

	if kind == "hive":
		var sc: Array = behavior.get("spawn_cd", [5.0, 9.0])
		_spawn_timer = randf_range(float(sc[0]), float(sc[1]))
		_stored_darts = int(behavior.get("max_stored", 6))

	if kind == "capital":
		var fk: Array = behavior.get("flak_cd", [2.5, 4.0])
		_flak_timer = randf_range(float(fk[0]), float(fk[1]))

	if kind == "ori":
		_beam_recharge_timer = randf_range(float(fc[0]), float(fc[1]))

	# This scene plays both sides, so unlike Player's fixed Hurtbox layer,
	# the physics layer itself (not just the group) has to be set here:
	# Projectile's area_entered/raycast checks match collision_layer bits,
	# groups are only ever used for the AoE and nearest-target *searches*.
	if faction == "hostile":
		_hurtbox.collision_layer = Projectile.LAYER_ENEMY_HULL
		_hurtbox.add_to_group("enemy_hull")
	else:
		_hurtbox.collision_layer = Projectile.LAYER_PLAYER_HULL
		_hurtbox.add_to_group("player_hull")
	_hurtbox.collision_mask = 0
	_hurtbox.monitoring = false
	_hurtbox.monitorable = true
	# enemy.tscn's hurtbox_shape sub-resource is shared across every
	# spawned instance; duplicating it here means resizing it in
	# _tick_shield_visual() only ever affects this one ship.
	_hurtbox_shape.shape = _hurtbox_shape.shape.duplicate()
	add_to_group("wingmen" if faction == "player" else "hostiles")
	_build_visual()


func get_ship_class() -> String:
	return ship_class_name


func is_wingman() -> bool:
	return faction == "player"


## Public so an attacker (see _handle_beam_cycle()'s own beam, or a
## redirected player/wingman shot) can stop a beam/line visual at this
## ship's current hurtbox surface -- shield bubble while shields hold,
## hull once they're down -- instead of drawing straight through to its
## center. Same radii _tick_shield_visual() already resizes the
## collision shape to.
func hurtbox_radius() -> float:
	return SHIELD_BUBBLE_RADIUS if shield > 0.0 else HULL_HURTBOX_RADIUS


# ==========================================================================
# Visuals
# ==========================================================================

func _build_visual() -> void:
	_hull_poly = Polygon2D.new()
	_hull_poly.polygon = Player._hull_shape_for(ship_class_name)
	_hull_poly.color = WINGMAN_COLOR if is_wingman() else KIND_COLORS.get(kind, Color.WHITE)
	add_child(_hull_poly)
	move_child(_hull_poly, 0)

	_beam_line = Line2D.new()
	_beam_line.width = 5.0
	_beam_line.default_color = Color(1.0, 0.3, 0.2, 0.85)
	_beam_line.visible = false
	add_child(_beam_line)


# ==========================================================================
# Frame loop
# ==========================================================================

func _physics_process(delta: float) -> void:
	if not alive:
		return

	_tick_infestation(delta)
	if not alive:
		return

	_panic_timer = maxf(0.0, _panic_timer - delta)

	if kind == "replicator":
		_fleeing = (hull / maxf(hull_max, 1.0)) < float(behavior.get("flee_hull_frac", 0.3))

	if _tick_docking(delta):
		_tick_shield_visual(delta)
		return

	var target := _find_target()
	if _panic_timer > 0.0:
		_tick_panic(delta, target)
	else:
		_tick_timers(delta, target)
		_move(delta, target)
	_tick_shield_visual(delta)


## Called on both ends of a redirected friendly-fire hit (see the file
## header on where) -- never on a wingman, since only "hostiles" group
## members are ever chosen as a redirect target or passed as
## attacker_node in the first place.
func panic() -> void:
	if not alive:
		return
	_panic_timer = maxf(_panic_timer, randf_range(PANIC_DURATION_MIN, PANIC_DURATION_MAX))


func _tick_panic(delta: float, target: Node2D) -> void:
	if (kind == "fighter" or kind == "dart") and target != null:
		_move_flee(delta, target)
	else:
		velocity = velocity.move_toward(Vector2.ZERO, max_speed * delta)
	velocity *= PANIC_SPEED_MULT
	move_and_slide()
	if _panic_timer <= delta:
		_panic_wild_shot = true


## Finds the player ship via the same "hurtbox's own group, then its
## parent" pattern _find_target() already uses -- there is exactly one
## player, so no distance search is needed.
func _find_player() -> Node2D:
	var hb := get_tree().get_first_node_in_group("player_hull")
	if hb == null or not is_instance_valid(hb):
		return null
	# hb.get_parent() is statically just Node -- untyped `=` (not `:=`)
	# here, then an explicitly Node2D-typed variable below, matching
	# _find_target()'s own established pattern for this exact shape.
	var owner_node = hb.get_parent()
	if owner_node == null or not is_instance_valid(owner_node):
		return null
	if "alive" in owner_node and not owner_node.alive:
		return null
	var player_ship: Node2D = owner_node
	return player_ship


## Returns true while this wingman is docking/docked, in which case the
## caller must skip its normal target-finding/combat/movement for this
## tick entirely -- docking always takes priority over combat.
func _tick_docking(delta: float) -> bool:
	if faction != "player":
		return false
	var player_ship := _find_player()
	if player_ship == null:
		docking = false
		return false

	if not docking:
		if shield / maxf(shield_max, 1.0) < DOCK_TRIGGER_FRAC:
			docking = true
		else:
			return false

	if shield >= shield_max:
		docking = false
		return false

	var to_player := player_ship.global_position - global_position
	if to_player.length() > DOCK_HOLD_RANGE:
		velocity = to_player.normalized() * max_speed
		move_and_slide()
	else:
		velocity = Vector2.ZERO
	rotation = to_player.angle()
	shield = clampf(shield + shield_max * DOCK_REGEN_FRAC * delta, 0.0, shield_max)
	return true


func _tick_shield_visual(delta: float) -> void:
	shield_flash = maxf(0.0, shield_flash - delta)
	shield_break = maxf(0.0, shield_break - delta)
	var target_radius := SHIELD_BUBBLE_RADIUS if shield > 0.0 else HULL_HURTBOX_RADIUS
	var shape := _hurtbox_shape.shape as CircleShape2D
	if shape.radius != target_radius:
		shape.radius = target_radius
	queue_redraw()


func _draw() -> void:
	var base_col: Color = WINGMAN_COLOR if faction == "player" else KIND_COLORS.get(kind, Color.WHITE)
	var hit_dir_local := shield_hit_dir.rotated(-rotation)
	PlaceholderGfx.draw_shield_bubble(self, SHIELD_BUBBLE_RADIUS,
			shield / maxf(shield_max, 0.001), shield_flash, hit_dir_local,
			base_col, shield_break)


func _find_target() -> Node2D:
	var group := "player_hull" if faction == "hostile" else "enemy_hull"
	var best: Node2D = null
	var best_dist := INF
	for hb in get_tree().get_nodes_in_group(group):
		if not is_instance_valid(hb):
			continue
		var victim = hb.get_parent()
		if victim == null or not is_instance_valid(victim):
			continue
		if "alive" in victim and not victim.alive:
			continue
		if "cloaked" in victim and victim.cloaked:
			continue
		var d := global_position.distance_to(victim.global_position)
		if d < best_dist:
			best_dist = d
			best = victim
	return best


## God mode's beam interception (see _handle_beam_cycle()) -- the same
## "nearest OTHER hostile, never self" search projectile.gd runs for a
## redirected gun round, just over the "hostiles" root-node group directly
## since this file already has that group, rather than hurtbox children.
func _nearest_other_hostile() -> Node2D:
	var best: Node2D = null
	var best_dist := INF
	for node in get_tree().get_nodes_in_group("hostiles"):
		if not is_instance_valid(node) or node == self:
			continue
		if "alive" in node and not node.alive:
			continue
		var d := global_position.distance_to(node.global_position)
		if d < best_dist:
			best_dist = d
			best = node
	return best


# ==========================================================================
# Movement
# ==========================================================================

func _move(delta: float, target: Node2D) -> void:
	if target == null:
		velocity = velocity.move_toward(Vector2.ZERO, max_speed * delta)
		move_and_slide()
		return

	if kind == "dart" and _diving:
		_move_dart_dive(delta, target)
	elif kind == "replicator" and _fleeing:
		_move_flee(delta, target)
	else:
		_move_orbit(delta, target)
	move_and_slide()


static func _turn_toward(current: float, target: float, max_delta: float) -> float:
	var diff := wrapf(target - current, -PI, PI)
	return current + clampf(diff, -max_delta, max_delta)


func _move_orbit(delta: float, target: Node2D) -> void:
	var to_target := target.global_position - global_position
	var dist := to_target.length()
	var keep_dist := _keep_dist
	if faction == "hostile" and GameState.god_mode:
		keep_dist *= FEAR_KEEP_DIST_MULT
	var desired_dir: Vector2
	if dist > keep_dist * 1.08:
		desired_dir = to_target.normalized()
	elif dist < keep_dist * 0.92:
		desired_dir = -to_target.normalized()
	else:
		desired_dir = to_target.normalized().rotated(PI * 0.5 * _strafe_dir)

	rotation = _turn_toward(rotation, desired_dir.angle(), turn_rate * delta)
	var desired_velocity := Vector2.RIGHT.rotated(rotation) * max_speed * 0.85
	velocity = velocity.move_toward(desired_velocity, max_speed * 2.0 * delta)


func _move_dart_dive(delta: float, target: Node2D) -> void:
	_dive_elapsed += delta
	var desired_angle := (target.global_position - global_position).angle()
	rotation = _turn_toward(rotation, desired_angle, turn_rate * delta)
	velocity = Vector2.RIGHT.rotated(rotation) * max_speed

	var dist := global_position.distance_to(target.global_position)
	if dist < RAM_HIT_RADIUS:
		# The dive itself is untouched by god mode -- this Dart still
		# beelines at and reaches the player exactly as always, same as a
		# gun round still gets fired straight at the player before
		# projectile.gd bends it. Only who actually takes the ram's
		# damage is redirected, at the very last instant it would connect.
		var victim := target
		if GameState.god_mode:
			victim = _nearest_other_hostile()
		if victim != null and victim.has_method("take_damage"):
			var dmg := Daedalus.dart_ram_damage(velocity.length())
			victim.take_damage(dmg, global_position - victim.global_position)
			if GameState.god_mode:
				victim.panic()
				panic()
		_end_dive()
	elif _dive_elapsed > DIVE_TIMEOUT:
		_end_dive()


func _end_dive() -> void:
	_diving = false
	_dive_elapsed = 0.0
	var dc: Array = behavior.get("dive_cd", [3.0, 5.0])
	_dive_timer = randf_range(float(dc[0]), float(dc[1]))


func _move_flee(delta: float, target: Node2D) -> void:
	var away := (global_position - target.global_position).normalized()
	rotation = _turn_toward(rotation, away.angle(), turn_rate * delta)
	var flee_speed := float(behavior.get("flee_speed", max_speed))
	velocity = velocity.move_toward(Vector2.RIGHT.rotated(rotation) * flee_speed, flee_speed * 2.0 * delta)


# ==========================================================================
# Timers -- firing, diving, spawning, beam cycling
# ==========================================================================

func _tick_timers(delta: float, target: Node2D) -> void:
	if kind == "dart" and bool(behavior.get("dive_enabled", false)) and not _diving:
		_dive_timer -= delta
		if _dive_timer <= 0.0 and target != null:
			_diving = true
			_dive_elapsed = 0.0

	if target == null:
		return

	match kind:
		"fighter":
			_handle_burst_fire(delta, target)
		"capital":
			_handle_burst_fire(delta, target)
			_handle_flak(delta, target)
		"dart":
			if not _diving:
				_handle_single_fire(delta, target)
		"hive":
			_handle_hive_spawn(delta, target)
		"replicator":
			if not _fleeing and not bool(behavior.get("infect_blocked", false)):
				_handle_infection(delta, target)
		"ori":
			_handle_beam_cycle(delta, target)


func _handle_burst_fire(delta: float, target: Node2D) -> void:
	if _burst_remaining <= 0:
		_fire_timer -= delta
		if _fire_timer <= 0.0:
			var burst_min := int(behavior.get("burst_min", 1))
			var burst_max := int(behavior.get("burst_max", 1))
			_burst_remaining = randi_range(mini(burst_min, burst_max), maxi(burst_min, burst_max))
			_burst_shot_timer = 0.0
	else:
		_burst_shot_timer -= delta
		if _burst_shot_timer <= 0.0:
			_fire_gun_at(target)
			_burst_remaining -= 1
			_burst_shot_timer = BURST_ROUND_INTERVAL
			if _burst_remaining <= 0:
				var fc: Array = behavior.get("fire_cd", [1.0, 2.0])
				_fire_timer = randf_range(float(fc[0]), float(fc[1]))


func _handle_flak(delta: float, target: Node2D) -> void:
	_flak_timer -= delta
	if _flak_timer <= 0.0:
		_fire_gun_at(target)
		var fk: Array = behavior.get("flak_cd", [2.5, 4.0])
		_flak_timer = randf_range(float(fk[0]), float(fk[1]))


func _handle_single_fire(delta: float, target: Node2D) -> void:
	_fire_timer -= delta
	if _fire_timer <= 0.0:
		_fire_gun_at(target)
		var fc: Array = behavior.get("fire_cd", [0.5, 0.8])
		_fire_timer = randf_range(float(fc[0]), float(fc[1]))


func _fire_gun_at(target: Node2D) -> void:
	if projectiles_root == null:
		return
	var dir := (target.global_position - _muzzle.global_position).normalized()
	if _panic_wild_shot:
		_panic_wild_shot = false
		dir = dir.rotated(deg_to_rad(randf_range(-PANIC_WILD_SPREAD_DEG, PANIC_WILD_SPREAD_DEG)))
	var shot := projectile_scene.instantiate() as Projectile
	projectiles_root.add_child(shot)
	shot.setup({
		"weapon_type": "enemy_gun",
		"attacker_kind": kind,
		# So god mode's interception (see projectile.gd) never bends a
		# hostile's own shot back into itself -- this ship never knows
		# either way, it just fires exactly as it always has.
		"attacker_node": self,
		"friendly": is_wingman(),
		"position": _muzzle.global_position,
		"direction": dir,
		"ship_velocity": velocity,
	})


func _handle_hive_spawn(delta: float, target: Node2D) -> void:
	var release_range := float(behavior.get("release_range", 300.0))
	var dist := global_position.distance_to(target.global_position)
	if dist <= release_range and _stored_darts > 0:
		var n := _stored_darts
		_stored_darts = 0
		for i in range(n):
			_spawn_dart()
		return
	_spawn_timer -= delta
	if _spawn_timer <= 0.0 and _stored_darts > 0:
		_spawn_dart()
		_stored_darts -= 1
		var sc: Array = behavior.get("spawn_cd", [5.0, 9.0])
		_spawn_timer = randf_range(float(sc[0]), float(sc[1]))


func _spawn_dart() -> void:
	if combatants_root == null:
		return
	var dart := enemy_scene.instantiate() as Enemy
	combatants_root.add_child(dart)
	dart.projectiles_root = projectiles_root
	dart.combatants_root = combatants_root
	dart.setup({
		"kind": "dart",
		"faction": faction,
		"player_key": player_key,
		"position": global_position + Vector2(randf_range(-24.0, 24.0), randf_range(-24.0, 24.0)),
	})


## No projectile object for an infection bolt -- the bolt's payload is not
## kinetic or energy damage (daedalus_ai.nova's gun_dmg is literally 0 for
## this kind), it is a direct increment to the target's infestation meter.
func _handle_infection(delta: float, target: Node2D) -> void:
	_fire_timer -= delta
	if _fire_timer <= 0.0:
		# Same redirect as every other attack type: while god mode is on,
		# the bolt is aimed at the nearest OTHER hostile instead -- who
		# now has its own infestation mechanic (see add_infestation()
		# below) to actually take it.
		var victim := target
		if GameState.god_mode:
			victim = _nearest_other_hostile()
		if victim != null and victim.has_method("add_infestation"):
			victim.add_infestation()
			if GameState.god_mode:
				victim.panic()
				panic()
		var fc: Array = behavior.get("fire_cd", [1.7, 2.3])
		_fire_timer = randf_range(float(fc[0]), float(fc[1]))


func _handle_beam_cycle(delta: float, target: Node2D) -> void:
	if _charging:
		_charge_timer -= delta
		if _charge_timer <= 0.0:
			_charging = false
			_beam_firing = true
			_beam_fire_timer = float(behavior.get("fire_time", 1.5))
	elif _beam_firing:
		_beam_fire_timer -= delta
		# Same god-mode interception as a gun round (see projectile.gd),
		# just without a projectile to bend: an Ori's beam has no travel
		# time to redirect mid-flight, so instead of damaging/tracking
		# `target` (always player-side -- see _tick_timers()'s match) it
		# damages/tracks the nearest OTHER hostile every tick, same as
		# `target` itself was already being recomputed fresh every tick.
		# No other hostile to point at -> the beam simply doesn't fire
		# this tick, same "fizzles rather than reaches the player" choice
		# projectile.gd makes when it runs out of a target to bend onto.
		var beam_target := target
		if GameState.god_mode:
			beam_target = _nearest_other_hostile()
		if beam_target != null and beam_target.has_method("take_damage"):
			var dps := float(behavior.get("beam_dps", 0.0))
			beam_target.take_damage(dps * delta, global_position - beam_target.global_position)
			# Victim only, not self -- the beam is continuous, so
			# panicking the shooter every single tick it's firing would
			# fight its own panic-freeze instead of reading as one
			# reaction to one event the way the gun/ram/infection cases do.
			if GameState.god_mode:
				beam_target.panic()
			# Stop the drawn line at beam_target's current hurtbox surface
			# (shield bubble while shields hold, hull once they're down)
			# rather than its center -- otherwise the beam visually spears
			# straight through an intact shield to the hull behind it, even
			# though take_damage() was already correctly billing the hit to
			# shield first.
			var to_target := beam_target.global_position - global_position
			var stop_radius := 0.0
			if beam_target.has_method("hurtbox_radius"):
				stop_radius = beam_target.hurtbox_radius()
			var beam_end := beam_target.global_position - to_target.normalized() * stop_radius
			_beam_line.visible = true
			_beam_line.points = PackedVector2Array([Vector2.ZERO, to_local(beam_end)])
		else:
			_beam_line.visible = false
		if _beam_fire_timer <= 0.0:
			_beam_firing = false
			_beam_line.visible = false
			var bc: Array = behavior.get("beam_cooldown", [2.1, 2.6])
			_beam_recharge_timer = randf_range(float(bc[0]), float(bc[1]))
	else:
		_beam_recharge_timer -= delta
		if _beam_recharge_timer <= 0.0:
			_charging = true
			_charge_timer = float(behavior.get("charge_time", 1.2))


# ==========================================================================
# Damage / death
# ==========================================================================

## Nothing here needs to know why a hit landed -- take_damage() already
## treats every attacker generically. That's what makes god mode's
## interception (projectile.gd) work with no changes here beyond
## _fire_gun_at() passing attacker_node above: a hostile's own gun round,
## redirected onto another hostile, lands on this exact same path a
## player's shot would have taken, computed the exact same way.
func take_damage(amount: float, from_dir: Vector2 = Vector2.ZERO) -> void:
	if not alive or amount <= 0.0 or docking:
		return
	if from_dir.length_squared() > 1e-9:
		shield_hit_dir = from_dir.normalized()
	var had_shield := shield > 0.0
	var remaining := amount
	if shield > 0.0:
		var absorbed := minf(shield, remaining)
		shield -= absorbed
		remaining -= absorbed
	if remaining > 0.0:
		hull -= remaining
	if had_shield:
		if shield <= 0.0:
			shield_break = 0.4
		else:
			shield_flash = 0.22
	if hull <= 0.0:
		_die()


## Unlike Player's version, this is never gated on GameState.god_mode --
## god mode's whole point is redirecting attacks onto hostiles instead of
## the player, so a hostile has to actually be infectable while it's on,
## not immune to it. See Player.add_infestation()/Player.INFEST_DURATION
## etc. for the shared constants and the full explanation of what this
## kickstarts (growth and hull drain both live in _tick_infestation()
## below, ticking on their own from here regardless of further hits).
func add_infestation() -> void:
	if infested <= 0.0:
		infested = 0.02


## No god-mode gate here either, and no GameState.difficulty_multiplier()
## scaling -- matches take_damage()'s existing asymmetry with Player's:
## difficulty only scales damage the PLAYER takes.
func _tick_infestation(delta: float) -> void:
	if infested <= 0.0:
		return
	infested = minf(1.6, infested + delta / Player.INFEST_DURATION)
	var frac := clampf(infested, 0.0, 1.0)
	var dps := Player.INFEST_DPS_START + (Player.INFEST_DPS_END - Player.INFEST_DPS_START) * frac
	if infested >= 1.0:
		dps += Player.INFEST_FAILURE_DPS
	hull -= dps * delta
	if hull <= 0.0:
		_die()


func _die() -> void:
	if not alive:
		return
	alive = false
	AudioBus.play_explosion()
	var score := int(behavior.get("score", 0))
	died.emit(kind, score, is_wingman())
	queue_free()
