# RHI Vulkan Refactoring Plan

**Issue:** [#244](https://github.com/OpenStaticFish/ZigCraft/issues/244) - Refactor rhi_vulkan.zig to eliminate god object anti-pattern

**Goal:** Reduce `rhi_vulkan.zig` from 5,228 lines to <800 lines with <30 field `VulkanContext`

**Current State:**
- File: `src/engine/graphics/rhi_vulkan.zig`
- Lines: 5,228
- `VulkanContext` fields: ~100+
- Anti-pattern: God object holding all Vulkan state

**Target State:**
- File: `src/engine/graphics/rhi_vulkan.zig`
- Lines: <800
- `VulkanContext` fields: <30
- Pattern: Coordinator delegating to focused subsystems

---

## PR Breakdown

### PR 1: Pipeline + Render Pass Extraction
**Status:** 🔄 In Progress  
**Scope:** Extract pipeline and render pass management into dedicated managers  
**Note:** Device and swapchain are already modular; this PR focuses on pipelines/render passes

**Files:**
- `src/engine/graphics/vulkan/pipeline_manager.zig` (CREATED ✓)
- `src/engine/graphics/vulkan/render_pass_manager.zig` (CREATED ✓)
- `src/engine/graphics/rhi_vulkan.zig` (Integration in progress)

**Extraction Targets:**
- [x] Create PipelineManager with all pipeline types and layouts
- [x] Create RenderPassManager with all render passes and framebuffers
- [ ] Integrate managers into VulkanContext
- [ ] Replace all pipeline/renderpass field accesses
- [ ] Remove old fields and functions from rhi_vulkan.zig

**Expected Reduction:** ~1,200 lines from rhi_vulkan.zig, ~23 fields from VulkanContext

---

### PR 2: Render Passes + Pipelines
**Status:** 📋 Planned
**Scope:** Extract render pass and pipeline management

**Files:**
- `src/engine/graphics/vulkan/pipeline_manager.zig` (CREATED ✓)
- `src/engine/graphics/vulkan/render_pass_manager.zig` (CREATED ✓)
- `src/engine/graphics/rhi_vulkan.zig` (REFACTOR)

**Extraction Targets:**
- [ ] `createMainRenderPass()` - HDR render pass creation
- [ ] `createGPassResources()` - G-Pass render pass and images
- [ ] `createMainPipelines()` - All graphics pipelines
- [ ] `createSwapchainUIPipelines()` - UI pipelines
- [ ] Pipeline layout creation
- [ ] Framebuffer management

**Expected Reduction:** ~1,200 lines from rhi_vulkan.zig

---

### PR 3: Resource Management + Post-Processing
**Status:** 📋 Planned
**Scope:** Extract resource management and consolidate post-processing

**Files:**
- `src/engine/graphics/vulkan/resource_manager.zig` (ENHANCE)
- `src/engine/graphics/vulkan/post_process_system.zig` (NEW)
- `src/engine/graphics/rhi_vulkan.zig` (REFACTOR)

**Extraction Targets:**
- [ ] HDR resource management (images, views, memory)
- [ ] Post-process render pass and descriptors
- [ ] Bloom system coordination
- [ ] FXAA system coordination
- [ ] SSAO integration
- [ ] Texture/sampler management consolidation

**Expected Reduction:** ~1,500 lines from rhi_vulkan.zig

---

### PR 4: UI Rendering System
**Status:** 📋 Planned
**Scope:** Extract UI rendering into dedicated subsystem

**Files:**
- `src/engine/graphics/vulkan/ui_rendering_system.zig` (NEW)
- `src/engine/graphics/rhi_vulkan.zig` (REFACTOR)

**Extraction Targets:**
- [ ] UI VBO management
- [ ] UI pipeline binding
- [ ] UI descriptor set management
- [ ] 2D drawing functions (`begin2DPass`, `drawRect2D`, etc.)
- [ ] Textured UI rendering

**Expected Reduction:** ~600 lines from rhi_vulkan.zig

---

### PR 5: Final Coordinator Refactor
**Status:** 📋 Planned
**Scope:** Final cleanup and coordinator pattern implementation

**Files:**
- `src/engine/graphics/rhi_vulkan.zig` (MAJOR REFACTOR)
- All subsystem files (MINOR UPDATES)

**Tasks:**
- [ ] Reduce `VulkanContext` to ~25 fields
- [ ] Convert to pure coordinator (no direct Vulkan calls)
- [ ] Clean up imports and dead code
- [ ] Update documentation
- [ ] Verify all tests pass

**Expected Final State:**
- rhi_vulkan.zig: <800 lines
- VulkanContext: <30 fields
- Clean separation of concerns

---

## Subsystem Architecture

```
VulkanContext (Coordinator)
├── DeviceManager
│   ├── VulkanDevice (physical/logical device)
│   └── Device capabilities
├── SwapchainManager
│   ├── SwapchainPresenter
│   └── Present mode management
├── RenderPassManager
│   ├── HDR render pass
│   ├── G-Pass render pass
│   ├── Post-process render pass
│   └── UI render pass
├── PipelineManager
│   ├── Terrain pipeline
│   ├── Wireframe pipeline
│   ├── Selection pipeline
│   ├── Line pipeline
│   ├── G-Pass pipeline
│   ├── Sky pipeline
│   └── UI pipelines
├── ResourceManager (existing)
│   ├── Buffer management
│   ├── Texture management
│   └── Shader management
├── PostProcessSystem
│   ├── HDR resources
│   ├── BloomSystem
│   ├── FXAASystem
│   └── SSAOSystem
├── UIRenderingSystem
│   ├── UI VBOs
│   ├── UI pipelines
│   └── UI descriptors
├── FrameManager (existing)
├── DescriptorManager (existing)
├── ShadowSystem (existing)
└── Timing/Query system
```

---

## Testing Strategy

Each PR must:
1. Compile without errors: `nix develop --command zig build`
2. Pass all unit tests: `nix develop --command zig build test`
3. Run integration test: `nix develop --command zig build test-integration`
4. Manual verification: Run application and verify rendering

---

## Migration Guide

### For PR 1 (Device + Swapchain):
```zig
// Before:
ctx.vulkan_device.init(...)
ctx.swapchain.recreate()

// After:
ctx.device_manager.init(...)
ctx.swapchain_manager.recreate()
```

### For PR 2 (Render Passes + Pipelines):
```zig
// Before:
try createMainRenderPass(ctx);
try createMainPipelines(ctx);

// After:
try ctx.render_pass_manager.createMainRenderPass(...);
try ctx.pipeline_manager.createMainPipelines(...);
```

### For PR 3 (Post-Processing):
```zig
// Before:
try createHDRResources(ctx);
ctx.bloom.init(...);

// After:
try ctx.post_process_system.initHDR(...);
ctx.post_process_system.bloom.init(...);
```

---

## Progress Tracking

| PR | Status | Lines Removed | Fields Removed | Tests Pass |
|----|--------|---------------|----------------|------------|
| 1  | 🔄     | -             | -              | -          |
| 2  | 📋     | -             | -              | -          |
| 3  | 📋     | -             | -              | -          |
| 4  | 📋     | -             | -              | -          |
| 5  | 📋     | -             | -              | -          |
| **Total** | | **~4,400** | **~70** | **✓** |

---

## Notes

- Each PR should be reviewable independently
- No functional changes - purely structural refactoring
- Maintain backward compatibility with RHI interface
- Document any breaking changes in PR descriptions
