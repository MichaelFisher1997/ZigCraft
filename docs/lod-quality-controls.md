# LOD Quality Controls

The render distance preset is the supported user-facing control for distant LOD quality. Presets intentionally expose a small set of stable knobs:

- `lod_radii`: chunk radii for LOD0 through LOD4.
- `horizon_radius`: the supported far-terrain horizon in chunks.
- `lod_store_size_cap_mb`: an aggregate cap across all persistent `.zlod`
  containers. The cache worker evicts the oldest containers after atomic
  writes and compacts live entries when sector growth reaches the cap.
- `horizontal_detail`: target horizontal detail per LOD. This is used as a floor for QEM triangle targets when the experimental QEM mesh path is enabled.
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
| Medium | 512 chunks | 33/49/49/65/65 | 2 | 256 MB | 1,024 MB | 8 |
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

- `ZIGCRAFT_LOD_MESH_PATH_QEM=1` forces the QEM decimation path.
- `ZIGCRAFT_LOD_MESH_PATH_SPANS=1` forces the column/span mesh path.

Use the stable heightfield defaults for normal gameplay. Use the override flags only when comparing visual quality or diagnosing LOD mesh regressions.
