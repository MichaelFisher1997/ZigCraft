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
- Duration: 30 seconds per preset

Lavapipe and Zig versions are pinned by the Nix inputs used by the workflow. If the flake lock changes, refresh this baseline so performance drift is tied to a known toolchain.

## Capture Procedure

Run the benchmark workflow on the baseline branch or on `dev`:

```bash
gh workflow run benchmark.yml --repo OpenStaticFish/ZigCraft --ref <branch> -f duration=30
```

After the run finishes, download the `benchmark-results` artifact and replace the corresponding `low`, `medium`, and `high` entries in `baseline.json` with the captured JSON payloads. Keep `generated` set to `true`.

## Tolerance Policy

`scripts/compare_benchmarks.sh` applies an explicit tolerance per metric:

- Warning threshold: 5% regression.
- Failure threshold: 10% regression.
- Lower `fps.p1` is a regression.
- Higher `gpu_ms.total_avg` is a regression.
- Higher `draw_calls_avg` is a regression.

The p1 FPS metric is the primary user-visible smoothness guard. GPU time and draw calls catch rendering-cost regressions even when FPS is noisy on virtualized runners.
