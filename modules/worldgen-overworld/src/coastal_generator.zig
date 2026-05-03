const noise_mod = @import("noise.zig");
const clamp01 = noise_mod.clamp01;
const noise_sampler_mod = @import("noise_sampler.zig");
const NoiseSampler = noise_sampler_mod.NoiseSampler;
const surface_builder_mod = @import("surface_builder.zig");
const SurfaceBuilder = surface_builder_mod.SurfaceBuilder;
const CoastalSurfaceType = surface_builder_mod.CoastalSurfaceType;

/// Coastal classifier and ocean/inland water helper.
pub const CoastalGenerator = struct {
    ocean_threshold: f32,

    pub fn init(ocean_threshold: f32) CoastalGenerator {
        return .{ .ocean_threshold = ocean_threshold };
    }

    pub fn getSurfaceType(
        surface_builder: *const SurfaceBuilder,
        continentalness: f32,
        slope: i32,
        height: i32,
        erosion: f32,
    ) CoastalSurfaceType {
        return surface_builder.getCoastalSurfaceType(continentalness, slope, height, erosion);
    }

    pub fn isOceanWater(self: *const CoastalGenerator, noise_sampler: *const NoiseSampler, wx: f32, wz: f32) bool {
        const warp = noise_sampler.computeWarp(wx, wz, 0);
        const xw = wx + warp.x;
        const zw = wz + warp.z;
        const c = noise_sampler.getContinentalness(xw, zw, 0);
        return c < self.ocean_threshold;
    }

    pub fn isInlandWater(self: *const CoastalGenerator, noise_sampler: *const NoiseSampler, wx: f32, wz: f32, height: i32, sea_level: i32) bool {
        const warp = noise_sampler.computeWarp(wx, wz, 0);
        const xw = wx + warp.x;
        const zw = wz + warp.z;
        const c = noise_sampler.getContinentalness(xw, zw, 0);
        return height < sea_level and c >= self.ocean_threshold;
    }

    pub fn applyCoastJitter(base_continentalness: f32, coast_jitter: f32) f32 {
        return clamp01(base_continentalness + coast_jitter);
    }
};
