extends Node2D

const AIDriver = preload("res://scripts/ai_driver.gd")

@export var track_seed: int = -1

var track: NodePath = "Track"
var car_scene: PackedScene = preload("res://scenes/car.tscn")

var _camera: Camera2D = null
var _hud_canvas: CanvasLayer

# HUD labels
var _p1_lap_label: Label
var _p1_pos_label: Label
var _p1_speed_label: Label
var _p1_best_label: Label
var _p2_lap_label: Label
var _p2_pos_label: Label
var _p2_speed_label: Label
var _p2_best_label: Label
var _timer_label: Label
var _countdown_label: Label
var _results_panel: Control

var _cars: Array = []
var _ai_drivers: Array = []
var _track: Node2D

var _frame_count: int = 0


func _ready() -> void:
	_track = $World/Track
	if track_seed >= 0:
		_track.set_seed(track_seed)
	_cars = [
		$World/Car1,
		$World/Car2,
		$World/Car3,
		$World/Car4,
	]

	# Camera setup
	_camera = $Camera2D
	_camera.position = Vector2.ZERO
	var zoom: float = _track.get_whole_track_zoom(Vector2(1920, 1080))
	# For MVP, static zoom — no following (Super Sprint whole-track style)
	_camera.zoom = Vector2(zoom, zoom)

	# Place cars at staggered starting grid (2 rows, 2 columns)
	for i in range(4):
		var car: CharacterBody2D = _cars[i]
		_cars[i].track = _track
		_cars[i].setup(i)
		_cars[i].position = _track.get_start_position(i)
		_cars[i].rotation = _track.get_start_rotation(i)
		_cars[i].reset_state(_track.get_start_rotation(i))

	# Attach AI drivers to Car3 and Car4
	for i in range(2, 4):
		var ai: AIDriver = AIDriver.new()
		ai.name = "AIDriver%d" % (i + 1)
		_cars[i].add_child(ai)
		ai.setup(_track, _cars[i])
		_ai_drivers.append(ai)

	# Register with RaceManager (car, human=true for P1/P2)
	RaceManager.reset_race_data()
	RaceManager.register_car(_cars[0], true)
	RaceManager.register_car(_cars[1], true)
	RaceManager.register_car(_cars[2], false)
	RaceManager.register_car(_cars[3], false)

	# Connect signals
	if not RaceManager.countdown_tick.is_connected(_on_countdown_tick):
		RaceManager.countdown_tick.connect(_on_countdown_tick)
	if not RaceManager.race_started.is_connected(_on_race_started):
		RaceManager.race_started.connect(_on_race_started)
	if not RaceManager.race_finished.is_connected(_on_race_finished):
		RaceManager.race_finished.connect(_on_race_finished)

	RaceManager.start_race()

	_build_hud()
	print("Retro race scene ready: 4 cars (2 human + 2 AI), whole-track view, zoom=%.2f" % zoom)


func _build_hud() -> void:
	_hud_canvas = CanvasLayer.new()
	_hud_canvas.name = "HUD"
	_hud_canvas.layer = 10
	add_child(_hud_canvas)

	# ── P1 HUD -- bottom-left ──
	var p1_box: VBoxContainer = VBoxContainer.new()
	p1_box.position = Vector2(40, 1080 - 180)
	_p1_pos_label = Label.new()
	_p1_pos_label.text = "P1  1/4"
	_p1_pos_label.add_theme_font_size_override("font_size", 32)
	_p1_pos_label.add_theme_color_override("font_color", Color(0.3, 0.7, 1.0))
	p1_box.add_child(_p1_pos_label)
	_p1_lap_label = Label.new()
	_p1_lap_label.text = "LAP 1/3"
	_p1_lap_label.add_theme_font_size_override("font_size", 24)
	_p1_lap_label.add_theme_color_override("font_color", Color.WHITE)
	p1_box.add_child(_p1_lap_label)
	_p1_speed_label = Label.new()
	_p1_speed_label.text = "SPD 0"
	_p1_speed_label.add_theme_font_size_override("font_size", 20)
	_p1_speed_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	p1_box.add_child(_p1_speed_label)
	_p1_best_label = Label.new()
	_p1_best_label.text = "BEST --.-"
	_p1_best_label.add_theme_font_size_override("font_size", 18)
	_p1_best_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))
	p1_box.add_child(_p1_best_label)
	_hud_canvas.add_child(p1_box)

	# ── P2 HUD -- bottom-right ──
	var p2_box: VBoxContainer = VBoxContainer.new()
	p2_box.position = Vector2(1920 - 220, 1080 - 180)
	_p2_pos_label = Label.new()
	_p2_pos_label.text = "P2  1/4"
	_p2_pos_label.add_theme_font_size_override("font_size", 32)
	_p2_pos_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	p2_box.add_child(_p2_pos_label)
	_p2_lap_label = Label.new()
	_p2_lap_label.text = "LAP 1/3"
	_p2_lap_label.add_theme_font_size_override("font_size", 24)
	_p2_lap_label.add_theme_color_override("font_color", Color.WHITE)
	p2_box.add_child(_p2_lap_label)
	_p2_speed_label = Label.new()
	_p2_speed_label.text = "SPD 0"
	_p2_speed_label.add_theme_font_size_override("font_size", 20)
	_p2_speed_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	p2_box.add_child(_p2_speed_label)
	_p2_best_label = Label.new()
	_p2_best_label.text = "BEST --.-"
	_p2_best_label.add_theme_font_size_override("font_size", 18)
	_p2_best_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))
	p2_box.add_child(_p2_best_label)
	_hud_canvas.add_child(p2_box)

	# ── Timer -- top-center ──
	_timer_label = Label.new()
	_timer_label.position = Vector2(900, 30)
	_timer_label.text = "0.00"
	_timer_label.add_theme_font_size_override("font_size", 36)
	_timer_label.add_theme_color_override("font_color", Color.WHITE)
	_hud_canvas.add_child(_timer_label)

	# ── Countdown overlay -- center ──
	_countdown_label = Label.new()
	_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_countdown_label.set_anchors_preset(Control.PRESET_CENTER)
	_countdown_label.add_theme_font_size_override("font_size", 200)
	_countdown_label.add_theme_color_override("font_color", Color.YELLOW)
	_countdown_label.text = ""
	_hud_canvas.add_child(_countdown_label)

	# ── Results panel (hidden) ──
	_results_panel = Control.new()
	_results_panel.name = "Results"
	_results_panel.visible = false
	_results_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg: ColorRect = ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0.82)
	_results_panel.add_child(bg)
	_hud_canvas.add_child(_results_panel)


func _process(_delta: float) -> void:
	_frame_count += 1

	# Feed car progress into RaceManager
	if _track and RaceManager.is_racing():
		for car in _cars:
			var p: float = _track.get_center_progress(car.position)
			RaceManager.update_car_progress(car, p)

	# Update HUD at ~10 Hz
	if _frame_count % 6 == 0:
		_update_hud()


func _update_hud() -> void:
	# P1
	if _cars[0]:
		var pos1: int = RaceManager.get_position(_cars[0])
		var lap1: int = mini(RaceManager.get_lap(_cars[0]) + 1, RaceManager.TOTAL_LAPS)
		_p1_pos_label.text = "P1  %d/%d" % [pos1, RaceManager.get_total_cars()]
		_p1_lap_label.text = "LAP %d/%d" % [lap1, RaceManager.TOTAL_LAPS]
		_p1_speed_label.text = "SPD %d" % int(_cars[0].get_speed())
		var best1: int = RaceManager.get_car_best_lap_ms(_cars[0])
		if best1 >= 0:
			_p1_best_label.text = "BEST %.2f" % (best1 / 1000.0)
		else:
			_p1_best_label.text = "BEST --.-"
	# P2
	if _cars[1]:
		var pos2: int = RaceManager.get_position(_cars[1])
		var lap2: int = mini(RaceManager.get_lap(_cars[1]) + 1, RaceManager.TOTAL_LAPS)
		_p2_pos_label.text = "P2  %d/%d" % [pos2, RaceManager.get_total_cars()]
		_p2_lap_label.text = "LAP %d/%d" % [lap2, RaceManager.TOTAL_LAPS]
		_p2_speed_label.text = "SPD %d" % int(_cars[1].get_speed())
		var best2: int = RaceManager.get_car_best_lap_ms(_cars[1])
		if best2 >= 0:
			_p2_best_label.text = "BEST %.2f" % (best2 / 1000.0)
		else:
			_p2_best_label.text = "BEST --.-"
	# Timer
	_timer_label.text = "%.2f" % RaceManager.get_elapsed_time()


# ── Signal handlers ──
func _on_countdown_tick(value: int) -> void:
	if value >= 1:
		_countdown_label.text = str(value)
		_countdown_label.add_theme_color_override("font_color", Color.YELLOW)
	elif value == 0:
		_countdown_label.text = "GO!"
		_countdown_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))


func _on_race_started() -> void:
	var t: SceneTreeTimer = get_tree().create_timer(0.7)
	t.timeout.connect(func(): _countdown_label.text = "")


func _on_race_finished() -> void:
	_results_panel.visible = true
	# Build results list
	var order: Array = RaceManager.get_finish_order()
	var results_text: String = "RACE COMPLETE\n\n"
	for i in range(order.size()):
		var car = order[i]
		var idx: int = _cars.find(car)
		var time_s: float = RaceManager.get_car_finish_time(car)
		var best: int = RaceManager.get_car_best_lap_ms(car)
		var best_str: String = "%.2f" % (best / 1000.0) if best >= 0 else "--.--"
		results_text += "%d. CAR %d -- %.2fs (best %ss)\n" % [i + 1, idx + 1, time_s, best_str]
	# Add any unfinished cars
	for i in range(_cars.size()):
		var car = _cars[i]
		if car not in order:
			var lap: int = RaceManager.get_lap(car)
			results_text += "%d. CAR %d -- DNF lap %d\n" % [order.size() + 1, i + 1, lap]

	# Create label
	var lbl: Label = Label.new()
	lbl.name = "ResultsText"
	lbl.text = results_text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.set_anchors_preset(Control.PRESET_CENTER)
	lbl.add_theme_font_size_override("font_size", 36)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))
	_results_panel.add_child(lbl)
	print(results_text)
