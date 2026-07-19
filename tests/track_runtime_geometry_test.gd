extends SceneTree

## Instantiates a deterministic track and verifies generated trigger spans.

var failures: int = 0


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("FAIL: " + message)


func _axis_span(shape_node: CollisionShape2D) -> float:
	var shape: RectangleShape2D = shape_node.shape as RectangleShape2D
	return shape.size.x


func _init() -> void:
	var track_scene: PackedScene = load("res://scenes/track.tscn")
	var track: Node2D = track_scene.instantiate()
	track.set_seed(1)
	get_root().add_child(track)
	await process_frame

	var finish: Area2D = track.get_node("StartFinishLine") as Area2D
	var finish_shape: CollisionShape2D = finish.get_node("CollisionShape2D") as CollisionShape2D
	_check(finish.collision_layer == 0 and finish.collision_mask == 2, "start/finish must detect car layer 2 only")
	_check(is_equal_approx(_axis_span(finish_shape), track.TRACK_WIDTH), "start/finish span must equal TRACK_WIDTH")

	var checkpoints: Node2D = track.get_node("Checkpoints") as Node2D
	_check(checkpoints.get_child_count() == 4, "track must generate four checkpoints")
	for checkpoint_index in range(checkpoints.get_child_count()):
		var gate: Area2D = checkpoints.get_child(checkpoint_index) as Area2D
		var shape_node: CollisionShape2D = gate.get_child(0) as CollisionShape2D
		_check(gate.collision_layer == 0 and gate.collision_mask == 2, "checkpoint %d must detect car layer 2 only" % checkpoint_index)
		_check(_axis_span(shape_node) > 0.0, "checkpoint %d must have a positive cross-track span" % checkpoint_index)

	track.queue_free()
	await process_frame
	if failures == 0:
		print("PASS: runtime trigger geometry")
	else:
		print("FAIL: %d runtime trigger geometry assertions" % failures)
	quit(0 if failures == 0 else 1)
