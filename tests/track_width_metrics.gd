extends SceneTree

## Deterministic acceptance and edge-safety metrics for procedural width tuning.
## Usage: godot --headless --path . -s tests/track_width_metrics.gd -- --seeds=60

var failures: int = 0
var seed_count: int = 60


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seeds="):
			seed_count = int(arg.trim_prefix("--seeds="))
	_run_metrics()


func _run_metrics() -> void:
	var track_gd: GDScript = load("res://scripts/track.gd")
	var total_attempts: int = 0
	var max_attempts: int = 0
	var min_radius: float = INF
	var min_edge_gap: float = INF

	for seed_value in range(1, seed_count + 1):
		var rng: RandomNumberGenerator = RandomNumberGenerator.new()
		rng.seed = seed_value
		var accepted: bool = false
		for attempt in range(track_gd.MAX_GEN_ATTEMPTS):
			var anchors: Array = track_gd._make_anchors(rng)
			if not track_gd._anchors_ok(anchors):
				continue
			var path: PackedVector2Array = track_gd._build_center_path(anchors)
			if track_gd._min_turn_radius(path) < track_gd.MIN_TURN_RADIUS:
				continue
			var edges: Array = track_gd._build_edges(path)
			if not track_gd._ring_is_simple(edges[0]) or not track_gd._ring_is_simple(edges[1]):
				continue
			accepted = true
			var used: int = attempt + 1
			total_attempts += used
			max_attempts = maxi(max_attempts, used)
			min_radius = minf(min_radius, track_gd._min_turn_radius(path))
			min_edge_gap = minf(min_edge_gap, _minimum_non_adjacent_gap(edges[0], edges[1]))
			break
		if not accepted:
			failures += 1
			print("FAIL seed %d: no accepted candidate" % seed_value)

	var accepted_count: int = seed_count - failures
	var average_attempts: float = float(total_attempts) / float(accepted_count) if accepted_count > 0 else INF
	print("METRICS width=%.1f margin=%.1f min_radius_required=%.1f nonadjacent_anchor_gap=%.1f seeds=%d accepted=%d failed=%d avg_attempts=%.3f max_attempts=%d min_accepted_radius=%.3f min_nonadjacent_edge_gap=%.3f" % [track_gd.TRACK_WIDTH, track_gd.WALL_MARGIN, track_gd.MIN_TURN_RADIUS, track_gd.ANCHOR_MIN_GAP_OTHER, seed_count, accepted_count, failures, average_attempts, max_attempts, min_radius, min_edge_gap])
	quit(0 if failures == 0 else 1)


func _minimum_non_adjacent_gap(outer: PackedVector2Array, inner: PackedVector2Array) -> float:
	var n: int = outer.size()
	var minimum: float = INF
	for i in range(n):
		for j in range(i + 3, n):
			if i == 0 and j >= n - 2:
				continue
			minimum = minf(minimum, outer[i].distance_to(outer[j]))
			minimum = minf(minimum, inner[i].distance_to(inner[j]))
	return minimum
