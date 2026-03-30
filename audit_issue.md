## 🔍 Module Scanned
`src/world/` (automated audit scan)

## 📝 Summary
The `GlobalVertexAllocator.free()` method queues vertex allocations into the **current** frame slot, but these allocations may still be in use by the GPU. When `tick(frame_index)` is called at the start of the next frame, it immediately frees allocations from that slot, creating a use-after-free race condition that can cause GPU crashes, visual corruption, or memory corruption.

## 📍 Location
- **File:** `src/world/chunk_allocator.zig:142-161`
- **Function/Scope:** `GlobalVertexAllocator.free()`

## 🔴 Severity: Critical
- **Critical:** Crashes, data corruption, security vulnerabilities, GPU device loss

## 💥 Impact
When a chunk mesh is freed (e.g., during chunk unloading or remeshing), its vertex allocation is returned to the `GlobalVertexAllocator`. Due to the double-buffering scheme (`MAX_FRAMES_IN_FLIGHT = 2`), the GPU may still be reading from these vertices for 1-2 frames after they're "freed." 

The current implementation:
1. Queues the free into `deferred_frees[ current_frame ]`
2. Frees allocations from slot `current_frame` on the next `tick(current_frame)` call

This creates a race window where:
- Frame N: Mesh is freed, queued to slot N
- Frame N+1: `tick(N)` frees the GPU memory while GPU may still be rendering Frame N
- Result: Use-after-free, GPU reads invalid memory

Symptoms include:
- Random GPU crashes/hangs
- Visual artifacts (missing chunks, corrupted geometry)
- Validation layer errors about accessing freed memory
- Potential GPU device loss requiring application restart

## 🔎 Evidence
```zig
// src/world/chunk_allocator.zig:142-161
pub fn free(self: *GlobalVertexAllocator, allocation: VertexAllocation) void {
    if (allocation.count == 0) return;

    self.mutex.lock();
    defer self.mutex.unlock();

    // Queue for the CURRENT frame slot.  // ← BUG: Wrong slot!
    // It will be reclaimed in the NEXT frame when we tick(current_frame).
    // Since current_frame slot won't be reused by the GPU until we submit this frame
    // and finish waiting for its fence, it's safe to free things from it.
    // HOWEVER, we must be careful with reuse.
    // A safer way is to queue for (frame_index + 1) % MAX_FRAMES_IN_FLIGHT.  // ← Fix mentioned!

    const frame_idx = self.device_query.getFrameIndex();  // ← Gets CURRENT frame
    self.deferred_frees[frame_idx].append(self.allocator, allocation) catch {
        // Fallback to immediate free if queue is full (better than leak, though slightly risky)
        log.log.warn("Deferred free queue full, falling back to immediate free", .{});
        self.freeImmediateUnlocked(allocation);
    };
}
```

The comment acknowledges the bug (line 153: "A safer way is to queue for (frame_index + 1) % MAX_FRAMES_IN_FLIGHT") but the code still uses the current frame index.

The `tick()` function (lines 68-77) processes and frees allocations:
```zig
pub fn tick(self: *GlobalVertexAllocator, frame_index: usize) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const frees = &self.deferred_frees[frame_index];  // ← Frees from CURRENT slot
    for (frees.items) |alloc| {
        self.freeImmediateUnlocked(alloc);  // ← GPU memory returned to free list
    }
    frees.clearRetainingCapacity();
}
```

Called from:
```zig
// src/world/world_renderer.zig:104
self.vertex_allocator.tick(self.query.getFrameIndex());
```

## 🛠️ Proposed Fix
Change the frame slot calculation in `free()` to use the **next** frame slot instead of the current one:

```zig
pub fn free(self: *GlobalVertexAllocator, allocation: VertexAllocation) void {
    if (allocation.count == 0) return;

    self.mutex.lock();
    defer self.mutex.unlock();

    // Queue for the NEXT frame slot to ensure GPU is done
    const current_frame = self.device_query.getFrameIndex();
    const frame_idx = (current_frame + 1) % rhi_mod.MAX_FRAMES_IN_FLIGHT;
    
    self.deferred_frees[frame_idx].append(self.allocator, allocation) catch {
        log.log.warn("Deferred free queue full, falling back to immediate free", .{});
        self.freeImmediateUnlocked(allocation);
    };
}
```

**Why this works:**
- With double buffering (`MAX_FRAMES_IN_FLIGHT = 2`), there are 2 frame slots: 0 and 1
- Frame N uses slot `N % 2` for rendering
- When `free()` is called during frame N, we queue to slot `(N + 1) % 2`
- `tick(N)` is called at the start of frame N, freeing slot N's allocations (from frame N-1)
- The allocation queued during frame N won't be freed until `tick((N + 1) % 2)` in frame N+1
- This guarantees at least 1 full frame of safety margin

## ✅ Acceptance Criteria
- [ ] The fix uses `(current_frame + 1) % MAX_FRAMES_IN_FLIGHT` for the deferred free slot
- [ ] All unit tests in `src/tests.zig` pass
- [ ] No memory leaks detected when running `nix develop --command zig build test`
- [ ] The change has been verified with `nix develop --command zig build test`
- [ ] Stress testing with rapid chunk loading/unloading shows no GPU validation errors
- [ ] Visual inspection confirms no rendering artifacts during chunk streaming

## 📚 References
- Double buffering explanation: https://docs.vulkan.org/tutorial/latest/03_Drawing_a_triangle/03_Drawing/03_Frames_in_flight.html
- Related code: `src/engine/graphics/rhi_types.zig:37` defines `MAX_FRAMES_IN_FLIGHT = 2`
- Call site: `src/world/world_renderer.zig:104` where `tick()` is invoked
