# ZigCraft Handoff

## Current State
- Branch: `handoff/world-rendering-handoff`
- Build/test status: `nix develop --command zig build test` passes
- GPU crash path: fixed enough that normal mode no longer segfaults after `VK_ERROR_DEVICE_LOST`
- Remaining problem: world rendering still has gaps/peeling, and some distant features are missing or unstable

## Symptoms Observed
- Terrain chunks disappear or "peel away" when the camera rotates
- There are visible holes/gaps in the terrain coverage
- Clouds are inconsistent or absent in some runs
- LOD rendering still looks unreliable
- Shadows may be missing or not showing as expected in normal mode

## What Was Fixed Already
- `VK_ERROR_DEVICE_LOST` no longer cascades into a RADV segfault
- `gpu_fault_detected` is now set when the frame ends with `GpuLost`
- Transfer flushes are guarded so the app stops calling into Vulkan after loss
- GPU recovery path was added to the main loop
- `ZIGCRAFT_SAFE_MODE` / `ZIGCRAFT_SAFE_RENDER` distinction was preserved

## Rendering Changes Made
- `src/game/session.zig`
  - Re-enabled LOD use in normal mode by removing the hardcoded `effective_lod_enabled = false`
  - Safe mode still disables LOD
- `src/world/world_renderer.zig`
  - Removed the chunk frustum-culling path that was likely causing chunks to vanish when looking around
- `src/world/lod_renderer.zig`
  - Restored proper region coverage checks instead of skipping based on only one chunk
  - Added a full chunk-coverage test for LOD coverage decisions
- `src/world/lod_manager.zig`
  - `cleanup_covered_regions` was changed to `false` by default to keep LOD meshes around

## Important Suspects
1. `src/world/lod_renderer.zig`
   - LOD visibility/coverage logic is still the most likely cause of holes
   - The region coverage check may still be too aggressive or use the wrong coordinate range
2. `src/world/lod_manager.zig`
   - Covered-region cleanup may still be interfering with visible terrain if it gets re-enabled elsewhere
3. `src/world/world_renderer.zig`
   - CPU-side chunk visibility logic was simplified to stop peel-away, but the deeper cause may still be in the render flow
4. `src/game/screens/world.zig` and `src/engine/graphics/render_system.zig`
   - Cloud/shadow pass wiring and runtime flags should be rechecked if those features still fail to appear

## File References
- `src/engine/graphics/vulkan/rhi_pass_orchestration.zig`
- `src/engine/graphics/rhi_vulkan.zig`
- `src/engine/graphics/vulkan/transfer_queue.zig`
- `src/engine/graphics/vulkan/rhi_state_control.zig`
- `src/game/app.zig`
- `src/game/session.zig`
- `src/world/world_renderer.zig`
- `src/world/lod_renderer.zig`
- `src/world/lod_manager.zig`
- `src/game/screens/world.zig`
- `src/engine/graphics/render_system.zig`

## Runtime Notes
- Current settings were tuned away from the earlier very-low profile
- The app now runs without crashing, but visual correctness is still incomplete
- The bug appears view-dependent, which points more toward culling/LOD than texture issues

## Suggested Next Steps
1. Reproduce the hole/peel behavior with logging disabled
2. Inspect LOD region coverage and chunk coverage math in `lod_renderer.zig`
3. Confirm whether LOD meshes are being drawn over or under normal chunks as the camera turns
4. Revisit shadow/cloud pass enablement only after terrain coverage is stable
5. If needed, temporarily draw debug bounds for LOD regions and chunk coverage to confirm which regions are being skipped

## Verification
- `nix develop --command zig build test`
- Runtime still needs visual retesting in normal mode
