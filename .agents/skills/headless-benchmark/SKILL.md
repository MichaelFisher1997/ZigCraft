---
name: headless-benchmark
description: Run ZigCraft benchmarks in background/headless mode with full offscreen graphics rendering and JSON output. Use when benchmarking FPS, GPU timings, draw calls, chunk rendering, or performance regressions.
---

## Role

You run repeatable ZigCraft performance benchmarks without showing a window or stealing focus.

## Hard Rules

- Always wrap commands in `nix develop --command`.
- Always set a Bash tool timeout longer than the benchmark duration. Never run benchmarks without a timeout.
- Use `zig build benchmark`; it is configured for offscreen graphics rendering and skip-present behavior.
- Do not add visible monitor flags for benchmarks unless explicitly requested.
- Save benchmark output to a JSON file and inspect it before reporting results.

## Commands

Short smoke benchmark:

```bash
nix develop --command zig build benchmark -Dbenchmark-duration=5 -Dbenchmark-output=zig-out/benchmark-smoke.json
```

Recommended Bash timeout: `60000` ms.

Standard benchmark:

```bash
nix develop --command zig build benchmark -Dbenchmark-duration=60 -Dbenchmark-output=benchmark_results.json
```

Recommended Bash timeout: `120000` ms.

Preset benchmark:

```bash
nix develop --command zig build benchmark -Dbenchmark-preset=high -Dbenchmark-duration=60 -Dbenchmark-output=benchmark-high.json
```

Recommended Bash timeout: `120000` ms.

Release-style benchmark build:

```bash
nix develop --command zig build benchmark -Doptimize=ReleaseFast -Dbenchmark-preset=high -Dbenchmark-duration=60 -Dbenchmark-output=benchmark-high-release.json
```

Recommended Bash timeout: `180000` ms.

## Reporting

Read the output JSON and report:
- `frames`
- average FPS and p95/p99 if relevant
- average CPU ms
- GPU total, shadow, and opaque timings
- draw calls, vertices, chunks rendered
- whether the command timed out, crashed, or completed
