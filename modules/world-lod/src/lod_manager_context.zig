const std = @import("std");
const engine_core = @import("engine-core");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODRegionKey = lod_chunk.LODRegionKey;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const LODColumnProvenance = world_core.LODColumnProvenance;

pub const ChunkCoordKey = struct {
    cx: i32,
    cz: i32,

    pub fn hash(self: ChunkCoordKey) u64 {
        const ux: u64 = @bitCast(@as(i64, self.cx));
        const uz: u64 = @bitCast(@as(i64, self.cz));
        return ux ^ (uz *% 0x9e3779b97f4a7c15);
    }
    pub fn eql(a: ChunkCoordKey, b: ChunkCoordKey) bool {
        return a.cx == b.cx and a.cz == b.cz;
    }
};

pub const ChunkCoordKeyContext = struct {
    pub fn hash(self: @This(), key: ChunkCoordKey) u64 {
        _ = self;
        return key.hash();
    }
    pub fn eql(self: @This(), a: ChunkCoordKey, b: ChunkCoordKey) bool {
        _ = self;
        return a.eql(b);
    }
};

pub const PendingIngestion = struct {
    cx: i32,
    cz: i32,
    provenance: LODColumnProvenance,
    pending_levels: u8,
    ttl: u16,
};

pub const GenerationCandidate = struct {
    key: LODRegionKey,
    chunk: *LODChunk,
    encoded_priority: i32,
    level: u3,
    coord_scale: i32,
    job_token: u32,
    lod_radius: i32,
    want_spans: bool,
};

pub const MeshCandidate = struct {
    chunk: *LODChunk,
    encoded_priority: i32,
    level: u3,
    coord_scale: i32,
    job_token: u32,
    lod_radius: i32,
};

pub const UploadCandidate = struct {
    chunk: *LODChunk,
    encoded_priority: i32,
    level: u3,
};

pub const PlayerChunkPos = struct {
    cx: i32,
    cz: i32,
};

pub const ChunkResolver = struct {
    ptr: *anyopaque,
    resolve_fn: *const fn (ptr: *anyopaque, cx: i32, cz: i32) ?*const Chunk,

    pub fn resolve(self: ChunkResolver, cx: i32, cz: i32) ?*const Chunk {
        return self.resolve_fn(self.ptr, cx, cz);
    }
};

pub const MAX_LOD_REGIONS = 2048;
// Bound queued and in-flight regions so a cold cache cannot bury the horizon
// fallback behind thousands of expensive generation jobs.
pub const MAX_PENDING_LOD_REGIONS: usize = 64;
pub const CHUNK_COVERAGE_PADDING: i32 = 1;
pub const LOD_UPDATE_DIVISOR: u32 = 2;
// WorldStreamer reserves these workers from its foreground pools whenever LOD
// is enabled, so horizon generation can be fast without oversubscribing CPUs.
pub const MIN_LOD_WORKERS: usize = 2;
pub const MAX_LOD_WORKERS: usize = 6;
pub const MAX_MEMORY_EVICTIONS_PER_UPDATE: usize = 32;
pub const MAX_MESH_DELETIONS_PER_SWEEP: usize = 64;
pub const DELETION_SWEEP_SECONDS: f32 = 1.0;
pub const DEFAULT_LOD_UPLOAD_BUDGET_BYTES: usize = 32 * 1024 * 1024;
pub const LOD_UPLOAD_BUDGET_ENV = "ZIGCRAFT_LOD_UPLOAD_BUDGET_MB";
pub const MAX_CACHE_LOADS_PER_UPDATE: usize = 8;
pub const MAX_PENDING_INGESTIONS: usize = 4096;
pub const PENDING_INGESTION_TTL: u16 = 240;
pub const EDIT_FLUSH_COOLDOWN: f32 = 1.0;
pub const LOD_FRAME_DT_APPROX: f32 = 0.016;

pub fn lodUploadBudgetBytes() usize {
    const raw = engine_core.getenv(LOD_UPLOAD_BUDGET_ENV) orelse return DEFAULT_LOD_UPLOAD_BUDGET_BYTES;
    const mb = std.fmt.parseUnsigned(usize, raw, 10) catch return DEFAULT_LOD_UPLOAD_BUDGET_BYTES;
    if (mb == 0) return std.math.maxInt(usize);
    return std.math.mul(usize, mb, 1024 * 1024) catch DEFAULT_LOD_UPLOAD_BUDGET_BYTES;
}

pub fn wouldExceedUploadBudget(uploaded_bytes: usize, pending_bytes: usize, budget_bytes: usize) bool {
    if (budget_bytes == 0 or budget_bytes == std.math.maxInt(usize)) return false;
    if (pending_bytes == 0) return false;
    if (uploaded_bytes >= budget_bytes) return true;
    return pending_bytes > budget_bytes - uploaded_bytes;
}

pub fn isUploadPressureError(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory, error.PendingCopyOverflow => true,
        else => false,
    };
}

comptime {
    if (LODLevel.count < 2) {
        @compileError("LOD system requires at least two levels (LOD0 and at least one simplified level)");
    }
}
