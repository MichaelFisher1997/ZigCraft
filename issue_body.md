## 🔍 Module Scanned
`src/game/` (automated audit scan)

## 📝 Summary
`GameSession.init()` contains a critical resource leak bug. When initialization fails partway through after some resources have been allocated, the error deferral only destroys the session struct itself but leaves previously allocated resources (World, WorldMap, GPU buffers) orphaned and leaking.

## 📍 Location
- **File:** `src/game/session.zig:105-181`
- **Function/Scope:** `GameSession.init()`

## 🔴 Severity: Critical
- **Critical:** Crashes, data corruption, security vulnerabilities, GPU device loss

## 💥 Impact
If world generation fails or any initialization step fails after partial resource allocation:
1. **Memory leaks**: World, WorldMap, and other allocated resources are never freed
2. **GPU resource leaks**: Buffer handles, texture resources remain allocated in GPU memory
3. **Cumulative degradation**: Repeated world loading/unloading (e.g., player creating multiple worlds in one session) will exhaust system memory and GPU memory
4. **Potential crashes**: GPU memory exhaustion can cause driver crashes or device loss

This affects:
- World creation in SingleplayerScreen (line 140)
- World reloading during gameplay
- Any scenario where GameSession initialization fails after partial success

## 🔎 Evidence
The problematic pattern in `src/game/session.zig`:

```zig
pub fn init(allocator: std.mem.Allocator, rhi: *RHI, ...) !*GameSession {
    const session = try allocator.create(GameSession);
    errdefer allocator.destroy(session);  // ← Only frees struct, not resources
    
    session.* = undefined;  // ← All fields are now undefined
    session.lod_config = lod_config;
    
    // If this succeeds...
    const world = try World.initGen(...);  // ← World is allocated
    
    // ...but this fails:
    const world_map = try WorldMap.init(...);  // ← OOM or error here
    
    // The errdefer runs and destroys the session struct,
    // but 'world' was never stored in session.world (still undefined)
    // → World leaks!
    
    session.* = .{
        .world = world,        // ← Never reached if error above
        .world_map = world_map, // ← Never reached
        // ... more fields
    };
    
    return session;
}
```

The `errdefer` on line 107 only calls `allocator.destroy(session)`, which frees the heap-allocated struct but does NOT call `session.deinit()` to clean up successfully allocated resources.

## 🛠️ Proposed Fix
Replace the simple allocator destroy with a proper cleanup deferral that tracks initialization progress:

```zig
pub fn init(allocator: std.mem.Allocator, rhi: *RHI, ...) !*GameSession {
    const session = try allocator.create(GameSession);
    
    // Track what needs cleanup with an enum or flags
    var initialized: enum {
        none,
        struct_only,
        world_created,
        world_map_created,
        block_outline_created,
        hand_renderer_created,
        ecs_render_created,
        fully_initialized,
    } = .struct_only;
    
    errdefer {
        switch (initialized) {
            .fully_initialized, .ecs_render_created => {
                session.ecs_render_system.deinit();
                // fallthrough intentional
            },
            // ... handle each level
            .world_created => {
                session.world.deinit();
                allocator.destroy(session);
            },
            .struct_only => allocator.destroy(session),
            .none => {},
        }
    }
    
    session.* = undefined;
    // ... rest of initialization, updating 'initialized' at each step
}
```

Alternatively, a simpler fix using the existing deinit:

```zig
pub fn init(allocator: std.mem.Allocator, rhi: *RHI, ...) !*GameSession {
    const session = try allocator.create(GameSession);
    
    // Set up a flag to track if we should run full deinit
    var cleanup_needed = true;
    errdefer {
        if (cleanup_needed) {
            // Only call deinit if we've started filling in fields
            // Check a sentinel field or use a separate bool
        }
        allocator.destroy(session);
    }
    
    // Initialize all fields to safe defaults first
    session.* = .{
        .allocator = allocator,
        .world = undefined,  // Will be set below
        // ... initialize all other fields to safe null/empty values
    };
    
    // Now do fallible operations and assign directly to session fields
    session.world = try World.initGen(...);
    errdefer session.world.deinit();  // Specific cleanup
    
    session.world_map = try WorldMap.init(...);
    errdefer session.world_map.deinit();
    
    // ... more initialization with specific errdefers
    
    cleanup_needed = false;  // All succeeded, normal deinit will handle cleanup
    return session;
}
```

The key insight: use `errdefer` after each fallible resource allocation to clean up that specific resource, rather than relying on a single cleanup at the end.

## ✅ Acceptance Criteria
- [ ] All unit tests in `src/tests.zig` pass
- [ ] No memory leaks detected when running with `zig build test` (if leak detection is available)
- [ ] Manual test: Create a world, then simulate an initialization failure (e.g., by temporarily injecting an error) and verify no resources leak
- [ ] The fix handles all initialization failure points: World.initGen, WorldMap.init, BlockOutline.init, HandRenderer.init, ECSRenderSystem.init
- [ ] The fix has been verified with `nix develop --command zig build test`

## 📚 References
- Related pattern discussion: Zig error handling documentation on errdefer
- Similar issues in: `WorldScreen.init()` at `src/game/screens/world.zig:46-61` (has same pattern with session)
