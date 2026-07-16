# LOD Quality Controls

The render distance preset is the supported user-facing control for distant LOD quality. Presets intentionally expose a small set of stable knobs:

- `lod_radii`: chunk radii for LOD0 through LOD4.
- `horizon_radius`: the supported far-terrain horizon in chunks.
- `lod_store_size_cap_mb`: an aggregate cap across all persistent `.zlod`
  containers. The cache worker evicts the oldest containers after atomic
  writes and compacts live entries when sector growth reaches the cap.
- `horizontal_detail`: target horizontal detail per LOD. This is used as a floor for QEM triangle targets when the experimental QEM mesh path is enabled.
- `sample_density`: source-grid density per LOD. Medium uses half density for
  LOD4 so its initial 512-chunk horizon has 33x33 source grids instead of
  65x65 grids; finer LODs replace those 16-block cells as they stream in.
- `vertical_span_budget`: enables rich column/span source data when nonzero.
  The numeric values are reserved preset policy; current source allocation is
  bounded by the engine-wide `MAX_LOD_VERTICAL_SPANS` limit.
- `mesh_path`: selects the rich `column_spans` path for near and mid-distance
  LODs. LOD3/LOD4 deliberately fall back to heightfields to bound far-horizon
  geometry and memory; `qem` remains available for controlled testing.
- `fog_start_percent`: controls the fade band for each LOD level.
- `memory_budget_mb` and `max_uploads_per_frame`: bound cache pressure and per-frame GPU upload work.

## Supported presets

| Preset | Horizon | Horizontal detail LOD0–4 | Span setting | RAM budget | Store cap | Uploads/frame |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| Low | 256 chunks | 33/33/33/65/65 | 2 | 128 MB | 512 MB | 4 |
| Medium | 512 chunks | 33/49/49/65/33 | 2 | 256 MB | 1,024 MB | 8 |
| High | 512 chunks | 33/65/65/97/97 | 3 | 384 MB | 1,536 MB | 8 |
| Ultra | 1,024 chunks | 33/65/65/129/129 | 4 | 512 MB | 3,072 MB | 12 |
| Extreme | 2,048 chunks | 33/65/65/129/129 | 4 | 1,024 MB | 4,096 MB | 16 |

These values are policy inputs, not a promise that all hardware sustains the
full horizon. The memory governor shrinks refinement radii under pressure but
preserves the coarsest parent horizon so missing children do not produce holes.
The benchmark SLOs and regression thresholds are maintained in
[`benchmarks/README.md`](benchmarks/README.md).

## Requirements and fallback behavior

- Vulkan compute and indirect drawing are preferred for GPU LOD culling. When
  unavailable or disabled, CPU visibility and indirect submission remain the
  correctness fallback.
- Compact far-tile encoding rejects source columns it cannot represent (for
  example, an unsupported span layout). Production rendering remains on the
  CPU mesh path until compact-tile residency and shaders are enabled, so
  unsupported data is never silently dropped.
- Parent regions remain visible until all four finer children are renderable
  and the transition window completes. Streaming delay therefore degrades to
  coarser terrain rather than a hierarchy hole.
- Pause and large traversal changes invalidate queued and in-flight worker
  tokens. Per-region cancellation prevents a stale generation result from
  publishing after unpause or teleport.
- Cache payloads are checksummed and keyed by seed, generator identity/version,
  coordinates, and schema. Corrupt or provenance-incomplete payloads are
  deleted and regenerated. Source authority (`worldgen`, `chunk_derived`, or
  `edited`) is serialized even for span-less far levels.
- Persistent storage, pending cache I/O, generation admission, CPU source/mesh
  memory, upload count, and upload bytes are bounded. A container that cannot
  fit within the aggregate store cap is rejected rather than allowing
  persistent storage to grow without limit.

## Diagnostics

Set `ZIGCRAFT_LOD_DIAG=1` to log LOD queue, render, and aggregate stats diagnostics. The output includes generation and upload queue depth, cache hits and misses, cache hit rate, mesh counts, vertex counts, visible region filtering, and fallback/culling reasons.

Runtime mesh path overrides are available while alternate mesh paths stabilize:

- `ZIGCRAFT_LOD_COMPACT=off` explicitly keeps expanded CPU LOD meshes.
- `ZIGCRAFT_LOD_COMPACT=auto` is the production capability-selected path only
  when immutable terrain/water descriptor sets are available. Unsupported
  mixed shoreline topology remains on the expanded mesh fallback; capability
  allocation alone is not a release criterion. `off` remains the explicit
  supported expanded fallback.
- `ZIGCRAFT_LOD_COMPACT=force` requests the same compact path for validation;
  unrepresentable terrain, partial-water tiles, allocation pressure, and runtime
  draw failures still fall back to a dedicated CPU-built GPU mesh rather than dropping a region.
- Normal expanded LOD drawing remains GPU-backed by default. The separate
  `ZIGCRAFT_LOD_GPU_CULLING=1` indirect-compaction optimization is opt-in and
  applies to the qualified compact-auto reload path through immutable per-layer
  terrain/water descriptor sets. Unsupported shoreline topology remains on the
  expanded fallback rather than sharing mutable descriptor state.
- Wet LOD3/4 regions with unsupported shoreline topology remain on the
  expanded fallback mesh. The saved-world RADV qualification requires this
  fallback alongside dry compact residency; compact allocation alone is not
  evidence that wet compact terrain was rendered.
- `ZIGCRAFT_LOD_MESH_PATH_QEM=1` forces the QEM decimation path.
- `ZIGCRAFT_LOD_MESH_PATH_SPANS=1` forces the column/span mesh path.

## Phase 5 visual regression gate

`zig build phase5-visual-gate` is a bounded, headless capture gate, not a
pixel-golden test. It launches the production flat generator in expanded
(`ZIGCRAFT_LOD_COMPACT=off`) and production compact (`auto`) modes, then applies
small deterministic runtime fixtures for three separate scenes:

- `seam` places contrasting geometry on both sides of the x=16 chunk boundary.
- `water` creates a resident full-detail water pool. The app records resident
  fixture-cell observations and the checker validates the water capture ROI.
- `lod-handoff` places a fixed camera in full detail looking into the LOD
  horizon, requiring both rendered full-detail chunks and compact allocation;
  its `auto` capture also enables MDI/GPU culling and requires a zero-mismatch
  candidate submission record.
- `lod-handoff-traversal` moves the production player 256 blocks across LOD
  rings; `fog-rapid-turn` makes two deterministic horizon rotations; and
  `teleport-handoff` jumps to a fixed distant pose before its full-detail/LOD
  handoff settles. These compact-auto scenes emit exact run/scene motion and
  readiness markers and require compact residency/submissions, zero culling
  mismatches/overflows, and completed delayed GPU validation.
- `saved-world-create` writes deterministic wet and dry edits, flushes the
  world save, and persists its LOD source cache in a unique per-run
  `ZIGCRAFT_SAVE_DIR`. `saved-world-reload` is a second process that reloads
  that exact save using `auto`, MDI/GPU culling validation, and a screenshot.
  It requires explicit save-loaded, wet/dry fallback, compact-residency,
  validation-complete, zero-mismatch, and zero-overflow evidence.

The seam/water visual pairs keep LOD MDI disabled so their compact-direct image
comparison isolates the production fallback/compact paths. The GPU-culling MDI
handoff capture is kept separate because it exercises a distinct submission
stream and has its own activation/validation evidence.

Each capture is frame- and wall-time-bounded (`PHASE5_VISUAL_CAPTURE_TIMEOUT`,
default `110s`). Captures default to frame 900 and require 180 consecutive
fixture/streaming/LOD-queue/transition-stable frames first
(`PHASE5_VISUAL_SETTLE_FRAMES`). The checker writes `zig-out/phase5-visual-smoke/manifest.json`
even when it fails. It requires compact allocation/capture counters, water
fixture evidence, whole-image and terrain ROI health, and tighter whole-image
and ROI expanded-versus-compact differences. The saved-world reload also
requires a healthy rendered image, rather than accepting save/telemetry logs
alone. Motion capture readiness additionally waits for the bounded pose script
to finish. CI allows 35 minutes for the now ten process-isolated captures and
uploads the isolated save, PNGs, logs, and manifest on both success and failure.

The water fixture validates the production full-detail water path. The
saved-world reload is the RADV qualification for production `auto`: dry tiles
use compact residency through immutable descriptors while unsupported wet
shorelines retain the expanded fallback. `ZIGCRAFT_LOD_COMPACT=off` remains
available throughout.

Use the stable heightfield defaults for normal gameplay. Use the override flags only when comparing visual quality or diagnosing LOD mesh regressions.
