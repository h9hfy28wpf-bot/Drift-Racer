extends Area2D

var _start_time: int = 0
const GRACE_PERIOD_MS: int = 1500


func _ready() -> void:
	_start_time = Time.get_ticks_msec()
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node2D) -> void:
	if not body.has_method("get_player_index"):
		return

	# Grace period to avoid false crossings at spawn
	var elapsed_ms: int = Time.get_ticks_msec() - _start_time
	if elapsed_ms < GRACE_PERIOD_MS:
		return

	var race_manager: Node = get_node_or_null("/root/RaceManager")
	if race_manager:
		race_manager.cross_start_finish(body)
