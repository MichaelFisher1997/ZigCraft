//! RenderDevice - backend-populated GPU resource statistics.
//!
//! Resource lifetime is owned by the active RHI backend via `ResourceManager`.
//! This type intentionally does not manufacture resource handles; it is the
//! optional stats sink passed into RHI initialization and read by diagnostics UI.

const std = @import("std");

pub const RenderDevice = struct {
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator) !RenderDevice {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *RenderDevice) void {
        _ = self;
    }

    pub fn setStats(self: *RenderDevice, stats: Stats) void {
        self.stats = stats;
    }

    pub fn getStats(self: *const RenderDevice) Stats {
        return self.stats;
    }
};

pub const Stats = struct {
    buffer_count: u32 = 0,
    texture_count: u32 = 0,
    shader_count: u32 = 0,
    total_buffer_memory: usize = 0,
    total_texture_memory: usize = 0,
};
