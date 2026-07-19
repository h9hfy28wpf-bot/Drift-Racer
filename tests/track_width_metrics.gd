extends SceneTree

## Deterministic acceptance and edge-safety metrics for procedural width tuning.
## Usage: godot --headless --path . -s tests/track_width_metrics.gd -- --seeds=60

var failures: int = 0
var seed_count: int = 60


func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seeds="):
			seed_count = int(arg.trim_prefix("--seeds="))
	_run_metrics()


func _run_metrics() -> void:
	var track_gd: GDScript = load("res://scripts/track.gd")
	var total_attempts: int = 0
	var max_attempts: int = 0
	var min_radius: float = INF
	var min_vertex_gap: float = INF
	var accepted_radii: Array[float] = []
	var accepted_vertex_gaps: Array[float] = []
	var attempts_used: Array[int] = []

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
			attempts_used.append(used)
			max_attempts = maxi(max_attempts, used)
			var radius: float = track_gd._min_turn_radius(path)
			var vertex_gap: float = _minimum_non_adjacent_vertex_gap(edges[0], edges[1])
			accepted_radii.append(radius)
			accepted_vertex_gaps.append(vertex_gap)
			min_radius = minf(min_radius, radius)
			min_vertex_gap = minf(min_vertex_gap, vertex_gap)
			break
		if not accepted:
			failures += 1
			print("FAIL seed %d: no accepted candidate" % seed_value)

	var accepted_count: int = seed_count - failures
	var average_attempts: float = float(total_attempts) / float(accepted_count) if accepted_count > 0 else INF
	attempts_used.sort()
	accepted_radii.sort()
	accepted_vertex_gaps.sort()
	var median_radius: float = _median_float(accepted_radii)
	var median_vertex_gap: float = _median_float(accepted_vertex_gaps)
	var p95_attempts: int = _percentile_int(attempts_used, 0.95)
	var p99_attempts: int = _percentile_int(attempts_used, 0.99)
	print("METRICS width=%.1f margin=%.1f min_radius_required=%.1f nonadjacent_anchor_gap=%.1f seeds=%d accepted=%d failed=%d fallback=%d avg_attempts=%.3f max_attempts=%d p95_attempts=%d p99_attempts=%d min_radius=%.3f median_radius=%.3f min_same_ring_vertex_gap=%.3f median_same_ring_vertex_gap=%.3f" % [track_gd.TRACK_WIDTH, track_gd.WALL_MARGIN, track_gd.MIN_TURN_RADIUS, track_gd.ANCHOR_MIN_GAP_OTHER, seed_count, accepted_count, failures, failures, average_attempts, max_attempts, p95_attempts, p99_attempts, min_radius, median_radius, min_vertex_gap, median_vertex_gap])
	quit(0 if failures == 0 else 1)


func _median_float(values: Array[float]) -> float:
	if values.is_empty():
		return INF
	var middle: int = values.size() / 2
	if values.size() % 2 == 1:
		return values[middle]
	return (values[middle - 1] + values[middle]) * 0.5


func _percentile_int(values: Array[int], percentile: float) -> int:
	if values.is_empty():
		return 0
	var index: int = mini(values.size() - 1, int(ceil(percentile * float(values.size()))) - 1)
	return values[index]


## Diagnostic only: same-ring vertex spacing, not segment-to-segment clearance.
func _minimum_non_adjacent_vertex_gap(outer: PackedVector2Array, inner: PackedVector2Array) -> float:
	var n: int = outer.size()
	var minimum: float = INF
	for i in range(n):
		for j in range(i + 3, n):
			if i == 0 and j >= n - 2:
				continue
			minimum = minf(minimum, outer[i].distance_to(outer[j]))
			minimum = minf(minimum, inner[i].distance_to(inner[j]))
	return minimum
