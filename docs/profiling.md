# Profiling Captures

`.github/workflows/profiling.yml` runs nightly and on manual dispatch. It captures a bounded fixed-world profiling run on the same Lavapipe graphics stack used by benchmark CI.

The current capture command is:

```bash
nix develop .#ci-graphics --command zig build benchmark -Doptimize=ReleaseFast -Dbenchmark-preset=medium -Dbenchmark-duration=10 -Dbenchmark-output=profiling-artifacts/fixed-world-profile.json
```

Artifacts are uploaded as `profiling-artifacts` and linked from the run summary:

- `fixed-world-profile.json`: raw deterministic benchmark metrics.
- `perfetto-trace.json`: Chrome/Perfetto trace-event JSON synthesized from the benchmark frame metrics.
- `tracy-frame.json`: stable ZigCraft Tracy-frame interchange JSON containing the same fixed-run frame events.

The generated trace artifacts are intentionally derived from the fixed-world benchmark output so every nightly run leaves inspectable timing evidence even before native Tracy/Perfetto exporters are added to the engine. The workflow is nightly-only to keep pull-request cost bounded.
