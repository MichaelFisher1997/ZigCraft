//! LOD Chunk data structures for Distant Horizons-style rendering.
//!
//! LOD levels merge progressively larger chunk regions. Runtime settings choose
//! each level's grid detail and mesh path.

const std = @import("std");
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
pub const LODMeshPath = @import("engine-rhi").LODMeshPath;

/// LOD level enum - higher values = more simplified
pub const LODLevel = @import("lod_types.zig").LODLevel;
pub const regionSizeBlocks = world_core.regionSizeBlocks;
pub const TRANSITION_FADE_FRAMES: u8 = 30;

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

    /// LOD chunk API `fromChunkCoords` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn fromChunkCoords(chunk_x: i32, chunk_z: i32, lod: LODLevel) LODRegionKey {
        const scale: i32 = @intCast(lod.chunksPerSide());
        return .{
            .rx = @divFloor(chunk_x, scale),
            .rz = @divFloor(chunk_z, scale),
            .lod = lod,
        };
    }

    /// LOD chunk API `hash` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn hash(self: LODRegionKey) u64 {
        const ux: u64 = @bitCast(@as(i64, self.rx));
        const uz: u64 = @bitCast(@as(i64, self.rz));
        const ul: u64 = @intFromEnum(self.lod);
        return ux ^ (uz *% 0x9e3779b97f4a7c15) ^ (ul *% 0x517cc1b727220a95);
    }

    /// LOD chunk API `eql` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn eql(a: LODRegionKey, b: LODRegionKey) bool {
        return a.rx == b.rx and a.rz == b.rz and a.lod == b.lod;
    }

    /// LOD chunk API `parentKey` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn parentKey(self: LODRegionKey) ?LODRegionKey {
        const lod_idx = @intFromEnum(self.lod);
        if (lod_idx + 1 >= LODLevel.count) return null;
        return .{
            .rx = @divFloor(self.rx, 2),
            .rz = @divFloor(self.rz, 2),
            .lod = @enumFromInt(@as(u3, @intCast(lod_idx + 1))),
        };
    }

    /// LOD chunk API `childKeys` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn childKeys(self: LODRegionKey) ?[4]LODRegionKey {
        const lod_idx = @intFromEnum(self.lod);
        if (lod_idx == 0) return null;
        const child_lod: LODLevel = @enumFromInt(@as(u3, @intCast(lod_idx - 1)));
        const base_x = self.rx * 2;
        const base_z = self.rz * 2;
        return .{
            .{ .rx = base_x, .rz = base_z, .lod = child_lod },
            .{ .rx = base_x + 1, .rz = base_z, .lod = child_lod },
            .{ .rx = base_x, .rz = base_z + 1, .lod = child_lod },
            .{ .rx = base_x + 1, .rz = base_z + 1, .lod = child_lod },
        };
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

    /// LOD chunk API `distanceSquaredToPoint` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn distanceSquaredToPoint(self: ChunkBounds, point_x: i32, point_z: i32) i64 {
        const dx = axisDistance(point_x, self.min_x, self.max_x);
        const dz = axisDistance(point_z, self.min_z, self.max_z);
        return dx * dx + dz * dz;
    }

    /// LOD chunk API `intersectsRadius` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
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
    /// LOD chunk API `hash` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn hash(self: @This(), key: LODRegionKey) u64 {
        _ = self;
        return key.hash();
    }

    /// LOD chunk API `eql` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
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

    /// Actual source-data height bounds in world block coordinates.
    min_height: f32,
    max_height: f32,

    /// Number of direct 2x2 finer child regions currently renderable.
    ready_children: u8,

    /// Remaining render ticks for child fade-in or parent fade-out after a
    /// hierarchy coverage transition.
    transition_frames_remaining: u8,

    /// Dirty flag for re-meshing
    dirty: bool,

    /// Source data changed since the last store flush (chunk-derived ingestion
    /// or edit). The manager writes the region container to disk lazily.
    store_dirty: bool,

    /// LOD chunk API `init` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
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
            .min_height = 0.0,
            .max_height = @floatFromInt(CHUNK_SIZE_Y),
            .ready_children = 0,
            .transition_frames_remaining = 0,
            .dirty = false,
            .store_dirty = false,
        };
    }

    /// LOD chunk API `deinit` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn deinit(self: *LODChunk, allocator: std.mem.Allocator) void {
        _ = allocator;
        switch (self.data) {
            .simplified => |*s| s.deinit(),
            .full => {}, // Full chunks are managed elsewhere
            .empty => {},
        }
        self.* = undefined;
    }

    /// LOD chunk API `pin` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn pin(self: *LODChunk) void {
        _ = self.pin_count.fetchAdd(1, .monotonic);
    }

    /// LOD chunk API `unpin` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn unpin(self: *LODChunk) void {
        _ = self.pin_count.fetchSub(1, .monotonic);
    }

    /// LOD chunk API `isPinned` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn isPinned(self: *const LODChunk) bool {
        return self.pin_count.load(.monotonic) > 0;
    }

    /// LOD chunk API `key` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn key(self: *const LODChunk) LODRegionKey {
        return .{ .rx = self.region_x, .rz = self.region_z, .lod = self.lod_level };
    }

    /// LOD chunk API `getState` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getState(self: *const LODChunk) LODState {
        return self.state;
    }

    /// LOD chunk API `setState` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn setState(self: *LODChunk, state: LODState) void {
        self.state = state;
    }

    /// LOD chunk API `isInFlight` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn isInFlight(self: *const LODChunk) bool {
        return self.state == .generating or self.state == .meshing or self.state == .uploading;
    }

    /// LOD chunk API `isRenderable` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn isRenderable(self: *const LODChunk) bool {
        return self.state == .renderable;
    }

    /// LOD chunk API `lodLevel` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn lodLevel(self: *const LODChunk) LODLevel {
        return self.lod_level;
    }

    /// LOD chunk API `readyChildren` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn readyChildren(self: *const LODChunk) u8 {
        return self.ready_children;
    }

    /// LOD chunk API `transitionFadeProgress` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn transitionFadeProgress(self: *const LODChunk) f32 {
        if (self.transition_frames_remaining == 0) return 1.0;
        const remaining = @as(f32, @floatFromInt(self.transition_frames_remaining));
        const total = @as(f32, @floatFromInt(TRANSITION_FADE_FRAMES));
        const t = @min(remaining / total, 1.0);
        if (self.lod_level != .lod1 and self.ready_children >= 4) return t;
        return 1.0 - t;
    }

    /// LOD chunk API `adjustReadyChildren` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn adjustReadyChildren(self: *LODChunk, delta: i8) void {
        const before = self.ready_children;
        if (delta > 0) {
            self.ready_children = @min(self.ready_children + @as(u8, @intCast(delta)), 4);
        } else if (delta < 0) {
            const amount: u8 = @intCast(-delta);
            self.ready_children = if (amount >= self.ready_children) 0 else self.ready_children - amount;
        }
        if (before < 4 and self.ready_children >= 4) {
            self.transition_frames_remaining = TRANSITION_FADE_FRAMES;
        } else if (self.ready_children < 4) {
            self.transition_frames_remaining = 0;
        }
    }

    /// LOD chunk API `markRenderable` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn markRenderable(self: *LODChunk, ready_children: u8) void {
        self.ready_children = @min(ready_children, 4);
        self.transition_frames_remaining = TRANSITION_FADE_FRAMES;
        self.state = .renderable;
    }

    /// LOD chunk API `tickTransition` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn tickTransition(self: *LODChunk) void {
        if (self.transition_frames_remaining > 0) self.transition_frames_remaining -= 1;
    }

    /// LOD chunk API `isCoveredByFinerLOD` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn isCoveredByFinerLOD(self: *const LODChunk, fallback_missing_child_threshold: f32) bool {
        if (self.lod_level == .lod0) return false;
        const missing_children = 4 - @min(self.ready_children, 4);
        const missing_fraction = @as(f32, @floatFromInt(missing_children)) / 4.0;
        return missing_fraction <= fallback_missing_child_threshold and self.transition_frames_remaining == 0;
    }

    /// LOD chunk API `markSourceDirty` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn markSourceDirty(self: *LODChunk) void {
        self.dirty = true;
        self.store_dirty = true;
    }

    /// LOD chunk API `setReadyChildren` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn setReadyChildren(self: *LODChunk, ready_children: u8) void {
        self.ready_children = @min(ready_children, 4);
    }

    /// World-space bounds structure for LOD regions
    pub const WorldBounds = struct {
        min_x: i32,
        min_z: i32,
        max_x: i32,
        max_z: i32,
        min_y: f32,
        max_y: f32,
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
            .min_y = self.min_height,
            .max_y = self.max_height,
        };
    }

    /// LOD chunk API `updateHeightBoundsFromData` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn updateHeightBoundsFromData(self: *LODChunk) void {
        switch (self.data) {
            .simplified => |*data| {
                var min_height: f32 = std.math.floatMax(f32);
                var max_height: f32 = -std.math.floatMax(f32);
                if (data.hasVerticalSpans()) {
                    const counts = data.vertical_span_counts.?;
                    const spans = data.vertical_spans.?;
                    for (counts, 0..) |span_count, column_idx| {
                        var span_idx: usize = 0;
                        while (span_idx < span_count) : (span_idx += 1) {
                            const span = spans[column_idx * world_core.MAX_LOD_VERTICAL_SPANS + span_idx];
                            min_height = @min(min_height, span.min_height);
                            max_height = @max(max_height, span.max_height);
                        }
                    }
                }
                for (data.heightmap) |height| {
                    min_height = @min(min_height, height);
                    max_height = @max(max_height, height);
                }
                if (min_height <= max_height) {
                    self.min_height = min_height;
                    self.max_height = max_height;
                }
            },
            else => {},
        }
    }

    /// LOD chunk API `chunkBounds` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
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
        getChunkRenderRadius: *const fn (ptr: *anyopaque) i32,
        getActiveLODCount: *const fn (ptr: *anyopaque) u32,
        setActiveLODCount: *const fn (ptr: *anyopaque, count: u32) void,
        setChunkRenderRadius: *const fn (ptr: *anyopaque, radius: i32) void,
        setLOD0Radius: *const fn (ptr: *anyopaque, radius: i32) void,
        setRadii: *const fn (ptr: *anyopaque, radii: [LODLevel.count]i32) void,
        getLODForDistance: *const fn (ptr: *anyopaque, dist_chunks: i32) LODLevel,
        isInRange: *const fn (ptr: *anyopaque, dist_chunks: i32) bool,
        getMaxUploadsPerFrame: *const fn (ptr: *anyopaque) u32,
        calculateMaskRadius: *const fn (ptr: *anyopaque) f32,
        getQEMTarget: *const fn (ptr: *anyopaque, lod: LODLevel) u32,
        getQEMMinInputTriangles: *const fn (ptr: *anyopaque) u32,
        getHorizontalDetail: *const fn (ptr: *anyopaque, lod: LODLevel) u32,
        getVerticalSpanBudget: *const fn (ptr: *anyopaque) u8,
        getMeshPath: *const fn (ptr: *anyopaque) LODMeshPath,
        getFogStartPercent: *const fn (ptr: *anyopaque, lod: LODLevel) f32,
        getFallbackMissingChildThreshold: *const fn (ptr: *anyopaque) f32,
        getMemoryBudgetMB: *const fn (ptr: *anyopaque) u32,
        getLODStoreSizeCapMB: *const fn (ptr: *anyopaque) u32,
    };

    /// LOD chunk API `getRadii` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getRadii(self: ILODConfig) [LODLevel.count]i32 {
        return self.vtable.getRadii(self.ptr);
    }
    /// LOD chunk API `getChunkRenderRadius` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getChunkRenderRadius(self: ILODConfig) i32 {
        return self.vtable.getChunkRenderRadius(self.ptr);
    }
    /// LOD chunk API `getActiveLODCount` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getActiveLODCount(self: ILODConfig) u32 {
        return self.vtable.getActiveLODCount(self.ptr);
    }
    /// LOD chunk API `setActiveLODCount` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn setActiveLODCount(self: ILODConfig, count: u32) void {
        self.vtable.setActiveLODCount(self.ptr, count);
    }
    /// LOD chunk API `setChunkRenderRadius` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn setChunkRenderRadius(self: ILODConfig, radius: i32) void {
        self.vtable.setChunkRenderRadius(self.ptr, radius);
    }
    /// LOD chunk API `setLOD0Radius` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn setLOD0Radius(self: ILODConfig, radius: i32) void {
        self.vtable.setLOD0Radius(self.ptr, radius);
    }
    /// LOD chunk API `setRadii` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn setRadii(self: ILODConfig, radii: [LODLevel.count]i32) void {
        self.vtable.setRadii(self.ptr, radii);
    }
    /// LOD chunk API `getLODForDistance` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getLODForDistance(self: ILODConfig, dist_chunks: i32) LODLevel {
        return self.vtable.getLODForDistance(self.ptr, dist_chunks);
    }
    /// LOD chunk API `isInRange` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn isInRange(self: ILODConfig, dist_chunks: i32) bool {
        return self.vtable.isInRange(self.ptr, dist_chunks);
    }
    /// LOD chunk API `getMaxUploadsPerFrame` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getMaxUploadsPerFrame(self: ILODConfig) u32 {
        return self.vtable.getMaxUploadsPerFrame(self.ptr);
    }

    /// Calculate the masking radius used by shaders to discard LOD pixels overlapping with high-detail chunks.
    /// This is a pure function based on config state, extracted for testability.
    pub fn calculateMaskRadius(self: ILODConfig) f32 {
        return self.vtable.calculateMaskRadius(self.ptr);
    }

    /// LOD chunk API `getQEMTarget` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getQEMTarget(self: ILODConfig, lod: LODLevel) u32 {
        return self.vtable.getQEMTarget(self.ptr, lod);
    }

    /// LOD chunk API `getQEMMinInputTriangles` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getQEMMinInputTriangles(self: ILODConfig) u32 {
        return self.vtable.getQEMMinInputTriangles(self.ptr);
    }

    /// LOD chunk API `getHorizontalDetail` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getHorizontalDetail(self: ILODConfig, lod: LODLevel) u32 {
        return self.vtable.getHorizontalDetail(self.ptr, lod);
    }

    /// LOD chunk API `getVerticalSpanBudget` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getVerticalSpanBudget(self: ILODConfig) u8 {
        return self.vtable.getVerticalSpanBudget(self.ptr);
    }

    /// LOD chunk API `getMeshPath` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getMeshPath(self: ILODConfig) LODMeshPath {
        return self.vtable.getMeshPath(self.ptr);
    }

    /// LOD chunk API `getFogStartPercent` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getFogStartPercent(self: ILODConfig, lod: LODLevel) f32 {
        return self.vtable.getFogStartPercent(self.ptr, lod);
    }

    /// LOD chunk API `getFallbackMissingChildThreshold` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getFallbackMissingChildThreshold(self: ILODConfig) f32 {
        return self.vtable.getFallbackMissingChildThreshold(self.ptr);
    }

    /// LOD chunk API `getMemoryBudgetMB` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getMemoryBudgetMB(self: ILODConfig) u32 {
        return self.vtable.getMemoryBudgetMB(self.ptr);
    }

    /// LOD chunk API `getLODStoreSizeCapMB` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getLODStoreSizeCapMB(self: ILODConfig) u32 {
        return self.vtable.getLODStoreSizeCapMB(self.ptr);
    }
};

/// LOD chunk API `activeLODCount` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
pub fn activeLODCount(config: ILODConfig) usize {
    return @intCast(std.math.clamp(config.getActiveLODCount(), 1, LODLevel.count));
}

/// Concrete implementation of LOD system configuration.
pub const LODConfig = struct {
    pub const default_chunk_render_radius: i32 = 16;
    pub const default_horizon_radius: i32 = 512;
    pub const target_lod1_radius: i32 = 96; // keep 2-block cells visible farther out.
    pub const target_lod2_radius: i32 = 256;
    pub const target_lod3_radius: i32 = 512;

    /// Radius of real full-detail chunks. LOD0 is a separate 1-block-column
    /// LOD ring that extends beyond this radius.
    chunk_render_radius: i32 = default_chunk_render_radius,

    radii: [LODLevel.count]i32 = .{ 32, target_lod1_radius, target_lod2_radius, target_lod3_radius, default_horizon_radius },

    memory_budget_mb: u32 = 256,

    lod_store_size_cap_mb: u32 = @import("lod_store.zig").DEFAULT_STORE_SIZE_CAP_MB,

    max_uploads_per_frame: u32 = 32,

    fog_transitions: bool = true,

    /// Fog start position as percentage of LOD radius (0.0-1.0) where fog begins.
    /// Values closer to 0.0 start fog near the player; 1.0 disables fog for that level.
    fog_start_percent: [LODLevel.count]f32 = .{ 0.55, 0.48, 0.38, 0.28, 0.22 },

    horizontal_detail: [LODLevel.count]u32 = .{ 33, 65, 65, 129, 129 },

    vertical_span_budget: u8 = 4,

    mesh_path: LODMeshPath = .column_spans,

    qem_triangle_targets: [LODLevel.count]u32 = .{ 0, 2000, 800, 200, 64 },

    qem_min_input_triangles: u32 = 50,

    skip_cutout_lod2: bool = false,

    skip_lighting_lod3: bool = false,

    active_lod_count: u32 = LODLevel.count,

    /// Maximum fraction of direct finer child regions that may be missing before
    /// a coarser parent must remain visible as fallback terrain.
    fallback_missing_child_threshold: f32 = 0.2,

    /// LOD chunk API `getQEMTarget` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getQEMTarget(self: *const LODConfig, lod: LODLevel) u32 {
        return self.qem_triangle_targets[@intFromEnum(lod)];
    }

    /// LOD chunk API `radiiForRenderDistance` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn radiiForRenderDistance(distance: i32) [LODLevel.count]i32 {
        return radiiForDistances(distance, default_horizon_radius);
    }

    /// LOD chunk API `radiiForDistances` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn radiiForDistances(distance: i32, horizon_distance: i32) [LODLevel.count]i32 {
        const requested = @max(distance, 1);
        const lod0_target = @max(@as(i64, requested) * 3, @as(i64, requested + 16));
        const lod0 = @as(i32, @intCast(@min(lod0_target, @as(i64, @max(horizon_distance, requested)))));
        const horizon = @max(horizon_distance, lod0);
        const max_radius_i64 = @as(i64, horizon);
        const lod1_target = @max(@as(i64, lod0) * 2, @as(i64, target_lod1_radius));
        const lod1 = @as(i32, @intCast(@min(lod1_target, max_radius_i64)));
        const lod2_target = @max(@as(i64, lod1) * 2, @as(i64, target_lod2_radius));
        const lod2 = @as(i32, @intCast(@min(lod2_target, max_radius_i64)));
        const lod3_target = @max(@as(i64, lod2) * 2, @as(i64, target_lod3_radius));
        const lod3 = @as(i32, @intCast(@min(lod3_target, max_radius_i64)));
        return .{ lod0, lod1, lod2, lod3, horizon };
    }

    /// LOD chunk API `activeCountForRenderDistance` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn activeCountForRenderDistance(distance: i32) u32 {
        _ = distance;
        return LODLevel.count;
    }

    /// LOD chunk API `coarsestLOD` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn coarsestLOD() LODLevel {
        return @enumFromInt(@as(u3, @intCast(LODLevel.count - 1)));
    }

    /// LOD chunk API `getLODForDistance` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn getLODForDistance(self: *const LODConfig, dist_chunks: i32) LODLevel {
        const active_lod_count = activeLODCount(self.interfaceConst());
        for (0..active_lod_count) |i| {
            if (dist_chunks <= self.radii[i]) return @enumFromInt(@as(u3, @intCast(i)));
        }
        return @enumFromInt(@as(u3, @intCast(active_lod_count - 1)));
    }

    /// LOD chunk API `isInRange` reads or updates one distant-terrain chunk while preserving its generation and mesh lifecycle invariants.
    pub fn isInRange(self: *const LODConfig, dist_chunks: i32) bool {
        return dist_chunks <= self.radii[activeLODCount(self.interfaceConst()) - 1];
    }

    /// Returns the interface for this concrete config.
    pub fn interface(self: *LODConfig) ILODConfig {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn interfaceConst(self: *const LODConfig) ILODConfig {
        return .{
            .ptr = @constCast(self),
            .vtable = &VTABLE,
        };
    }

    const VTABLE = ILODConfig.VTable{
        .getRadii = getRadiiWrapper,
        .getChunkRenderRadius = getChunkRenderRadiusWrapper,
        .getActiveLODCount = getActiveLODCountWrapper,
        .setActiveLODCount = setActiveLODCountWrapper,
        .setChunkRenderRadius = setChunkRenderRadiusWrapper,
        .setLOD0Radius = setLOD0RadiusWrapper,
        .setRadii = setRadiiWrapper,
        .getLODForDistance = getLODForDistanceWrapper,
        .isInRange = isInRangeWrapper,
        .getMaxUploadsPerFrame = getMaxUploadsPerFrameWrapper,
        .calculateMaskRadius = calculateMaskRadiusWrapper,
        .getQEMTarget = getQEMTargetWrapper,
        .getQEMMinInputTriangles = getQEMMinInputTrianglesWrapper,
        .getHorizontalDetail = getHorizontalDetailWrapper,
        .getVerticalSpanBudget = getVerticalSpanBudgetWrapper,
        .getMeshPath = getMeshPathWrapper,
        .getFogStartPercent = getFogStartPercentWrapper,
        .getFallbackMissingChildThreshold = getFallbackMissingChildThresholdWrapper,
        .getMemoryBudgetMB = getMemoryBudgetMBWrapper,
        .getLODStoreSizeCapMB = getLODStoreSizeCapMBWrapper,
    };

    fn getRadiiWrapper(ptr: *anyopaque) [LODLevel.count]i32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.radii;
    }
    fn getChunkRenderRadiusWrapper(ptr: *anyopaque) i32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.chunk_render_radius;
    }
    fn getActiveLODCountWrapper(ptr: *anyopaque) u32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return std.math.clamp(self.active_lod_count, 1, LODLevel.count);
    }
    fn setActiveLODCountWrapper(ptr: *anyopaque, count: u32) void {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        self.active_lod_count = std.math.clamp(count, 1, LODLevel.count);
    }
    fn setChunkRenderRadiusWrapper(ptr: *anyopaque, radius: i32) void {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        self.chunk_render_radius = @max(radius, 1);
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
        const overlap_chunks = @max(self.chunk_render_radius - 2, 0);
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
    fn getHorizontalDetailWrapper(ptr: *anyopaque, lod: LODLevel) u32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.horizontal_detail[@intFromEnum(lod)];
    }
    fn getVerticalSpanBudgetWrapper(ptr: *anyopaque) u8 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return @min(self.vertical_span_budget, @as(u8, @intCast(world_core.MAX_LOD_VERTICAL_SPANS)));
    }
    fn getMeshPathWrapper(ptr: *anyopaque) LODMeshPath {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.mesh_path;
    }
    fn getFogStartPercentWrapper(ptr: *anyopaque, lod: LODLevel) f32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.fog_start_percent[@intFromEnum(lod)];
    }
    fn getFallbackMissingChildThresholdWrapper(ptr: *anyopaque) f32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return std.math.clamp(self.fallback_missing_child_threshold, 0.0, 1.0);
    }
    fn getMemoryBudgetMBWrapper(ptr: *anyopaque) u32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.memory_budget_mb;
    }
    fn getLODStoreSizeCapMBWrapper(ptr: *anyopaque) u32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.lod_store_size_cap_mb;
    }
};

// Tests
test "LODLevel scale calculations" {
    try std.testing.expectEqual(@as(u32, 1), LODLevel.lod0.scale());
    try std.testing.expectEqual(@as(u32, 2), LODLevel.lod1.scale());
    try std.testing.expectEqual(@as(u32, 4), LODLevel.lod2.scale());
    try std.testing.expectEqual(@as(u32, 8), LODLevel.lod3.scale());
    try std.testing.expectEqual(@as(u32, 16), LODLevel.lod4.scale());

    try std.testing.expectEqual(@as(u32, 4), LODLevel.lod0.totalChunks());
    try std.testing.expectEqual(@as(u32, 16), LODLevel.lod1.totalChunks());
    try std.testing.expectEqual(@as(u32, 64), LODLevel.lod2.totalChunks());
    try std.testing.expectEqual(@as(u32, 256), LODLevel.lod3.totalChunks());
    try std.testing.expectEqual(@as(u32, 1024), LODLevel.lod4.totalChunks());
}

test "LODRegionKey from chunk coords" {
    const key1 = LODRegionKey.fromChunkCoords(5, 7, .lod1);
    try std.testing.expectEqual(@as(i32, 1), key1.rx); // 5 / 4 = 1
    try std.testing.expectEqual(@as(i32, 1), key1.rz); // 7 / 4 = 1

    const key2 = LODRegionKey.fromChunkCoords(-3, -5, .lod2);
    try std.testing.expectEqual(@as(i32, -1), key2.rx); // -3 / 8 = -1
    try std.testing.expectEqual(@as(i32, -1), key2.rz); // -5 / 8 = -1
}

test "LODRegionKey parent and child keys handle negative coordinates" {
    const child = LODRegionKey{ .rx = -1, .rz = -3, .lod = .lod1 };
    const parent = child.parentKey().?;
    try std.testing.expectEqual(LODRegionKey{ .rx = -1, .rz = -2, .lod = .lod2 }, parent);

    const children = parent.childKeys().?;
    try std.testing.expectEqual(LODRegionKey{ .rx = -2, .rz = -4, .lod = .lod1 }, children[0]);
    try std.testing.expectEqual(LODRegionKey{ .rx = -1, .rz = -4, .lod = .lod1 }, children[1]);
    try std.testing.expectEqual(LODRegionKey{ .rx = -2, .rz = -3, .lod = .lod1 }, children[2]);
    try std.testing.expectEqual(LODRegionKey{ .rx = -1, .rz = -3, .lod = .lod1 }, children[3]);
}

test "LODConfig distance calculation" {
    const config = LODConfig{};
    try std.testing.expectEqual(LODLevel.lod0, config.getLODForDistance(10));
    try std.testing.expectEqual(LODLevel.lod0, config.getLODForDistance(20));
    try std.testing.expectEqual(LODLevel.lod1, config.getLODForDistance(50));
    try std.testing.expectEqual(LODLevel.lod2, config.getLODForDistance(100));
}

test "LODConfig distance calculation respects active LOD count" {
    const config = LODConfig{
        .radii = .{ 16, 32, 64, 128, 256 },
        .active_lod_count = 2,
    };

    try std.testing.expectEqual(LODLevel.lod0, config.getLODForDistance(10));
    try std.testing.expectEqual(LODLevel.lod1, config.getLODForDistance(20));
    try std.testing.expectEqual(LODLevel.lod1, config.getLODForDistance(100));
    try std.testing.expect(!config.isInRange(100));
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
    try std.testing.expectEqual(@as(u32, LODLevel.count), LODConfig.activeCountForRenderDistance(8));
    try std.testing.expectEqual(@as(u32, LODLevel.count), LODConfig.activeCountForRenderDistance(32));

    const low_radii = LODConfig.radiiForRenderDistance(8);
    try std.testing.expectEqual(@as(i32, 24), low_radii[0]);
    try std.testing.expectEqual(@as(i32, 96), low_radii[1]);
    try std.testing.expectEqual(@as(i32, 256), low_radii[2]);
    try std.testing.expectEqual(@as(i32, 512), low_radii[3]);
    try std.testing.expectEqual(@as(i32, 512), low_radii[4]);

    const radii = LODConfig.radiiForRenderDistance(32);
    try std.testing.expectEqual(@as(i32, 96), radii[0]);
    try std.testing.expectEqual(@as(i32, 192), radii[1]);
    try std.testing.expectEqual(@as(i32, 384), radii[2]);
    try std.testing.expectEqual(@as(i32, 512), radii[3]);
    try std.testing.expectEqual(@as(i32, 512), radii[4]);

    const custom_horizon = LODConfig.radiiForDistances(12, 1024);
    try std.testing.expectEqual(@as(i32, 36), custom_horizon[0]);
    try std.testing.expectEqual(@as(i32, 96), custom_horizon[1]);
    try std.testing.expectEqual(@as(i32, 256), custom_horizon[2]);
    try std.testing.expectEqual(@as(i32, 512), custom_horizon[3]);
    try std.testing.expectEqual(@as(i32, 1024), custom_horizon[4]);
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
        .chunk_render_radius = 16,
        .radii = .{ 16, 40, 80, 160, 512 },
    };
    const interface = config.interface();
    try std.testing.expectEqual(@as(f32, 224.0), interface.calculateMaskRadius());

    config.chunk_render_radius = 32;
    try std.testing.expectEqual(@as(f32, 480.0), interface.calculateMaskRadius());
}

test "ILODConfig exposes fallback missing child threshold" {
    var config = LODConfig{ .fallback_missing_child_threshold = 0.2 };
    var interface = config.interface();
    try std.testing.expectEqual(@as(f32, 0.2), interface.getFallbackMissingChildThreshold());

    config.fallback_missing_child_threshold = -1.0;
    try std.testing.expectEqual(@as(f32, 0.0), interface.getFallbackMissingChildThreshold());

    config.fallback_missing_child_threshold = 2.0;
    try std.testing.expectEqual(@as(f32, 1.0), interface.getFallbackMissingChildThreshold());
}

test "ILODConfig exposes LOD quality tuning controls" {
    var config = LODConfig{
        .horizontal_detail = .{ 16, 24, 32, 40, 24 },
        .vertical_span_budget = 99,
        .mesh_path = .qem,
    };
    const interface = config.interface();

    try std.testing.expectEqual(@as(u32, 32), interface.getHorizontalDetail(.lod2));
    try std.testing.expectEqual(@as(u8, world_core.MAX_LOD_VERTICAL_SPANS), interface.getVerticalSpanBudget());
    try std.testing.expectEqual(LODMeshPath.qem, interface.getMeshPath());
}
