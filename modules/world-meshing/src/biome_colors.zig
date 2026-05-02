const BiomeId = @import("world-core").BiomeId;

pub const BiomeColors = struct {
    grass: [3]f32 = .{ 0.22, 0.72, 0.16 },
    foliage: [3]f32 = .{ 0.14, 0.58, 0.12 },
    water: [3]f32 = .{ 0.12, 0.38, 0.78 },
};

pub fn getBiomeColors(id: BiomeId) BiomeColors {
    return switch (id) {
        .deep_ocean => .{ .water = .{ 0.1, 0.2, 0.5 } },
        .warm_ocean => .{ .water = .{ 0.08, 0.50, 0.82 } },
        .tropical => .{ .grass = .{ 0.18, 0.74, 0.18 }, .foliage = .{ 0.10, 0.62, 0.10 }, .water = .{ 0.05, 0.55, 0.85 } },
        .plains => .{},
        .forest => .{ .grass = .{ 0.18, 0.64, 0.16 }, .foliage = .{ 0.12, 0.52, 0.12 } },
        .taiga => .{ .grass = .{ 0.24, 0.56, 0.24 }, .foliage = .{ 0.18, 0.46, 0.18 } },
        .desert => .{ .grass = .{ 0.75, 0.70, 0.35 } },
        .snow_tundra => .{ .grass = .{ 0.7, 0.75, 0.8 } },
        .snowy_mountains => .{ .grass = .{ 0.85, 0.90, 0.95 } },
        .swamp => .{ .grass = .{ 0.26, 0.58, 0.18 }, .foliage = .{ 0.22, 0.52, 0.16 }, .water = .{ 0.16, 0.38, 0.30 } },
        .jungle => .{ .grass = .{ 0.10, 0.76, 0.08 }, .foliage = .{ 0.08, 0.62, 0.08 } },
        .savanna => .{ .grass = .{ 0.55, 0.55, 0.30 }, .foliage = .{ 0.50, 0.50, 0.28 } },
        .badlands => .{ .grass = .{ 0.5, 0.4, 0.3 } },
        .mushroom_fields => .{ .grass = .{ 0.4, 0.8, 0.4 } },
        .foothills => .{ .grass = .{ 0.24, 0.62, 0.22 }, .foliage = .{ 0.18, 0.50, 0.16 } },
        .dry_plains => .{ .grass = .{ 0.55, 0.50, 0.28 } },
        .coastal_plains => .{ .grass = .{ 0.24, 0.66, 0.24 }, .foliage = .{ 0.18, 0.52, 0.16 } },
        else => .{},
    };
}
