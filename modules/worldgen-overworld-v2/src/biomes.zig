const world_core = @import("world-core");
const terrain_shape = @import("terrain_shape.zig");
const util = @import("util.zig");

const BiomeId = world_core.BiomeId;

pub fn selectBiome(self: anytype, wx: i32, wz: i32, height: i32, river: bool, temperature: f32, humidity: f32) BiomeId {
    if (river) return if (temperature < 0.22) .frozen_river else .river;
    if (height < self.params.sea_level - 24) return if (temperature < 0.2) .frozen_ocean else .deep_ocean;
    if (height < self.params.sea_level - 2) return if (temperature < 0.2) .cold_ocean else .ocean;
    if (isBeachColumn(self, wx, wz, height)) return if (temperature < 0.18) .snowy_beach else .beach;
    if (height > self.params.sea_level + 95) return if (temperature < 0.35) .frozen_peaks else .jagged_peaks;
    if (height > self.params.sea_level + 62) return if (temperature < 0.28) .snowy_slopes else .mountains;
    if (temperature < 0.18) return .snow_tundra;
    if (temperature < 0.30) return if (humidity > 0.55) .taiga else .snowy_taiga;
    if (temperature > 0.78 and humidity < 0.30) return .desert;
    if (temperature > 0.70 and humidity > 0.68) return .jungle;
    if (temperature > 0.66 and humidity < 0.45) return .savanna;
    if (humidity > 0.70) return .forest;
    return .plains;
}

pub fn isBeachColumn(self: anytype, wx: i32, wz: i32, height: i32) bool {
    if (height < self.params.sea_level - 1 or height > self.params.sea_level + 1) return false;

    const offsets = [_][2]i32{
        .{ -6, 0 },
        .{ 6, 0 },
        .{ 0, -6 },
        .{ 0, 6 },
        .{ -8, -8 },
        .{ 8, -8 },
        .{ -8, 8 },
        .{ 8, 8 },
    };

    for (offsets) |offset| {
        const neighbor_base = util.floorToI32(terrain_shape.baseTerrainLevelAtPoint(self, wx + offset[0], wz + offset[1]));
        if (neighbor_base < self.params.sea_level - 1) return true;
    }

    return false;
}
