//! LOD Chunk data structures for Distant Horizons-style rendering.
//!
//! LOD levels:
//! - LOD0: Full detail, 2x2 chunks merged
//! - LOD1: 2x block resolution, 4x4 chunks merged
//! - LOD2: 4x block resolution, 8x8 chunks merged
//! - LOD3: 8x block resolution, 16x16 chunks merged, heightmap-only

const std = @import("std");
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;

/// LOD level enum - higher values = more simplified
pub const LODLevel = @import("lod_types.zig").LODLevel;
pub const regionSizeBlocks = world_core.regionSizeBlocks;

/// State for LOD chunks/regions
pub const LODState = @import("lod_types.zig").LODState;

/// Simplified data for distant LOD levels (LOD1+).
/// Only stores essential data needed for rendering distant terrain.
pub const LODSimplifiedData = world_core.LODSimplifiedData;

/// LOD region key - identifies a region at a specific LOD level
pub const LODRegionKey = struct {
    /// Region X coordinate (in region units, not chunks)
    rx: i32,
    /// Region Z coordinate
    rz: i32,
    /// LOD level
    lod: LODLevel,

    pub fn fromChunkCoords(chunk_x: i32, chunk_z: i32, lod: LODLevel) LODRegionKey {
        const scale: i32 = @intCast(lod.chunksPerSide());
        return .{
            .rx = @divFloor(chunk_x, scale),
            .rz = @divFloor(chunk_z, scale),
            .lod = lod,
        };
    }

    pub fn hash(self: LODRegionKey) u64 {
        const ux: u64 = @bitCast(@as(i64, self.rx));
        const uz: u64 = @bitCast(@as(i64, self.rz));
        const ul: u64 = @intFromEnum(self.lod);
        return ux ^ (uz *% 0x9e3779b97f4a7c15) ^ (ul *% 0x517cc1b727220a95);
    }

    pub fn eql(a: LODRegionKey, b: LODRegionKey) bool {
        return a.rx == b.rx and a.rz == b.rz and a.lod == b.lod;
    }

    /// Get the chunk coordinates that this region covers
    pub fn chunkBounds(self: LODRegionKey) ChunkBounds {
        const scale: i32 = @intCast(self.lod.chunksPerSide());
        return .{
            .min_x = self.rx * scale,
            .min_z = self.rz * scale,
            .max_x = self.rx * scale + scale - 1,
            .max_z = self.rz * scale + scale - 1,
        };
    }
};

pub const ChunkBounds = struct {
    min_x: i32,
    min_z: i32,
    max_x: i32,
    max_z: i32,

    pub fn distanceSquaredToPoint(self: ChunkBounds, point_x: i32, point_z: i32) i64 {
        const dx = axisDistance(point_x, self.min_x, self.max_x);
        const dz = axisDistance(point_z, self.min_z, self.max_z);
        return dx * dx + dz * dz;
    }

    pub fn intersectsRadius(self: ChunkBounds, center_x: i32, center_z: i32, radius_chunks: i32) bool {
        const radius_sq: i64 = @as(i64, radius_chunks) * @as(i64, radius_chunks);
        return self.distanceSquaredToPoint(center_x, center_z) <= radius_sq;
    }

    fn axisDistance(point: i32, min_value: i32, max_value: i32) i64 {
        if (point < min_value) return @as(i64, min_value) - @as(i64, point);
        if (point > max_value) return @as(i64, point) - @as(i64, max_value);
        return 0;
    }
};

/// Context for LODRegionKey HashMap
pub const LODRegionKeyContext = struct {
    pub fn hash(self: @This(), key: LODRegionKey) u64 {
        _ = self;
        return key.hash();
    }

    pub fn eql(self: @This(), a: LODRegionKey, b: LODRegionKey) bool {
        _ = self;
        return a.eql(b);
    }
};

/// LOD Chunk - represents terrain data at a specific LOD level
pub const LODChunk = struct {
    /// Region position
    region_x: i32,
    region_z: i32,

    /// LOD level
    lod_level: LODLevel,

    /// Current state
    state: LODState,

    /// Job token for tracking async work
    job_token: u32,

    /// Pin count for preventing unload during async work
    pin_count: std.atomic.Value(u32),

    /// Chunk data - either full detail or simplified
    data: union(enum) {
        /// LOD0: Full chunk data (pointer to existing Chunk)
        full: *Chunk,
        /// LOD1+: Simplified heightmap-based data
        simplified: LODSimplifiedData,
        /// Not yet generated
        empty: void,
    },

    /// Mesh handle (0 = no mesh)
    mesh_handle: u32,

    /// Dirty flag for re-meshing
    dirty: bool,

    pub fn init(rx: i32, rz: i32, lod: LODLevel) LODChunk {
        return .{
            .region_x = rx,
            .region_z = rz,
            .lod_level = lod,
            .state = .missing,
            .job_token = 0,
            .pin_count = std.atomic.Value(u32).init(0),
            .data = .{ .empty = {} },
            .mesh_handle = 0,
            .dirty = false,
        };
    }

    pub fn deinit(self: *LODChunk, allocator: std.mem.Allocator) void {
        _ = allocator;
        switch (self.data) {
            .simplified => |*s| s.deinit(),
            .full => {}, // Full chunks are managed elsewhere
            .empty => {},
        }
        self.* = undefined;
    }

    pub fn pin(self: *LODChunk) void {
        _ = self.pin_count.fetchAdd(1, .monotonic);
    }

    pub fn unpin(self: *LODChunk) void {
        _ = self.pin_count.fetchSub(1, .monotonic);
    }

    pub fn isPinned(self: *const LODChunk) bool {
        return self.pin_count.load(.monotonic) > 0;
    }

    /// World-space bounds structure for LOD regions
    pub const WorldBounds = struct {
        min_x: i32,
        min_z: i32,
        max_x: i32,
        max_z: i32,
    };

    /// Get the world-space bounds of this LOD region
    pub fn worldBounds(self: *const LODChunk) WorldBounds {
        const scale: i32 = @intCast(self.lod_level.chunksPerSide());
        const size: i32 = scale * CHUNK_SIZE_X;
        return .{
            .min_x = self.region_x * size,
            .min_z = self.region_z * size,
            .max_x = self.region_x * size + size,
            .max_z = self.region_z * size + size,
        };
    }

    pub fn chunkBounds(self: *const LODChunk) ChunkBounds {
        return .{
            .min_x = self.region_x * @as(i32, @intCast(self.lod_level.chunksPerSide())),
            .min_z = self.region_z * @as(i32, @intCast(self.lod_level.chunksPerSide())),
            .max_x = (self.region_x + 1) * @as(i32, @intCast(self.lod_level.chunksPerSide())) - 1,
            .max_z = (self.region_z + 1) * @as(i32, @intCast(self.lod_level.chunksPerSide())) - 1,
        };
    }
};

/// Configuration interface for LOD system to decouple settings from logic.
pub const ILODConfig = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getRadii: *const fn (ptr: *anyopaque) [LODLevel.count]i32,
        getActiveLODCount: *const fn (ptr: *anyopaque) u32,
        setActiveLODCount: *const fn (ptr: *anyopaque, count: u32) void,
        setLOD0Radius: *const fn (ptr: *anyopaque, radius: i32) void,
        setRadii: *const fn (ptr: *anyopaque, radii: [LODLevel.count]i32) void,
        getLODForDistance: *const fn (ptr: *anyopaque, dist_chunks: i32) LODLevel,
        isInRange: *const fn (ptr: *anyopaque, dist_chunks: i32) bool,
        getMaxUploadsPerFrame: *const fn (ptr: *anyopaque) u32,
        calculateMaskRadius: *const fn (ptr: *anyopaque) f32,
        getQEMTarget: *const fn (ptr: *anyopaque, lod: LODLevel) u32,
        getQEMMinInputTriangles: *const fn (ptr: *anyopaque) u32,
        getFogStartPercent: *const fn (ptr: *anyopaque, lod: LODLevel) f32,
    };

    pub fn getRadii(self: ILODConfig) [LODLevel.count]i32 {
        return self.vtable.getRadii(self.ptr);
    }
    pub fn getActiveLODCount(self: ILODConfig) u32 {
        return self.vtable.getActiveLODCount(self.ptr);
    }
    pub fn setActiveLODCount(self: ILODConfig, count: u32) void {
        self.vtable.setActiveLODCount(self.ptr, count);
    }
    pub fn setLOD0Radius(self: ILODConfig, radius: i32) void {
        self.vtable.setLOD0Radius(self.ptr, radius);
    }
    pub fn setRadii(self: ILODConfig, radii: [LODLevel.count]i32) void {
        self.vtable.setRadii(self.ptr, radii);
    }
    pub fn getLODForDistance(self: ILODConfig, dist_chunks: i32) LODLevel {
        return self.vtable.getLODForDistance(self.ptr, dist_chunks);
    }
    pub fn isInRange(self: ILODConfig, dist_chunks: i32) bool {
        return self.vtable.isInRange(self.ptr, dist_chunks);
    }
    pub fn getMaxUploadsPerFrame(self: ILODConfig) u32 {
        return self.vtable.getMaxUploadsPerFrame(self.ptr);
    }

    /// Calculate the masking radius used by shaders to discard LOD pixels overlapping with high-detail chunks.
    /// This is a pure function based on config state, extracted for testability.
    pub fn calculateMaskRadius(self: ILODConfig) f32 {
        return self.vtable.calculateMaskRadius(self.ptr);
    }

    pub fn getQEMTarget(self: ILODConfig, lod: LODLevel) u32 {
        return self.vtable.getQEMTarget(self.ptr, lod);
    }

    pub fn getQEMMinInputTriangles(self: ILODConfig) u32 {
        return self.vtable.getQEMMinInputTriangles(self.ptr);
    }

    pub fn getFogStartPercent(self: ILODConfig, lod: LODLevel) f32 {
        return self.vtable.getFogStartPercent(self.ptr, lod);
    }
};

/// Concrete implementation of LOD system configuration.
pub const LODConfig = struct {
    pub const dynamic_lod0_radius: i32 = 16;
    pub const dynamic_lod3_radius: i32 = 512;

    radii: [LODLevel.count]i32 = .{ 16, 40, 80, 160 },

    memory_budget_mb: u32 = 256,

    max_uploads_per_frame: u32 = 8,

    fog_transitions: bool = true,

    /// Fog start position as percentage of LOD radius (0.0-1.0) where fog begins.
    /// Values closer to 0.0 start fog near the player; 1.0 disables fog for that level.
    fog_start_percent: [LODLevel.count]f32 = .{ 0.5, 0.5, 0.4, 0.3 },

    qem_triangle_targets: [LODLevel.count]u32 = .{ 0, 2000, 800, 200 },

    qem_min_input_triangles: u32 = 50,

    skip_cutout_lod2: bool = false,

    skip_lighting_lod3: bool = false,

    active_lod_count: u32 = 4,

    pub fn getQEMTarget(self: *const LODConfig, lod: LODLevel) u32 {
        return self.qem_triangle_targets[@intFromEnum(lod)];
    }

    pub fn radiiForRenderDistance(distance: i32) [LODLevel.count]i32 {
        const lod0 = @min(@max(distance, 1), dynamic_lod0_radius);
        const dist_i64 = @as(i64, @max(distance, 1));
        const max_radius_i64 = @as(i64, dynamic_lod3_radius);
        const lod1 = @as(i32, @intCast(@min(@max(@as(i64, lod0) * 2, dist_i64 * 2), max_radius_i64)));
        const lod2 = @as(i32, @intCast(@min(@max(@as(i64, lod1) * 2, dist_i64 * 4), max_radius_i64)));
        return .{ lod0, @min(lod1, dynamic_lod3_radius), lod2, dynamic_lod3_radius };
    }

    pub fn activeCountForRenderDistance(distance: i32) u32 {
        return if (distance > dynamic_lod0_radius) LODLevel.count else 2;
    }

    pub fn getLODForDistance(self: *const LODConfig, dist_chunks: i32) LODLevel {
        inline for (0..LODLevel.count) |i| {
            if (dist_chunks <= self.radii[i]) return @enumFromInt(@as(u3, @intCast(i)));
        }
        return .lod3; // Beyond max distance, still use LOD3
    }

    pub fn isInRange(self: *const LODConfig, dist_chunks: i32) bool {
        return dist_chunks <= self.radii[LODLevel.count - 1];
    }

    /// Returns the interface for this concrete config.
    pub fn interface(self: *LODConfig) ILODConfig {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    const VTABLE = ILODConfig.VTable{
        .getRadii = getRadiiWrapper,
        .getActiveLODCount = getActiveLODCountWrapper,
        .setActiveLODCount = setActiveLODCountWrapper,
        .setLOD0Radius = setLOD0RadiusWrapper,
        .setRadii = setRadiiWrapper,
        .getLODForDistance = getLODForDistanceWrapper,
        .isInRange = isInRangeWrapper,
        .getMaxUploadsPerFrame = getMaxUploadsPerFrameWrapper,
        .calculateMaskRadius = calculateMaskRadiusWrapper,
        .getQEMTarget = getQEMTargetWrapper,
        .getQEMMinInputTriangles = getQEMMinInputTrianglesWrapper,
        .getFogStartPercent = getFogStartPercentWrapper,
    };

    fn getRadiiWrapper(ptr: *anyopaque) [LODLevel.count]i32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.radii;
    }
    fn getActiveLODCountWrapper(ptr: *anyopaque) u32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return std.math.clamp(self.active_lod_count, 1, LODLevel.count);
    }
    fn setActiveLODCountWrapper(ptr: *anyopaque, count: u32) void {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        self.active_lod_count = std.math.clamp(count, 1, LODLevel.count);
    }
    fn setLOD0RadiusWrapper(ptr: *anyopaque, radius: i32) void {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        self.radii[0] = radius;
    }
    fn setRadiiWrapper(ptr: *anyopaque, radii: [LODLevel.count]i32) void {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        self.radii = radii;
    }
    fn getLODForDistanceWrapper(ptr: *anyopaque, dist_chunks: i32) LODLevel {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.getLODForDistance(dist_chunks);
    }
    fn isInRangeWrapper(ptr: *anyopaque, dist_chunks: i32) bool {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.isInRange(dist_chunks);
    }
    fn getMaxUploadsPerFrameWrapper(ptr: *anyopaque) u32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.max_uploads_per_frame;
    }
    fn calculateMaskRadiusWrapper(ptr: *anyopaque) f32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        // Keep a small overlap so the chunk ring and LOD ring blend instead of
        // leaving a camera-centered dead zone between them.
        const overlap_chunks = @max(self.radii[0] - 1, 0);
        return @as(f32, @floatFromInt(overlap_chunks)) * @as(f32, @floatFromInt(CHUNK_SIZE_X));
    }
    fn getQEMTargetWrapper(ptr: *anyopaque, lod: LODLevel) u32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.getQEMTarget(lod);
    }
    fn getQEMMinInputTrianglesWrapper(ptr: *anyopaque) u32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.qem_min_input_triangles;
    }
    fn getFogStartPercentWrapper(ptr: *anyopaque, lod: LODLevel) f32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.fog_start_percent[@intFromEnum(lod)];
    }
};

// Tests
test "LODLevel scale calculations" {
    try std.testing.expectEqual(@as(u32, 1), LODLevel.lod0.scale());
    try std.testing.expectEqual(@as(u32, 2), LODLevel.lod1.scale());
    try std.testing.expectEqual(@as(u32, 4), LODLevel.lod2.scale());
    try std.testing.expectEqual(@as(u32, 8), LODLevel.lod3.scale());

    try std.testing.expectEqual(@as(u32, 4), LODLevel.lod0.totalChunks());
    try std.testing.expectEqual(@as(u32, 16), LODLevel.lod1.totalChunks());
    try std.testing.expectEqual(@as(u32, 64), LODLevel.lod2.totalChunks());
    try std.testing.expectEqual(@as(u32, 256), LODLevel.lod3.totalChunks());
}

test "LODRegionKey from chunk coords" {
    const key1 = LODRegionKey.fromChunkCoords(5, 7, .lod1);
    try std.testing.expectEqual(@as(i32, 1), key1.rx); // 5 / 4 = 1
    try std.testing.expectEqual(@as(i32, 1), key1.rz); // 7 / 4 = 1

    const key2 = LODRegionKey.fromChunkCoords(-3, -5, .lod2);
    try std.testing.expectEqual(@as(i32, -1), key2.rx); // -3 / 8 = -1
    try std.testing.expectEqual(@as(i32, -1), key2.rz); // -5 / 8 = -1
}

test "LODConfig distance calculation" {
    const config = LODConfig{};
    try std.testing.expectEqual(LODLevel.lod0, config.getLODForDistance(10));
    try std.testing.expectEqual(LODLevel.lod1, config.getLODForDistance(20));
    try std.testing.expectEqual(LODLevel.lod2, config.getLODForDistance(50));
    try std.testing.expectEqual(LODLevel.lod3, config.getLODForDistance(100));
}

test "ILODConfig exposes clamped active LOD count" {
    var config = LODConfig{ .active_lod_count = 2 };
    var interface = config.interface();
    try std.testing.expectEqual(@as(u32, 2), interface.getActiveLODCount());

    config.active_lod_count = 0;
    interface = config.interface();
    try std.testing.expectEqual(@as(u32, 1), interface.getActiveLODCount());

    config.active_lod_count = LODLevel.count + 10;
    interface = config.interface();
    try std.testing.expectEqual(@as(u32, LODLevel.count), interface.getActiveLODCount());
}

test "LODConfig expands render distance into distant LOD horizon" {
    try std.testing.expectEqual(@as(u32, 2), LODConfig.activeCountForRenderDistance(8));
    try std.testing.expectEqual(@as(u32, LODLevel.count), LODConfig.activeCountForRenderDistance(32));

    const radii = LODConfig.radiiForRenderDistance(32);
    try std.testing.expectEqual(@as(i32, 16), radii[0]);
    try std.testing.expectEqual(@as(i32, 64), radii[1]);
    try std.testing.expectEqual(@as(i32, 128), radii[2]);
    try std.testing.expectEqual(@as(i32, 512), radii[3]);
}

test "ChunkBounds intersects radius radially" {
    const axis_region = ChunkBounds{ .min_x = 16, .min_z = 0, .max_x = 31, .max_z = 15 };
    try std.testing.expect(axis_region.intersectsRadius(0, 0, 16));

    const diagonal_region = ChunkBounds{ .min_x = 16, .min_z = 16, .max_x = 31, .max_z = 31 };
    try std.testing.expect(!diagonal_region.intersectsRadius(0, 0, 16));
    try std.testing.expectEqual(@as(i64, 16 * 16 + 16 * 16), diagonal_region.distanceSquaredToPoint(0, 0));
}

test "ILODConfig.calculateMaskRadius" {
    var config = LODConfig{
        .radii = .{ 16, 40, 80, 160 },
    };
    const interface = config.interface();
    try std.testing.expectEqual(@as(f32, 240.0), interface.calculateMaskRadius());

    config.radii[0] = 32;
    try std.testing.expectEqual(@as(f32, 496.0), interface.calculateMaskRadius());
}
