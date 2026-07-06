const world_core = @import("world-core");
const util = @import("util.zig");

const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;

pub const GroundDecoration = enum {
    tall_grass,
    flower_red,
    flower_yellow,
    dead_bush,
    cactus,
    bamboo,
    snow_layer,
};

pub fn placeVegetation(self: anytype, chunk: *Chunk, stop_flag: ?*const bool) void {
    const world_x0 = chunk.getWorldX();
    const world_z0 = chunk.getWorldZ();

    var local_z: u32 = 0;
    while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
        if (stop_flag) |sf| if (sf.*) return;
        var local_x: u32 = 0;
        while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
            const surface_y = chunk.getSurfaceHeight(local_x, local_z);
            // Explicit i32 cast on both sides of the bounds check. See issue #707 / trees.zig for rationale.
            if (@as(i32, surface_y) <= 0 or @as(i32, surface_y) >= @as(i32, CHUNK_SIZE_Y) - 2) continue;

            const biome = chunk.biomes[local_x + local_z * CHUNK_SIZE_X];
            const surface = chunk.getBlock(local_x, @intCast(surface_y), local_z);
            const wx = world_x0 + @as(i32, @intCast(local_x));
            const wz = world_z0 + @as(i32, @intCast(local_z));

            if (surface_y < self.params.sea_level and chunk.getBlockSafe(@intCast(local_x), surface_y + 1, @intCast(local_z)) == .water) {
                placeAquaticVegetation(self, chunk, local_x, @intCast(surface_y), local_z, biome, surface, wx, wz);
            } else {
                placeGroundVegetation(self, chunk, local_x, @intCast(surface_y), local_z, biome, surface, wx, wz);
            }
        }
    }
}

pub fn isVegetationBlock(block: BlockType) bool {
    return switch (block) {
        .tall_grass, .flower_red, .flower_yellow, .dead_bush, .cactus, .bamboo, .snow_layer, .seagrass, .tall_seagrass, .kelp, .seaweed, .coral_block, .coral_fan => true,
        else => false,
    };
}

fn placeGroundVegetation(self: anytype, chunk: *Chunk, x: u32, surface_y: u32, z: u32, biome: BiomeId, surface: BlockType, wx: i32, wz: i32) void {
    const place_y = surface_y + 1;
    if (place_y >= CHUNK_SIZE_Y or chunk.getBlock(x, place_y, z) != .air) return;

    const variant = util.hashUnit(wx, wz, self.seed32 +% 5101);
    const scatter = util.hashUnit(wx, wz, self.seed32 +% 5107);
    const deco = groundDecorationForBiome(biome, surface, variant, scatter) orelse return;

    switch (deco) {
        .cactus => placeCactus(chunk, x, place_y, z, 2 + @as(u32, @intFromFloat(util.hashUnit(wx, wz, self.seed32 +% 5113) * 3.0))),
        .bamboo => placeColumnDecoration(chunk, x, place_y, z, .bamboo, 2 + @as(u32, @intFromFloat(util.hashUnit(wx, wz, self.seed32 +% 5119) * 5.0))),
        .snow_layer => if (surface == .snow_block or biome == .snow_tundra or biome == .snowy_taiga or biome == .snowy_slopes) setDecorationBlock(chunk, x, place_y, z, .snow_layer),
        else => setDecorationBlock(chunk, x, place_y, z, groundDecorationBlock(deco)),
    }
}

fn placeAquaticVegetation(self: anytype, chunk: *Chunk, x: u32, surface_y: u32, z: u32, biome: BiomeId, surface: BlockType, wx: i32, wz: i32) void {
    if (!isOceanBiome(biome)) return;
    if (surface != .sand and surface != .gravel and surface != .clay and surface != .coral_block) return;

    const water_depth = columnWaterDepth(chunk, x, z, @intCast(surface_y));
    if (water_depth < 2) return;

    const variant = util.hashUnit(wx, wz, self.seed32 +% 5201);
    const scatter = util.hashUnit(wx, wz, self.seed32 +% 5207);
    const place_y = surface_y + 1;
    if (chunk.getBlock(x, place_y, z) != .water) return;

    if ((biome == .warm_ocean or biome == .tropical) and scatter < 0.04 and water_depth <= 10) {
        if (variant < 0.35) {
            setDecorationBlock(chunk, x, surface_y, z, .coral_block);
        } else {
            setDecorationBlock(chunk, x, place_y, z, .coral_fan);
        }
        return;
    }

    if (water_depth >= 6 and scatter < 0.06) {
        placeKelp(chunk, x, place_y, z, @min(water_depth - 1, 2 + @as(u8, @intFromFloat(variant * 7.0))));
    } else if (water_depth >= 4 and scatter < 0.13) {
        setDecorationBlock(chunk, x, place_y, z, .tall_seagrass);
    } else if (scatter < 0.24) {
        setDecorationBlock(chunk, x, place_y, z, if (variant < 0.75) .seagrass else .seaweed);
    }
}

fn groundDecorationForBiome(biome: BiomeId, surface: BlockType, variant: f32, scatter: f32) ?GroundDecoration {
    return switch (biome) {
        .plains => if (surface == .grass and scatter < 0.58) flowerOrGrass(variant, 0.10) else null,
        .forest => if (surface == .grass and scatter < 0.44) flowerOrGrass(variant, 0.06) else null,
        .taiga => if (surface == .grass and scatter < 0.24) .tall_grass else null,
        .snowy_taiga, .snow_tundra, .snowy_slopes => if (surface == .snow_block and scatter < 0.18) .snow_layer else null,
        .jungle => if (surface == .grass and scatter < 0.72) if (variant < 0.22) .bamboo else .tall_grass else null,
        .savanna => if (surface == .grass and scatter < 0.34) .tall_grass else null,
        .desert => if (surface == .sand) desertDecoration(variant, scatter) else null,
        .beach => if (surface == .sand and scatter < 0.02) .dead_bush else null,
        .mountains => if (surface == .grass and scatter < 0.10) .tall_grass else null,
        else => null,
    };
}

fn groundDecorationBlock(decoration: GroundDecoration) BlockType {
    return switch (decoration) {
        .tall_grass => .tall_grass,
        .flower_red => .flower_red,
        .flower_yellow => .flower_yellow,
        .dead_bush => .dead_bush,
        .cactus => .cactus,
        .bamboo => .bamboo,
        .snow_layer => .snow_layer,
    };
}

fn flowerOrGrass(variant: f32, flower_chance: f32) GroundDecoration {
    if (variant < flower_chance * 0.5) return .flower_red;
    if (variant < flower_chance) return .flower_yellow;
    return .tall_grass;
}

fn desertDecoration(variant: f32, scatter: f32) ?GroundDecoration {
    if (scatter < 0.025) return .cactus;
    if (variant < 0.10 and scatter < 0.12) return .dead_bush;
    return null;
}

fn isOceanBiome(biome: BiomeId) bool {
    return switch (biome) {
        .ocean, .deep_ocean, .warm_ocean, .cold_ocean, .frozen_ocean, .tropical => true,
        else => false,
    };
}

fn columnWaterDepth(chunk: *const Chunk, x: u32, z: u32, surface_y: i32) u8 {
    var depth: u8 = 0;
    var y = surface_y + 1;
    while (y < CHUNK_SIZE_Y and depth < 30) : (y += 1) {
        if (chunk.getBlock(x, @intCast(y), z) != .water) break;
        depth += 1;
    }
    return depth;
}

fn placeCactus(chunk: *Chunk, x: u32, y: u32, z: u32, height: u32) void {
    placeColumnDecoration(chunk, x, y, z, .cactus, height);
}

fn placeKelp(chunk: *Chunk, x: u32, y: u32, z: u32, height: u8) void {
    var dy: u32 = 0;
    while (dy < height and y + dy < CHUNK_SIZE_Y) : (dy += 1) {
        if (chunk.getBlock(x, y + dy, z) != .water) break;
        chunk.blocks[Chunk.getIndex(x, y + dy, z)] = .kelp;
    }
}

fn placeColumnDecoration(chunk: *Chunk, x: u32, y: u32, z: u32, block: BlockType, height: u32) void {
    var dy: u32 = 0;
    while (dy < height and y + dy < CHUNK_SIZE_Y) : (dy += 1) {
        if (chunk.getBlock(x, y + dy, z) != .air) break;
        chunk.blocks[Chunk.getIndex(x, y + dy, z)] = block;
    }
}

fn setDecorationBlock(chunk: *Chunk, x: u32, y: u32, z: u32, block: BlockType) void {
    if (y >= CHUNK_SIZE_Y) return;
    const existing = chunk.getBlock(x, y, z);
    const can_replace = existing == .air or (existing == .water and isAquaticDecoration(block));
    if (!can_replace) return;
    chunk.blocks[Chunk.getIndex(x, y, z)] = block;
}

fn isAquaticDecoration(block: BlockType) bool {
    return switch (block) {
        .seagrass, .tall_seagrass, .kelp, .seaweed, .coral_fan => true,
        else => false,
    };
}
