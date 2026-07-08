# ZigCraft Agent Guidelines

Essential instructions for agentic coding agents operating in this Zig voxel engine repository.

---

## Development Environment

Uses Nix for dependency management. **All build/test commands MUST be wrapped in `nix develop --command`**.

### Build & Run
```bash
nix develop --command zig build                      # Debug build
nix develop --command zig build run                  # Run application
nix develop --command zig build -Doptimize=ReleaseFast  # Release build
rm -rf zig-out/ .zig-cache/                          # Clean artifacts
```

### Testing
```bash
nix develop --command zig build test                 # Unit tests + shader validation
nix develop --command zig build test -- --test-filter "Vec3 addition"  # Single test
nix develop --command zig build test-integration     # Window init smoke test
nix develop --command zig build test-robustness      # GPU robustness test
```

### Headless Runtime Verification
Use project skills for bounded background runs:
- `headless-crash-test` for crash, hang, startup, and world-load checks
- `headless-screenshot` for offscreen screenshots and visual evidence
- `headless-benchmark` for JSON benchmark runs with full offscreen graphics rendering
- `headless-graphics-verification` for graphics/RHI/shader verification workflows

When launching the game from an agent, prefer `-Dskip-present` unless the user explicitly requests a visible window. Always set a tool timeout for runtime, screenshot, and benchmark commands so the agent never gets stuck on a hung game process.

### Formatting & Git Hooks
```bash
nix develop --command zig fmt src/                   # Format code
./scripts/setup-hooks.sh                             # Enable pre-push checks
```

### Debug Build Options
```bash
-Ddebug_shadows    # Enable shadow debug visualization
-Dsmoke-test       # Auto-load world and exit (for automated testing)
-Dskip-present     # Full offscreen graphics mode (render without showing/presenting a window)
-Dbenchmark-preset=low  # Graphics preset for benchmark runs (low/medium/high/ultra/extreme)
-Dauto-world=normal  # Auto-open a generator directly (normal/overworld or flat)
-Dmonitor-index=1  # Open the game window on a specific 0-based SDL display index
-Dmonitor-name=DP-2  # Move the game window to a named Hyprland monitor
-Dwindow-video-driver=x11  # Force SDL's video backend (useful when Wayland ignores window placement)
-Dwindow-no-focus  # Create the game window without taking keyboard focus
-Dstartup-diagnostic-seconds=5  # Wait N seconds, log chunk/LOD counts, and exit
-Dchunk-debug-mode  # Disable LOD, water, caves, and decorations for isolation
-Dchunk-debug-enable=lod,caves  # Re-enable individual systems in chunk-debug-mode
```

`-Dchunk-debug-enable=` accepts a comma-separated list of:
- `lod`
- `water`
- `watergen`
- `waterrender`
- `caves`
- `decorations`

---

## Git Workflow

- **Default branch**: `dev`
- **All PRs target `dev`** (not `main`)
- **Never push directly to `dev`** unless the user explicitly instructs you to do so
- Code changes should land through a pull request targeting `dev` so they receive PR code review
- Branch naming: `feature/*`, `bug/*`, `hotfix/*`, `ci/*`
- Conventional commits: `feat:`, `fix:`, `refactor:`, `test:`, `docs:`

---

## Project Structure

```
modules/
  engine-core/      # Window, time, logging, job system, shared interfaces
  engine-graphics/  # Render system, Vulkan backend, shaders, textures, camera, shadows
  engine-rhi/       # RHI contracts, resource manager, render settings, culling interfaces
  engine-math/      # Vec3, Mat4, AABB, Frustum, ray/voxel helpers
  engine-input/     # Input handling
  engine-ui/        # Immediate-mode UI, fonts, widgets, overlays
  world-core/       # Blocks, chunk data, coordinates, light packing
  world-worldgen/   # Terrain generation, biomes, caves, decorations, generator registry
  world-meshing/    # Chunk storage, chunk mesh generation, GPU block buffers, meshing helpers
  world-lod/        # Distant terrain LOD chunks, meshes, scheduler, renderer, manager
  world-runtime/    # World facade, streamer, renderer, mutation, GPU meshing runtime
  world-persistence/# Level data, region files, chunk serialization, save manager
src/
  game/             # Application logic, state, menus
  c.zig             # Central C imports (@cImport for SDL3, Vulkan)
  main.zig          # Entry point
  tests.zig         # Unit test suite aggregator
libs/               # Local dependencies (zig-math, zig-noise)
assets/shaders/     # GLSL shaders (vulkan/ contains SPIR-V)
```

---

## Code Style

### Naming Conventions
- **Types/Structs/Enums**: `PascalCase` (`RenderSystem`, `BufferHandle`, `BlockType`)
- **Functions**: `camelCase` following Zig stdlib convention (`initRenderer`, `meshQueue`, `chunkX`)
- **Variables**: `snake_case` (`mesh_queue`, `chunk_x`)
- **Constants/Globals**: `SCREAMING_SNAKE_CASE` (`MAX_CHUNKS`, `CHUNK_SIZE_X`)
- **Files**: `snake_case.zig`

### Import Order
```zig
// 1. Standard library
const std = @import("std");
const Allocator = std.mem.Allocator;

// 2. C imports (always via c.zig)
const c = @import("../c.zig").c;

// 3. Project modules by package name
const Vec3 = @import("engine-math").Vec3;
const log = @import("engine-core").log;
```

### Memory Management
- Functions allocating heap memory MUST accept `std.mem.Allocator`
- Use `defer`/`errdefer` for cleanup immediately after allocation
- Prefer `std.ArrayListUnmanaged` in structs that store the allocator elsewhere
- Use `extern struct` for GPU-shared data layouts (e.g., `Vertex`)

### Error Handling
- Propagate errors with `try`; define subsystem-specific error sets (`RhiError`)
- Log errors via `@import("engine-core").log`: `log.log.err("msg: {}", .{err})`
- Use `//!` for module-level docs, `///` for public API documentation

### Type Patterns
- GPU resource handles are opaque `u32` (`BufferHandle`, `TextureHandle`, `ShaderHandle`)
- Invalid handles are `0` (`InvalidBufferHandle`, etc.)
- Packed data uses `packed struct` (e.g., `PackedLight` for sky/block light)
- Chunk coordinates: `i32`; local block coordinates: `u32` (0-15 for X/Z, 0-255 for Y)

---

## Coordinate Systems

- **World**: Global (x, y, z) in blocks/meters
- **Chunk**: `(chunk_x, chunk_z)` via `@divFloor(world, 16)`
- **Local**: (x, y, z) within a chunk
- Use `worldToChunk()` and `worldToLocal()` from `@import("world-core")`

---

## Architecture

### Render Hardware Interface (RHI)
- All rendering uses the `RHI` interface exported by `engine-rhi`
- Vulkan is the only backend (`rhi_vulkan.zig`)
- Extend functionality by updating `RHI.VTable` and backend implementation

### Job System & Concurrency
- Use `JobSystem` for heavy tasks (world gen, meshing, lighting)
- **Never call RHI or windowing from worker threads**
- Synchronize shared state with `std.Thread.Mutex`
- Use `chunk.pin()`/`chunk.unpin()` when passing chunks to background jobs

---

## Common Tasks

### Adding a New Block Type
1. Add entry to `BlockType` enum in `modules/world-core/src/block.zig`
2. Register properties in `modules/world-core/src/block_registry.zig`
3. Add textures to `modules/engine-graphics/src/texture_atlas.zig`
4. Standardize PBR textures using `./scripts/process_textures.sh`
5. Update `modules/world-meshing/src/chunk_mesh.zig` for special face/transparency logic

### Modifying Shaders
1. GLSL sources in `assets/shaders/vulkan/`
2. Vulkan SPIR-V validated during `zig build test` via `glslangValidator`
3. Uniform names must match exactly between shader source and RHI backends

### Adding Unit Tests
- Add tests alongside modules and expose them from the owning module root; aggregate broad suites from `src/tests.zig`
- Use `std.testing` assertions: `expectEqual`, `expectApproxEqAbs`, `expect`
- Test naming: descriptive, e.g., `test "Vec3 normalize"`

---

## Verification Checklist

Before committing:
- [ ] Run `zig fmt src/` to format code
- [ ] Run `zig build test` (includes shader validation)
- [ ] Run `zig build -Doptimize=ReleaseFast` for performance-critical changes
- [ ] Run `./scripts/process_textures.sh` for any new texture assets

---

## Performance Notes

- Chunk mesh building runs on worker threads; avoid allocations in hot paths
- Use packed structs for large arrays (e.g., light data)
- Profile before optimizing; use `ReleaseFast` for benchmarks
