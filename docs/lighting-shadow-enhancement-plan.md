# Lighting And Shadow Enhancement Plan

Current state:
- Shadows are intentionally hard-disabled in `src/engine/graphics/render_system.zig`.
- The renderer is using the simplified no-shadow baseline in `assets/shaders/vulkan/terrain.frag`.
- Recent fixes already landed for:
  - exposed-face light sampling at mesh boundaries
  - grass/leaf tint preservation in simple lighting mode
  - grass cutout shimmer reduction

This document turns the current roadmap into an execution checklist.

## Principles

- Keep the current no-shadow baseline stable until direct light and skylight feel correct.
- Reintroduce one major system at a time.
- Treat LPV as a later quality phase, not a dependency for the first full relight.
- Validate every phase in the same fixed scenes before moving on.

## Validation Scenes

Use these scenes for every phase:

1. Single stone pillar on flat grass at noon
2. Tree trunk under canopy
3. Sunset hillside
4. Moonlit field
5. Cave mouth
6. Deep cave
7. Torch in cave
8. Dense grass patch at medium distance

## Phase 1: Cinematic Baseline Polish

Goal:
- strong directional sun/moon read
- small but intentional skylight fill
- dark caves
- readable dusk and night

Files:
- `assets/shaders/vulkan/terrain.frag`
- `assets/shaders/vulkan/sky.frag`
- `src/game/screens/world.zig`

Tasks:
- Refine `computeSimpleLighting(...)` into a deliberate 3-term model:
  - key light from `sun_dir`
  - sky fill from skylight exposure
  - block light
- Keep billboard-specific handling for cutout vegetation.
- Keep caves dark by reducing fill when `vSkyLight` is low.
- Strengthen the visual readability of the sun disk, solar glow, moon, and dusk palette.
- Keep LPV, SSAO, volumetrics, and fog disabled in simple mode.

Acceptance:
- Lit and unlit faces are readable outdoors.
- Unlit outdoor faces are dark but not crushed.
- Cave interiors are intentionally dark.
- The sky clearly communicates time of day and primary light direction.

Rollback:
- Revert only terrain/sky tuning, not mesh-lighting fixes.

## Phase 2: Skylight Propagation Overhaul

Goal:
- replace column-only skylight with propagation through connected open air

Files:
- `src/world/worldgen/lighting_computer.zig`
- `src/world/chunk.zig`
- `src/world/world.zig`
- `src/world/chunk_tests.zig`

Tasks:
- Replace the top-down per-column skylight assignment with a queue-based propagation pass.
- Seed from sky-exposed cells and flood through non-opaque blocks.
- Preserve water attenuation.
- Update edit-time recomputation so block changes affect nearby skylight, not just one column.
- Add/adjust tests for:
  - cave mouth light bleed
  - overhangs
  - water attenuation
  - block edits near openings

Acceptance:
- Cave mouths show a gradient instead of a binary cutoff.
- Overhangs and openings receive believable skylight.
- Newly placed/removed blocks update nearby skylight correctly.

Rollback:
- If incremental updates are unstable, keep the new generator-time propagation and temporarily use conservative local rebuilds after block edits.

## Phase 3: Baseline Debug Views

Goal:
- make the simple lighting model inspectable before shadows come back

Files:
- `assets/shaders/vulkan/terrain.frag`
- `src/game/settings/data.zig`
- `src/game/screens/world.zig`

Tasks:
- Add debug channels for:
  - direct key light amount
  - sky fill amount
  - block light amount
  - outdoor/skylight exposure factor
- Keep shadow debug channels dormant while shadows are off.

Acceptance:
- It is obvious why a face is bright or dark without guessing from the final frame.

## Phase 4: Shadow System Return

Goal:
- restore cascaded directional shadows on top of the improved baseline

Files:
- `src/engine/graphics/render_system.zig`
- `src/game/screens/world.zig`
- `src/engine/graphics/render_graph.zig`
- `src/engine/graphics/csm.zig`
- `src/engine/graphics/shadow_system.zig`
- `src/engine/graphics/vulkan/rhi_resource_setup.zig`
- `src/engine/graphics/vulkan/rhi_frame_orchestration.zig`
- `src/engine/graphics/vulkan/rhi_resource_lifecycle.zig`
- `assets/shaders/vulkan/terrain.frag`
- `src/world/world_renderer.zig`
- `src/engine/ui/debug_shadow_overlay.zig`

Tasks:
- Remove the hardcoded shadow kill switch.
- Re-enable the four shadow passes in the render graph.
- Revalidate CSM split distribution, texel snapping, and seam blending.
- Confirm reverse-Z sampling, compare op, and depth layouts remain correct.
- Reintroduce terrain shadow contribution.
- Decide whether to keep the current shadow-pass caster-culling bypass or replace it with a correct culling path.

Acceptance:
- Stable outdoor directional shadows.
- No detached shadows.
- No obvious cascade pop near the camera.
- Shadow debug maps and shadow-factor views become trustworthy again.

Rollback:
- If cascades regress, disable shadow passes again but keep the improved terrain/sky/skylight baseline.

## Phase 5: Vegetation And Cutout Shadowing

Goal:
- restore believable foliage shadows without reintroducing grass shimmer/noise

Files:
- `assets/shaders/vulkan/shadow.vert`
- `assets/shaders/vulkan/shadow.frag`
- `src/engine/graphics/vulkan/rhi_resource_setup.zig`
- `src/world/meshing/cross_mesher.zig`
- `assets/shaders/vulkan/terrain.frag`

Tasks:
- Reassess the cutout shadow path now that the baseline and CSM are stable.
- Keep alpha-tested shadow casting for leaves.
- Decide whether grass should cast shadows at all.
- Keep the no-duplicate-plane grass mesh path.
- Retune cutout alpha thresholds only if needed.

Acceptance:
- Leaves cast believable shadows.
- Grass remains visually stable.
- No billboard/X-shaped shadow artifacts.

## Phase 6: Atmosphere Extras

Goal:
- reintroduce atmosphere without rebreaking interiors or caves

Files:
- `src/game/screens/world.zig`
- `assets/shaders/vulkan/terrain.frag`
- `assets/shaders/vulkan/sky.frag`

Tasks:
- Re-enable in this order:
  1. fog
  2. volumetrics
- Keep every effect gated by real sky visibility.
- Ensure caves and interiors do not pick up screen-wide or camera-relative light layers.

Acceptance:
- Fog improves mood instead of flattening the scene.
- Volumetric lighting reads near the sun and stays out of caves.

Rollback:
- Any atmospheric layer that reintroduces moving cave light goes back off immediately.

## Phase 7: LPV Return

Goal:
- bring indirect light back as a quality layer after direct light, skylight, and shadows are solid

Files:
- `src/engine/graphics/lpv_system.zig`
- `assets/shaders/vulkan/terrain.frag`
- `src/game/screens/world.zig`

Tasks:
- Re-enable LPV only after the previous phases are stable.
- Fix world-space stability and reduce grid pop.
- Add sky/atmosphere injection later, only if needed.
- Keep indoor leakage checks strict.

Acceptance:
- LPV adds richness without creating camera-following light blobs.
- Disabling LPV lowers quality but does not fix correctness.

## Immediate Execution Order

Recommended first implementation batch:

1. Phase 1: terrain and sky polish
2. Phase 2: skylight propagation overhaul
3. Phase 3: baseline debug views

Only after those are stable:

4. Phase 4: shadows back on
5. Phase 5: cutout shadow polish
6. Phase 6: atmosphere extras
7. Phase 7: LPV return

## Current Temporary Toggles To Remove Later

- `src/engine/graphics/render_system.zig`
  - `temporary_disable_shadows = true`
- `src/game/screens/world.zig`
  - `simple_lighting_mode = shadows_disabled`

These stay in place until the Phase 4 shadow return work begins.
