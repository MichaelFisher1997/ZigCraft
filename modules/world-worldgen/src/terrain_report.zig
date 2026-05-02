//! Deterministic worldgen baseline reporting for biome and height distribution.

const std = @import("std");
const world_core = @import("world-core");
const biome_mod = @import("biome.zig");
const TerrainShapeGenerator = @import("terrain_shape_generator.zig").TerrainShapeGenerator;

const Allocator = std.mem.Allocator;
const BiomeId = biome_mod.BiomeId;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;

pub const representative_seeds = [_]u64{ 42, 424242, 987654321 };
pub const default_origin_x: i32 = -256;
pub const default_origin_z: i32 = -256;
pub const default_width: u32 = 512;
pub const default_depth: u32 = 512;

const BIOME_COUNT = @typeInfo(BiomeId).@"enum".fields.len;

pub const TerrainReport = struct {
    seed: u64,
    origin_x: i32,
    origin_z: i32,
    width: u32,
    depth: u32,
    sample_count: u32,
    biome_counts: [BIOME_COUNT]u32,
    min_height: i32,
    max_height: i32,
    average_height: f64,
    sea_level_coverage: f64,
    ocean_ratio: f64,
    land_ratio: f64,
    mountain_coverage: f64,

    pub fn biomeCount(self: TerrainReport, biome_id: BiomeId) u32 {
        return self.biome_counts[@intFromEnum(biome_id)];
    }
};

const ColumnSample = struct {
    height: i32,
    continentalness: f32,
    erosion: f32,
    ridge_mask: f32,
    river_mask: f32,
    temperature: f32,
    humidity: f32,
    is_ocean: bool,
};

pub fn sampleDefaultRegion(allocator: Allocator, seed: u64) !TerrainReport {
    return sampleRegion(allocator, seed, default_origin_x, default_origin_z, default_width, default_depth);
}

pub fn sampleRegion(
    allocator: Allocator,
    seed: u64,
    origin_x: i32,
    origin_z: i32,
    width: u32,
    depth: u32,
) !TerrainReport {
    if (width == 0 or depth == 0) return error.EmptySampleRegion;

    const sample_count = try std.math.mul(u32, width, depth);
    const samples = try allocator.alloc(ColumnSample, sample_count);
    defer allocator.free(samples);

    var generator = TerrainShapeGenerator.init(seed);

    var report = TerrainReport{
        .seed = seed,
        .origin_x = origin_x,
        .origin_z = origin_z,
        .width = width,
        .depth = depth,
        .sample_count = sample_count,
        .biome_counts = [_]u32{0} ** BIOME_COUNT,
        .min_height = std.math.maxInt(i32),
        .max_height = std.math.minInt(i32),
        .average_height = 0.0,
        .sea_level_coverage = 0.0,
        .ocean_ratio = 0.0,
        .land_ratio = 0.0,
        .mountain_coverage = 0.0,
    };

    var height_sum: i64 = 0;
    var sea_level_or_below_count: u32 = 0;
    var ocean_count: u32 = 0;
    var mountain_count: u32 = 0;
    const sea_level = generator.getSeaLevel();

    var z: u32 = 0;
    while (z < depth) : (z += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const idx = index(x, z, width);
            const wx_i = origin_x + @as(i32, @intCast(x));
            const wz_i = origin_z + @as(i32, @intCast(z));
            const column = generator.sampleColumnData(@floatFromInt(wx_i), @floatFromInt(wz_i), 0);
            const height = column.terrain_height_i;

            samples[idx] = .{
                .height = height,
                .continentalness = column.continentalness,
                .erosion = column.erosion,
                .ridge_mask = column.ridge_mask,
                .river_mask = column.river_mask,
                .temperature = column.temperature,
                .humidity = column.humidity,
                .is_ocean = column.is_ocean,
            };

            report.min_height = @min(report.min_height, height);
            report.max_height = @max(report.max_height, height);
            height_sum += height;
            if (height <= sea_level) sea_level_or_below_count += 1;
            if (column.is_ocean) ocean_count += 1;
            if (height >= sea_level + 48 or column.ridge_mask >= 0.65) mountain_count += 1;
        }
    }

    z = 0;
    while (z < depth) : (z += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const idx = index(x, z, width);
            const sample = samples[idx];
            const slope = maxNeighborSlope(samples, x, z, width, depth);
            const climate = generator.getBiomeSource().computeClimate(
                sample.temperature,
                sample.humidity,
                sample.height,
                sample.continentalness,
                sample.erosion,
                CHUNK_SIZE_Y,
            );
            const structural = biome_mod.StructuralParams{
                .height = sample.height,
                .slope = slope,
                .continentalness = sample.continentalness,
                .ridge_mask = sample.ridge_mask,
            };
            const biome_id = generator.getBiomeSource().selectBiome(climate, structural, sample.river_mask);
            report.biome_counts[@intFromEnum(biome_id)] += 1;
        }
    }

    const denominator: f64 = @floatFromInt(sample_count);
    report.average_height = @as(f64, @floatFromInt(height_sum)) / denominator;
    report.sea_level_coverage = @as(f64, @floatFromInt(sea_level_or_below_count)) / denominator;
    report.ocean_ratio = @as(f64, @floatFromInt(ocean_count)) / denominator;
    report.land_ratio = 1.0 - report.ocean_ratio;
    report.mountain_coverage = @as(f64, @floatFromInt(mountain_count)) / denominator;

    return report;
}

pub fn writeReport(writer: anytype, report: TerrainReport) !void {
    try writer.print(
        \\worldgen terrain report
        \\seed: {d}
        \\region: origin=({d},{d}) size={d}x{d} samples={d}
        \\height: min={d} max={d} avg={d:.2}
        \\coverage: sea_level_or_below={d:.4} ocean={d:.4} land={d:.4} mountain={d:.4}
        \\biomes:
        \\
    , .{
        report.seed,
        report.origin_x,
        report.origin_z,
        report.width,
        report.depth,
        report.sample_count,
        report.min_height,
        report.max_height,
        report.average_height,
        report.sea_level_coverage,
        report.ocean_ratio,
        report.land_ratio,
        report.mountain_coverage,
    });

    var i: usize = 0;
    while (i < BIOME_COUNT) : (i += 1) {
        const biome_id: BiomeId = @enumFromInt(i);
        const count = report.biomeCount(biome_id);
        if (count == 0) continue;
        const percent = @as(f64, @floatFromInt(count)) * 100.0 / @as(f64, @floatFromInt(report.sample_count));
        try writer.print("  {s}: {d} ({d:.2}%)\n", .{ @tagName(biome_id), count, percent });
    }
}

fn maxNeighborSlope(samples: []const ColumnSample, x: u32, z: u32, width: u32, depth: u32) i32 {
    const current = samples[index(x, z, width)].height;
    var max_slope: i32 = 0;
    if (x > 0) max_slope = @max(max_slope, heightDelta(current, samples[index(x - 1, z, width)].height));
    if (x + 1 < width) max_slope = @max(max_slope, heightDelta(current, samples[index(x + 1, z, width)].height));
    if (z > 0) max_slope = @max(max_slope, heightDelta(current, samples[index(x, z - 1, width)].height));
    if (z + 1 < depth) max_slope = @max(max_slope, heightDelta(current, samples[index(x, z + 1, width)].height));
    return max_slope;
}

fn heightDelta(a: i32, b: i32) i32 {
    return if (a > b) a - b else b - a;
}

fn index(x: u32, z: u32, width: u32) u32 {
    return x + z * width;
}

test "TerrainReport is deterministic for fixed seed and region" {
    const allocator = std.testing.allocator;

    const first = try sampleRegion(allocator, 42, -32, -32, 64, 64);
    const second = try sampleRegion(allocator, 42, -32, -32, 64, 64);

    try std.testing.expectEqual(first.seed, second.seed);
    try std.testing.expectEqual(first.origin_x, second.origin_x);
    try std.testing.expectEqual(first.origin_z, second.origin_z);
    try std.testing.expectEqual(first.width, second.width);
    try std.testing.expectEqual(first.depth, second.depth);
    try std.testing.expectEqual(first.sample_count, second.sample_count);
    try std.testing.expectEqualSlices(u32, &first.biome_counts, &second.biome_counts);
    try std.testing.expectEqual(first.min_height, second.min_height);
    try std.testing.expectEqual(first.max_height, second.max_height);
    try std.testing.expectEqual(first.average_height, second.average_height);
    try std.testing.expectEqual(first.sea_level_coverage, second.sea_level_coverage);
    try std.testing.expectEqual(first.ocean_ratio, second.ocean_ratio);
    try std.testing.expectEqual(first.land_ratio, second.land_ratio);
    try std.testing.expectEqual(first.mountain_coverage, second.mountain_coverage);
}

test "TerrainReport metrics cover the full sample area" {
    const allocator = std.testing.allocator;

    const report = try sampleRegion(allocator, 424242, -64, 16, 64, 64);

    var biome_total: u32 = 0;
    for (report.biome_counts) |count| biome_total += count;

    try std.testing.expectEqual(report.sample_count, biome_total);
    try std.testing.expect(report.min_height <= report.max_height);
    try std.testing.expect(report.average_height >= @as(f64, @floatFromInt(report.min_height)));
    try std.testing.expect(report.average_height <= @as(f64, @floatFromInt(report.max_height)));
    try std.testing.expect(report.sea_level_coverage >= 0.0 and report.sea_level_coverage <= 1.0);
    try std.testing.expect(report.ocean_ratio >= 0.0 and report.ocean_ratio <= 1.0);
    try std.testing.expect(report.land_ratio >= 0.0 and report.land_ratio <= 1.0);
    try std.testing.expect(report.mountain_coverage >= 0.0 and report.mountain_coverage <= 1.0);
    try std.testing.expectApproxEqAbs(1.0, report.ocean_ratio + report.land_ratio, 0.000001);
}
