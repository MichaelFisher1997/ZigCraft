const std = @import("std");
const region_pkg = @import("region.zig");
const DecorationProvider = @import("decoration_provider.zig").DecorationProvider;
const NoiseSampler = @import("noise_sampler.zig").NoiseSampler;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const BlockType = world_core.BlockType;

/// Biome decoration subsystem.
/// Handles post-terrain passes: ores and biome features/vegetation.
pub const BiomeDecorator = struct {
    decoration_provider: DecorationProvider,
    ore_seed: u64,
    region_seed: u64,

    pub fn init(seed: u64, decoration_provider: DecorationProvider) BiomeDecorator {
        return .{
            .decoration_provider = decoration_provider,
            .ore_seed = seed +% 30,
            .region_seed = seed +% 20,
        };
    }

    pub fn generateOres(self: *const BiomeDecorator, chunk: *Chunk) void {
        var prng = std.Random.DefaultPrng.init(self.ore_seed +% @as(u64, @bitCast(@as(i64, chunk.chunk_x))) *% 59381 +% @as(u64, @bitCast(@as(i64, chunk.chunk_z))) *% 28411);
        const random = prng.random();
        placeOreVeins(chunk, .coal_ore, 20, 6, 10, 128, random);
        placeOreVeins(chunk, .iron_ore, 10, 4, 5, 64, random);
        placeOreVeins(chunk, .gold_ore, 3, 3, 2, 32, random);
        placeOreVeins(chunk, .glowstone, 8, 4, 5, 40, random);
    }

    fn placeOreVeins(chunk: *Chunk, block: BlockType, count: u32, size: u32, min_y: i32, max_y: i32, random: std.Random) void {
        for (0..count) |_| {
            const cx = random.uintLessThan(u32, CHUNK_SIZE_X);
            const cz = random.uintLessThan(u32, CHUNK_SIZE_Z);
            const range = max_y - min_y;
            if (range <= 0) continue;
            const cy = min_y + @as(i32, @intCast(random.uintLessThan(u32, @intCast(range))));
            const vein_size = random.uintLessThan(u32, size) + 2;
            var i: u32 = 0;
            while (i < vein_size) : (i += 1) {
                const ox = @as(i32, @intCast(random.uintLessThan(u32, 4))) - 2;
                const oy = @as(i32, @intCast(random.uintLessThan(u32, 4))) - 2;
                const oz = @as(i32, @intCast(random.uintLessThan(u32, 4))) - 2;
                const tx = @as(i32, @intCast(cx)) + ox;
                const ty = cy + oy;
                const tz = @as(i32, @intCast(cz)) + oz;
                if (chunk.getBlockSafe(tx, ty, tz) == .stone) {
                    if (tx >= 0 and tx < CHUNK_SIZE_X and ty >= 0 and ty < CHUNK_SIZE_Y and tz >= 0 and tz < CHUNK_SIZE_Z) {
                        chunk.setBlock(@intCast(tx), @intCast(ty), @intCast(tz), block);
                    }
                }
            }
        }
    }

    pub fn generateFeatures(self: *const BiomeDecorator, chunk: *Chunk, noise_sampler: *const NoiseSampler) void {
        var prng = std.Random.DefaultPrng.init(self.region_seed ^ @as(u64, @bitCast(@as(i64, chunk.chunk_x))) ^ (@as(u64, @bitCast(@as(i64, chunk.chunk_z))) << 32));
        const random = prng.random();
        const world_x = chunk.getWorldX();
        const world_z = chunk.getWorldZ();
        const controls = region_pkg.RegionControlCorners.init(
            self.region_seed,
            world_x,
            world_z,
            world_x + CHUNK_SIZE_X - 1,
            world_z + CHUNK_SIZE_Z - 1,
        );

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const surface_y = chunk.getSurfaceHeight(local_x, local_z);
                if (surface_y <= 0 or surface_y >= CHUNK_SIZE_Y - 1) continue;

                const biome = chunk.biomes[local_x + local_z * CHUNK_SIZE_X];
                const wx_i = world_x + @as(i32, @intCast(local_x));
                const wz_i = world_z + @as(i32, @intCast(local_z));
                const wx: f32 = @floatFromInt(wx_i);
                const wz: f32 = @floatFromInt(wz_i);
                const variant_val = noise_sampler.variant_noise.get2D(wx, wz);
                const column_controls = controls.sample(wx_i, wz_i);
                const surface_block = chunk.getBlock(local_x, @intCast(surface_y), local_z);
                const water_depth = columnWaterDepth(chunk, local_x, local_z, @intCast(surface_y));

                self.decoration_provider.decorate(.{
                    .chunk = chunk,
                    .local_x = local_x,
                    .local_z = local_z,
                    .surface_y = @intCast(surface_y),
                    .surface_block = surface_block,
                    .water_depth = water_depth,
                    .biome = biome,
                    .variant = variant_val,
                    .allow_subbiomes = column_controls.subbiome_mask > 0.5,
                    .veg_mult = column_controls.vegetation_mult,
                    .random = random,
                });
            }
        }
    }

    fn columnWaterDepth(chunk: *const Chunk, local_x: u32, local_z: u32, surface_y: i32) u8 {
        var depth: u8 = 0;
        var y = surface_y + 1;
        while (y < CHUNK_SIZE_Y and depth < std.math.maxInt(u8)) : (y += 1) {
            if (chunk.getBlock(local_x, @intCast(y), local_z) != .water) break;
            depth += 1;
        }
        return depth;
    }
};
