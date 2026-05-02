//! Registry of all available decorations and their placement rules.
//! Configures the specific decorations (both simple and schematic) that populate the world.
//! Re-exports decoration types for consumers like the generator.

const std = @import("std");
const world_core = @import("world-core");
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;
const biome_mod = @import("biome.zig");
const tree_registry = @import("tree_registry.zig");

// Import types and schematics
pub const types = @import("decoration_types.zig");
pub const schematics = @import("schematics.zig");

// Re-export types for consumers (like generator.zig)
pub const Rotation = types.Rotation;
pub const SimpleDecoration = types.SimpleDecoration;
pub const SchematicBlock = types.SchematicBlock;
pub const Schematic = types.Schematic;
pub const SchematicDecoration = types.SchematicDecoration;
pub const DecorationRule = types.DecorationRule;
pub const Decoration = types.Decoration;
pub const DecorationProvider = @import("decoration_provider.zig").DecorationProvider;
pub const DecorationContext = @import("decoration_provider.zig").DecorationProvider.DecorationContext;

pub const DECORATIONS = [_]Decoration{
    // === Grass ===
    .{ .simple = .{
        .block = .tall_grass,
        .place_on = &.{.grass},
        .biomes = &.{ .plains, .forest, .savanna, .swamp, .jungle, .bamboo_jungle, .sparse_jungle, .taiga },
        .probability = 0.5,
    } },

    // === Flowers (Standard) ===
    .{
        .simple = .{
            .block = .flower_red,
            .place_on = &.{.grass},
            .biomes = &.{ .plains, .forest },
            .probability = 0.02,
            .variant_min = -0.6, // Normal distribution
        },
    },

    // === Flower Patches (Variant < -0.6) ===
    .{
        .simple = .{
            .block = .flower_yellow,
            .place_on = &.{.grass},
            .biomes = &.{ .plains, .forest },
            .probability = 0.4, // Dense!
            .variant_max = -0.6,
        },
    },

    // === Dead Bush ===
    .{ .simple = .{
        .block = .dead_bush,
        .place_on = &.{ .sand, .red_sand },
        .biomes = &.{ .desert, .badlands, .eroded_badlands },
        .probability = 0.02,
    } },

    // === Cacti ===
    .{ .simple = .{
        .block = .cactus,
        .place_on = &.{.sand},
        .biomes = &.{.desert},
        .probability = 0.01,
    } },

    // === Aquatic vegetation ===
    .{ .simple = .{
        .block = .seagrass,
        .place_on = &.{ .sand, .gravel, .clay },
        .biomes = &.{ .ocean, .warm_ocean, .tropical },
        .requires_water = true,
        .min_water_depth = 2,
        .max_water_depth = 12,
        .probability = 0.18,
    } },
    .{ .simple = .{
        .block = .tall_seagrass,
        .place_on = &.{ .sand, .gravel, .clay },
        .biomes = &.{ .ocean, .warm_ocean, .tropical },
        .requires_water = true,
        .min_water_depth = 4,
        .max_water_depth = 14,
        .probability = 0.08,
    } },
    .{ .simple = .{
        .block = .kelp,
        .place_on = &.{ .sand, .gravel, .clay },
        .biomes = &.{ .ocean, .warm_ocean },
        .requires_water = true,
        .min_water_depth = 6,
        .max_water_depth = 30,
        .probability = 0.08,
    } },
    .{ .simple = .{
        .block = .coral_fan,
        .place_on = &.{ .sand, .gravel, .coral_block },
        .biomes = &.{ .warm_ocean, .tropical },
        .requires_water = true,
        .min_water_depth = 2,
        .max_water_depth = 10,
        .probability = 0.06,
    } },

    // === Boulders (Rocky Patches: Variant > 0.6) ===
    .{
        .simple = .{
            .block = .cobblestone,
            .place_on = &.{.grass},
            .biomes = &.{ .plains, .mountains, .taiga, .windswept_savanna },
            .probability = 0.05,
            .variant_min = 0.6,
        },
    },
};

pub fn chooseStaticSimpleDecoration(biome: BiomeId, surface_block: BlockType, variant: f32, allow_subbiomes: bool, veg_mult: f32, water_depth: u8, random: std.Random) ?SimpleDecoration {
    for (DECORATIONS) |deco| {
        switch (deco) {
            .simple => |simple| {
                if (!simple.isAllowed(biome, surface_block, water_depth)) continue;
                if (!variantAllowed(variant, allow_subbiomes, simple.variant_min, simple.variant_max)) continue;

                const prob = @min(1.0, simple.probability * veg_mult);
                if (random.float(f32) >= prob) continue;

                return simple;
            },
            .schematic => {},
        }
    }
    return null;
}

fn variantAllowed(variant: f32, allow_subbiomes: bool, min: f32, max: f32) bool {
    if (allow_subbiomes) return variant >= min and variant <= max;
    return min == -1.0 and max == 1.0;
}

const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;

pub const StandardDecorationProvider = struct {
    pub fn provider() DecorationProvider {
        return .{
            .ptr = null, // Stateless
            .vtable = &VTABLE,
        };
    }

    const VTABLE = DecorationProvider.VTable{
        .decorate = decorate,
    };

    /// Check if area around (x, z) is clear of obstructions (logs/leaves)
    fn isAreaClear(chunk: *Chunk, x: i32, y: i32, z: i32, radius: i32) bool {
        var dz: i32 = -radius;
        while (dz <= radius) : (dz += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                if (dx == 0 and dz == 0) continue;

                const check_x = x + dx;
                const check_z = z + dz;

                if (check_x >= 0 and check_x < CHUNK_SIZE_X and
                    check_z >= 0 and check_z < CHUNK_SIZE_Z)
                {
                    var dy: i32 = 1;
                    while (dy <= 3) : (dy += 1) {
                        const block = chunk.getBlockSafe(check_x, y + dy, check_z);
                        if (block == .wood or block == .leaves or
                            block == .birch_log or block == .birch_leaves or
                            block == .spruce_log or block == .spruce_leaves or
                            block == .jungle_log or block == .jungle_leaves or
                            block == .acacia_log or block == .acacia_leaves or
                            block == .mangrove_log or block == .mangrove_leaves)
                        {
                            return false;
                        }
                    }
                }
            }
        }
        return true;
    }

    fn decorate(ptr: ?*anyopaque, ctx: DecorationContext) void {
        _ = ptr;
        const chunk = ctx.chunk;
        const local_x = ctx.local_x;
        const local_z = ctx.local_z;
        const surface_y = ctx.surface_y;
        const surface_block = ctx.surface_block;
        const biome = ctx.biome;
        const variant = ctx.variant;
        const allow_subbiomes = ctx.allow_subbiomes;
        const veg_mult = ctx.veg_mult;
        const water_depth = ctx.water_depth;
        const random = ctx.random;

        // 1. Static decorations (flowers, grass)
        if (chooseStaticSimpleDecoration(biome, surface_block, variant, allow_subbiomes, veg_mult, water_depth, random)) |simple| {
            const place_y = surface_y + 1;
            if (place_y >= 0 and place_y < CHUNK_SIZE_Y) {
                const target = chunk.getBlock(local_x, @intCast(place_y), local_z);
                const required_target: BlockType = if (simple.requires_water) .water else .air;
                if (target == required_target) {
                    chunk.setBlock(local_x, @intCast(place_y), local_z, simple.block);
                }
            }
        }

        // 2. Biome-defined block decoration rules
        const biome_def = biome_mod.getBiomeDefinition(biome);
        const vegetation = biome_def.vegetation;

        for (vegetation.decoration_rules) |rule| {
            if (!rule.isAllowed(surface_block, surface_y, variant, allow_subbiomes, water_depth)) continue;

            const prob = @min(1.0, rule.chance * veg_mult);
            if (random.float(f32) >= prob) continue;

            const place_y = surface_y + 1;
            if (place_y < 0 or place_y >= CHUNK_SIZE_Y) continue;
            const target = chunk.getBlockSafe(@intCast(local_x), place_y, @intCast(local_z));
            const required_target: BlockType = if (rule.requires_water) .water else .air;
            if (target != required_target) continue;

            chunk.setBlock(local_x, @intCast(place_y), local_z, rule.block);
            break;
        }

        // 3. Dynamic Tree Registry (from Biome Definition)
        if (vegetation.tree_types.len > 0) {
            for (vegetation.tree_types) |tree_type| {
                if (tree_registry.getTreeDefinition(tree_type)) |tree_def| {
                    // Check surface block
                    var valid_surface = false;
                    for (tree_def.place_on) |valid_block| {
                        if (surface_block == valid_block) {
                            valid_surface = true;
                            break;
                        }
                    }
                    if (!valid_surface) continue;

                    // Check variant noise
                    if (allow_subbiomes) {
                        if (variant < tree_def.variant_min or variant > tree_def.variant_max) continue;
                    } else {
                        if (tree_def.variant_min != -1.0 or tree_def.variant_max != 1.0) continue;
                    }

                    // Check probability
                    const prob = @min(1.0, tree_def.probability * veg_mult);
                    if (random.float(f32) >= prob) continue;

                    // Enforce spacing
                    if (tree_def.spacing_radius > 0) {
                        if (!isAreaClear(chunk, @intCast(local_x), surface_y, @intCast(local_z), tree_def.spacing_radius)) {
                            continue;
                        }
                    }

                    // Place tree
                    tree_def.schematic.place(chunk, local_x, @intCast(surface_y + 1), local_z, random);

                    // Break after placing a tree to avoid multiple trees spawning in the same block column
                    break;
                }
            }
        }
    }
};
