# Benchmark Baselines

ZigCraft benchmark gating compares every `dev` benchmark run against `baseline.json`.

## Reference Hardware

Baselines are captured on the GitHub Actions benchmark job runner:

- Runner label: `blacksmith-2vcpu-ubuntu-2404`
- Workflow: `.github/workflows/benchmark.yml`
- Graphics backend: Mesa Lavapipe via `.github/actions/setup-lavapipe`
- Zig version: `0.16.0`, provided by the Nix flake
- Build mode: `ReleaseFast`
- Presets: `low`, `medium`, `high`
- Duration: 5 sampled seconds per preset after a 1-second warmup for the CI canary gate

Lavapipe and Zig versions are pinned by the Nix inputs used by the workflow. If the flake lock changes, refresh this baseline so performance drift is tied to a known toolchain.

## Capture Procedure

Run the benchmark workflow on the baseline branch or on `dev`:

```bash
gh workflow run benchmark.yml --repo OpenStaticFish/ZigCraft --ref <branch> -f duration=5
```

After the run finishes, download the `benchmark-results` artifact and replace the corresponding `low`, `medium`, and `high` entries in `baseline.json` with the captured JSON payloads. Keep `generated` set to `true`.

This gate is intentionally a short canary so every `dev` push gets a bounded performance signal without consuming long runner time. The benchmark warmup is excluded from samples so startup shader/resource transitions do not dominate steady-state regression checks. Longer profiling runs should use the manual workflow input with a larger duration and should not replace the CI canary baseline unless that policy changes deliberately.

## Reproducible scenarios

`-Dbenchmark-scenario` selects a deterministic, bounded camera path. The
default is `traversal`, which is the original benchmark path and remains the
only scenario used by the current CI baseline.

| Scenario | Path | Intended signal |
| --- | --- | --- |
| `stationary` | Holds the camera at `(8, 100, 8)`. | Steady-state LOD and renderer cost. |
| `traversal` | The original 60-second, smoothly interpolated six-waypoint loop. | Streaming and normal movement; default. |
| `rapid-turn` | Holds position at `(8, 100, 8)` while cycling its view every second. | Frustum, visibility, and coverage churn without streaming movement. |
| `teleport-eviction` | Jumps every four seconds between five fixed positions within ±1,536 blocks. | Streaming, cache, deferred-destruction, and eviction pressure. |

Every benchmark starts the `overworld` generator with fixed seed `12345`, runs
headless at 1920×1080, and records the scenario, seed, and build metadata in
the result JSON. The `build` object records the Zig optimize mode, headless
status, and fixed resolution, so artifacts can be compared only when their
configuration is compatible.

Run each bounded scenario with these commands (15 sampled seconds plus the
one-second warmup; the external timeout also bounds a stalled process):

```bash
timeout --preserve-status 90s nix develop --command zig build benchmark -Doptimize=ReleaseFast -Dbenchmark-duration=15 -Dbenchmark-scenario=stationary -Dbenchmark-output=docs/benchmarks/results/stationary.json
timeout --preserve-status 90s nix develop --command zig build benchmark -Doptimize=ReleaseFast -Dbenchmark-duration=15 -Dbenchmark-scenario=traversal -Dbenchmark-output=docs/benchmarks/results/traversal.json
timeout --preserve-status 90s nix develop --command zig build benchmark -Doptimize=ReleaseFast -Dbenchmark-duration=15 -Dbenchmark-scenario=rapid-turn -Dbenchmark-output=docs/benchmarks/results/rapid-turn.json
timeout --preserve-status 90s nix develop --command zig build benchmark -Doptimize=ReleaseFast -Dbenchmark-duration=15 -Dbenchmark-scenario=teleport-eviction -Dbenchmark-output=docs/benchmarks/results/teleport-eviction.json
```

Use the same preset and render-distance override for before/after comparison.
For example, append `-Dbenchmark-preset=high -Dbenchmark-render-distance=16`
to both commands. Unknown scenario values fail at build configuration time.

## LOD telemetry JSON

Benchmark results include an opt-in `lod` object when LOD profiling is enabled.
`lod.cpu_categories.manager_lock_wait` and
`lod.cpu_categories.manager_lock_hold` report cumulative CPU timing deltas as
`total_ms` and per-sampled-frame `avg_ms`, just like the other CPU categories.

`lod.memory_bytes` reports LOD accounting gauges as `avg_bytes`, `max_bytes`,
and `last_bytes`; these are current known allocations, not GPU-driver memory
measurements. The gauge fields are:

- `pending_cpu_upload_bytes`
- `deferred_deletion_gpu_bytes` and `deferred_deletion_cpu_bytes`
- `pool_gpu_capacity_bytes`, `pool_gpu_allocated_bytes`,
  `pool_gpu_slack_bytes`, and `pool_cpu_shadow_bytes`
- `compact_pool_capacity_bytes`, `compact_pool_allocated_bytes`,
  `compact_pool_free_bytes`, and `compact_pool_retired_bytes`
- `direct_mesh_gpu_bytes` and `known_memory_bytes`

`deferred_deletion_bytes` remains as a compatibility alias of the GPU deferred
deletion gauge. In contrast, `upload_total_bytes`, visibility totals, and
pressure counts are cumulative counter deltas over sampled frames; they must
not be interpreted as allocation gauges.

## Phase 5 production gate

Run the lightweight policy gate with:

```bash
nix develop --command zig build phase5-gate
```

It verifies that the build accepts exactly the four scenarios above (and rejects
an unbounded name), that the runtime parser recognizes the same bounded set,
that LOD3/LOD4 retain the CPU heightfield fallback when an optional mesh path
is selected, and that the tables in this document and
[`../lod-quality-controls.md`](../lod-quality-controls.md) match the runtime
benchmark SLO and LOD-preset budgets.

The compact visual smoke gate is intentionally a separate graphics target. It
captures the same deterministic dry `flat` auto-world scene with
`ZIGCRAFT_LOD_COMPACT=off` and `force`, writing `compact-off.png`,
`compact-auto.png`, per-capture logs, and `metrics.json` to
`zig-out/phase5-visual-smoke/`. It rejects missing, black, or visually empty
captures, requires non-zero compact pool residency in the forced capture, and
rejects gross coarse-sampled divergence above 0.70. This deliberately avoids a pixel-exact golden; override its broad
health thresholds only for diagnosed platform differences with
`PHASE5_VISUAL_MIN_NON_BLACK`, `PHASE5_VISUAL_MIN_LUMA_RANGE`,
`PHASE5_VISUAL_MIN_LUMA_BINS`, and
`PHASE5_VISUAL_MAX_NMAE`.

Run only this slower graphics check with:

```bash
nix develop --command zig build phase5-visual-gate
```

## Visual baseline capture matrix

When a LOD rendering change needs visual evidence, capture before and after
images using the matching fixed seed, preset, render distance, and scenario.
The benchmark runner is headless; this table defines the required evidence
rather than storing screenshots in this repository.

| Visual concern | Scenario | Capture points | Inspect |
| --- | --- | --- | --- |
| Terrain seams | `stationary` | After one-second warmup; after full-detail chunks settle. | Cracks, gaps, normal discontinuities, and material changes at LOD boundaries. |
| LOD transitions | `traversal` | Before, during, and after each terrain-ring handoff. | Popping, holes, duplicate terrain, and transition timing. |
| Water | `traversal` | Near water at an LOD boundary and after the boundary moves. | Shoreline cracks, water/terrain overlap, and missing distant water. |
| Fog | `rapid-turn` | Each cardinal-view turn, especially toward the horizon. | Fog discontinuities, horizon banding, and terrain visible through fog. |
| Full-detail handoff | `teleport-eviction` | Immediately after a jump and after detailed chunks replace LOD. | Stale regions, incorrect ownership, and gaps while uploads/evictions overlap. |

Record the generated JSON filename beside each capture set. No screenshot is
required for routine benchmark changes; use this matrix when visual behavior
is affected.

## Tolerance Policy

`scripts/compare_benchmarks.sh` applies an explicit tolerance per metric:

- Warning threshold: 5% regression.
- Failure threshold: 10% regression.
- Lower `fps.p1` is a regression.
- Higher `gpu_ms.total_avg` is a regression.
- Higher `draw_calls_avg` is a regression.

The p1 FPS metric is the primary user-visible smoothness guard. GPU time and draw calls catch rendering-cost regressions even when FPS is noisy on virtualized runners.

## Absolute SLOs

The benchmark harness also enforces absolute service-level objectives before regression comparison. These thresholds are intentionally separate from `baseline.json`: a run can fail even if there is no baseline drift when the absolute floor or ceiling is breached. The LOD preset's CPU-source/mesh RAM cap and persistent-store cap are defined in [`../lod-quality-controls.md`](../lod-quality-controls.md); the GPU limits below cover measured renderer resource memory.

| Preset | p1 FPS min | Max frame ms | Draw calls avg max | Vertices avg max | GPU memory max |
| --- | ---: | ---: | ---: | ---: | ---: |
| low | 12 | 260 | 700 | 3,500,000 | 2,200 MB |
| medium | 8 | 260 | 2,600 | 6,000,000 | 2,400 MB |
| high | 6 | 260 | 3,600 | 8,500,000 | 2,800 MB |
| ultra | 4 | 260 | 4,500 | 12,000,000 | 3,400 MB |
| extreme | 3 | 260 | 5,500 | 16,000,000 | 4,096 MB |

The FPS floors are Lavapipe CI canary values, not player-facing hardware targets. The 260 ms spike guard allows the current Lavapipe startup spike in 5-second canary runs while still failing large stalls. Draw-call, vertex, and measured GPU resource memory ceilings are deliberately loose enough for runner variance but strict enough to fail large accidental rendering explosions.

Benchmark history is pushed to Bencher when the `BENCHER_API_TOKEN` and `BENCHER_PROJECT` secrets are configured. Pull-request benchmark runs are gated by either relevant file changes (`src/**`, `modules/**`, `assets/shaders/**`, or `build.zig`) or the `run-benchmark` label.
