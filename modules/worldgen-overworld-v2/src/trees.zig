const world_core = @import("world-core");
const block_colors = @import("block_colors.zig");
const util = @import("util.zig");

const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;

pub const TreeBlocks = struct {
    trunk: BlockType,
    leaves: BlockType,
};

pub const TreeShape = enum {
    oak,
    birch,
    spruce,
    jungle,
    acacia,
};

pub fn placeTrees(self: anytype, chunk: *Chunk, stop_flag: ?*const bool) void {
    const world_x0 = chunk.getWorldX();
    const world_z0 = chunk.getWorldZ();

    var local_z: u32 = 0;
    while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
        if (stop_flag) |sf| if (sf.*) return;
        var local_x: u32 = 0;
        while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
            const surface_y = chunk.getSurfaceHeight(local_x, local_z);
            if (surface_y <= self.params.sea_level or surface_y >= CHUNK_SIZE_Y - 8) continue;

            const surface = chunk.getBlock(local_x, @intCast(surface_y), local_z);
            if (surface != .grass and surface != .dirt and surface != .snow_block and surface != .sand) continue;

            const biome = chunk.biomes[local_x + local_z * CHUNK_SIZE_X];
            const wx = world_x0 + @as(i32, @intCast(local_x));
            const wz = world_z0 + @as(i32, @intCast(local_z));
            const tree = treeForColumn(self, biome, wx, wz) orelse continue;
            placeTreeShape(chunk, local_x, @intCast(surface_y + 1), local_z, tree);
        }
    }
}

pub fn treeForColumn(self: anytype, biome: BiomeId, wx: i32, wz: i32) ?TreeShape {
    const density = treeDensityForBiome(biome);
    if (density <= 0.0) return null;

    const spacing: i32 = switch (biome) {
        .jungle => 4,
        .forest, .taiga, .snowy_taiga => 5,
        .savanna => 7,
        else => 6,
    };
    if (@mod(wx, spacing) != @mod(util.hash2i(wx, wz, self.seed32 +% 4101), spacing)) return null;
    if (@mod(wz, spacing) != @mod(util.hash2i(wx, wz, self.seed32 +% 4109), spacing)) return null;

    const roll = util.hashUnit(wx, wz, self.seed32 +% 4127);
    if (roll > density) return null;

    return switch (biome) {
        .taiga, .snowy_taiga, .snow_tundra, .old_growth_taiga, .grove => .spruce,
        .jungle, .bamboo_jungle, .sparse_jungle => .jungle,
        .savanna, .savanna_plateau, .windswept_savanna => .acacia,
        .birch_forest => .birch,
        .forest, .flower_forest => if (util.hashUnit(wx, wz, self.seed32 +% 4133) < 0.25) .birch else .oak,
        else => .oak,
    };
}

pub fn treeBlocksForShape(shape: TreeShape) TreeBlocks {
    return switch (shape) {
        .birch => .{ .trunk = .birch_log, .leaves = .birch_leaves },
        .spruce => .{ .trunk = .spruce_log, .leaves = .spruce_leaves },
        .jungle => .{ .trunk = .jungle_log, .leaves = .jungle_leaves },
        .acacia => .{ .trunk = .acacia_log, .leaves = .acacia_leaves },
        .oak => .{ .trunk = .wood, .leaves = .leaves },
    };
}

pub fn treeHeightForShape(shape: TreeShape) f32 {
    return switch (shape) {
        .spruce => 7.0,
        .jungle => 8.0,
        .acacia => 5.0,
        .birch, .oak => 6.0,
    };
}

pub fn defaultTreeShapeForBiome(biome: BiomeId) TreeShape {
    return switch (biome) {
        .taiga, .snowy_taiga, .snow_tundra, .old_growth_taiga, .grove => .spruce,
        .jungle, .bamboo_jungle, .sparse_jungle => .jungle,
        .savanna, .savanna_plateau, .windswept_savanna => .acacia,
        .birch_forest => .birch,
        else => .oak,
    };
}

pub fn isTreeBlock(block: BlockType) bool {
    return switch (block) {
        .wood, .leaves, .birch_log, .birch_leaves, .spruce_log, .spruce_leaves, .jungle_log, .jungle_leaves, .acacia_log, .acacia_leaves => true,
        else => false,
    };
}

pub fn treeDensityForBiome(biome: BiomeId) f32 {
    return switch (biome) {
        .forest => 0.72,
        .birch_forest => 0.68,
        .dark_forest => 0.92,
        .flower_forest => 0.42,
        .taiga, .snowy_taiga => 0.58,
        .old_growth_taiga => 0.82,
        .grove => 0.46,
        .jungle, .bamboo_jungle => 0.86,
        .sparse_jungle => 0.48,
        .swamp, .mangrove_swamp => 0.42,
        .savanna, .savanna_plateau, .windswept_savanna => 0.30,
        .plains, .coastal_plains, .foothills => 0.14,
        .mountains => 0.08,
        else => 0.0,
    };
}

fn placeTreeShape(chunk: *Chunk, x: u32, y: u32, z: u32, shape: TreeShape) void {
    const trunk: BlockType = switch (shape) {
        .birch => .birch_log,
        .spruce => .spruce_log,
        .jungle => .jungle_log,
        .acacia => .acacia_log,
        .oak => .wood,
    };
    const leaves: BlockType = switch (shape) {
        .birch => .birch_leaves,
        .spruce => .spruce_leaves,
        .jungle => .jungle_leaves,
        .acacia => .acacia_leaves,
        .oak => .leaves,
    };
    const height: u32 = switch (shape) {
        .spruce => 7,
        .jungle => 8,
        .acacia => 5,
        else => 6,
    };

    if (y + height + 1 >= CHUNK_SIZE_Y) return;

    var dy: u32 = 0;
    while (dy < height) : (dy += 1) {
        setTreeBlock(chunk, x, y + dy, z, trunk, false);
    }

    switch (shape) {
        .spruce => placeConeLeaves(chunk, x, y + 2, z, height, leaves),
        .acacia => placeFlatCanopy(chunk, x, y + height - 1, z, leaves),
        else => placeRoundCanopy(chunk, x, y + height - 2, z, leaves),
    }
}

fn placeRoundCanopy(chunk: *Chunk, cx: u32, cy: u32, cz: u32, leaves: BlockType) void {
    var oy: i32 = -1;
    while (oy <= 2) : (oy += 1) {
        const radius: i32 = if (oy == 2) 1 else 2;
        var oz: i32 = -radius;
        while (oz <= radius) : (oz += 1) {
            var ox: i32 = -radius;
            while (ox <= radius) : (ox += 1) {
                if (@abs(ox) == radius and @abs(oz) == radius and oy >= 1) continue;
                setTreeBlockOffset(chunk, cx, cy, cz, ox, oy, oz, leaves, true);
            }
        }
    }
}

fn placeConeLeaves(chunk: *Chunk, cx: u32, base_y: u32, cz: u32, height: u32, leaves: BlockType) void {
    var layer: u32 = 0;
    while (layer < height) : (layer += 1) {
        const cy = base_y + layer;
        const remaining = height - layer;
        const radius: i32 = if (remaining > 4) 2 else if (remaining > 1) 1 else 0;
        var oz: i32 = -radius;
        while (oz <= radius) : (oz += 1) {
            var ox: i32 = -radius;
            while (ox <= radius) : (ox += 1) {
                if (@abs(ox) + @abs(oz) > radius + 1) continue;
                setTreeBlockOffset(chunk, cx, cy, cz, ox, 0, oz, leaves, true);
            }
        }
    }
}

fn placeFlatCanopy(chunk: *Chunk, cx: u32, cy: u32, cz: u32, leaves: BlockType) void {
    var oz: i32 = -2;
    while (oz <= 2) : (oz += 1) {
        var ox: i32 = -2;
        while (ox <= 2) : (ox += 1) {
            if (@abs(ox) == 2 and @abs(oz) == 2) continue;
            setTreeBlockOffset(chunk, cx, cy, cz, ox, 0, oz, leaves, true);
        }
    }
    setTreeBlock(chunk, cx, cy + 1, cz, leaves, true);
}

fn setTreeBlockOffset(chunk: *Chunk, cx: u32, base_y: u32, cz: u32, ox: i32, oy: i32, oz: i32, block: BlockType, leaves_only: bool) void {
    const x = @as(i32, @intCast(cx)) + ox;
    const y = @as(i32, @intCast(base_y)) + oy;
    const z = @as(i32, @intCast(cz)) + oz;
    if (x < 0 or x >= CHUNK_SIZE_X or y < 0 or y >= CHUNK_SIZE_Y or z < 0 or z >= CHUNK_SIZE_Z) return;
    setTreeBlock(chunk, @intCast(x), @intCast(y), @intCast(z), block, leaves_only);
}

fn setTreeBlock(chunk: *Chunk, x: u32, y: u32, z: u32, block: BlockType, leaves_only: bool) void {
    const idx = Chunk.getIndex(x, y, z);
    const existing = chunk.blocks[idx];
    if (leaves_only and existing != .air and !block_colors.isLeafBlock(existing)) return;
    if (!leaves_only and existing != .air and !block_colors.isLeafBlock(existing) and !isReplaceableTreeBase(existing)) return;
    chunk.blocks[idx] = block;
}

fn isReplaceableTreeBase(block: BlockType) bool {
    return switch (block) {
        .tall_grass, .flower_red, .flower_yellow, .dead_bush, .snow_layer, .seagrass, .tall_seagrass, .kelp, .seaweed => true,
        else => false,
    };
}
