const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("worldgen-overworld-v2", .{ .root_source_file = b.path("src/root.zig") });
}
