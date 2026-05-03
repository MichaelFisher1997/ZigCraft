const LODLevel = @import("lod_types.zig").LODLevel;
const LODSimplifiedData = @import("lod_chunk.zig").LODSimplifiedData;

pub const LODGenerator = struct {
    ptr: *anyopaque,
    generate_heightmap_only: *const fn (ptr: *anyopaque, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel) void,
    maybe_recenter_cache: *const fn (ptr: *anyopaque, player_x: i32, player_z: i32) bool,
    seed: u64,
    identity_hash: u64,
    version: u32,

    pub fn generateHeightmapOnly(self: LODGenerator, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel) void {
        self.generate_heightmap_only(self.ptr, data, region_x, region_z, lod_level);
    }

    pub fn maybeRecenterCache(self: LODGenerator, player_x: i32, player_z: i32) bool {
        return self.maybe_recenter_cache(self.ptr, player_x, player_z);
    }
};
