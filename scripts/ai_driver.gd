extends Node2D
class_name AIDriver

## AI driver: follows track centerline with lateral noise + rubber-banding.
## Attach to a CharacterBody2D that has a car.gd script.

const LOOKAHEAD_SAMPLES: int = 18
const STEER_GAIN: float = 2.8
const COLLISION_AVOID_DIST: float = 220.0
const AVOID_LATERAL_RANGE: float = 55.0
const AVOID_PUSH: float = 70.0
const STUCK_SPEED_THRESHOLD: float = 60.0
const STUCK_TIME: float = 0.8
const REVERSE_TIME: float = 0.7

var _track = null  # typed as Track but untyped var to avoid load-order issues
var _car: CharacterBody2D = null
var _personality_offset: float = 0.0
var _stuck_timer: float = 0.0
var _reverse_timer: float = 0.0
var _reverse_steer: float = 0.0
var _rng := RandomNumberGenerator.new()


func setup(track_ref, car_ref: CharacterBody2D) -> void:
	_track = track_ref
	_car = car_ref
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_personality_offset = rng.randf_range(-0.55, 0.55)
	if _car:
		_car.is_ai = true


func _physics_process(delta: float) -> void:
	if not _track or not _car:
		return
	if _car.finished:
		_car.ai_throttle = 0.0
		_car.ai_brake_input = 1.0
		_car.ai_steer = 0.0
		return

	var race_mgr: Node = get_node_or_null("/root/RaceManager")
	var locked: bool = false
	if race_mgr:
		locked = race_mgr.is_input_locked()
	if locked:
		_car.ai_throttle = 0.0
		_car.ai_brake_input = 1.0
		_car.ai_steer = 0.0
		return

	# Stuck recovery: if we are commanding throttle but physics says we are
	# barely moving (pinned against a wall or another car), back up briefly,
	# then let normal steering take a fresh line around the obstacle.
	if _reverse_timer > 0.0:
		_reverse_timer -= delta
		_car.ai_throttle = -1.0
		_car.ai_brake_input = 0.0
		_car.ai_steer = _reverse_steer
		_car.ai_drift = false
		return
	# Any commanded throttle counts: avoidance may be feathering it (e.g.
	# 0.35 behind a parked car), and that must not disable stuck detection
	# or the car noses against the obstacle forever. Use the real velocity
	# from physics — the `velocity` property can read full speed while the
	# body is wedged motionless between opposing contacts.
	if _car.ai_throttle > 0.15 and _car.get_real_velocity().length() < STUCK_SPEED_THRESHOLD:
		_stuck_timer += delta
		if _stuck_timer >= STUCK_TIME:
			_stuck_timer = 0.0
			_reverse_timer = REVERSE_TIME
			# Randomize the backing arc so each retry takes a fresh line.
			_reverse_steer = _rng.randf_range(-0.6, 0.6)
			return
	else:
		_stuck_timer = 0.0

	# Access track data via duck typing
	var center: PackedVector2Array = _track._center_path
	if center.size() == 0:
		return
	var n: int = center.size()

	# Find nearest sample
	var best_idx: int = 0
	var best_sq: float = INF
	for i in range(n):
		var sq: float = center[i].distance_squared_to(_car.position)
		if sq < best_sq:
			best_sq = sq
			best_idx = i

	# Aim point: lookahead along the path
	var aim_idx: int = (best_idx + LOOKAHEAD_SAMPLES) % n
	var aim_pos: Vector2 = center[aim_idx]

	# Apply personality lateral offset
	var road_half_w: float = _track.get_road_half_width()
	var tangent_idx: int = (aim_idx + 1) % n
	var tangent: Vector2 = (center[tangent_idx] - center[aim_idx]).normalized()
	var perp: Vector2 = Vector2(-tangent.y, tangent.x)
	aim_pos += perp * _personality_offset * road_half_w

	# Avoid other cars
	var avoid: Dictionary = _avoidance()
	aim_pos += avoid["offset"]

	# Compute steering
	var desired_heading: float = (aim_pos - _car.position).angle() + PI / 2.0
	var heading_error: float = wrapf(desired_heading - _car.rotation, -PI, PI)
	_car.ai_steer = clampf(heading_error * STEER_GAIN, -1.0, 1.0)

	# Rubber-banding, throttled down when another car blocks the path ahead
	var speed_mult: float = _compute_rubber_band_factor()
	_car.ai_throttle = clampf(speed_mult, 0.0, 1.5) * avoid["throttle_scale"]
	_car.ai_brake_input = 0.0

	# AI drift: sometimes drift for style when going fast around corners
	_car.ai_drift = abs(heading_error) > 0.3 and _car.speed > 400.0


func _compute_rubber_band_factor() -> float:
	var race_mgr: Node = get_node_or_null("/root/RaceManager")
	if not race_mgr or not race_mgr.has_method("get_player_median_progress"):
		return 1.0
	var player_median: float = race_mgr.get_player_median_progress()
	var my_progress: float = race_mgr.get_car_progress(_car)
	var delta: float = my_progress - player_median
	# Soft: ±8% shift
	var factor: float = 1.0 - clampf(delta * 0.16, -0.08, 0.08)
	return factor


## Returns {"offset": Vector2 aim displacement, "throttle_scale": float}.
## Detection range scales with speed so a fast car reacts in time; a slow
## obstacle dead ahead also cuts throttle so we swerve instead of ramming.
func _avoidance() -> Dictionary:
	var result: Dictionary = {"offset": Vector2.ZERO, "throttle_scale": 1.0}
	var race_mgr: Node = get_node_or_null("/root/RaceManager")
	if not race_mgr or not race_mgr.has_method("get_cars_list"):
		return result
	var all_cars: Array = race_mgr.get_cars_list()
	var my_pos: Vector2 = _car.position
	var my_fwd: Vector2 = Vector2.UP.rotated(_car.rotation)
	var side: Vector2 = Vector2(-my_fwd.y, my_fwd.x)
	var range_ahead: float = maxf(COLLISION_AVOID_DIST, absf(_car.speed) * 0.45)
	# Consider the whole cluster of cars ahead, not just the first one found:
	# reacting to one car at a time makes the dodge direction oscillate when
	# two cars sit side by side (e.g. the starting grid).
	var lat_sum: float = 0.0
	var blockers: int = 0
	var nearest_along: float = INF
	var nearest_speed: float = 0.0
	for other in all_cars:
		if other == _car:
			continue
		var to_other: Vector2 = other.position - my_pos
		var along: float = to_other.dot(my_fwd)
		if along < 0.0 or along > range_ahead:
			continue
		var lateral: float = to_other.dot(side)
		if absf(lateral) < AVOID_LATERAL_RANGE:
			blockers += 1
			lat_sum += lateral
			if along < nearest_along:
				nearest_along = along
				nearest_speed = other.velocity.length() if "velocity" in other else 0.0
	if blockers == 0:
		return result
	var mean_lat: float = lat_sum / float(blockers)
	var dir: float = -signf(mean_lat)
	if absf(mean_lat) < 8.0:
		# Cluster dead ahead: pick a consistent per-driver side to pass on.
		dir = 1.0 if _personality_offset >= 0.0 else -1.0
	result["offset"] = side * (AVOID_PUSH * dir)
	# Nearly stationary obstacle close ahead: ease off so steering can carry
	# us around it instead of plowing into it.
	if nearest_along < 130.0 and nearest_speed < 100.0:
		result["throttle_scale"] = 0.35
	return result
