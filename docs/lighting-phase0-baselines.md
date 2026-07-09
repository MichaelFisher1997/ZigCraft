# Lighting Phase 0 Baselines

The phase-zero fixture uses seed `12345`, frozen time, fixed camera poses, and the
`zigcraft:shadow-test` generator. It provides these named captures:

- `noon`
- `low-sun`
- `cave-entrance`
- `sealed-cave`
- `rgb-emitter`
- `foliage-cutout`
- `water`
- `cross-chunk-corridor`

Capture the complete scene/channel matrix with:

```bash
./scripts/capture_lighting_baselines.sh screenshots/lighting-phase0
```

The canonical channels are final output (0), raw shadow factor (1), cascade
index (2), caster coverage (3), RGB block light (9), raw skylight (12), and raw
vertex AO (13). `ZIGCRAFT_DEBUG_SHADER=<id>` selects a channel for an individual
capture. Out-of-bounds caster coverage is magenta rather than a clamped shadow
map sample.

Headless UNORM captures apply the sRGB display transfer during readback, while
windowed sRGB output leaves that transfer to the attachment. PNGs include the
sRGB rendering-intent chunk. Compare
captures after decoding both as sRGB. The baseline tolerance is mean absolute
per-channel error <= 1/255 and maximum absolute per-channel error <= 3/255;
captures outside either bound fail parity review.

Record the pre-rewrite high-preset benchmark with:

```bash
nix develop --command zig build benchmark -Doptimize=ReleaseFast \
  -Dbenchmark-preset=high -Dbenchmark-duration=60 \
  -Dbenchmark-output=lighting-phase0-high.json
```

The JSON records CPU frame time, FPS distribution, shadow/opaque/total GPU
timings, draw counts, chunk counts, and GPU memory for later phase comparisons.
The captured phase-zero result is committed at
`docs/benchmarks/lighting-phase0-high.json`. It intentionally records the
current draw-call and memory SLO breaches rather than filtering them from the
baseline.
