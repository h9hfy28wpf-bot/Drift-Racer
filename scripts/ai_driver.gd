extends Node2D
class_name AIDriver

## AI driver: follows track centerline with lateral noise + rubber-banding.
## Attach to a CharacterBody2D that has a car.gd script.

const LOOKAHEAD_SAMPLES: int = 18
const STEER_GAIN: float = 2.8
const COLLISION_AVOID_DIST: float = 80.0

var _track = null  # typed as Track but untyped var to avoid load-order issues
var _car: CharacterBody2D = null
var _personality_offset: float = 0.0


func setup(track_ref, car_ref: CharacterBody2D) -> void:
	_track = track_ref
	_car = car_ref
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_personality_offset = rng.randf_range(-0.55, 0.55)
	if _car:
		_car.is_ai = true


func _physics_process(_delta: float) -> void:
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
	var avoid_offset: Vector2 = _avoidance_offset()
	aim_pos += avoid_offset

	# Compute steering
	var desired_heading: float = (aim_pos - _car.position).angle() + PI / 2.0
	var heading_error: float = wrapf(desired_heading - _car.rotation, -PI, PI)
	_car.ai_steer = clampf(heading_error * STEER_GAIN, -1.0, 1.0)

	# Rubber-banding
	var speed_mult: float = _compute_rubber_band_factor()
	_car.ai_throttle = clampf(speed_mult, 0.0, 1.5)
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


func _avoidance_offset() -> Vector2:
	var race_mgr: Node = get_node_or_null("/root/RaceManager")
	if not race_mgr:
		return Vector2.ZERO
	var all_cars: Array
	if race_mgr.has_method("get_cars_list"):
		all_cars = race_mgr.get_cars_list()
	else:
		return Vector2.ZERO
	var my_pos: Vector2 = _car.position
	var my_fwd: Vector2 = Vector2.UP.rotated(_car.rotation)
	for other in all_cars:
		if other == _car:
			continue
		var to_other: Vector2 = other.position - my_pos
		var along: float = to_other.dot(my_fwd)
		if along < 0.0 or along > COLLISION_AVOID_DIST:
			continue
		var lateral: Vector2 = to_other - my_fwd * along
		if lateral.length() < 40.0:
			var side: Vector2 = Vector2(-my_fwd.y, my_fwd.x)
			if lateral.dot(side) > 0.0:
				return side * 25.0
			else:
				return -side * 25.0
	return Vector2.ZERO
