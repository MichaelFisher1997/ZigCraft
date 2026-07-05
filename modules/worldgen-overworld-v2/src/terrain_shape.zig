const std = @import("std");
const world_core = @import("world-core");
const noise = @import("noise.zig");
const util = @import("util.zig");

const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;

const LUANTI_WATER_LEVEL: i32 = 1;
const MGV7_MOUNTAINS: u32 = 0x01;
const MGV7_RIDGES: u32 = 0x02;

pub fn estimateTerrainHeight(self: anytype, wx: i32, wz: i32, base_surface_y: i32) i32 {
    var y: i32 = CHUNK_SIZE_Y - 1;
    while (y >= 1) : (y -= 1) {
        if (isTerrainStone(self, wx, y, wz, base_surface_y)) return y;
    }
    return 0;
}

pub fn baseTerrainLevelAtPoint(self: anytype, wx: i32, wz: i32) f32 {
    const x: f32 = @floatFromInt(wx);
    const z: f32 = @floatFromInt(wz);
    const hselect = std.math.clamp(noise.noiseFractal2D(&self.noise_height_select, x, z, self.seed32), 0.0, 1.0);
    const persist = noise.noiseFractal2D(&self.noise_terrain_persist, x, z, self.seed32);

    const height_base = noise.noiseFractal2DWithPersist(&self.noise_terrain_base, x, z, self.seed32, persist);
    const height_alt = noise.noiseFractal2DWithPersist(&self.noise_terrain_alt, x, z, self.seed32, persist);
    const luanti_height = if (height_alt > height_base)
        height_alt
    else
        height_base * hselect + height_alt * (1.0 - hselect);

    return luanti_height + @as(f32, @floatFromInt(verticalShift(self)));
}

pub fn isTerrainStone(self: anytype, wx: i32, y: i32, wz: i32, base_surface_y: i32) bool {
    const river_channel = (self.params.spflags & MGV7_RIDGES != 0) and getRiverChannelAt(self, wx, y, wz);
    if (y <= base_surface_y and !river_channel) return true;
    if ((self.params.spflags & MGV7_MOUNTAINS != 0) and !river_channel and getMountainTerrainAt(self, wx, y, wz)) return true;
    return false;
}

pub fn getMountainTerrainAt(self: anytype, wx: i32, y: i32, wz: i32) bool {
    const x: f32 = @floatFromInt(wx);
    const z: f32 = @floatFromInt(wz);
    const luanti_y = toLuantiY(self, y);
    const mount_height = @max(noise.noiseFractal2D(&self.noise_mount_height, x, z, self.seed32), 1.0);
    const density_gradient = -((luanti_y - @as(f32, @floatFromInt(self.params.mount_zero_level))) / mount_height);
    const mountain = noise.noiseFractal3D(&self.noise_mountain, x, luanti_y, z, self.seed32);
    return mountain + density_gradient >= 0.0;
}

pub fn getRiverChannelAt(self: anytype, wx: i32, y: i32, wz: i32) bool {
    const width: f32 = 0.2;
    const x: f32 = @floatFromInt(wx);
    const z: f32 = @floatFromInt(wz);
    const absuwater = @abs(noise.noiseFractal2D(&self.noise_ridge_uwater, x, z, self.seed32)) * 2.0;
    if (absuwater > width) return false;

    const altitude = @as(f32, @floatFromInt(y - self.params.sea_level));
    const height_mod = (altitude + 17.0) / 2.5;
    const width_mod = width - absuwater;
    const ridge = noise.noiseFractal3D(&self.noise_ridge, x, toLuantiY(self, y), z, self.seed32) * @max(altitude, 0.0) / 7.0;
    return ridge + width_mod * height_mod >= 0.6;
}

pub fn isRiverColumn(self: anytype, wx: i32, wz: i32) bool {
    if (self.params.spflags & MGV7_RIDGES == 0) return false;
    const x: f32 = @floatFromInt(wx);
    const z: f32 = @floatFromInt(wz);
    return @abs(noise.noiseFractal2D(&self.noise_ridge_uwater, x, z, self.seed32)) * 2.0 <= 0.2;
}

pub fn fillerDepth(self: anytype, wx: i32, wz: i32) i32 {
    const depth = 4.0 + noise.noiseFractal2D(&self.noise_filler_depth, @floatFromInt(wx), @floatFromInt(wz), self.seed32);
    return @max(2, util.floorToI32(depth));
}

pub fn estimateGroundedTerrainHeight(self: anytype, wx: i32, wz: i32, base_surface_y: i32) i32 {
    var top: i32 = 0;
    var connected_to_base = true;

    var y: i32 = 1;
    while (y < CHUNK_SIZE_Y) : (y += 1) {
        const stone = isTerrainStone(self, wx, y, wz, base_surface_y);
        if (stone and connected_to_base) top = y;
        if (!stone and y > base_surface_y) connected_to_base = false;
    }

    return top;
}

pub fn verticalShift(self: anytype) i32 {
    return self.params.sea_level - LUANTI_WATER_LEVEL;
}

pub fn toLuantiY(self: anytype, y: i32) f32 {
    return @floatFromInt(y - verticalShift(self));
}
