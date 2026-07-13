//! Dedicated world-lod test root.

test {
    _ = @import("lod_cache.zig");
    _ = @import("lod_manager_internal_tests.zig");
    _ = @import("lod_manager_tests.zig");
    _ = @import("lod_store.zig");
}
