extends Node

## Race state machine + lap tracking + position ranking + best-lap memory.
## Arcade Super Sprint style: 3 laps, 4 checkpoints, per-car stats.

signal countdown_tick(value: int)
signal race_started
signal race_finished
signal lap_completed(car, lap_num: int)
signal position_changed(car, new_position: int)

enum State { COUNTDOWN, RACING, FINISHED }

const TOTAL_LAPS: int = 3
const NUM_CHECKPOINTS: int = 4
const ZONE_HALF_WIDTH: float = 0.06

var state: int = State.COUNTDOWN
var countdown_value: int = 3
var countdown_timer: float = 1.0

var cars: Array = []                      # all cars (players + AI)
var _human_cars: Array = []               # only human players (for rubber-band baseline)
var _car_checkpoints: Dictionary = {}     # car -> Array[bool]
var _car_last_progress: Dictionary = {}   # car -> float 0..1
var _car_laps: Dictionary = {}            # car -> int completed laps
var _car_finish_time: Dictionary = {}     # car -> float seconds
var _car_best_lap: Dictionary = {}        # car -> int milliseconds (-1 = unset)
var _car_lap_start_ms: Dictionary = {}    # car -> int ms
var _car_positions: Dictionary = {}       # car -> int (1-based rank)
var finish_order: Array = []              # cars in finish order
var race_start_time: int = 0
var elapsed_time: float = 0.0


func _ready() -> void:
	pass


func _process(delta: float) -> void:
	if state == State.COUNTDOWN:
		countdown_timer -= delta
		if countdown_timer <= 0.0:
			emit_signal("countdown_tick", countdown_value)
			countdown_value -= 1
			if countdown_value >= 0:
				countdown_timer = 1.0
			else:
				state = State.RACING
				race_start_time = Time.get_ticks_msec()
				# Initialize lap start for all cars
				for car in cars:
					_car_lap_start_ms[car] = race_start_time
				emit_signal("race_started")
	elif state == State.RACING:
		elapsed_time = (Time.get_ticks_msec() - race_start_time) / 1000.0
		_update_positions()


# ─── Registration ──────────────────────────────────────────────────
func register_car(car, human: bool = false) -> void:
	if car in cars:
		return
	cars.append(car)
	if human:
		_human_cars.append(car)
	var cp_flags: Array = []
	for _i in range(NUM_CHECKPOINTS):
		cp_flags.append(false)
	_car_checkpoints[car] = cp_flags
	_car_last_progress[car] = 0.0
	_car_laps[car] = 0
	_car_finish_time[car] = -1.0
	_car_best_lap[car] = -1
	_car_lap_start_ms[car] = -1
	_car_positions[car] = cars.size()   # will be recomputed next frame


func reset_race_data() -> void:
	cars.clear()
	_human_cars.clear()
	_car_checkpoints.clear()
	_car_last_progress.clear()
	_car_laps.clear()
	_car_finish_time.clear()
	_car_best_lap.clear()
	_car_lap_start_ms.clear()
	_car_positions.clear()
	finish_order.clear()
	elapsed_time = 0.0
	race_start_time = 0
	state = State.COUNTDOWN
	countdown_value = 3
	countdown_timer = 1.0


func start_race() -> void:
	state = State.COUNTDOWN
	countdown_value = 3
	countdown_timer = 1.0


# ─── Progress updates (tracks checkpoints only) ──────────
func update_car_progress(car, progress: float) -> void:
	_car_last_progress[car] = progress

	if state != State.RACING:
		return
	if car in finish_order:
		return

	# Mark checkpoints visited
	for i in range(NUM_CHECKPOINTS):
		var cp_center: float = float(i) / float(NUM_CHECKPOINTS)
		if _in_zone(progress, cp_center, ZONE_HALF_WIDTH):
			_car_checkpoints[car][i] = true

func _in_zone(progress: float, center: float, half_width: float) -> bool:
	var diff: float = wrapf(progress - center, -0.5, 0.5)
	return abs(diff) < half_width


# ─── Start/finish line crossing (called by Area2D) ──────────
func cross_start_finish(car) -> void:
	if state != State.RACING:
		return
	if car in finish_order:
		return

	# Check if all checkpoints were visited
	var all_visited: bool = true
	for flag in _car_checkpoints[car]:
		if not flag:
			all_visited = false
			break

	if all_visited:
		# Lap completed
		var now_ms: int = Time.get_ticks_msec()
		var lap_duration_ms: int = now_ms - _car_lap_start_ms.get(car, now_ms)
		_car_laps[car] += 1
		emit_signal("lap_completed", car, _car_laps[car])

		# Update best lap
		var current_best: int = _car_best_lap.get(car, -1)
		if current_best < 0 or lap_duration_ms < current_best:
			_car_best_lap[car] = lap_duration_ms

		# Reset for next lap
		_car_lap_start_ms[car] = now_ms
		for i in range(NUM_CHECKPOINTS):
			_car_checkpoints[car][i] = false

		# Check for race finish
		if _car_laps[car] >= TOTAL_LAPS:
			_car_finish_time[car] = elapsed_time
			finish_order.append(car)
			if finish_order.size() >= cars.size():
				state = State.FINISHED
				emit_signal("race_finished")


# ─── Position ranking ─────────────────────────────────────────────
## Ranks all cars by: (laps_completed, progress). Higher lap first, then higher progress.
func _update_positions() -> void:
	# Build sortable entries: [lap_score, car] where lap_score = laps + progress
	var entries: Array = []
	for car in cars:
		var score: float = float(_car_laps.get(car, 0)) + _car_last_progress.get(car, 0.0)
		entries.append([score, car])
	# Sort descending by score
	entries.sort_custom(func(a, b):
		return a[0] > b[0]
	)
	# Assign rank 1-based
	for i in range(entries.size()):
		var car = entries[i][1]
		var new_pos: int = i + 1
		var old_pos: int = _car_positions.get(car, new_pos)
		if new_pos != old_pos:
			emit_signal("position_changed", car, new_pos)
		_car_positions[car] = new_pos


# ─── Public API ───────────────────────────────────────────────────
func is_input_locked() -> bool:
	return state != State.RACING

func is_racing() -> bool:
	return state == State.RACING

func is_finished() -> bool:
	return state == State.FINISHED

func get_countdown_value() -> int:
	return countdown_value

func get_lap(car) -> int:
	return _car_laps.get(car, 0)

func get_position(car) -> int:
	return _car_positions.get(car, 1)

func get_car_progress(car) -> float:
	return _car_last_progress.get(car, 0.0)

func get_elapsed_time() -> float:
	return elapsed_time

func get_finish_order() -> Array:
	return finish_order

func get_car_finish_time(car) -> float:
	return _car_finish_time.get(car, -1.0)

func get_car_best_lap_ms(car) -> int:
	return _car_best_lap.get(car, -1)

func get_total_cars() -> int:
	return cars.size()


func get_cars_list() -> Array:
	return cars


## Median progress of human players (for rubber-banding baseline).
func get_player_median_progress() -> float:
	if _human_cars.is_empty():
		return 0.0
	var progresses: Array = []
	for car in _human_cars:
		var lap_score: float = float(_car_laps.get(car, 0)) + _car_last_progress.get(car, 0.0)
		progresses.append(lap_score)
	progresses.sort()
	var mid: int = int(progresses.size()) / 2
	return progresses[mid]
