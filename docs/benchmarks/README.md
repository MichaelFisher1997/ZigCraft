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

## Tolerance Policy

`scripts/compare_benchmarks.sh` applies an explicit tolerance per metric:

- Warning threshold: 5% regression.
- Failure threshold: 10% regression.
- Lower `fps.p1` is a regression.
- Higher `gpu_ms.total_avg` is a regression.
- Higher `draw_calls_avg` is a regression.

The p1 FPS metric is the primary user-visible smoothness guard. GPU time and draw calls catch rendering-cost regressions even when FPS is noisy on virtualized runners.

## Absolute SLOs

The benchmark harness also enforces absolute service-level objectives before regression comparison. These thresholds are intentionally separate from `baseline.json`: a run can fail even if there is no baseline drift when the absolute floor or ceiling is breached.

| Preset | p1 FPS min | Max frame ms | Draw calls avg max | Vertices avg max | GPU memory max |
| --- | ---: | ---: | ---: | ---: | ---: |
| low | 12 | 260 | 700 | 3,500,000 | 2,200 MB |
| medium | 8 | 260 | 2,600 | 6,000,000 | 2,400 MB |
| high | 6 | 260 | 3,600 | 8,500,000 | 2,800 MB |
| ultra | 4 | 260 | 4,500 | 12,000,000 | 3,400 MB |
| extreme | 3 | 260 | 5,500 | 16,000,000 | 4,096 MB |

The FPS floors are Lavapipe CI canary values, not player-facing hardware targets. The 260 ms spike guard allows the current Lavapipe startup spike in 5-second canary runs while still failing large stalls. Draw-call, vertex, and measured GPU resource memory ceilings are deliberately loose enough for runner variance but strict enough to fail large accidental rendering explosions.

Benchmark history is pushed to Bencher when the `BENCHER_API_TOKEN` and `BENCHER_PROJECT` secrets are configured. Pull-request benchmark runs are gated by either relevant file changes (`src/**`, `modules/**`, `assets/shaders/**`, or `build.zig`) or the `run-benchmark` label.
