# Retro Top-Down Arcade Racer

A procedurally generated top-down racing game built with **Godot 4.7.1**. Features seed-based track generation via Catmull-Rom splines, split-screen 2-player support (human vs AI), and retro-styled visuals.

## Features

- **Procedural tracks**: 8-sector anchor layout smoothed with Catmull-Rom spline interpolation (160 samples)
- **Seed support**: Reproducible tracks via integer seed
- **Multiplayer**: 2 human players (split-screen) + 2 AI opponents
- **Hazards**: Oil slicks, boost pads, and ramps placed along the track
- **Whole-track minimap view** with zoom-to-fit

## Fixed: Wall Collision Bug on Sharp Turns

### The problem (historical)

The track walls (invisible collision boundaries) produced **invisible walls on sharp turns** and **gaps** where the player could drive through. Additionally, the road surface polygon occasionally disappeared behind the wall geometry on certain seeds.

Both issues shared one root cause: **the perpendicular offset of the centerline self-intersects on sharp turns**. A hairpin of centerline radius `R` places the inside road edge at `R − TRACK_WIDTH/2` from the center of curvature; when `TRACK_WIDTH/2 > R`, that edge crosses the center of curvature and emerges on the far side — the offset curve folds over itself. Any wall quads built between the folded vertices invert and overlap the road (invisible walls), and the road `Polygon2D` gets a self-crossing outline that triangulates into artifacts or nothing (disappearing road).

Joint-level workarounds were tried and all failed, because they operate downstream of the broken edge geometry:

1. **Segment-perpendicular quads** — adjacent quads' perpendiculars diverge on turns, overlapping into the road on one side and leaving gaps on the other.
2. **Miter joints** (`miter_scale` clamped to 2.5) — near-180° hairpins make the tangent bisector shoot the miter vertex far past the track center.
3. **Bevel joints** — the unscaled bisector collapses on hairpins and can point back into the road.
4. **Extended-segment quads** (`WALL_THICKNESS * 0.6` overlap) — closes seams on moderate turns but cannot rescue a self-intersecting edge.

**No miter/bevel/extend trick can fix a self-intersecting offset curve.** Measurement confirmed the scale of the problem: across 196 random anchor layouts, the *median* minimum turn radius was ~22 px and the median clearance between track legs was ~63 px — against a 200 px road width, essentially every raw layout was geometrically unable to host the road. So seed rejection alone was also a dead end; the generator had to actively reshape the spline.

### The fix (implemented in `scripts/track.gd`)

Three layers, addressing the geometry at the source:

1. **Curvature-targeted spline smoothing** (`_smooth_path_curvature`). After the usual Catmull-Rom sampling and relaxation, points whose local turn radius (circumradius of 3 consecutive samples) is below `MIN_TURN_RADIUS` (= `TRACK_WIDTH/2 + WALL_MARGIN` = 130 px) are iteratively relaxed toward their neighbors' midpoint. This opens hairpins into arcs the road physically fits through, while leaving already-gentle sections untouched.

2. **Exact validity gate with re-roll** (`_generate_track`). A candidate layout is accepted only if:
   - non-adjacent anchors are at least `TRACK_WIDTH + 2·WALL_THICKNESS` apart (cheap pre-filter for overlapping legs),
   - the smoothed path's minimum turn radius is ≥ `MIN_TURN_RADIUS`, and
   - **both offset edge rings are simple polygons** (`_ring_is_simple`, exact segment-intersection test) — this is the precise invariant the wall collision and the road triangulation depend on, and it also catches *non-local* overlaps (two track legs passing closer than the road width, which no curvature check can see).

   Invalid candidates are re-rolled from the same seeded RNG stream (deterministic per seed), up to `MAX_GEN_ATTEMPTS`. In practice all tested seeds are accepted within ~4 attempts on average.

3. **Curvature-clamped offsets as a safety net** (`_build_edges`). Each edge offset is clamped to never reach the local center of curvature (`min(half_width, max(R − WALL_MARGIN, R/2))`), so even a worst-case fall-through layout cannot produce a folded edge. Offsets are smoothed with a narrow-only (min) filter, which preserves the guarantee.

The wall builder (`_build_ring_wall`) was also rewritten: instead of independent segment-perpendicular quads, each edge vertex is pushed along its **bisector normal with a clamped miter**, and adjacent quads **share those junction vertices**. The wall ring is therefore watertight by construction — no corner gaps to slip through, no stray quad protruding into the road. (Miter joints failed before only because the edges themselves were folded; on valid edges with bounded curvature they are the standard, correct solution.)

Two related cleanups:

- The road annulus polygon is now a **closed keyhole** (outer ring repeated at its start before cutting to the inner ring), making the two cut edges coincide — this removes a one-sample-wide slit that was visible at the start/finish seam.
- `get_surface_at()` compares against the actual per-point edge offsets rather than assuming a constant `TRACK_WIDTH/2`, and `validate_track()` now checks spline curvature and edge-ring simplicity, not just anchor spacing.

### Verification

`tests/track_geometry_test.gd` mirrors the generation accept-loop for 60 seeds and asserts that each seed yields a layout whose minimum turn radius is ≥ 130 px and whose edge rings are simple polygons:

```bash
godot --headless -s tests/track_geometry_test.gd
# PASS: 60 seeds produce valid track geometry
```

An exhaustive segment-intersection sweep over the generated edge rings of 60 seeds finds zero self-intersections (previously: multiple per seed on the inside edge).

## Project Structure

```
├── project.godot
├── scripts/
│   ├── track.gd          # Spline generation, edge offsets, wall building
│   ├── car.gd            # Vehicle physics
│   └── main.gd           # Scene orchestration
├── scenes/
│   ├── main.tscn         # Root scene
│   └── track.tscn        # Track with collision bodies
├── tests/
│   └── track_geometry_test.gd  # Headless track-geometry regression test
└── assets/               # Sprites, fonts
```

## Running

```bash
# Headless smoke test (validates scene + track generation)
timeout 10 godot --headless --quit

# Track geometry regression test
godot --headless -s tests/track_geometry_test.gd

# Full game
godot
```

---

*Last updated: July 2026*
