extends CharacterBody2D

## Arcade drift car — velocity decomposition, drift meter, boost stages.
## Shared by player + AI.

const MAX_SPEED: float = 800.0
const ACCELERATION: float = 1200.0
const BRAKE_FORCE: float = 1500.0
const STEER_SPEED: float = 4.5
const DRIFT_STEER_SPEED: float = 3.2
const FRICTION: float = 300.0
const DRIFT_SPEED_PENALTY: float = 50.0
const REVERSE_MAX: float = 0.5

# Surface physics
const GRASS_SPEED_MULT: float = 0.70
const WALL_SPEED_MULT: float = 0.15

# Drift
const DRIFT_ENTER_SPEED: float = 200.0
const DRIFT_LATERAL_BLEED: float = 0.82
const DRIFT_VELOCITY_SNAP: float = 0.35
const DRIFT_ANGLE_MAX: float = 0.9
const DRIFT_FILL_RATE: float = 0.55
const MINI_BOOST_THRESHOLD: float = 0.30
const SUPER_BOOST_THRESHOLD: float = 0.70
const MINI_BOOST_MULT: float = 1.35
const MINI_BOOST_TIME: float = 0.5
const SUPER_BOOST_MULT: float = 1.65
const SUPER_BOOST_TIME: float = 1.0

# Visual
const CAR_WIDTH: float = 24.0
const CAR_HEIGHT: float = 48.0
const P1_COLOR: Color = Color(0.3, 0.7, 1.0)
const P2_COLOR: Color = Color(1.0, 0.5, 0.3)
const P3_COLOR: Color = Color(0.4, 1.0, 0.4)
const P4_COLOR: Color = Color(0.9, 0.4, 0.9)
const SMOKE_MAX_AGE: float = 0.55

# State
var player_index: int = -1
var input_prefix: String = ""
var is_ai: bool = false
var track = null  # Reference to track node (set by race_scene)
var finished: bool = false  # True when car has completed the race

var speed: float = 0.0
var drift_active: bool = false
var drift_meter: float = 0.0
var boost_timer: float = 0.0
var boost_strength: float = 1.0
var _prev_rotation: float = 0.0
var surface_speed_mult: float = 1.0

# AI inputs (set by ai_driver.gd each frame)
var ai_throttle: float = 0.0
var ai_brake_input: float = 0.0
var ai_steer: float = 0.0
var ai_drift: bool = false

var _smoke_points: Array = []
var _hazard_cooldowns: Dictionary = {}
var _oil_timer: float = 0.0


func _ready() -> void:
	if player_index == -1:
		setup(0)


func setup(p_index: int, face_rotation: float = 0.0) -> void:
	player_index = p_index
	input_prefix = "p%d_" % (p_index + 1)
	rotation = face_rotation
	_prev_rotation = rotation
	queue_redraw()


func reset_state(face_rotation: float = 0.0) -> void:
	velocity = Vector2.ZERO
	rotation = face_rotation
	_prev_rotation = face_rotation
	speed = 0.0
	drift_active = false
	drift_meter = 0.0
	boost_timer = 0.0
	boost_strength = 1.0
	_smoke_points.clear()
	_hazard_cooldowns.clear()
	_oil_timer = 0.0
	queue_redraw()


func get_player_index() -> int:
	return player_index


func get_speed() -> float:
	return speed


func get_drift_meter() -> float:
	return drift_meter


func get_boost_timer() -> float:
	return boost_timer


func is_drifting() -> bool:
	return drift_active


func _physics_process(delta: float) -> void:
	if player_index == -1:
		return

	var race_mgr: Node = get_node_or_null("/root/RaceManager")
	if race_mgr and race_mgr.has_method("is_input_locked"):
		if race_mgr.is_input_locked():
			velocity = velocity.move_toward(Vector2.ZERO, 600.0 * delta)
			move_and_slide()
			queue_redraw()
			return

	# Surface detection
	surface_speed_mult = 1.0
	if track and track.has_method("get_surface_at"):
		var surface: int = track.get_surface_at(global_position)
		if surface == Track.Surface.GRASS:
			surface_speed_mult = GRASS_SPEED_MULT
		elif surface == Track.Surface.WALL:
			surface_speed_mult = WALL_SPEED_MULT

	# 1. Read input
	var move_input: float
	var steer_input: float
	var drift_input: bool
	if is_ai:
		move_input = ai_throttle
		steer_input = ai_steer
		drift_input = ai_drift
	else:
		move_input = Input.get_axis(input_prefix + "down", input_prefix + "up")
		steer_input = Input.get_axis(input_prefix + "left", input_prefix + "right")
		drift_input = Input.is_action_pressed(input_prefix + "button1")

	# 2. Steering
	var steer_rate: float = DRIFT_STEER_SPEED if drift_active else STEER_SPEED
	if abs(steer_input) > 0.01:
		rotation += steer_input * steer_rate * delta

	# 3. Drift enter/exit
	var abs_speed: float = abs(speed)
	if drift_input and abs_speed > DRIFT_ENTER_SPEED and abs(steer_input) > 0.15 and not drift_active:
		drift_active = true
	elif drift_active and (not drift_input or abs_speed < 40.0):
		_release_drift()

	# 4. Velocity build
	var heading: Vector2 = Vector2.UP.rotated(rotation)
	var heading_delta: float = wrapf(rotation - _prev_rotation, -PI, PI)
	_prev_rotation = rotation

	if drift_active:
		var current_vel_len: float = velocity.length()
		if current_vel_len > 5.0:
			velocity = velocity.rotated(heading_delta * DRIFT_VELOCITY_SNAP)
		else:
			velocity = heading * speed

		if move_input > 0.0:
			velocity += heading * ACCELERATION * move_input * delta
		elif move_input < 0.0:
			velocity += heading * BRAKE_FORCE * move_input * delta

		var v_parallel: Vector2 = heading * velocity.dot(heading)
		var v_perp: Vector2 = velocity - v_parallel
		var fwd_len: float = v_parallel.length()
		if fwd_len > 0.0:
			v_parallel = v_parallel.normalized() * maxf(fwd_len - DRIFT_SPEED_PENALTY * delta, 0.0)
		velocity = v_parallel + v_perp * DRIFT_LATERAL_BLEED

		speed = velocity.dot(heading)

		if velocity.length() > 10.0:
			var vel_dir: Vector2 = velocity.normalized()
			var angle_diff: float = abs(wrapf(heading.angle() - vel_dir.angle(), -PI, PI))
			var fill_ratio: float = minf(angle_diff / DRIFT_ANGLE_MAX, 1.0)
			drift_meter = minf(drift_meter + DRIFT_FILL_RATE * fill_ratio * delta, 1.0)

		_spawn_smoke()
	else:
		if move_input > 0.0:
			speed += ACCELERATION * move_input * delta
		elif move_input < 0.0:
			speed += BRAKE_FORCE * move_input * delta
		else:
			if abs(speed) < FRICTION * delta:
				speed = 0.0
			else:
				speed -= sign(speed) * FRICTION * delta
		var effective_max: float = MAX_SPEED * surface_speed_mult
		speed = clampf(speed, -effective_max * REVERSE_MAX, effective_max)
		velocity = heading * speed

	# 5. Boost
	if boost_timer > 0.0:
		boost_timer -= delta
		var boost_extra: float = speed * (boost_strength - 1.0)
		velocity += heading * boost_extra * delta * 4.0

	# 6. Speed clamp (includes surface multiplier)
	var effective_max_clamp: float = MAX_SPEED * surface_speed_mult * 1.2
	var forward_speed_now: float = velocity.length()
	if forward_speed_now > MAX_SPEED * 1.2:
		velocity = velocity.normalized() * MAX_SPEED * 1.2

	# 7. Hazard effects
	if _oil_timer > 0.0:
		_oil_timer -= delta
		# Random steering jitter while on oil
		if not drift_active:
			rotation += randf_range(-0.05, 0.05)
		
	_process_hazard_collisions()

	move_and_slide()
	_age_smoke(delta)
	queue_redraw()


func _release_drift() -> void:
	drift_active = false
	if drift_meter >= SUPER_BOOST_THRESHOLD:
		boost_strength = SUPER_BOOST_MULT
		boost_timer = SUPER_BOOST_TIME
	elif drift_meter >= MINI_BOOST_THRESHOLD:
		boost_strength = MINI_BOOST_MULT
		boost_timer = MINI_BOOST_TIME
	drift_meter = 0.0


func _spawn_smoke() -> void:
	var rl: Vector2 = Vector2(-CAR_WIDTH * 0.5 + 2.0, CAR_HEIGHT * 0.4)
	var rr: Vector2 = Vector2(CAR_WIDTH * 0.5 - 2.0, CAR_HEIGHT * 0.4)
	_smoke_points.append({"pos": to_global(rl), "age": 0.0, "size": 4.0})
	_smoke_points.append({"pos": to_global(rr), "age": 0.0, "size": 4.0})
	if _smoke_points.size() > 40:
		_smoke_points = _smoke_points.slice(_smoke_points.size() - 40)


func _age_smoke(delta: float) -> void:
	var i: int = _smoke_points.size() - 1
	while i >= 0:
		_smoke_points[i]["age"] += delta
		_smoke_points[i]["size"] += delta * 8.0
		if _smoke_points[i]["age"] > SMOKE_MAX_AGE:
			_smoke_points.remove_at(i)
		i -= 1


## Checks distance to each hazard and applies effects with cooldown.
func _process_hazard_collisions() -> void:
	if not track or not track.has_method("get_hazards"):
		return
	
	var hazards: Array = track.get_hazards()
	var hazard_id: int = 0
	
	for hazard in hazards:
		# Check cooldown
		if _hazard_cooldowns.has(hazard_id):
			hazard_id += 1
			continue
		
		var dist: float = position.distance_to(hazard["position"])
		if dist < hazard["radius"]:
			# Trigger hazard effect
			_apply_hazard(hazard["type"])
			# Set cooldown (2.5 seconds)
			_hazard_cooldowns[hazard_id] = 2.5
		
		hazard_id += 1
	
	# Decay cooldowns
	for key in _hazard_cooldowns.keys():
		_hazard_cooldowns[key] -= get_physics_process_delta_time()
		if _hazard_cooldowns[key] <= 0.0:
			_hazard_cooldowns.erase(key)


## Applies the effect of a hazard based on its type.
func _apply_hazard(type: int) -> void:
	match type:
		0:  # OIL - speed penalty + steering jitter
			speed *= 0.7  # 30% speed loss
			_oil_timer = 1.5  # 1.5 seconds of jitter
		1:  # BOOST - temporary speed increase
			boost_strength = 1.35
			boost_timer = 1.0
		2:  # RAMP - launch forward with speed burst
			speed = min(speed * 1.5, MAX_SPEED * 1.15)
			boost_strength = 1.4
			boost_timer = 0.8


func _draw() -> void:
	var base_color: Color
	match player_index:
		0: base_color = P1_COLOR
		1: base_color = P2_COLOR
		2: base_color = P3_COLOR
		3: base_color = P4_COLOR
		_: base_color = Color.GRAY

	var draw_color: Color = base_color
	if drift_active:
		draw_color = base_color.lerp(Color(1.0, 0.95, 0.5), 0.4)

	var half_w: float = CAR_WIDTH * 0.5
	var half_h: float = CAR_HEIGHT * 0.5
	var body_rect: Rect2 = Rect2(-half_w, -half_h, CAR_WIDTH, CAR_HEIGHT)

	for s in _smoke_points:
		var local_pos: Vector2 = to_local(s["pos"])
		var alpha: float = 1.0 - s["age"] / SMOKE_MAX_AGE
		draw_circle(local_pos, s["size"], Color(1.0, 1.0, 1.0, alpha * 0.6))

	if boost_timer > 0.0:
		var flame_len: float = 40.0 * (boost_strength - 1.0) / 0.65
		var flame_w: float = 10.0
		var flame_color: Color
		if boost_strength >= SUPER_BOOST_MULT:
			flame_color = Color(0.2, 1.0, 1.0, 0.9)
		else:
			flame_color = Color(1.0, 0.85, 0.2, 0.9)
		var flame_poly: PackedVector2Array = PackedVector2Array()
		flame_poly.append(Vector2(-flame_w, half_h - 2.0))
		flame_poly.append(Vector2(flame_w, half_h - 2.0))
		flame_poly.append(Vector2(0.0, half_h + flame_len))
		var flame_colors: PackedColorArray = PackedColorArray()
		flame_colors.append(flame_color)
		flame_colors.append(flame_color)
		flame_colors.append(flame_color.lightened(0.3))
		draw_polygon(flame_poly, flame_colors)

	draw_rect(body_rect, draw_color, true)
	var ws_color: Color = draw_color.lightened(0.45)
	draw_rect(Rect2(-half_w + 3.0, -half_h + 3.0, CAR_WIDTH - 6.0, 8.0), ws_color, true)
	var braking: bool = false
	if not is_ai and input_prefix != "":
		braking = Input.is_action_pressed(input_prefix + "down")
	else:
		braking = ai_brake_input > 0.1
	var bl_color: Color = Color.RED if braking else Color.DARK_RED
	draw_rect(Rect2(-half_w + 2.0, half_h - 8.0, 4.0, 6.0), bl_color, true)
	draw_rect(Rect2(half_w - 6.0, half_h - 8.0, 4.0, 6.0), bl_color, true)
	draw_rect(body_rect, Color.BLACK, false, 1.0)

	if drift_active or drift_meter > 0.01:
		var bar_w: float = CAR_WIDTH + 10.0
		var bar_h: float = 4.0
		var bar_y: float = -half_h - 10.0
		draw_rect(Rect2(-bar_w * 0.5, bar_y, bar_w, bar_h), Color(0.15, 0.15, 0.15, 0.9), true)
		var fill_color: Color
		if drift_meter >= SUPER_BOOST_THRESHOLD:
			fill_color = Color.CYAN
		elif drift_meter >= MINI_BOOST_THRESHOLD:
			fill_color = Color.YELLOW
		else:
			fill_color = Color(1.0, 0.4, 0.2)
		draw_rect(Rect2(-bar_w * 0.5, bar_y, bar_w * drift_meter, bar_h), fill_color, true)
		draw_rect(Rect2(-bar_w * 0.5 + bar_w * MINI_BOOST_THRESHOLD - 0.5, bar_y, 1.0, bar_h), Color.WHITE, true)
		draw_rect(Rect2(-bar_w * 0.5 + bar_w * SUPER_BOOST_THRESHOLD - 0.5, bar_y, 1.0, bar_h), Color.WHITE, true)
