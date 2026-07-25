# Steering doc: water walls + slow LOD kick-in (issue #752, iteration 5)

Audience: the agent on `feature/distant-horizons-lod-overhaul-752`.
All work continues in the **single existing PR/branch** targeting `dev`.

## Where we are

The detail-band restructure landed (wider fine rings, canopy at more levels,
new `radiiForDistances`). Two severe problems remain, both confirmed in the
latest screenshots and traced to code:

1. **Oceans render as a grid of giant blue walls/slabs.** Vertical
   water-colored walls appear at every LOD region border, and neighboring
   regions' water planes sit at different heights, producing a tiled grid
   across the whole sea.
2. **LOD takes a very long time to appear.** After world load there is a long
   window with bare sky beyond the chunk ring before any LOD pops in.

---

## W — Fix the ocean grid (root causes found, in `lod_mesh.zig`)

### W1: region-border walls come from null-neighbor = "fully exposed"

`addExposedSpanFace` (~line 1366): when the neighbor cell is outside this
region (`neighbor_gx`/`neighbor_gz` null at `gx == 0`, `gx+1 >= width-1`,
etc.), **no interval is subtracted and the whole span face is emitted**.
Combined with `collectColumnSpans` (~line 1256) synthesizing a seafloor span
from **`min_height = 0.0`** up to terrain height for every water column —
colored with `data.colors[idx]`, which is water-blue over oceans — every
region border under the sea gets a bedrock-to-seafloor blue wall. That is
the grid in the screenshot.

Fix, in order of preference:

1. **Sample the true neighbor.** The neighboring region's edge data is the
   same worldgen/chunk source — expose a `stitchedNeighborColumn(data, dir)`
   lookup (the seam-stitching machinery and `lod_seam.zig` already model
   this) or have the generator fill a 1-cell border apron
   (`width + 2` samples) so border cells always have a real neighbor. Apron
   is the standard solution and also fixes top-face seams.
2. Until the apron exists, **clamp the border assumption**: at a null
   neighbor, assume the neighbor column is identical to this one (subtract
   the span's own interval → emit nothing) instead of assuming air. Distant
   Horizons does exactly this: never draw side faces at section borders
   against unknown neighbors.
3. The synthesized seafloor span should start at the local minimum
   surrounding terrain height minus a small skirt (e.g. 8 blocks), **not
   y=0**, and its color must be the **subsurface material color**
   (sand/gravel via `terrainBlockForLODQuad`), never `data.colors[idx]`
   (water-tinted over oceans).

### W2: water plane height must be uniform per water body

Adjacent regions quantize their water tops independently
(`quantizedWaterSurfaceHeightForSpan` takes a per-cell max of corner
samples), so region A's sea sits at 62 and region B's at 63 → visible tile
edges. Sea-level water should use the **worldgen sea level constant**
directly (one flat plane world-wide); only genuinely elevated water bodies
(lakes) use sampled heights, quantized from the **same source sample**, not
per-cell corner maxima. Add a regression test: two adjacent ocean regions
must emit water tops at identical heights.

### W3: acceptance for water

- Status: visual acceptance still needs manual verification on a live scene.
- Expected open-ocean result: one continuous flat translucent plane to the
  horizon, zero grid lines, zero vertical blue walls.
- Expected coastline result: beach steps down under the water plane, seafloor
  visible through shallow water.

## L — Fix time-to-first-LOD

The world stays empty beyond the chunk ring for a long time after load. The
recent config changes multiplied generation cost: `mesh_path = .column_spans`
with `vertical_span_budget = 4`, `horizontal_detail = 33` for **all** levels
(LOD4 was 24), and much wider fine rings. Steer toward "horizon appears
instantly, detail streams in":

1. **Coarse-first must be visible-first.** On world load, schedule the
   complete LOD4 shell (cheapest, covers everything) before *any* finer
   ring, and make sure the scheduler doesn't starve it behind the huge LOD0
   queue (check the priority bias and the new horizon-protected scheduling
   in `lod_manager.zig`/`lod_scheduler.zig`). Success metric: some LOD
   terrain visible at the horizon within ~2 seconds of world load, refining
   inward afterwards.
2. **Cheapen the coarse levels again**: LOD3/LOD4 do not need
   `horizontal_detail = 33` and 4 vertical spans; heightfield or span-budget
   1–2 with detail 16–24 is indistinguishable at those distances and cuts
   the initial fill time massively. Only LOD0/LOD1 need the full span
   treatment.
3. **Verify the persistent store/cache actually hits** on reload
   (`lod_store.zig`, `lod_cache.zig`): second load of the same world should
   show LOD almost immediately. Log hit/miss counters in `LODStats` and
   check them in a headless run.
4. Measure with `-Dstartup-diagnostic-seconds=10`: log LOD counts per level
   at 1s intervals; attach the numbers to the PR.

Status: automated build/test/shader validation is covered by PR verification;
manual startup timing numbers are still pending because bounded headless runs
timed out in the local environment before useful LOD diagnostics were emitted.

## Carry-over polish (unchanged, lower priority)

- LOD ground color still brighter than chunk grass — calibrate at the seam.
- Far bands should reach full fog at the horizon; sun-directional side-face
  shading.

## Verification

- `devenv shell zig build test` after every change (add the W2
  regression test).
- `headless-screenshot` (`-Dskip-present -Dauto-world=normal`): open-ocean
  view, coastline view, and a shot taken ~3 seconds after load to prove the
  fast coarse shell.
- `headless-benchmark` on `low`: initial-fill time and frame time must not
  regress; coarse-level cheapening should improve both.
- `headless-crash-test` after scheduler changes.

Single PR, conventional commits (suggested: `fix: neighbor-aware span faces
at region borders`, `fix: uniform sea-level water plane`, `perf: coarse
LOD fill fast path`). Before/after screenshots of the ocean grid and a
load-time comparison in the PR description.
