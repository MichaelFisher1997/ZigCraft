## 🔍 Module Scanned
`src/engine/graphics/vulkan/rhi_resource_lifecycle.zig` (automated audit scan)

## 📝 Summary
Two functions (`transitionImagesToShaderRead` and `transitionImagesToPresent`) contain stack buffer overflow vulnerabilities due to fixed-size arrays without bounds checking. Both functions allocate a fixed array of 16 `VkImageMemoryBarrier` structures on the stack but accept a variable-length slice of images without validating that the count doesn't exceed 16.

## 📍 Location
- **File:** `src/engine/graphics/vulkan/rhi_resource_lifecycle.zig`
- **Function/Scope:** `transitionImagesToShaderRead()` (lines 156-197) and `transitionImagesToPresent()` (lines 199-240)

## 🔴 Severity: High
- **Critical:** Crashes, data corruption, security vulnerabilities, GPU device loss
- **High:** Memory leaks, race conditions, incorrect rendering, broken features
- **Medium:** Performance degradation, missing error handling, suboptimal patterns
- **Low:** Code style, dead code, minor improvements

## 💥 Impact
If these functions are called with more than 16 images, they will write past the end of the `barriers` array, causing:
1. **Stack buffer overflow** - Undefined behavior, potential security vulnerability
2. **Memory corruption** - Overwriting adjacent stack variables or return addresses
3. **Crashing or hangs** - Especially dangerous in GPU driver code paths
4. **Silent failures** - If the overflow corrupts data structures instead of crashing immediately

Currently, the code is safe because:
- `transitionImagesToShaderRead` is called with max 11 images (6 candidates + 5 bloom mips)
- `transitionImagesToPresent` is called with max 8 images (`MAX_SWAPCHAIN_IMAGES`)

However, this is a **latent bug** that will trigger if:
- `BLOOM_MIP_COUNT` is increased beyond 10 (currently 5)
- More candidate images are added to the transition lists
- The functions are called from new code paths with larger image arrays

## 🔎 Evidence

### Problematic code in `transitionImagesToShaderRead`:
```zig
pub fn transitionImagesToShaderRead(ctx: anytype, images: []const c.VkImage, is_depth: bool) !void {
    // ...
    const count = images.len;  // No bounds check!
    var barriers: [16]c.VkImageMemoryBarrier = undefined;  // Fixed size: 16
    for (0..count) |i| {  // Will overflow if count > 16
        barriers[i] = std.mem.zeroes(c.VkImageMemoryBarrier);
        // ...
    }
    c.vkCmdPipelineBarrier(cmd, ..., @intCast(count), &barriers[0]);
    // ...
}
```

### Problematic code in `transitionImagesToPresent`:
```zig
pub fn transitionImagesToPresent(ctx: anytype, images: []const c.VkImage) !void {
    // ...
    const count = images.len;  // No bounds check!
    var barriers: [16]c.VkImageMemoryBarrier = undefined;  // Fixed size: 16
    for (0..count) |i| {  // Will overflow if count > 16
        barriers[i] = std.mem.zeroes(c.VkImageMemoryBarrier);
        // ...
    }
    c.vkCmdPipelineBarrier(cmd, ..., @intCast(count), &barriers[0]);
    // ...
}
```

### Caller sites that could overflow if modified:
- `rhi_frame_orchestration.zig:104` - Uses array of 32 but calls function with `count`
- `rhi_init_deinit.zig:182` - Uses array of 32 but calls function with `count`

## 🛠️ Proposed Fix
Add bounds checking at the start of both functions:

```zig
pub fn transitionImagesToShaderRead(ctx: anytype, images: []const c.VkImage, is_depth: bool) !void {
    const max_barriers = 16;
    if (images.len > max_barriers) {
        log.log.err("transitionImagesToShaderRead: too many images ({} > max {})", .{ images.len, max_barriers });
        return error.TooManyObjects;
    }
    // ... rest of function
}

pub fn transitionImagesToPresent(ctx: anytype, images: []const c.VkImage) !void {
    const max_barriers = 16;
    if (images.len > max_barriers) {
        log.log.err("transitionImagesToPresent: too many images ({} > max {})", .{ images.len, max_barriers });
        return error.TooManyObjects;
    }
    // ... rest of function
}
```

Alternatively, for a more robust solution:
1. Use a dynamic allocation via the context's allocator
2. Or use `std.ArrayList` with a pre-allocated capacity
3. Or process images in batches of 16

## ✅ Acceptance Criteria
- [ ] Bounds checking added to `transitionImagesToShaderRead` to reject calls with >16 images
- [ ] Bounds checking added to `transitionImagesToPresent` to reject calls with >16 images
- [ ] Error is logged when bounds are exceeded (fail-fast behavior)
- [ ] All unit tests in `src/tests.zig` pass
- [ ] No regression in `nix develop --command zig build test`
- [ ] Consider adding comptime assertions at call sites to catch issues at compile time

## 📚 References
- **CWE-121:** Stack-based Buffer Overflow (https://cwe.mitre.org/data/definitions/121.html)
- **Vulkan spec:** `vkCmdPipelineBarrier` can handle up to `UINT32_MAX` barriers, but implementation limits may vary
- **Zig safety:** Use `std.debug.assert` or explicit bounds checks for safety-critical code
- **Related constants:** `MAX_SWAPCHAIN_IMAGES = 8`, `BLOOM_MIP_COUNT = 5` in `rhi_types.zig`
