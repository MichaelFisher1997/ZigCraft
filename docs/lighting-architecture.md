# Lighting Architecture

Terrain uses one production lighting model: skylight and RGB block light stored in `PackedLight` and propagated by `WorldLightingEngine` across each connected loaded chunk component. Chunk arrival and block mutations trigger reconciliation; unloaded chunks are a propagation frontier.

World generation may seed local light for initial chunk data. Runtime reconciliation is authoritative and removes stale values before meshing. Entrance-bounce storage, directional packing, and its mesh/shader path have been retired; save files contain only `PackedLight`, so no chunk migration is needed.

Terrain vertices carry normalized skylight, RGB block light, and AO. The terrain shader combines these with CSM direct lighting, IBL sky fill, and optional volumetric lighting. Cloud vertices use the packed block-light alpha byte solely as an internal cloud marker.

GPU meshing is disabled until its output matches the CPU vertex stride, lighting inputs, AO, and pass routing. CPU meshing is the only production terrain mesh path.

Use `ZIGCRAFT_DEBUG_SHADER` for deterministic terrain captures. The supported capture channels are documented in `lighting-phase0-baselines.md`; capture the full scene matrix with `scripts/capture_lighting_baselines.sh`.

Shadow quality controls PCF tap count, cascade blending, resolution, and distance. LOW, MEDIUM, HIGH, ULTRA, and EXTREME presets should be evaluated with `zig build benchmark`; the committed baseline and CI benchmark comparison are the regression gate. The CPU/shader shadow uniform block is checked by `scripts/check_shadow_abi.sh` during `zig build test`.
