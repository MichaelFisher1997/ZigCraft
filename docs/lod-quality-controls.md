# LOD Quality Controls

The render distance preset is the supported user-facing control for distant LOD quality. Presets intentionally expose a small set of stable knobs:

- `lod_radii`: chunk radii for LOD0 through LOD3.
- `horizontal_detail`: target horizontal detail per LOD. This is used as a floor for QEM triangle targets when the experimental QEM mesh path is enabled.
- `vertical_span_budget`: enables rich column/span source data when greater than zero. Defaults keep this disabled to preserve current memory and generation cost.
- `mesh_path`: selects the stable heightfield path by default. `column_spans` and `qem` are available for controlled testing.
- `fog_start_percent`: controls the fade band for each LOD level.
- `memory_budget_mb` and `max_uploads_per_frame`: bound cache pressure and per-frame GPU upload work.

Default presets preserve existing performance expectations by keeping `mesh_path = .heightfield` and `vertical_span_budget = 0`.

## Diagnostics

Set `ZIGCRAFT_LOD_DIAG=1` to log LOD queue, render, and aggregate stats diagnostics. The output includes generation and upload queue depth, cache hits and misses, cache hit rate, mesh counts, vertex counts, visible region filtering, and fallback/culling reasons.

Runtime mesh path overrides are available while alternate mesh paths stabilize:

- `ZIGCRAFT_LOD_MESH_PATH_QEM=1` forces the QEM decimation path.
- `ZIGCRAFT_LOD_MESH_PATH_SPANS=1` forces the column/span mesh path.

Use the stable heightfield defaults for normal gameplay. Use the override flags only when comparing visual quality or diagnosing LOD mesh regressions.
