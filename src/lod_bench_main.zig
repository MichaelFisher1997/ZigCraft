//! CPU-only LOD heightmap generation benchmark (no graphics/Vulkan needed).
//!
//! Measures the actual per-region cost of `generateHeightmapOnly` for each LOD
//! level, so we can tell whether LOD loading is bounded by generation cost or by
//! worker throughput/contention. Run with: `zig build lod-bench`.

const std = @import("std");
const world_worldgen = @import("world-worldgen");
const world_core = @import("world-core");
const LODLevel = world_core.LODLevel;
const LODSimplifiedData = world_core.LODSimplifiedData;

fn nowMs() i64 {
    return std.Io.Clock.real.now(std.Options.debug_io).toMilliseconds();
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const allocator = init.arena.allocator();

    const seed: u64 = 1337;
    var gen = try world_worldgen.createGeneratorById("overworld", seed, allocator);
    defer gen.deinit(allocator);

    try stdout.print("=== LOD heightmap generation benchmark (generator='overworld' seed={}) ===\n", .{seed});

    const levels = [_]LODLevel{ .lod1, .lod2, .lod3, .lod4 };
    const samples: u32 = 6;

    for (levels) |lvl| {
        var min_ms: f64 = std.math.floatMax(f64);
        var max_ms: f64 = 0;
        var sum_ms: f64 = 0;
        var width: u32 = 0;

        var done: u32 = 0;
        var i: i32 = 0;
        while (done < samples) : (i += 1) {
            var data = try LODSimplifiedData.init(allocator, lvl);
            defer data.deinit();
            width = data.width;

            const t0 = nowMs();
            gen.generateHeightmapOnly(&data, i * 7, i * 5, lvl, null);
            const dt = nowMs() - t0;

            const ms = @as(f64, @floatFromInt(@max(dt, 0)));
            if (ms < min_ms) min_ms = ms;
            if (ms > max_ms) max_ms = ms;
            sum_ms += ms;
            done += 1;
        }

        const avg = sum_ms / @as(f64, @floatFromInt(samples));
        try stdout.print("  {s}: grid={}x{} (~{} cols)  avg={d:.1}ms  min={d:.1}ms  max={d:.1}ms\n", .{
            @tagName(lvl),
            width,
            width,
            width * width,
            avg,
            min_ms,
            max_ms,
        });
    }

    try stdout.print("\nInterpretation:\n", .{});
    try stdout.print("  - If LOD4 avg < ~500ms: generation is cheap; LOD loading is bounded by\n", .{});
    try stdout.print("    worker throughput/contention, not per-region cost.\n", .{});
    try stdout.print("  - If LOD4 avg > ~2000ms: generation itself is the bottleneck.\n", .{});
    try stdout.flush();
}
