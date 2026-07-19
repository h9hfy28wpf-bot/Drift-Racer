extends Node2D
class_name Track

## Sector-based random track generator with seed support and surface lookup.
## Generates a closed Catmull-Rom loop with road/grass/wall surfaces.

const SECTORS: int = 8
const SPLINE_SAMPLES: int = 160
const RELAX_PASSES: int = 2
const RELAX_WEIGHT: float = 0.15
const TRACK_WIDTH: float = 200.0
const WALL_THICKNESS: float = 48.0
const SPAWN_BEHIND: float = 80.0
const RADIUS_MIN: float = 180.0
const RADIUS_MAX: float = 420.0
const JITTER_DEG: float = 20.0
const WALL_MARGIN: float = 30.0
const MIN_TURN_RADIUS: float = TRACK_WIDTH * 0.5 + WALL_MARGIN
const MAX_GEN_ATTEMPTS: int = 60
const OFFSET_SMOOTH_PASSES: int = 3
const CURVATURE_SMOOTH_ITERS: int = 400
const ANCHOR_MIN_GAP_ADJACENT: float = 50.0
const ANCHOR_MIN_GAP_OTHER: float = TRACK_WIDTH + 2.0 * WALL_THICKNESS

enum Surface { ROAD = 0, GRASS = 1, WALL = 2 }
enum HazardType { OIL = 0, BOOST = 1, RAMP = 2 }
const HAZARD_OIL_RADIUS: float = 28.0
const HAZARD_BOOST_RADIUS: float = 32.0
const HAZARD_RAMP_RADIUS: float = 36.0
const HAZARD_COUNT_MIN: int = 6
const HAZARD_COUNT_MAX: int = 10
const HAZARD_MIN_SPLINE_SPACING: int = 14
const HAZARD_START_SAFE_ZONE: int = 20

var _road_outer: PackedVector2Array = PackedVector2Array()
var _road_inner: PackedVector2Array = PackedVector2Array()
var _off_outer: PackedFloat32Array = PackedFloat32Array()
var _off_inner: PackedFloat32Array = PackedFloat32Array()
var _center_path: PackedVector2Array = PackedVector2Array()
var _seed: int = 0
var _hazards: Array = []

func set_seed(s: int) -> void:
	_seed = s

func get_hazards() -> Array:
	return _hazards


func _ready() -> void:
	_generate_track()


## Headless validation: checks if a seed produces a valid closed loop —
## anchor spacing, spline curvature (hairpins tighter than MIN_TURN_RADIUS
## self-intersect the road's offset edges), and finally that both offset
## edge rings are simple polygons.
static func validate_track(seed_value: int) -> bool:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var anchors: Array[Vector2] = _make_anchors(rng)
	if not _anchors_ok(anchors):
		return false
	var path: PackedVector2Array = _build_center_path(anchors)
	if _min_turn_radius(path) < MIN_TURN_RADIUS:
		return false
	var edges: Array = _build_edges(path)
	return _ring_is_simple(edges[0]) and _ring_is_simple(edges[1])


func _generate_track() -> void:
	var rng := RandomNumberGenerator.new()
	if _seed != 0:
		rng.seed = _seed
	else:
		rng.randomize()

	# 1. Generate a valid layout: anchors -> curvature-smoothed spline ->
	# clamped offset edges. Accept only if both edge rings are simple
	# polygons (no self-intersection: that is the invariant the wall
	# collision and the road Polygon2D triangulation depend on). Re-roll
	# otherwise; if every attempt fails, the last candidate is still
	# playable because the offsets are curvature-clamped.
	var edges: Array = []
	for _attempt in range(MAX_GEN_ATTEMPTS):
		var anchors: Array[Vector2] = _make_anchors(rng)
		if not _anchors_ok(anchors):
			continue
		_center_path = _build_center_path(anchors)
		if _min_turn_radius(_center_path) < MIN_TURN_RADIUS:
			continue
		edges = _build_edges(_center_path)
		if _ring_is_simple(edges[0]) and _ring_is_simple(edges[1]):
			break

	if edges.is_empty():
		# Every attempt failed the anchor pre-filter; build from a final
		# roll anyway (clamped offsets keep it locally valid).
		_center_path = _build_center_path(_make_anchors(rng))
		edges = _build_edges(_center_path)

	_road_outer = edges[0]
	_road_inner = edges[1]
	_off_outer = edges[2]
	_off_inner = edges[3]

	# 4. Road surface polygon: annulus as a "keyhole" polygon. Closing the
	# outer ring (repeat outer[0]) before cutting to inner[0] makes the two
	# cut edges coincide, so no slit is visible at the seam.
	var road_poly: PackedVector2Array = PackedVector2Array()
	road_poly.append_array(_road_outer)
	road_poly.append(_road_outer[0])
	road_poly.append(_road_inner[0])
	var inner_rev: PackedVector2Array = _road_inner.duplicate()
	inner_rev.reverse()
	road_poly.append_array(inner_rev)

	# 4b. Draw grass background (big rect covering track extents)
	var bg: Polygon2D = $GrassBackground
	bg.z_index = -10
	bg.color = Color(0.28, 0.52, 0.18)   # retro grass green
	var bounds: Vector2 = _compute_track_extents()
	bg.polygon = PackedVector2Array([
		Vector2(-bounds.x, -bounds.y),
		Vector2( bounds.x, -bounds.y),
		Vector2( bounds.x,  bounds.y),
		Vector2(-bounds.x,  bounds.y)
	])

	# 5. Road surface polygon
	var road: Polygon2D = $RoadSurface
	road.polygon = road_poly
	road.color = Color(0.25, 0.25, 0.28)   # dark asphalt color
	road.z_index = -1

	# 6. Wall collision. The anchor loop always winds counter-clockwise, so
	# the bisector normals of both edge rings point toward the loop's
	# interior; the flags below choose the flip that places each wall band
	# OUTSIDE the road surface (island side for the inner edge, grass side
	# for the outer edge). Getting this backwards puts invisible walls on
	# the road itself — the original "invisible wall" bug.
	_build_ring_wall($OuterWall, _road_outer, false)
	_build_ring_wall($InnerWall, _road_inner, true)

	# 7. Visual outlines
	$OuterWallOutline.points = _road_outer
	$InnerWallOutline.points = _road_inner

	# 8. Amber anchor marker at spline point 0
	_draw_amber_anchor(_center_path[0])

	# 9. Checkered start/finish line visual
	_draw_checkered_line(_road_outer[0], _road_outer[1], _road_inner[0], _road_inner[1])

	# 10. Start/finish line collision at first edge
	_setup_start_finish_line(_road_outer[0], _road_outer[1], _road_inner[0], _road_inner[1])

	# 11. Generate hazards along the track
	_spawn_hazards(rng)


## ── Anchor / Path Generation ───────────────────────────────────────

## One anchor per angular sector, randomized radius + jitter.
static func _make_anchors(rng: RandomNumberGenerator) -> Array[Vector2]:
	var anchors: Array[Vector2] = []
	var sector_deg: float = 360.0 / float(SECTORS)
	var jitter_rad: float = deg_to_rad(JITTER_DEG)
	for i in range(SECTORS):
		var base_angle: float = deg_to_rad(float(i) * sector_deg)
		var jitter: float = rng.randf_range(-jitter_rad, jitter_rad)
		var angle: float = base_angle + jitter
		var radius: float = rng.randf_range(RADIUS_MIN, RADIUS_MAX)
		anchors.append(Vector2(cos(angle) * radius, sin(angle) * radius))
	return anchors


## Anchor spacing pre-filter: ring-adjacent anchors may be close (the road
## just flows through), but non-adjacent anchors closer than roughly the
## road width guarantee overlapping road sections — reject early.
static func _anchors_ok(anchors: Array[Vector2]) -> bool:
	var n: int = anchors.size()
	for i in range(n):
		for j in range(i + 1, n):
			var ring_gap: int = mini(j - i, n - (j - i))
			var min_gap: float = ANCHOR_MIN_GAP_ADJACENT if ring_gap <= 1 else ANCHOR_MIN_GAP_OTHER
			if anchors[i].distance_to(anchors[j]) < min_gap:
				return false
	return true


## Closed, relaxed Catmull-Rom center path through the anchors, then
## curvature-smoothed so no turn is tighter than MIN_TURN_RADIUS (random
## anchor layouts routinely produce kinks with ~20px radius — far too
## tight for a TRACK_WIDTH-wide road; see README).
static func _build_center_path(anchors: Array[Vector2]) -> PackedVector2Array:
	var closed: Array[Vector2] = anchors.duplicate()
	closed.append(closed[0])
	var path: PackedVector2Array = _sample_spline_closed(closed, SPLINE_SAMPLES)
	for _pass in range(RELAX_PASSES):
		_relax_path(path, RELAX_WEIGHT)
	_smooth_path_curvature(path)
	return path


## Iteratively relaxes only the points whose local turn radius is below
## target, opening hairpins into arcs the road can actually fit through.
static func _smooth_path_curvature(path: PackedVector2Array) -> void:
	var n: int = path.size()
	var target: float = MIN_TURN_RADIUS * 1.15
	for _iter in range(CURVATURE_SMOOTH_ITERS):
		var copy: PackedVector2Array = path.duplicate()
		var touched: bool = false
		for i in range(n):
			var r: float = absf(_signed_turn_radius(copy, i))
			if r > 0.0 and r < target:
				var prev: Vector2 = copy[(i - 1 + n) % n]
				var next: Vector2 = copy[(i + 1) % n]
				path[i] = path[i].lerp((prev + next) * 0.5, 0.5)
				touched = true
		if not touched:
			return


## Offsets the center path to both sides, clamping each offset so it never
## reaches the local center of curvature (which would self-intersect the
## offset curve). Returns [outer_edge, inner_edge, off_outer, off_inner].
static func _build_edges(path: PackedVector2Array) -> Array:
	var n: int = path.size()
	var half_w: float = TRACK_WIDTH * 0.5
	var off_outer: PackedFloat32Array = PackedFloat32Array()
	var off_inner: PackedFloat32Array = PackedFloat32Array()
	off_outer.resize(n)
	off_inner.resize(n)
	for i in range(n):
		off_outer[i] = half_w
		off_inner[i] = half_w
		var r: float = _signed_turn_radius(path, i)
		if r > 0.0:
			off_outer[i] = minf(half_w, maxf(r - WALL_MARGIN, r * 0.5))
		elif r < 0.0:
			off_inner[i] = minf(half_w, maxf(-r - WALL_MARGIN, -r * 0.5))

	# Smooth the clamped offsets (min with neighbor average only ever
	# narrows, so the no-self-intersection guarantee is preserved).
	for _pass in range(OFFSET_SMOOTH_PASSES):
		var oc: PackedFloat32Array = off_outer.duplicate()
		var ic: PackedFloat32Array = off_inner.duplicate()
		for i in range(n):
			var p: int = (i - 1 + n) % n
			var q: int = (i + 1) % n
			off_outer[i] = minf(oc[i], (oc[p] + oc[q]) * 0.5)
			off_inner[i] = minf(ic[i], (ic[p] + ic[q]) * 0.5)

	var outer: PackedVector2Array = PackedVector2Array()
	var inner: PackedVector2Array = PackedVector2Array()
	outer.resize(n)
	inner.resize(n)
	for i in range(n):
		var tangent: Vector2 = _path_tangent(path, i)
		var perp: Vector2 = Vector2(-tangent.y, tangent.x)
		outer[i] = path[i] + perp * off_outer[i]
		inner[i] = path[i] - perp * off_inner[i]
	return [outer, inner, off_outer, off_inner]


## True if the closed ring has no self-intersections (simple polygon).
static func _ring_is_simple(ring: PackedVector2Array) -> bool:
	var n: int = ring.size()
	for i in range(n):
		var a1: Vector2 = ring[i]
		var a2: Vector2 = ring[(i + 1) % n]
		for j in range(i + 2, n):
			if i == 0 and j == n - 1:
				continue  # adjacent segments share an endpoint
			if Geometry2D.segment_intersects_segment(a1, a2, ring[j], ring[(j + 1) % n]) != null:
				return false
	return true


## ── Curvature ──────────────────────────────────────────────────────

## Signed radius of curvature at path[i] (circumradius of 3 consecutive
## samples). Positive: center of curvature on the +perp side; negative:
## on the -perp side; 0.0 means locally straight (infinite radius).
static func _signed_turn_radius(path: PackedVector2Array, i: int) -> float:
	var n: int = path.size()
	var a: Vector2 = path[(i - 1 + n) % n]
	var b: Vector2 = path[i]
	var c: Vector2 = path[(i + 1) % n]
	var d1: Vector2 = b - a
	var d2: Vector2 = c - b
	var cross: float = d1.cross(d2)
	if absf(cross) < 0.0001:
		return 0.0
	var r: float = d1.length() * d2.length() * (c - a).length() / (2.0 * absf(cross))
	return r if cross > 0.0 else -r


static func _min_turn_radius(path: PackedVector2Array) -> float:
	var min_r: float = INF
	for i in range(path.size()):
		var r: float = absf(_signed_turn_radius(path, i))
		if r > 0.0:
			min_r = minf(min_r, r)
	return min_r


## ── Catmull-Rom Spline ─────────────────────────────────────────────

static func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2: float = t * t
	var t3: float = t2 * t
	return 0.5 * (
		(2.0 * p1) +
		(-p0 + p2) * t +
		(2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
		(-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
	)


static func _sample_spline_closed(anchors: Array[Vector2], num_samples: int) -> PackedVector2Array:
	var m: int = anchors.size() - 1  # Last anchor is duplicate of first
	var result: PackedVector2Array = PackedVector2Array()
	result.resize(num_samples)

	for i in range(num_samples):
		var t: float = float(i) / float(num_samples)
		var seg: float = t * float(m)
		var seg_idx: int = int(seg)
		var local_t: float = seg - float(seg_idx)

		var p0: Vector2 = anchors[(seg_idx - 1 + m) % m]
		var p1: Vector2 = anchors[seg_idx]
		var p2: Vector2 = anchors[(seg_idx + 1) % m]
		var p3: Vector2 = anchors[(seg_idx + 2) % m]

		result[i] = _catmull_rom(p0, p1, p2, p3, local_t)

	return result


static func _path_tangent(path: PackedVector2Array, i: int) -> Vector2:
	var n: int = path.size()
	var prev: Vector2 = path[(i - 1 + n) % n]
	var next: Vector2 = path[(i + 1) % n]
	return (next - prev).normalized()


## ── Relaxation ─────────────────────────────────────────────────────

static func _relax_path(path: PackedVector2Array, weight: float) -> void:
	var n: int = path.size()
	var copy: PackedVector2Array = path.duplicate()
	for i in range(n):
		var prev: Vector2 = copy[(i - 1 + n) % n]
		var next: Vector2 = copy[(i + 1) % n]
		var avg: Vector2 = (prev + next) * 0.5
		path[i] = path[i].lerp(avg, weight)


## ── Wall Collision ─────────────────────────────────────────────────

func _build_ring_wall(wall_node: StaticBody2D, edge: PackedVector2Array, push_outward: bool) -> void:
	var n: int = edge.size()

	# Push each edge vertex along its bisector normal (clamped miter) to get
	# the wall's far edge. Adjacent quads share these junction vertices, so
	# the wall ring is watertight: no corner gaps to slip through and no
	# stray quad protruding into the road.
	var far: PackedVector2Array = PackedVector2Array()
	far.resize(n)
	for i in range(n):
		var prev: Vector2 = edge[(i - 1 + n) % n]
		var next: Vector2 = edge[(i + 1) % n]
		var tangent: Vector2 = (next - prev).normalized()
		var normal: Vector2 = Vector2(-tangent.y, tangent.x)
		var seg_dir: Vector2 = (next - edge[i]).normalized()
		var seg_perp: Vector2 = Vector2(-seg_dir.y, seg_dir.x)
		if push_outward:
			normal = -normal
			seg_perp = -seg_perp
		# Miter scale keeps thickness on corners; clamp caps the spike on
		# sharp vertices (wall thins slightly there instead of exploding).
		var miter: float = 1.0 / clampf(normal.dot(seg_perp), 0.5, 1.0)
		far[i] = edge[i] + normal * (WALL_THICKNESS * miter)

	for i in range(n):
		var j: int = (i + 1) % n
		var quad: PackedVector2Array = PackedVector2Array([edge[i], edge[j], far[j], far[i]])

		var coll: CollisionPolygon2D = CollisionPolygon2D.new()
		coll.polygon = quad
		coll.name = "Seg%d" % i
		wall_node.add_child(coll)


## ── Amber Anchor Marker ───────────────────────────────────────

func _draw_amber_anchor(pos: Vector2) -> void:
	var marker: Polygon2D = $AmberAnchor
	marker.position = pos
	# Small circle approximated as 16-gon
	var radius: float = 14.0
	var poly: PackedVector2Array = PackedVector2Array()
	for i in range(16):
		var angle: float = TAU * float(i) / 16.0
		poly.append(Vector2(cos(angle), sin(angle)) * radius)
	marker.polygon = poly
	marker.color = Color(1.0, 0.75, 0.0)
	marker.z_index = 1

## ── Checkered Start/Finish Visual ─────────────────────────────

func _draw_checkered_line(o1: Vector2, o2: Vector2, i1: Vector2, i2: Vector2) -> void:
	var sf_vis: Node2D = $StartFinishVisual
	# The Line2D is a Node2D child, so we'll draw a simple checkered pattern
	# by positioning a small Polygon2D child
	var mid_outer: Vector2 = (o1 + o2) * 0.5
	var mid_inner: Vector2 = (i1 + i2) * 0.5
	var center: Vector2 = (mid_outer + mid_inner) * 0.5
	var dir: Vector2 = (o2 - o1).normalized()
	var perp: Vector2 = Vector2(-dir.y, dir.x)

	# Clear old children
	for child in sf_vis.get_children():
		child.queue_free()

	# Draw alternating black/white squares across the road
	var square_count: int = 6
	var square_size: float = TRACK_WIDTH / float(square_count)
	for i in range(square_count):
		var x_offset: float = -TRACK_WIDTH * 0.5 + float(i) * square_size + square_size * 0.5
		var square_pos: Vector2 = center + perp * x_offset

		var black: bool = (i % 2) == 0
		var sq: Polygon2D = Polygon2D.new()
		sq.name = "Sq%d" % i
		# Build square polygon
		var half_s: float = square_size * 0.5
		var local_perp: Vector2 = perp * half_s
		var local_dir: Vector2 = dir * half_s
		var poly: PackedVector2Array = PackedVector2Array()
		poly.append(Vector2.ZERO - local_dir - local_perp)
		poly.append(Vector2.ZERO + local_dir - local_perp)
		poly.append(Vector2.ZERO + local_dir + local_perp)
		poly.append(Vector2.ZERO - local_dir + local_perp)
		sq.polygon = poly
		sq.color = Color(0, 0, 0) if black else Color(1, 1, 1)
		sq.z_index = 1
		sq.position = square_pos
		sf_vis.add_child(sq)

## ── Start / Finish Line ───────────────────────────────────────────

func _setup_start_finish_line(o1: Vector2, o2: Vector2, i1: Vector2, i2: Vector2) -> void:
	var edge_dir: Vector2 = (o2 - o1).normalized()
	var mid_outer: Vector2 = (o1 + o2) * 0.5
	var mid_inner: Vector2 = (i1 + i2) * 0.5
	var center: Vector2 = (mid_outer + mid_inner) * 0.5

	var sf: Area2D = $StartFinishLine as Area2D
	sf.position = center
	sf.rotation = edge_dir.angle()

	var shape: RectangleShape2D = RectangleShape2D.new()
	shape.size = Vector2(TRACK_WIDTH, 20.0)

	var col_shape: CollisionShape2D = $StartFinishLine/CollisionShape2D as CollisionShape2D
	col_shape.shape = shape


## Generates oil slicks, boost pads, and ramps along the track.
## Uses spacing constraints to avoid clustering near start or each other.
func _spawn_hazards(rng: RandomNumberGenerator) -> void:
	_hazards.clear()
	
	var hazard_count: int = rng.randi_range(HAZARD_COUNT_MIN, HAZARD_COUNT_MAX)
	var min_idx: int = HAZARD_START_SAFE_ZONE
	var max_idx: int = _center_path.size() - HAZARD_START_SAFE_ZONE
	var last_spawn_idx: int = -1000
	
	for _i in range(hazard_count):
		# Find a valid index with spacing constraint
		var idx: int = -1
		for _attempt in range(20):  # max attempts to find valid spot
			var candidate: int = rng.randi_range(min_idx, max_idx)
			if abs(candidate - last_spawn_idx) >= 15:
				idx = candidate
				break
		
		if idx < 0:
			continue  # couldn't find valid spot, skip
		
		last_spawn_idx = idx
		
		# Determine hazard type
		var type: int = rng.randi_range(0, 2)  # 0=oil, 1=boost, 2=ramp
		
		# Position: slight lateral offset from center path
		var pos: Vector2 = _center_path[idx]
		var tangent: Vector2 = Vector2.ZERO
		if idx < _center_path.size() - 1:
			tangent = (_center_path[idx + 1] - _center_path[idx]).normalized()
		elif idx > 0:
			tangent = (_center_path[idx] - _center_path[idx - 1]).normalized()
		else:
			tangent = Vector2.RIGHT  # fallback
		
		var perp: Vector2 = Vector2(-tangent.y, tangent.x)
		var lateral_offset: float = rng.randf_range(-20.0, 20.0)
		pos += perp * lateral_offset
		
		var radius: float
		match type:
			HazardType.OIL:
				radius = HAZARD_OIL_RADIUS
			HazardType.BOOST:
				radius = HAZARD_BOOST_RADIUS
			HazardType.RAMP:
				radius = HAZARD_RAMP_RADIUS
			_:
				radius = 30.0
		
		_hazards.append({
			"type": type,
			"position": pos,
			"radius": radius,
			"tangent": tangent
		})
	
	# Draw hazard visuals if hazards parent exists
	if has_node("Hazards"):
		_draw_hazards()


## Draws colored circles for each hazard on the track.
func _draw_hazards() -> void:
	var hazards_parent: Node = get_node("Hazards")
	# Clear old hazards
	for child in hazards_parent.get_children():
		child.queue_free()
	
	for hazard in _hazards:
		var circle: Polygon2D = Polygon2D.new()
		var pos: Vector2 = hazard["position"]
		var radius: float = hazard["radius"]
		var type: int = hazard["type"]
		
		# Create circle polygon (12 segments)
		var vertices: PackedVector2Array = PackedVector2Array()
		var segments: int = 12
		for i in range(segments):
			var angle: float = (float(i) / float(segments)) * TAU
			vertices.append(Vector2(cos(angle), sin(angle)) * radius)
		circle.polygon = vertices
		
		# Color based on type
		match type:
			HazardType.OIL:
				circle.color = Color(0.2, 0.2, 0.3, 0.7)  # dark blue-black
			HazardType.BOOST:
				circle.color = Color(0.3, 0.8, 0.3, 0.7)  # green
			HazardType.RAMP:
				circle.color = Color(0.9, 0.6, 0.2, 0.7)  # orange
		
		circle.position = pos
		circle.z_index = -1
		hazards_parent.add_child(circle)


## Returns the surface type at a world position (road, grass, or wall).
## Compares distance from the nearest center_path point against that
## point's actual (curvature-clamped) edge offset for the relevant side.
func get_surface_at(pos: Vector2) -> int:
	var n: int = _center_path.size()
	if n == 0:
		return Surface.WALL
	var min_sq: float = INF
	var best_i: int = 0
	for i in range(n):
		var sq: float = _center_path[i].distance_squared_to(pos)
		if sq < min_sq:
			min_sq = sq
			best_i = i
	var dist: float = sqrt(min_sq)
	var half_w: float = TRACK_WIDTH * 0.5
	if _off_outer.size() == n and _off_inner.size() == n:
		var tangent: Vector2 = _path_tangent(_center_path, best_i)
		var perp: Vector2 = Vector2(-tangent.y, tangent.x)
		var outward: bool = (pos - _center_path[best_i]).dot(perp) >= 0.0
		half_w = _off_outer[best_i] if outward else _off_inner[best_i]
	if dist < half_w:
		return Surface.ROAD
	elif dist < half_w + WALL_THICKNESS:
		return Surface.GRASS
	else:
		return Surface.WALL


## Half width from center to road edge (for AI lateral offset).
func get_road_half_width() -> float:
	return TRACK_WIDTH * 0.5


## Returns world position at a given progress 0..1 along centerline.
func get_center_position_at(progress: float) -> Vector2:
	if _center_path.size() == 0:
		return Vector2.ZERO
	var idx: int = int(progress * float(_center_path.size())) % _center_path.size()
	return _center_path[idx]


## Bounding extents of the track (absolute X, Y max + padding).
func _compute_track_extents() -> Vector2:
	var max_x: float = 0.0
	var max_y: float = 0.0
	for pt in _road_outer:
		max_x = maxf(max_x, abs(pt.x))
		max_y = maxf(max_y, abs(pt.y))
	return Vector2(max_x + 200.0, max_y + 200.0)


## Viewport-fit zoom for whole-track view.
func get_whole_track_zoom(viewport_size: Vector2) -> float:
	var extents: Vector2 = _compute_track_extents()
	var zx: float = viewport_size.x / (extents.x * 2.0)
	var zy: float = viewport_size.y / (extents.y * 2.0)
	return minf(minf(zx, zy), 1.0) * 0.85


func get_start_position(player_index: int) -> Vector2:
	if _road_outer.size() < 2:
		return Vector2.ZERO

	var o1: Vector2 = _road_outer[0]
	var i1: Vector2 = _road_inner[0]
	var edge_dir: Vector2 = (_road_outer[1] - o1).normalized()

	var road_center: Vector2 = (o1 + i1) * 0.5
	var behind: Vector2 = road_center - edge_dir * SPAWN_BEHIND

	var perp: Vector2 = Vector2(-edge_dir.y, edge_dir.x)
	var offset: float = (float(player_index) - 0.5) * 40.0

	return behind + perp * offset


## Rotation that makes the car point along the track travel direction at the start line.
func get_start_rotation(_player_index: int) -> float:
	if _road_outer.size() < 2:
		return 0.0
	var edge_dir: Vector2 = (_road_outer[1] - _road_outer[0]).normalized()
	# Car's forward is Vector2.UP rotated by rotation, so match that to edge_dir
	return edge_dir.angle() + PI / 2.0


## Returns progress 0..1 along the center path for a given world position.
func get_center_progress(pos: Vector2) -> float:
	if _center_path.size() == 0:
		return 0.0
	var n: int = _center_path.size()
	var best_idx: int = 0
	var best_square_dist: float = INF
	for i in range(n):
		var d: float = _center_path[i].distance_squared_to(pos)
		if d < best_square_dist:
			best_square_dist = d
			best_idx = i
	return float(best_idx) / float(n)
