# ZigCraft Handoff

## Current State
- Branch: `handoff/world-rendering-handoff`
- Status: terrain-gap investigation is still **work in progress**
- Main user-visible bug: a large one-sided white terrain hole / missing full-chunk coverage remains near the LOD0 radius
- Latest change is **not yet retested**: GPU mesher allocation failures now reset chunks back to `.generated` instead of leaving them orphaned in `.uploading`

## Problem Summary
- The original suspicion was chunk-coordinate rounding on negative float positions.
- That issue was real and was fixed with a shared floor-based float-to-chunk helper.
- The visual gap still remained after that fix.
- LOD coverage / masking was then investigated and tightened, but that also did not remove the hole.
- The strongest current suspect is now the **full-chunk meshing/upload pipeline**, especially the GPU mesher path.

## Changes Made In This WIP
- `src/world/chunk.zig`
  - Added `worldToChunkFromFloat()` using floor semantics for negative float world positions.
- `src/world/world_renderer.zig`
  - Switched camera chunk selection to `worldToChunkFromFloat()`.
- `src/world/world_streamer.zig`
  - Switched streamer player-chunk logic to `worldToChunkFromFloat()`.
- `src/world/lod_manager.zig`
  - Switched LOD player chunk tracking to `worldToChunkFromFloat()`.
- `src/world/lod_renderer.zig`
  - Switched camera chunk logic to `worldToChunkFromFloat()`.
  - Added logic to disable the LOD near-camera mask when a region is missing real full chunks inside the LOD0 radius.
  - Fixed `isCoveredByChunks()` so it scans the full region instead of bailing on the first chunk outside the radius.
- `src/game/session.zig`
  - Switched HUD chunk display to `worldToChunkFromFloat()`.
- `src/tests.zig`
  - Added regression tests for negative float positions such as `-0.1`, `-15.9`, `-16.0`, and `-16.1`.
- `src/world/gpu_mesher.zig`
  - Fixed GPU mesher finalize failure handling so vertex-allocation failures reset chunks to `.generated` for retry instead of leaving them stuck in `.uploading`.

## What Was Tried But Did Not Fix The Hole
- Shared floor-based float-to-chunk conversion for negative positions.
- LOD mask disable for missing full chunks inside the LOD0 radius.
- LOD coverage-scan fix for boundary LOD regions.

## Current Findings
- CPU chunk culling is the active full-chunk render path.
- GPU chunk culling is initialized but **disabled by default** in `WorldRenderer`.
- GPU mesh build dispatch runs in `MeshBuildPass`, which is scheduled before `OpaquePass` in the render graph.
- `WorldStreamer.updateFrame()` runs before rendering each frame.
- `ChunkStorage.isChunkRenderable()` returns true for chunks in `.renderable` or for chunks that already have any mesh allocation.
- Before the latest `gpu_mesher.zig` fix, a GPU mesher allocation failure could leave a chunk stuck in `.uploading` with no recovery path.
- The boundary meshing helpers in `src/world/meshing/boundary.zig` currently treat missing neighbors as `air`, so that code does **not** yet look like the primary cause.

## Why The Latest Fix Matters
- In `GpuMesher.finalizeCompletedMeshes()`, allocation failure previously just logged and `continue`d.
- That discarded the submitted request while leaving the chunk state unchanged.
- Because the chunk was already in `.uploading`, it could become permanently invisible with no retry path.
- The new behavior resets such chunks to `.generated`, allowing them to re-enter meshing instead of being orphaned forever.

## Recommended Next Steps
1. Retest the exact same scene / camera position after the `src/world/gpu_mesher.zig` recovery change.
2. Capture and compare logs for:
   - `GPU_MESHER`
   - `CHUNK_STATES`
   - `CHUNK_DIAG`
   - `CPU_CULL_GAP`
3. If the hole still persists:
   - temporarily disable GPU meshing / force CPU meshing to determine whether the bug is GPU-path-specific
   - compare the missing chunk coordinates reported by diagnostics against the visible hole
   - add explicit recovery / diagnostics for chunks that remain in `.uploading` too long
4. If CPU meshing also reproduces the hole:
   - revisit boundary-face generation and neighbor lookup with targeted coordinate logging on the missing side

## Build / Test Status
- Full project tests were **not** successfully rerun to completion in this session.
- Prior test attempts were blocked by local environment / dependency issues, including missing external tools or modules such as:
  - `glslangValidator`
  - `SDL3/SDL.h`
  - `zig-math`
  - `zig-noise`

## Modified Files In This WIP
- `HANDOFF.md`
- `src/game/session.zig`
- `src/tests.zig`
- `src/world/chunk.zig`
- `src/world/gpu_mesher.zig`
- `src/world/lod_manager.zig`
- `src/world/lod_renderer.zig`
- `src/world/world_renderer.zig`
- `src/world/world_streamer.zig`
