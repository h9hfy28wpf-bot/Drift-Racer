extends SceneTree

## Regression test for the wall-collision / road-geometry fix (see README).
## Mirrors _generate_track()'s accept loop for many seeds and asserts that:
##   1. a layout is accepted within MAX_GEN_ATTEMPTS,
##   2. the accepted center path has no turn tighter than MIN_TURN_RADIUS,
##   3. both offset edge rings are simple polygons (no self-intersection).
##
## Run:  godot --headless -s tests/track_geometry_test.gd

const SEED_COUNT: int = 60

func _init() -> void:
	var track_gd: GDScript = load("res://scripts/track.gd")
	var failures: int = 0
	for seed_v in range(1, SEED_COUNT + 1):
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_v
		var accepted: bool = false
		for _attempt in range(track_gd.MAX_GEN_ATTEMPTS):
			var anchors: Array = track_gd._make_anchors(rng)
			if not track_gd._anchors_ok(anchors):
				continue
			var path: PackedVector2Array = track_gd._build_center_path(anchors)
			if track_gd._min_turn_radius(path) < track_gd.MIN_TURN_RADIUS:
				continue
			var edges: Array = track_gd._build_edges(path)
			if track_gd._ring_is_simple(edges[0]) and track_gd._ring_is_simple(edges[1]):
				accepted = true
				break
		if not accepted:
			failures += 1
			print("FAIL seed %d: no valid layout within %d attempts" % [seed_v, track_gd.MAX_GEN_ATTEMPTS])
	if failures == 0:
		print("PASS: %d seeds produce valid track geometry" % SEED_COUNT)
	else:
		print("FAIL: %d/%d seeds without valid geometry" % [failures, SEED_COUNT])
	quit(0 if failures == 0 else 1)
