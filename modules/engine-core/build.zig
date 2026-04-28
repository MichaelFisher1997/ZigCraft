const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fs_module = b.createModule(.{ .root_source_file = b.path("src/fs.zig"), .target = target, .optimize = optimize });
    const sync_module = b.createModule(.{ .root_source_file = b.path("src/sync.zig"), .target = target, .optimize = optimize });
    const engine_core = b.addModule("engine-core", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    engine_core.addImport("fs", fs_module);
    engine_core.addImport("sync", sync_module);
}
