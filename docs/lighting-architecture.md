# Lighting Architecture

Terrain uses one production lighting model: skylight and RGB block light stored in `PackedLight`. World generators seed new chunks locally; `WorldLightingEngine` propagates only mismatched boundary light when adjacent chunks arrive and reserves bounded 3x3 rebuilding for persisted lighting migrations.

Saved chunks marked with outdated lighting are reconciled before meshing. Runtime lighting updates run on the bounded mesh worker pool and queue affected chunks for remeshing when propagation finishes. Entrance-bounce storage, directional packing, and its mesh/shader path have been retired; save files contain only `PackedLight`, so no storage-format migration is needed.

Terrain vertices carry normalized skylight, RGB block light, and AO. The terrain shader combines these with CSM direct lighting, IBL sky fill, and optional volumetric lighting. Cloud vertices use the packed block-light alpha byte solely as an internal cloud marker.

GPU meshing is disabled until its output matches the CPU vertex stride, lighting inputs, AO, and pass routing. CPU meshing is the only production terrain mesh path.

Use `ZIGCRAFT_DEBUG_SHADER` for deterministic terrain captures. The supported capture channels are documented in `lighting-phase0-baselines.md`; capture the full scene matrix with `scripts/capture_lighting_baselines.sh`.

Shadow quality controls PCF tap count, cascade blending, resolution, and distance. LOW, MEDIUM, HIGH, ULTRA, and EXTREME presets should be evaluated with `zig build benchmark`; the committed baseline and CI benchmark comparison are the regression gate. The CPU/shader shadow uniform block is checked by `scripts/check_shadow_abi.sh` during `zig build test`.
