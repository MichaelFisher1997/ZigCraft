//! Deterministic climate-space snapshots for worldgen tuning.

const std = @import("std");
const biome_mod = @import("biome.zig");
const TerrainShapeGenerator = @import("terrain_shape_generator.zig").TerrainShapeGenerator;
const world_core = @import("world-core");

const Allocator = std.mem.Allocator;
const BiomeId = biome_mod.BiomeId;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;

pub const default_seed: u64 = 42;
pub const default_origin_x: i32 = -256;
pub const default_origin_z: i32 = -256;
pub const default_width: u32 = 128;
pub const default_depth: u32 = 128;
pub const default_step: f32 = 4.0;

pub const Config = struct {
    seed: u64 = default_seed,
    origin_x: i32 = default_origin_x,
    origin_z: i32 = default_origin_z,
    width: u32 = default_width,
    depth: u32 = default_depth,
    step: f32 = default_step,
    reduction: u8 = 0,
};

pub const Field = enum {
    temperature,
    humidity,
    continentalness,
    erosion,
    ruggedness,
    river_mask,
    ridge_mask,
    cave_region,
    elevation,
    height,
};

pub const Sample = struct {
    world_x: f32,
    world_z: f32,
    height: i32,
    temperature: f32,
    humidity: f32,
    continentalness: f32,
    erosion: f32,
    ruggedness: f32,
    river_mask: f32,
    ridge_mask: f32,
    cave_region: f32,
    elevation: f32,
    biome: BiomeId,
    is_ocean: bool,
};

pub const Snapshot = struct {
    config: Config,
    samples: []Sample,

    pub fn deinit(self: *Snapshot, allocator: Allocator) void {
        allocator.free(self.samples);
        self.* = undefined;
    }
};

pub fn capture(allocator: Allocator, config: Config) !Snapshot {
    if (config.width == 0 or config.depth == 0) return error.EmptySnapshotRegion;
    if (config.step <= 0.0) return error.InvalidSnapshotStep;

    const sample_count = try std.math.mul(u32, config.width, config.depth);
    const samples = try allocator.alloc(Sample, sample_count);
    errdefer allocator.free(samples);

    var generator = TerrainShapeGenerator.init(config.seed);
    const biome_source = generator.getBiomeSource();

    var z: u32 = 0;
    while (z < config.depth) : (z += 1) {
        var x: u32 = 0;
        while (x < config.width) : (x += 1) {
            const wx = @as(f32, @floatFromInt(config.origin_x)) + @as(f32, @floatFromInt(x)) * config.step;
            const wz = @as(f32, @floatFromInt(config.origin_z)) + @as(f32, @floatFromInt(z)) * config.step;
            const column = generator.sampleColumnData(wx, wz, config.reduction);
            const climate = biome_source.computeClimate(
                column.temperature,
                column.humidity,
                column.terrain_height_i,
                column.continentalness,
                column.erosion,
                CHUNK_SIZE_Y,
            );
            const structural = biome_mod.StructuralParams{
                .height = column.terrain_height_i,
                .slope = 0,
                .continentalness = column.continentalness,
                .ridge_mask = column.ridge_mask,
            };

            samples[index(x, z, config.width)] = .{
                .world_x = wx,
                .world_z = wz,
                .height = column.terrain_height_i,
                .temperature = climate.temperature,
                .humidity = climate.humidity,
                .continentalness = climate.continentalness,
                .erosion = column.erosion,
                .ruggedness = climate.ruggedness,
                .river_mask = column.river_mask,
                .ridge_mask = column.ridge_mask,
                .cave_region = column.cave_region,
                .elevation = climate.elevation,
                .biome = biome_source.selectBiome(climate, structural, column.river_mask),
                .is_ocean = column.is_ocean,
            };
        }
    }

    return .{ .config = config, .samples = samples };
}

pub fn writeJson(writer: *std.Io.Writer, snapshot: Snapshot) !void {
    const c = snapshot.config;
    try writer.print(
        \\{{
        \\  "schema": "zigcraft.worldgen.climate_snapshot.v1",
        \\  "seed": {d},
        \\  "origin": {{ "x": {d}, "z": {d} }},
        \\  "size": {{ "width": {d}, "depth": {d} }},
        \\  "step": {d:.6},
        \\  "reduction": {d},
        \\  "fields": ["world_x", "world_z", "height", "temperature", "humidity", "continentalness", "erosion", "ruggedness", "river_mask", "ridge_mask", "cave_region", "elevation", "biome", "is_ocean"],
        \\  "samples": [
        \\
    , .{ c.seed, c.origin_x, c.origin_z, c.width, c.depth, c.step, c.reduction });

    for (snapshot.samples, 0..) |sample, i| {
        if (i != 0) try writer.writeAll(",\n");
        try writer.print(
            "    {{ \"world_x\": {d:.3}, \"world_z\": {d:.3}, \"height\": {d}, \"temperature\": {d:.6}, \"humidity\": {d:.6}, \"continentalness\": {d:.6}, \"erosion\": {d:.6}, \"ruggedness\": {d:.6}, \"river_mask\": {d:.6}, \"ridge_mask\": {d:.6}, \"cave_region\": {d:.6}, \"elevation\": {d:.6}, \"biome\": \"{s}\", \"is_ocean\": {} }}",
            .{
                sample.world_x,
                sample.world_z,
                sample.height,
                sample.temperature,
                sample.humidity,
                sample.continentalness,
                sample.erosion,
                sample.ruggedness,
                sample.river_mask,
                sample.ridge_mask,
                sample.cave_region,
                sample.elevation,
                @tagName(sample.biome),
                sample.is_ocean,
            },
        );
    }

    try writer.writeAll("\n  ]\n}\n");
}

pub fn writeHeatmapPpm(writer: *std.Io.Writer, snapshot: Snapshot, field: Field) !void {
    const c = snapshot.config;
    try writer.print("P3\n# ZigCraft climate snapshot {s}\n{d} {d}\n255\n", .{ @tagName(field), c.width, c.depth });

    const range = fieldRange(snapshot, field);
    var z: u32 = 0;
    while (z < c.depth) : (z += 1) {
        var x: u32 = 0;
        while (x < c.width) : (x += 1) {
            const value = fieldValue(snapshot.samples[index(x, z, c.width)], field);
            const t = normalize(value, range[0], range[1]);
            const rgb = falseColor(t);
            try writer.print("{d} {d} {d}", .{ rgb[0], rgb[1], rgb[2] });
            if (x + 1 < c.width) try writer.writeByte(' ');
        }
        try writer.writeByte('\n');
    }
}

pub fn parseField(name: []const u8) ?Field {
    inline for (@typeInfo(Field).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn fieldRange(snapshot: Snapshot, field: Field) [2]f32 {
    if (field != .height) return .{ 0.0, 1.0 };

    var min_height: f32 = std.math.inf(f32);
    var max_height: f32 = -std.math.inf(f32);
    for (snapshot.samples) |sample| {
        const height: f32 = @floatFromInt(sample.height);
        min_height = @min(min_height, height);
        max_height = @max(max_height, height);
    }
    return .{ min_height, max_height };
}

fn fieldValue(sample: Sample, field: Field) f32 {
    return switch (field) {
        .temperature => sample.temperature,
        .humidity => sample.humidity,
        .continentalness => sample.continentalness,
        .erosion => sample.erosion,
        .ruggedness => sample.ruggedness,
        .river_mask => sample.river_mask,
        .ridge_mask => sample.ridge_mask,
        .cave_region => sample.cave_region,
        .elevation => sample.elevation,
        .height => @floatFromInt(sample.height),
    };
}

fn normalize(value: f32, min_value: f32, max_value: f32) f32 {
    if (max_value <= min_value) return 0.0;
    return std.math.clamp((value - min_value) / (max_value - min_value), 0.0, 1.0);
}

fn falseColor(t: f32) [3]u8 {
    const r = std.math.clamp(1.5 * t - 0.25, 0.0, 1.0);
    const g = std.math.clamp(1.0 - @abs(t - 0.5) * 2.0, 0.0, 1.0);
    const b = std.math.clamp(1.25 - 1.5 * t, 0.0, 1.0);
    return .{
        @intFromFloat(r * 255.0),
        @intFromFloat(g * 255.0),
        @intFromFloat(b * 255.0),
    };
}

fn index(x: u32, z: u32, width: u32) u32 {
    return x + z * width;
}

test "ClimateSnapshot is deterministic for fixed seed and region" {
    const allocator = std.testing.allocator;
    const config = Config{ .seed = 12345, .origin_x = -16, .origin_z = 24, .width = 8, .depth = 8, .step = 2.0 };

    var first = try capture(allocator, config);
    defer first.deinit(allocator);
    var second = try capture(allocator, config);
    defer second.deinit(allocator);

    try std.testing.expectEqual(first.config, second.config);
    try std.testing.expectEqual(first.samples.len, second.samples.len);
    for (first.samples, second.samples) |a, b| {
        try std.testing.expectEqual(a, b);
    }
}

test "ClimateSnapshot values are normalized for heatmap fields" {
    const allocator = std.testing.allocator;
    var snapshot = try capture(allocator, .{ .seed = 42, .width = 4, .depth = 4, .step = 8.0 });
    defer snapshot.deinit(allocator);

    for (snapshot.samples) |sample| {
        try std.testing.expect(sample.temperature >= 0.0 and sample.temperature <= 1.0);
        try std.testing.expect(sample.humidity >= 0.0 and sample.humidity <= 1.0);
        try std.testing.expect(sample.continentalness >= 0.0 and sample.continentalness <= 1.0);
        try std.testing.expect(sample.erosion >= 0.0 and sample.erosion <= 1.0);
        try std.testing.expect(sample.ruggedness >= 0.0 and sample.ruggedness <= 1.0);
        try std.testing.expect(sample.river_mask >= 0.0 and sample.river_mask <= 1.0);
        try std.testing.expect(sample.ridge_mask >= 0.0 and sample.ridge_mask <= 1.0);
        try std.testing.expect(sample.elevation >= 0.0 and sample.elevation <= 1.0);
    }
}
