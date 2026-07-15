# Benchmark Baselines

Benchmark artifacts use schema v3. The checked-in `baseline.json` has been
regenerated from real paired captures and is ready for canary comparison; no
values are invented to make a gate pass.

The default script captures the real `overworld` generator with no fixture. A
fixture such as `lod-handoff` is diagnostic-only and must be stated in the
artifact provenance; it is not acceptance evidence. Normal compact baseline
pairs explicitly reject the dedicated `gpu-culling-scale` fixture, so they
cannot be confused with the culling workload.

Capture low/medium/high for all four scenarios in both compact modes, then
assemble the ready 5-second canary baseline:

```bash
ZIGCRAFT_BENCHMARK_GPU_ADAPTER='your adapter' \
ZIGCRAFT_BENCHMARK_GPU_DRIVER='your driver' \
ZIGCRAFT_BENCHMARK_RUNNER='your runner label' \
ZIGCRAFT_BENCHMARK_ZIG_TOOLCHAIN='Zig 0.16.0 / your toolchain' \
scripts/run_benchmark.sh --duration 5 --presets low,medium,high \
  --scenarios stationary,traversal,rapid-turn,teleport-eviction \
  --compact-modes off,auto --benchmark-world overworld --output-dir benchmark-results
python3 scripts/benchmark_baseline.py validate-compact-matrix benchmark-results
python3 scripts/benchmark_baseline.py assemble --output docs/benchmarks/baseline.json \
  --overwrite benchmark-results
```

Assembly retains both complete `off` and `auto` artifacts under `compact_pairs`
as well as the intended auto result used by regression comparison. It refuses a
missing pair, duplicate capture, incomplete startup/readiness evidence, or
incompatible seed/build/headless/resolution/hardware/toolchain provenance.
`ultra` and `extreme` remain runtime policy-covered presets but are not required
capture rows.

The checked `acceptance-baseline.json` is the corresponding 60-second matrix.
It covers the complete traversal loop, repeated rapid turns, and repeated
teleport/eviction cycles. Regenerate it separately; never overwrite the canary
baseline used for short comparisons.

At readiness, each artifact preserves cumulative upload bytes, worker generation
and mesh-construction time, compact submissions, and resident geometry gauges.
It also records LOD3/LOD4 representation-specific counters:
`far_expanded_upload_bytes`, `compact_upload_bytes`,
`worker_far_expanded_mesh_construction_ms`, and
`worker_compact_encode_ms`. Steady-state sampled deltas remain in `lod`.
Every pair must show zero compact residency/submissions for `off` and nonzero
values for `auto`.

The auto result must reduce **far resident geometry**
(`direct_mesh_gpu_bytes + compact_pool_allocated_bytes`) and **far
representation upload bytes** (`far_expanded_upload_bytes +
compact_upload_bytes`) by **at least 20%** whenever the corresponding `off`
value is positive. The near pooled allocation and `pool_cpu_shadow_bytes` are
contextual fields only: they are reported but are not acceptance thresholds.
Total upload remains contextual because unrelated near streaming varies. Worker
far-representation work is the sum of expanded-worker construction and compact
encoding in each run, so auto fallbacks are not hidden. It has the same 20%
requirement only when both runs provide a positive, stable numeric timing basis.
Otherwise its delta is reported without inventing a percentage.

`scripts/benchmark_baseline.py compatibility BASELINE RESULT --preset P
--scenario S` verifies the exact provenance before metrics are compared.

## Reference Hardware

The checked canary and acceptance baselines were captured on:

- Runner label: `local NixOS x86_64`
- GPU: `AMD Radeon RX 5700 XT`
- Graphics driver: Mesa RADV 25.2.6
- Zig version: `0.16.0`, provided by the Nix flake
- Build mode: `ReleaseFast`
- Presets: `low`, `medium`, `high`
- `baseline.json`: 5 sampled seconds per row after readiness
- `acceptance-baseline.json`: 60 sampled seconds per row after readiness

Each evidence artifact records explicit GPU/adapter, driver, runner, and Zig
toolchain labels. Evidence mode rejects missing or `unknown` labels. CI also
runs the full matrix on its independently labelled Lavapipe runner and enforces
the schema, material-reduction, SLO, and Vulkan-validation gates. Strict numeric
comparison is skipped when that runner does not match the checked reference
provenance; Bencher retains CI-hardware trends instead of pretending the two
devices are comparable. Refresh a baseline whenever its recorded hardware or
toolchain changes.

## Capture Procedure

Run the benchmark workflow on the baseline branch or on `dev`:

```bash
gh workflow run benchmark.yml --repo OpenStaticFish/ZigCraft --ref <branch> -f duration=60
```

After the run finishes, download the complete `benchmark-results` artifact and
run `assemble`; do not copy selected auto payloads into a baseline. PR and push
runs are intentionally short canaries. Scheduled/manual runs are longer
acceptance captures. Both are bounded, and neither lets warmup contaminate the
steady-state metrics; startup evidence is retained separately. A canary baseline
is regenerated from canary captures and compared only to canaries. Acceptance
captures are retained as longer evidence and are never numerically compared to
the 5-second canary: compatibility rejects a duration mismatch.

## Reproducible scenarios

`-Dbenchmark-scenario` selects a deterministic, bounded camera path. The
default is `traversal`; all four scenarios are captured and validated by CI.

| Scenario | Path | Intended signal |
| --- | --- | --- |
| `stationary` | Holds the camera at `(8, 100, 8)`. | Steady-state LOD and renderer cost. |
| `traversal` | The original 60-second, smoothly interpolated six-waypoint loop. | Streaming and normal movement; default. |
| `rapid-turn` | Holds position at `(8, 100, 8)` while cycling its view every second. | Frustum, visibility, and coverage churn without streaming movement. |
| `teleport-eviction` | Jumps every four seconds between five fixed positions within ±1,536 blocks. | Streaming, cache, deferred-destruction, and eviction pressure. |

Default benchmarks start the `overworld` generator with fixed seed `12345`, run
headless at 1920×1080, and record the scenario, seed, and build metadata in
the result JSON. The `build` object records the Zig optimize mode, headless
status, and fixed resolution, so artifacts can be compared only when their
configuration is compatible.

Use `run_benchmark.sh` for evidence captures: it supplies the bounded external
timeout, all scenarios and both modes, evidence mode, and provenance labels.
Direct `zig build benchmark` runs are diagnostic only unless the same evidence
environment and labels are supplied. `-Dbenchmark-horizon-distance=N` (or
`run_benchmark.sh --benchmark-horizon-distance N`) changes only the coarsest
LOD horizon; it never changes near `render_distance`. `0` preserves the selected
preset horizon. Results record the effective horizon both at top level and as
`build.horizon_distance`, and compatibility rejects a different or unrecorded
horizon. Use the same preset, render-distance override, and horizon override
for before/after comparison. Unknown scenario values fail at build configuration
time.

Large-horizon diagnostic captures can raise **only** the LOD admission budget
with `-Dbenchmark-lod-memory-budget-mb=N` or
`run_benchmark.sh --benchmark-lod-memory-budget-mb N`. `0` is the default and
uses the selected preset unchanged; values above 4096 MiB are rejected. The
requested value is recorded in `build.benchmark_lod_memory_budget_mb`, so it is
never silently compared with a different capture budget. This does not alter
production settings or normal canary/acceptance captures.

`--benchmark-require-gpu-candidates N` is a matched-pair warmup gate. Both CPU
and GPU sources wait for at least `N` current renderable LOD regions, one second
of settled queues, and the existing minimum warmup. A GPU-culling-on source also
waits for its current candidate gauge to reach `N` and a compact submission.
The common region gauge keeps the CPU source comparable instead of inventing a
GPU-only counter for it. `0` preserves the existing warmup behavior. Targets
and readiness evidence are recorded in `build`, `completion`, and
`startup_evidence`.

## Dedicated CPU-vs-GPU culling baseline

`gpu-culling-baseline.json` is a separate schema-v3 artifact, not an inferred
claim from the compact matrix. It retains both full high-or-extreme/traversal source
artifacts and a derived comparison. Its sources must use the exact
`gpu-culling-scale` fixture: a bounded 32×32 lattice of **1,024** real,
non-overlapping LOD4 regions with valid compact tiles uploaded through the
production compact pool. It spans negative and positive region coordinates
across the 4,096-chunk horizon while retaining manager-owned region/mesh maps
and CPU hierarchy authority. Capture the matched 60-second pair on the same
hardware/build, with the same provenance labels and compact mode:

```bash
# CPU culling source: GPU culling explicitly disabled.
scripts/run_benchmark.sh --duration 60 --presets extreme --scenarios traversal \
  --compact-modes auto --gpu-culling off --gpu-culling-threshold 128 \
  --benchmark-world flat --benchmark-fixture gpu-culling-scale \
  --benchmark-horizon-distance 4096 --benchmark-lod-memory-budget-mb 2048 \
  --benchmark-require-gpu-candidates 1024 \
  --output-dir gpu-culling-results/cpu --per-preset-timeout 900

# GPU culling source: compute culling and its delayed validator explicitly enabled.
scripts/run_benchmark.sh --duration 60 --presets extreme --scenarios traversal \
  --compact-modes auto --gpu-culling on --gpu-culling-threshold 128 \
  --benchmark-world flat --benchmark-fixture gpu-culling-scale \
  --benchmark-horizon-distance 4096 --benchmark-lod-memory-budget-mb 2048 \
  --benchmark-require-gpu-candidates 1024 \
  --output-dir gpu-culling-results/gpu --per-preset-timeout 900

python3 scripts/benchmark_baseline.py assemble-gpu-culling --overwrite \
  --output docs/benchmarks/gpu-culling-baseline.json \
  gpu-culling-results/cpu/auto/extreme/traversal.json \
  gpu-culling-results/gpu/auto/extreme/traversal.json
python3 scripts/benchmark_baseline.py validate-gpu-culling \
  docs/benchmarks/gpu-culling-baseline.json
```

The gate requires the exact `gpu-culling-scale` fixture (and rejects it from
normal compact baselines), matched seed/build/headless/resolution/hardware/toolchain,
recorded horizon, CPU requested `off`, GPU requested `on`, candidates sampled
at or above the documented **1,024-region** readiness target (not just the
culling threshold), the matched bounded memory budget and resident-region
readiness target, nonzero GPU draw submissions, and completed
delayed validation. It accepts `high` or `extreme`, but requires traversal for
at least 60 seconds and `build.horizon_distance >= 4096`; this prevents the
small default workload from pretending to prove a GPU-culling win. The CPU
source uses production visibility/direct-or-MDI fallback; the GPU source uses
production compute plus indirect draws over the identical fixture and camera
path. It also
requires zero mismatch/overflow, finite p50/p95 plus positive average/p99 culling
timestamps, at least 1% improvement in measured CPU-frame p95, and no more than
1% regression in CPU-frame p99 or total-GPU p99. LOD-only CPU categories remain
in the source artifacts for attribution; the acceptance policy uses complete
CPU frame duration because indirect submission intentionally trades candidate
preparation for fewer CPU draw submissions.
Ratios are evaluated on the raw
artifact numbers without rounding tolerances. The derived report also retains
the measured draw-call delta for review. The checked artifact is ready and
retains both full 60-second source captures.

`run_benchmark.sh` defaults to `--gpu-culling off`, preserving existing compact
baseline commands. `--gpu-culling on` honestly sets
`ZIGCRAFT_LOD_GPU_CULLING=1`, validation on, and the requested threshold;
`off` sets both culling and validation to zero.

The fixture has fixed 1,024-region cardinality and compact source density, so
its memory remains bounded by the documented benchmark-only 2,048 MiB admission
budget rather than normal-world horizon fill. Warmup waits for at least 1,024
common renderable regions (and 1,024 GPU candidates in GPU mode), with the
existing bounded timeout. Start with a bounded smoke capture, inspect JSON/logs
for timeout or pressure evidence, then run the paired 60-second capture only on
hardware with enough headroom. It does not change default compact-matrix
workloads, defaults, or baselines.

The scheduled benchmark workflow retains this bounded source pair as
`gpu-culling-results`; manual workflow dispatches can request the same capture
with `capture_gpu_culling=true`. Do not promote CI/Lavapipe sources to the
AMD/RADV baseline: provenance matching intentionally rejects that substitution.

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

The sampled `lod` output also includes total far-expanded and compact upload
bytes, plus worker far-expanded construction and compact-encode time. The
paired acceptance calculation uses the separate cumulative `startup_evidence`
snapshot after the fixed 10-second minimum warmup and one fully settled second;
it never derives far representation evidence from the near pool.

Memory accounting uses an exact **zero-byte tolerance** for allocations owned
by the LOD system. `known_memory_bytes` is the checked sum of source data,
pending CPU vertices, CPU shadows, direct buffers, deferred CPU/GPU resources,
and allocated pool capacities (including slack). Unit tests compare that sum to
the component capacities exactly. GPU-driver-private allocation overhead is not
observable through the RHI and is therefore explicitly outside this total; the
telemetry must not be described as whole-process or driver VRAM usage.

## CPU frame percentile evidence

The checked 60-second matched `off`/`auto` acceptance matrix records complete
CPU frame p95 and p99 rather than inferring CPU improvement from average FPS.
For example, medium traversal measures p95 `5.2879402637481645` ms to
`5.0434266328811646` ms and p99 `6.667467823028565` ms to
`6.187350249290465` ms; medium rapid-turn measures p95
`3.6425690650939946` ms to `3.4344258308410645` ms and p99
`3.8853954601287843` ms to `3.8102028369903564` ms. High stationary,
traversal, and teleport/eviction also improve both percentiles. These are
integrated pipeline comparisons, not claims that compact representation alone
or any single Phase 1 optimization owns the full delta; rows that regress remain
present in the artifact rather than being hidden.

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
captures deterministic production-flat seam/water pairs, a static LOD handoff,
three bounded compact-auto motion scenes, and the persisted saved-world reload,
writing PNGs, per-capture logs, and `manifest.json` to
`zig-out/phase5-visual-smoke/`. It rejects missing, black, or visually empty
captures; requires non-zero compact residency and compact submissions in auto
captures; and requires zero-overflow, zero-mismatch completed GPU validation
for the MDI motion/handoff paths. This deliberately avoids a pixel-exact golden;
override its broad health thresholds only for diagnosed platform differences with
`PHASE5_VISUAL_MIN_NON_BLACK`, `PHASE5_VISUAL_MIN_LUMA_RANGE`,
`PHASE5_VISUAL_MIN_LUMA_BINS`, and
`PHASE5_VISUAL_MAX_NMAE`.

Run only this slower graphics check with:

```bash
nix develop --command zig build phase5-visual-gate
```

## Automated motion captures

`phase5-visual-gate` runs the following production compact-auto scenes in a
bounded session update script. The screenshot is taken only after the scripted
motion marker and settled-readiness marker are emitted; it is not a set of
static scene labels.

| Automated scene | Session motion | Capture evidence |
| --- | --- | --- |
| `lod-handoff-traversal` | Traverses 256 blocks across LOD rings. | Completed traversal, compact residency/submission, GPU culling, delayed validation, settled capture. |
| `fog-rapid-turn` | Holds position while making two deterministic horizon rotations. | Completed turn/yaw change, compact residency/submission, GPU culling, delayed validation, settled capture. |
| `teleport-handoff` | Teleports to a fixed distant pose, then waits for full-detail/LOD handoff to settle. | Completed teleport/displacement, compact residency/submission, GPU culling, delayed validation, settled capture. |

## Optional manual visual inspection matrix

Use this matrix for targeted manual inspection when a LOD rendering change
needs deeper before/after evidence than the automated terminal motion captures.
The benchmark runner is headless; no routine screenshot set is required.

| Visual concern | Scenario | Capture points | Inspect |
| --- | --- | --- | --- |
| Terrain seams | `stationary` | After readiness; after full-detail chunks settle. | Cracks, gaps, normal discontinuities, and material changes at LOD boundaries. |
| LOD transitions | `traversal` | Before, during, and after each terrain-ring handoff. | Popping, holes, duplicate terrain, and transition timing. |
| Water | `traversal` | Near water at an LOD boundary and after the boundary moves. | Shoreline cracks, water/terrain overlap, and missing distant water. |
| Fog | `rapid-turn` | Each cardinal-view turn, especially toward the horizon. | Fog discontinuities, horizon banding, and terrain visible through fog. |
| Full-detail handoff | `teleport-eviction` | Immediately after a jump and after detailed chunks replace LOD. | Stale regions, incorrect ownership, and gaps while uploads/evictions overlap. |

Record the generated JSON filename beside each optional manual capture set.

## Tolerance Policy

`scripts/compare_benchmarks.sh` applies an explicit tolerance per metric:

- Warning threshold: 5% regression.
- Failure threshold: 10% regression.
- Lower `fps.p1` is a regression.
- Higher `gpu_ms.total.avg` is a regression.
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
