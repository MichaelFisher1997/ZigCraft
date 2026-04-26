# Phase 5 Module Boundaries

Tracks the final ownership boundaries for issues [#470](https://github.com/OpenStaticFish/ZigCraft/issues/470), [#471](https://github.com/OpenStaticFish/ZigCraft/issues/471), and [#472](https://github.com/OpenStaticFish/ZigCraft/issues/472).

## App And Session

`src/game/app.zig` owns process-level systems and shutdown ordering:

- window/input/time
- settings persistence
- audio and UI managers
- render system lifetime
- screen stack lifetime

Screens receive these systems through `EngineContext`. They should not construct or own world streaming internals directly.

`src/game/session.zig` owns active gameplay state. It constructs a `World` with `World.InitOptions`, creates player/gameplay helpers, and tears those down before returning control to the screen stack.

## World

`src/world/world.zig` is the world-level coordinator. It owns:

- `ChunkStorage`
- `WorldRenderer`
- `WorldStreamer`
- optional `WorldLOD`
- optional persistence and GPU block-buffer handles

Use `World.init(.{ ... })` for construction. LOD is selected by passing `lod_config`; non-LOD worlds leave it `null`. Do not add compatibility constructors for older call-site shapes unless there is a persisted-data or external API requirement.

`World.deinit()` preserves the required shutdown order: idle RHI, flush persistence, stop streaming, release storage mesh allocations, release renderer resources, release LOD, then release the generator.

## World Streaming

`src/world/world_streamer.zig` owns worker queues, worker pools, and the streaming frame lifecycle. Detailed responsibilities are delegated to focused coordinators:

- `ChunkQueueCoordinator` owns generation, meshing, upload queues, save-manager linkage, and stuck-state recovery.
- `LODStreamingCoordinator` owns active render radius, startup ramping, player movement, and LOD manager updates.
- `GpuAccelerationCoordinator` owns GPU meshing availability, CPU fallback, and GPU block-buffer slot lifetime.

Worker callbacks should stay on these coordinators. The streamer should remain an orchestration layer and should not grow direct chunk-state transition logic again.

## Render System

`src/engine/graphics/render_system.zig` owns render-system lifetime and render graph setup. Feature toggles should live on the pass or system they affect:

- shadow draw enablement lives on `ShadowPass`
- G-pass enablement lives on `GPass`
- SSAO enablement lives on `SSAOPass`
- water enablement lives on `WaterReflectionPass` and `WaterPass`
- TAA, bloom, and FXAA enablement live on their pass structs

Environment-variable overrides are applied during render-system construction and initialize the owning pass state. Screen-level debug toggles may call render-system accessors, but those accessors must forward to pass-owned state instead of reintroducing top-level forwarding fields.

## Migration Notes

- Prefer options structs for constructors that cross module boundaries and already have more than a few parameters.
- Keep ownership in the module that performs teardown. If a module allocates a subsystem, it should also deinitialize it.
- Add interfaces at module boundaries when a caller only needs behavior, not concrete storage.
- Avoid compatibility getters, setters, or constructors unless an external consumer requires them.
- Keep environment override parsing at the process/system boundary, then store the resulting state in the owning subsystem or pass.

## Validation

Run these through Nix from the repository root:

```bash
nix develop --command zig fmt src/
nix develop --command zig build test
nix develop --command zig build
```

For startup/shutdown validation, run an automated world launch:

```bash
nix develop --command zig build -Dsmoke-test -Dauto-world=normal run
```
