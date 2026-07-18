# Retro Top-Down Arcade Racer

A procedurally generated top-down racing game built with **Godot 4.7.1**. Features seed-based track generation via Catmull-Rom splines, split-screen 2-player support (human vs AI), and retro-styled visuals.

## Features

- **Procedural tracks**: 8-sector anchor layout smoothed with Catmull-Rom spline interpolation (160 samples)
- **Seed support**: Reproducible tracks via integer seed
- **Multiplayer**: 2 human players (split-screen) + 2 AI opponents
- **Hazards**: Oil slicks, boost pads, and ramps placed along the track
- **Whole-track minimap view** with zoom-to-fit

## Known Issue: Wall Collision Bug on Sharp Turns

### Problem Statement

The track walls (invisible collision boundaries) produce **invisible walls on sharp turns** and **gaps** where the player can drive through. Additionally, the road surface polygon occasionally disappears behind the wall geometry on certain seeds.

Both issues are driven by the same root cause: **the wall polygon construction cannot handle sharp corners without self-intersection**.

---

### Current Implementation

Walls are built in `_build_ring_wall()` in `scripts/track.gd`. The road edges (`_road_outer`, `_road_inner`) are computed by perpendicular-offsetting the center spline by `TRACK_WIDTH / 2.0`. Each pair of consecutive spline samples produces a **quad (4-vertex CollisionPolygon2D)** that is attached to a `StaticBody2D`.

```gdscript
# Current approach: Extended-segment quads
for i in range(n):
    var a: Vector2 = edge[i]
    var b: Vector2 = edge[j]
    var seg_dir: Vector2 = (b - a).normalized()
    var perp: Vector2 = Vector2(-seg_dir.y, seg_dir.x)
    var ext_vec: Vector2 = seg_dir * extend  # extend = WALL_THICKNESS * 0.6
    
    quad[0] = a - ext_vec            # Extended bottom-left
    quad[1] = b + ext_vec            # Extended bottom-right  
    quad[2] = b + ext_vec + perp * WALL_THICKNESS  # Extended top-right
    quad[3] = a - ext_vec + perp * WALL_THICKNESS  # Extended top-left
```

---

### Approaches Tried (and why they failed)

#### Attempt 1: Segment-perpendicular quads (Original)

Each quad uses the perpendicular of **its own segment direction** for all 4 vertices.

**Why it fails**: On sharp turns, adjacent segments rotate significantly between sample `i` and `i+1`. Their perpendiculars diverge, causing adjacent quads to **overlap into the road surface** — creating an invisible wall that the player hits in empty-looking space.

**Also fails because**: The perpendiculars at the junction point don't meet; there's a visible gap or a protruding ridge depending on inside/outside of curve.

#### Attempt 2: Miter joints (miter_scale clamped to 2.5)

Vertex normals are computed at each spline point by averaging the incoming and outgoing tangent directions. A `miter_scale` factor (clamped to 2.5) stretches the offset outward on curves to maintain wall thickness.

```gdscript
# Miter joint approach (FAILED)
var tangent_in: Vector2 = (edge[i] - prev).normalized()
var tangent_out: Vector2 = (next - edge[i]).normalized()
var vertex_normal: Vector2 = (tangent_in + tangent_out).normalized()
var miter_scale: float = clampf(
    1.0 / maxf(tangent_in.dot(vertex_normal), 0.1), 1.0, 2.5
)
```

**Why it fails**: On hairpins approaching ~180° reversal, the incoming and outgoing tangents are nearly anti-parallel. The averaged normal becomes nearly perpendicular to either direction, and the miter_scale shoots the collision vertex **far past the track center** into the road. The clamp to 2.5 wasn't high enough to fix thickness but caused massive overlap on the outside of the turn. Also didn't fix the disappearing road surface.

#### Attempt 3: Bevel joints (no miter_scale)

Same vertex-normal approach but without the stretch factor — the normal is just the unit bisector without scaling.

```gdscript
# Bevel joint approach (FAILED)
var vertex_normal: Vector2 = (tangent_in + tangent_out).normalized()
# No miter_scale, just use normal directly
```

**Why it fails**: The bisector normal on an inside-curve junction still points roughly outward (correct), but on an extreme hairpin the bisector can **point back INTO the road** because both tangent contributions cancel and the normal collapses. Adjacent quads at the same junction can have their inside-curve edges overlapping each other or leaving gaps — depending on which side of the curve they're on.

Fundamentally, bevel joints maintain correct thickness only up to the point where the inner offset curve crosses itself.

#### Attempt 4: Extended-segment quads (CURRENT)

Each quad is extended by `WALL_THICKNESS * 0.6` past both endpoints along the segment direction. Adjacent quads' extensions overlap, closing corner seams.

```gdscript
# Extended-segment quads (CURRENT)
var extend: float = WALL_THICKNESS * 0.6
var ext_vec: Vector2 = seg_dir * extend
quad[0] = a - ext_vec       # Extended beyond prev segment
quad[1] = b + ext_vec       # Extended into next segment
```

**Why it helps partially**: On moderate turns, the overlap zone is cleanly in the wall region and seams disappear visually/functionally.

**Why it still fails**: On extreme hairpins, the "road edge" (`edge[i]` points) themselves don't form a clean boundary — the inner road edge self-intersects on tight turns. Extending quads past the endpoint can't rescue what is fundamentally a broken inner boundary. Also creates visible polygon artifacts at extreme corners.

---

### Root Cause Analysis

All four approaches share the same fundamental flaw: they treat the track edges as if the perpendicular offset is well-defined everywhere along the centerline. **On sharp hairpins, the perpendicular offset of a curved path self-intersects.**

Consider a hairpin of radius R at the centerline. The inner wall edge sits at `R - TRACK_WIDTH/2` from the center of curvature. If `TRACK_WIDTH/2 > R`, the inner wall edge crosses the center of curvature and emerges on the other side of the track — the offset curve self-intersects.

```
         Before hairpin →  ╱
                          ╱
    ─────────────────────↰────────  ← Inner road edge
         road surface              COLLAPSES here
    ─────────────────────↱────────  ← Outer road edge
                          ╲
         After hairpin  →  ╲

    The "inner wall" vertices at samples near the apex 
    cross each other → the collision quads invert.
```

With `TRACK_WIDTH = 200` and minimum spline radius of curvature on hairpins potentially as low as ~100px (depending on anchor placement), the inner offset regularly self-intersects. The spline's Catmull-Rom relaxation (`RELAX_PASSES = 2, RELAX_WEIGHT = 0.15`) reduces but doesn't eliminate tight corners — some seeds produce hairpins with curvature radius well below `TRACK_WIDTH/2 = 100`.

**No miter/bevel/extend trick can fix a self-intersecting offset curve.** The inner wall's geometry simply becomes invalid — vertices cross each other, and any quad built between them overlaps the road surface.

#### Secondary bug: Road surface disappearing

The road `Polygon2D` is constructed by appending `_road_outer` then reversed `_road_inner`. If the offset edges self-intersect, the resulting polygon has a self-crossing topology. Polygon2D (and its triangulator) produces rendering artifacts — sometimes the polygon renders behind other z-layers, sometimes it culls itself, sometimes it renders as a thin sliver. The `z_index = -1` on the road vs the wall StaticBody2D children exacerbates this; on self-intersecting seeds, the road geometry may not produce a valid triangulation at all.

---

### Recommended Fix Paths

The collision problem cannot be solved by tweaking perp/normal math at the quad level. The fix must address the self-intersection at the edge-offset level.

#### Option A: Curvature-gated offset (prevent inner self-intersection)

Before building walls, detect spline points where the local radius of curvature is less than `TRACK_WIDTH/2`. At those points, collapse the inner edge toward the center (or clamp the offset to `min(R, TRACK_WIDTH/2)`). This prevents the inner wall from crossing itself at hairpins.

```gdscript
# Pseudocode
for i in range(center_path.size()):
    var curvature: float = compute_curvature(center_path, i)
    var radius: float = 1.0 / maxf(curvature, 0.001)
    var offset: float = minf(TRACK_WIDTH * 0.5, radius - WALL_MARGIN)
    road_inner[i] = center_path[i] - perp * offset  # Clamped
```

#### Option B: Line-segment collision (avoid polygon quads entirely)

Instead of building quads, attach `CollisionShape2D` with `SegmentShape2D` or use `PhysicsBody2D` with individual line segments along the road edge. Adjacent segments share endpoints — no corner math needed, no self-intersection possible (each segment is independently valid).

Trade-off: `SegmentShape2D` is one-sided and doesn't provide the "push-in" wall thickness behavior. Would need a workaround (doubled segments, or `ConvexPolygonShape2D` per segment).

#### Option C: Offset-path with self-intersection removal

Compute the raw perpendicular offset, then run a computational-geometry cleanup (e.g., Clipper2/polygon clipping library) to remove self-intersecting regions. Godot doesn't ship Clipper2 natively but there are GDNative/Extension bindings.

#### Option D: SDF-based collision

Build a signed distance field from the road center path. The wall collision becomes an implicit surface (`SDF > TRACK_WIDTH/2` = collision zone). No polygons needed; curvature is handled automatically. Trade-off: SDFs need 2D physics integration work not natively in Godot.

#### Option E (simplest): Constrain track generation

Add a minimum curvature radius constraint during spline generation. If two consecutive anchors would produce a hairpin tighter than `TRACK_WIDTH/2 + margin`, reject that seed or redistribute anchors. The current `validate_track()` only checks anchor-to-anchor proximity — it doesn't check spline curvature.

---

### How to Reproduce

1. Run the game with `godot` (or `godot --headless --quit` for smoke test)
2. Try seeds that produce hairpin-dense layouts — the issue is seed-dependent
3. Watch for:
   - Player car bouncing off invisible wall in what looks like open road
   - Road polygon vanishing on some seeds
   - Player driving through a wall at a corner

### Project Structure

```
├── project.godot
├── scripts/
│   ├── track.gd          # Spline generation, wall building (bug location)
│   ├── car.gd           # Vehicle physics
│   └── main.gd          # Scene orchestration
├── scenes/
│   ├── main.tscn        # Root scene
│   └── track.tscn       # Track with collision bodies
└── assets/              # Sprites, fonts
```

### Running

```bash
# Headless smoke test (validates track generation)
timeout 10 godot --headless --quit

# Full game
godot
```

---

*Last updated: July 2026*
