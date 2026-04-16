# ZigCraft Handoff

## Current State
- Branch: `handoff/world-rendering-handoff`
- Status: terrain-gap investigation is still **work in progress**
- Main user-visible bug: a large one-sided white terrain hole / missing full-chunk coverage remains near the LOD0 radius
- **KEY CLUE**: The bug does NOT occur in flat worlds, only in normal (overworld) terrain. This points to terrain generation or vertex complexity as the root cause.

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
  - Protected `.uploading` chunks from unloading (prevents vertex allocation leaks).
  - Added stuck-chunk timeout for `.uploading` state (resets to `.generated` after 60 frames, max 3 attempts).
  - Added `ZIGCRAFT_FORCE_CPU_MESHING` env var for runtime GPU→CPU meshing switch.
  - `setPaused` now resets `.uploading` chunks to `.generated` alongside `.meshing`.
  - **NEW:** `processGenJob` now validates `chunk.generated` flag after generation. Chunks where the generator returned without setting `generated=true` are reset to `.missing` with `CHUNK_GEN_FAILED` log.
  - **NEW:** `processGenJob` now validates chunk has non-air blocks after generation. Chunks with zero non-air blocks are reset to `.missing` with `CHUNK_GEN_EMPTY` log.
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
- `src/world/chunk_allocator.zig`
  - **NEW:** `reserve()` now logs detailed OOM diagnostics (capacity, total free, largest block, free block count) — previously returned `error.OutOfMemory` silently.
  - **NEW:** `freeImmediateUnlocked` falls back to `append` when `insert` fails, preventing memory leak on OOM.

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
- Before the latest `gpu_mesher.zig` fix, a GPU mesher allocation allocation failure could leave a chunk stuck in `.uploading` with no recovery path.
- The boundary meshing helpers in `src/world/meshing/boundary.zig` currently treat missing neighbors as `air`, so that code does **not** yet look like the primary cause.

### New Findings (Deep Investigation)
1. **Vertex allocation leak via unloading**: Chunks in `.uploading` were NOT protected from unloading (`processUnloads` only protected `.generating` and `.meshing`). If a chunk is unloaded while the GPU mesher has dispatched a compute shader for it, `finalizeCompletedMeshes` creates vertex allocations via `reserve()` but the `replaceAllocations` call fails (storage lookup returns null). These vertices are **permanently leaked**, eventually causing vertex buffer OOM and cascading allocation failures for all chunks. **FIXED**: `.uploading` is now protected from unloading.

2. **No timeout for `.uploading` state**: Unlike `.generating` (120-frame timeout) and `.renderable` (3-attempt recovery), chunks in `.uploading` had no timeout mechanism. A chunk could loop between `.mesh_ready` ↔ `.uploading` indefinitely if the GPU mesher batch was full. **FIXED**: 60-frame timeout with 3-attempt max.

3. **`processGenJob` didn't validate generation success**: The function unconditionally set `state = .generated` without checking `chunk.generated` (set by the generator). If `OverworldGenerator.generate()` returned early on an error path (OOM in `prepareChunkPhaseData`, `fillChunkBlocks` returning false, etc.), the chunk had uninitialized/empty blocks but entered the meshing pipeline. The mesh would have zero vertices, becoming `.renderable` with no allocations. **FIXED**: Added validation for `chunk.generated` flag and non-air block count.

4. **`reserve()` silent OOM**: The `GlobalVertexAllocator.reserve()` method (used by the GPU mesher) returned `error.OutOfMemory` with zero diagnostic logging, unlike `allocate()` which logs detailed diagnostics. This made vertex buffer exhaustion invisible in logs. **FIXED**: Added diagnostic logging matching `allocate()`.

5. **`freeImmediateUnlocked` leak on OOM**: If `free_blocks.insert()` failed, the function silently returned, permanently losing track of the freed memory block. **FIXED**: Falls back to `append()` when `insert()` fails.

6. **Flat world vs normal world**: The bug does NOT occur in flat worlds. This strongly suggests the issue is related to:
   - Normal terrain producing higher vertex counts (vertex buffer exhaustion)
   - The OverworldGenerator having edge cases at specific chunk coordinates
   - GPU compute shader overflow on complex terrain geometry
   - Chunks with very different heights from their neighbors causing boundary meshing issues

7. **GPU mesher `cmd == null` silent loss**: In `finalizeCompletedMeshes`, if `cmd` (current command buffer) is null, the function returns early WITHOUT clearing `submitted[prev_fi]`. On the next frame, `dispatchQueuedMeshes` calls `submitted[fi].clearRetainingCapacity()`, which discards the unprocessed items. The chunks remain in `.uploading` state (now recoverable via the new timeout).

8. **`worldToChunkFromFloat` correctness verified**: Floor semantics work correctly for all tested negative boundary positions. `-16.0` → chunk -1, `-16.1` → chunk -2. This is NOT the cause of the remaining hole.

## Why The Latest Fix Matters
- In `GpuMesher.finalizeCompletedMeshes()`, allocation failure previously just logged and `continue`d.
- That discarded the submitted request while leaving the chunk state unchanged.
- Because the chunk was already in `.uploading`, it could become permanently invisible with no retry path.
- The new behavior resets such chunks to `.generated`, allowing them to re-enter meshing instead of being orphaned forever.

## Recommended Next Steps
1. Retest the exact same scene / camera position with all the new fixes.
2. **Capture logs and look for these new diagnostic messages**:
   - `CHUNK_GEN_FAILED` — generator returned without setting generated=true
   - `CHUNK_GEN_EMPTY` — generated chunk has zero non-air blocks
   - `GlobalVertexAllocator RESERVE OOM` — vertex buffer exhaustion with diagnostics
   - `CHUNK_UPLOAD_STUCK` — uploading timeout recoveries
3. **Use `ZIGCRAFT_FORCE_CPU_MESHING=1` to force CPU meshing** at runtime. This is the primary diagnostic for determining if the bug is GPU-path-specific.
   - Note: the env var is polled every 30 frames. When toggled ON, all `.mesh_ready`/`.uploading` chunks are immediately reset to `.generated` for CPU re-meshing.
4. If the hole persists with CPU meshing too:
   - the bug is in the streaming/culling pipeline or terrain generation, not the GPU mesher
   - compare the missing chunk coordinates from `CHUNK_DIAG`/`CPU_CULL_GAP` against the visible hole
   - check for `CHUNK_GEN_FAILED` or `CHUNK_GEN_EMPTY` at the missing coordinates
5. If the hole disappears with CPU meshing:
   - the bug is in the GPU compute shader or the GPU mesher finalize path
   - check the `GlobalVertexAllocator RESERVE OOM` logs — normal terrain may exhaust the vertex buffer
   - check if the compute shader produces overflow (`overflow_mask != 0`) for complex chunks
6. Given that flat world works but normal terrain doesn't, **suspect vertex buffer exhaustion**:
   - normal terrain produces ~5-10x more vertices per chunk than flat terrain
   - if the vertex buffer fills up, `reserve()` fails → chunk reset to `.generated` → re-mesh loop
   - after 3 recovery attempts, chunk is permanently stuck `.renderable` with no allocations
   - check the `RESERVE OOM` log for capacity vs total free vs largest block metrics

## Build / Test Status
- Full project tests **pass** (exit code 0) with `nix develop --command zig build test`.
- All unit tests including regression tests for negative float positions pass.
- Shader compilation and validation pass.

## Modified Files In This WIP
- `HANDOFF.md`
- `src/game/session.zig`
- `src/tests.zig`
- `src/world/chunk.zig`
- `src/world/chunk_allocator.zig`
- `src/world/gpu_mesher.zig`
- `src/world/lod_manager.zig`
- `src/world/lod_renderer.zig`
- `src/world/world_renderer.zig`
- `src/world/world_streamer.zig`
