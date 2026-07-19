extends SceneTree

## Headless regression tests for ordered procedural checkpoints and car layers.

var failures: int = 0

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("FAIL: " + message)


func _make_manager_with_car() -> Array:
	var manager: Node = load("res://scripts/race_manager.gd").new()
	var car: Node = Node.new()
	manager.register_car(car, true)
	manager.state = manager.State.RACING
	manager.race_start_time = Time.get_ticks_msec()
	manager._car_lap_start_ms[car] = manager.race_start_time
	return [manager, car]


func _test_checkpoint_order() -> void:
	var setup: Array = _make_manager_with_car()
	var manager: Node = setup[0]
	var car: Node = setup[1]

	manager.cross_checkpoint(car, 1)
	_check(manager.get_next_checkpoint(car) == 0, "out-of-order checkpoint must be ignored")

	manager.cross_checkpoint(car, 0)
	_check(manager.get_next_checkpoint(car) == 1, "first checkpoint must advance expected index")

	manager.cross_checkpoint(car, 1)
	manager.cross_checkpoint(car, 2)
	manager.cross_checkpoint(car, 3)
	_check(manager.get_next_checkpoint(car) == manager.NUM_CHECKPOINTS, "all ordered checkpoints must complete the gate sequence")

	manager.cross_start_finish(car)
	_check(manager.get_lap(car) == 1, "finish must count a lap after ordered checkpoints")
	_check(manager.get_next_checkpoint(car) == 0, "new lap must reset expected checkpoint")
	manager.free()
	car.free()


func _test_car_collision_policy() -> void:
	var car_scene: PackedScene = load("res://scenes/car.tscn")
	var car: CharacterBody2D = car_scene.instantiate()
	_check(car.collision_layer == 2, "cars must stay on layer 2 for trigger detection")
	_check(car.collision_mask == 1, "cars must collide with walls only, never other cars")
	car.free()


func _init() -> void:
	_test_checkpoint_order()
	_test_car_collision_policy()
	if failures == 0:
		print("PASS: ordered checkpoints and car collision policy")
	else:
		print("FAIL: %d race progression assertions" % failures)
	quit(0 if failures == 0 else 1)
