//! LOD vegetation hint computation for overworld tree placement.

const std = @import("std");
const biome_mod = @import("biome.zig");
const BiomeId = biome_mod.BiomeId;
const region_pkg = @import("region.zig");
const decoration_registry = @import("decoration_registry.zig");
const NoiseSampler = @import("noise_sampler.zig").NoiseSampler;
const schematics = @import("schematics.zig");
const tree_registry = @import("tree_registry.zig");
const world_core = @import("world-core");
const BlockType = world_core.BlockType;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;

pub const TreeHintChunk = [CHUNK_SIZE_X * CHUNK_SIZE_Z]world_core.LODVegetationHint;

pub const TreeBlocks = struct {
    trunk: BlockType,
    leaves: BlockType,
};

pub const ClassifiedSample = struct {
    biome: BiomeId,
    surface_block: BlockType,
    terrain_height_i: i32,
};

pub const ClassifyFn = *const fn (*const anyopaque, f32, f32, i32, region_pkg.RegionControlCorners) ClassifiedSample;

pub const ComputeParams = struct {
    chunk_x: i32,
    chunk_z: i32,
    world_x: i32,
    world_z: i32,
    sea_level: i32,
    terrain_region_seed: u64,
    decorator_region_seed: u64,
    noise_sampler: *const NoiseSampler,
    classify_context: *const anyopaque,
    classify_fn: ClassifyFn,
};

pub fn computeChunkTreeHints(params: ComputeParams) TreeHintChunk {
    const controls = region_pkg.RegionControlCorners.init(
        params.terrain_region_seed,
        params.world_x,
        params.world_z,
        params.world_x + @as(i32, @intCast(CHUNK_SIZE_X)) - 1,
        params.world_z + @as(i32, @intCast(CHUNK_SIZE_Z)) - 1,
    );
    var prng = std.Random.DefaultPrng.init(params.decorator_region_seed ^ @as(u64, @bitCast(@as(i64, params.chunk_x))) ^ (@as(u64, @bitCast(@as(i64, params.chunk_z))) << 32));
    const random = prng.random();
    var tree_occupancy = [_]bool{false} ** world_core.CHUNK_VOLUME;
    var hints = [_]world_core.LODVegetationHint{world_core.LODVegetationHint.empty} ** (CHUNK_SIZE_X * CHUNK_SIZE_Z);

    var lz: u32 = 0;
    while (lz < CHUNK_SIZE_Z) : (lz += 1) {
        var lx: u32 = 0;
        while (lx < CHUNK_SIZE_X) : (lx += 1) {
            const wx_i = params.world_x + @as(i32, @intCast(lx));
            const wz_i = params.world_z + @as(i32, @intCast(lz));
            const sample = params.classify_fn(params.classify_context, @floatFromInt(wx_i), @floatFromInt(wz_i), params.sea_level, controls);
            const column_controls = controls.sample(wx_i, wz_i);
            const variant = params.noise_sampler.variant_noise.get2D(@floatFromInt(wx_i), @floatFromInt(wz_i));
            _ = decoration_registry.chooseStaticSimpleDecoration(sample.biome, sample.surface_block, variant, column_controls.subbiome_mask > 0.5, column_controls.vegetation_mult, 0, random);

            const placed_tree = choosePlacedTree(sample.biome, sample.surface_block, variant, column_controls.subbiome_mask > 0.5, column_controls.vegetation_mult, lx, lz, sample.terrain_height_i, &tree_occupancy, random);
            if (placed_tree) |tree| {
                placeTreeOccupancy(tree.schematic, lx, @intCast(sample.terrain_height_i + 1), lz, &tree_occupancy, random);
                hints[lx + lz * CHUNK_SIZE_X] = treeHintForType(tree.tree_type);
            }
        }
    }
    return hints;
}

pub fn estimatedTreeHintForBiome(biome_id: BiomeId, wx: f32, wz: f32, seed: u64) world_core.LODVegetationHint {
    const tree_types = biome_mod.getBiomeDefinition(biome_id).vegetation.tree_types;
    if (tree_types.len == 0) return world_core.LODVegetationHint.empty;

    var best_type = tree_types[0];
    var best_probability: f32 = 0.0;
    var probability_sum: f32 = 0.0;
    for (tree_types) |tree_type| {
        const def = tree_registry.getTreeDefinition(tree_type) orelse continue;
        probability_sum += def.probability;
        if (def.probability > best_probability) {
            best_probability = def.probability;
            best_type = tree_type;
        }
    }

    const base_coverage = std.math.clamp(probability_sum * 7.5, 0.0, 1.0);
    if (base_coverage < 0.035) return world_core.LODVegetationHint.empty;

    const wx_i: i32 = @intFromFloat(@floor(wx));
    const wz_i: i32 = @intFromFloat(@floor(wz));
    const jitter = hashUnit2D(wx_i, wz_i, seed);
    const placement_roll = hashUnit2D(wx_i, wz_i, seed ^ 0x6D2B79F5);
    const placement_probability = std.math.clamp(base_coverage * 0.32, 0.025, 0.55);
    if (placement_roll > placement_probability) return world_core.LODVegetationHint.empty;

    const blocks = blocksForType(best_type);
    return .{
        .tree_coverage = std.math.clamp(0.12 + base_coverage * (0.18 + jitter * 0.08), 0.0, 0.45),
        .avg_tree_height = heightForType(best_type),
        .offset_x = (hashUnit2D(wx_i, wz_i, seed ^ 0xA53A9D13) - 0.5) * 2.0,
        .offset_z = (hashUnit2D(wx_i, wz_i, seed ^ 0xC2B2AE35) - 0.5) * 2.0,
        .trunk = blocks.trunk,
        .leaves = blocks.leaves,
    };
}

pub fn cacheKey(chunk_x: i32, chunk_z: i32) u64 {
    const x: u64 = @bitCast(@as(i64, chunk_x));
    const z: u64 = @bitCast(@as(i64, chunk_z));
    return (x *% 0x9E3779B97F4A7C15) ^ (z *% 0xC2B2AE3D27D4EB4F);
}

pub fn blocksForBiome(biome_id: BiomeId) TreeBlocks {
    return switch (biome_id) {
        .taiga, .snowy_taiga, .old_growth_taiga, .snow_tundra, .snowy_mountains, .grove, .snowy_slopes => .{ .trunk = .spruce_log, .leaves = .spruce_leaves },
        .birch_forest => .{ .trunk = .birch_log, .leaves = .birch_leaves },
        .jungle => .{ .trunk = .jungle_log, .leaves = .jungle_leaves },
        .savanna => .{ .trunk = .acacia_log, .leaves = .acacia_leaves },
        .swamp, .mangrove_swamp, .marsh => .{ .trunk = .mangrove_log, .leaves = .mangrove_leaves },
        else => .{ .trunk = .wood, .leaves = .leaves },
    };
}

fn hashUnit2D(x: i32, z: i32, seed: u64) f32 {
    var h = seed;
    h ^= @as(u64, @bitCast(@as(i64, x))) *% 0x9E3779B97F4A7C15;
    h ^= @as(u64, @bitCast(@as(i64, z))) *% 0xC2B2AE3D27D4EB4F;
    h ^= h >> 33;
    h *%= 0xFF51AFD7ED558CCD;
    h ^= h >> 33;
    const bucket: u32 = @intCast(h & 0xFFFF);
    return @as(f32, @floatFromInt(bucket)) / 65535.0;
}

const PlacedTree = struct {
    tree_type: tree_registry.TreeType,
    schematic: schematics.Schematic,
};

fn choosePlacedTree(
    biome_id: BiomeId,
    surface_block: BlockType,
    variant: f32,
    allow_subbiomes: bool,
    veg_mult: f32,
    local_x: u32,
    local_z: u32,
    surface_y: i32,
    tree_occupancy: *const [world_core.CHUNK_VOLUME]bool,
    random: std.Random,
) ?PlacedTree {
    const vegetation = biome_mod.getBiomeDefinition(biome_id).vegetation;
    if (vegetation.tree_types.len == 0) return null;

    for (vegetation.tree_types) |tree_type| {
        const tree_def = tree_registry.getTreeDefinition(tree_type) orelse continue;
        if (!treeSurfaceAllowed(tree_def.place_on, surface_block)) continue;
        if (!variantAllowed(variant, allow_subbiomes, tree_def.variant_min, tree_def.variant_max)) continue;
        const prob = @min(1.0, tree_def.probability * veg_mult);
        if (random.float(f32) >= prob) continue;
        if (tree_def.spacing_radius > 0 and !isTreeAreaClear(tree_occupancy, @intCast(local_x), surface_y, @intCast(local_z), tree_def.spacing_radius)) continue;
        return .{
            .tree_type = tree_type,
            .schematic = tree_def.schematic,
        };
    }
    return null;
}

fn variantAllowed(variant: f32, allow_subbiomes: bool, min: f32, max: f32) bool {
    if (allow_subbiomes) return variant >= min and variant <= max;
    return min == -1.0 and max == 1.0;
}

fn treeSurfaceAllowed(place_on: []const BlockType, surface_block: BlockType) bool {
    for (place_on) |valid| {
        if (surface_block == valid) return true;
    }
    return false;
}

fn isTreeAreaClear(tree_occupancy: *const [world_core.CHUNK_VOLUME]bool, x: i32, y: i32, z: i32, radius: i32) bool {
    var dz: i32 = -radius;
    while (dz <= radius) : (dz += 1) {
        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            if (dx == 0 and dz == 0) continue;
            const check_x = x + dx;
            const check_z = z + dz;
            if (check_x >= 0 and check_x < CHUNK_SIZE_X and check_z >= 0 and check_z < CHUNK_SIZE_Z) {
                var dy: i32 = 1;
                while (dy <= 3) : (dy += 1) {
                    const check_y = y + dy;
                    if (check_y >= 0 and check_y < CHUNK_SIZE_Y) {
                        const idx: usize = @intCast(@as(u32, @intCast(check_x)) + @as(u32, @intCast(check_z)) * CHUNK_SIZE_X + @as(u32, @intCast(check_y)) * CHUNK_SIZE_X * CHUNK_SIZE_Z);
                        if (tree_occupancy[idx]) return false;
                    }
                }
            }
        }
    }
    return true;
}

fn placeTreeOccupancy(schematic: schematics.Schematic, x: u32, y: u32, z: u32, tree_occupancy: *[world_core.CHUNK_VOLUME]bool, random: std.Random) void {
    const center_x = @as(i32, @intCast(x));
    const center_y = @as(i32, @intCast(y));
    const center_z = @as(i32, @intCast(z));
    for (schematic.blocks) |block| {
        if (block.probability < 1.0) {
            if (random.float(f32) >= block.probability) continue;
        }
        const bx = center_x + block.offset[0] - schematic.center_x;
        const by = center_y + block.offset[1];
        const bz = center_z + block.offset[2] - schematic.center_z;
        if (bx >= 0 and bx < CHUNK_SIZE_X and bz >= 0 and bz < CHUNK_SIZE_Z and by >= 0 and by < CHUNK_SIZE_Y and isTreeBlock(block.block)) {
            const idx: usize = @intCast(@as(u32, @intCast(bx)) + @as(u32, @intCast(bz)) * CHUNK_SIZE_X + @as(u32, @intCast(by)) * CHUNK_SIZE_X * CHUNK_SIZE_Z);
            tree_occupancy[idx] = true;
        }
    }
}

fn isTreeBlock(block: BlockType) bool {
    return switch (block) {
        .wood,
        .leaves,
        .birch_log,
        .birch_leaves,
        .spruce_log,
        .spruce_leaves,
        .jungle_log,
        .jungle_leaves,
        .acacia_log,
        .acacia_leaves,
        .mangrove_log,
        .mangrove_leaves,
        => true,
        else => false,
    };
}

fn treeHintForType(tree_type: tree_registry.TreeType) world_core.LODVegetationHint {
    const blocks = blocksForType(tree_type);
    return .{
        .tree_coverage = 1.0,
        .avg_tree_height = heightForType(tree_type),
        .offset_x = 0.0,
        .offset_z = 0.0,
        .trunk = blocks.trunk,
        .leaves = blocks.leaves,
    };
}

fn blocksForType(tree_type: tree_registry.TreeType) TreeBlocks {
    return switch (tree_type) {
        .spruce => .{ .trunk = .spruce_log, .leaves = .spruce_leaves },
        .dense_spruce => .{ .trunk = .spruce_log, .leaves = .spruce_leaves },
        .birch, .dense_birch => .{ .trunk = .birch_log, .leaves = .birch_leaves },
        .jungle => .{ .trunk = .jungle_log, .leaves = .jungle_leaves },
        .acacia => .{ .trunk = .acacia_log, .leaves = .acacia_leaves },
        .mangrove => .{ .trunk = .mangrove_log, .leaves = .mangrove_leaves },
        .huge_red_mushroom => .{ .trunk = .mushroom_stem, .leaves = .red_mushroom_block },
        .huge_brown_mushroom => .{ .trunk = .mushroom_stem, .leaves = .brown_mushroom_block },
        else => .{ .trunk = .wood, .leaves = .leaves },
    };
}

fn heightForType(tree_type: tree_registry.TreeType) f32 {
    return switch (tree_type) {
        .jungle => 13.0,
        .spruce => 10.0,
        .dense_spruce => 12.0,
        .acacia => 8.0,
        .swamp_oak, .mangrove => 7.0,
        .huge_red_mushroom, .huge_brown_mushroom => 6.0,
        else => 6.0,
    };
}
