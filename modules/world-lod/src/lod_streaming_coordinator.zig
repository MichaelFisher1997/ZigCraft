//! LOD and predictive-loading coordination for the world streamer.

const std = @import("std");
const Vec3 = @import("engine-math").Vec3;
const ChunkStorage = @import("world-meshing").ChunkStorage;
const JobQueue = @import("engine-core").JobQueue;
const LODManager = @import("lod_manager.zig").LODManager;
const worldToChunkFromFloat = @import("world-core").worldToChunkFromFloat;
const log = @import("engine-core").log;

/// Player movement tracking for predictive chunk loading.
pub const PlayerMovement = struct {
    /// Normalized movement direction (0,0 if stationary)
    dir_x: f32 = 0,
    dir_z: f32 = 0,
    /// Speed in blocks/second
    speed: f32 = 0,
    /// Last position for velocity calculation
    last_pos: Vec3 = Vec3.init(0, 0, 0),
    /// Whether we have valid velocity data
    has_velocity: bool = false,

    /// Update with new position, returns true if direction changed significantly.
    pub fn update(self: *PlayerMovement, pos: Vec3, dt: f32) bool {
        if (dt <= 0.001) return false;

        const dx = pos.x - self.last_pos.x;
        const dz = pos.z - self.last_pos.z;
        self.last_pos = pos;

        const dist = @sqrt(dx * dx + dz * dz);
        self.speed = dist / dt;

        if (self.speed < 2.0) {
            self.has_velocity = false;
            return false;
        }

        const old_dx = self.dir_x;
        const old_dz = self.dir_z;

        self.dir_x = dx / dist;
        self.dir_z = dz / dist;
        self.has_velocity = true;

        const dot = old_dx * self.dir_x + old_dz * self.dir_z;
        return dot < 0.707;
    }

    /// Calculate priority weight for a chunk based on movement direction.
    pub fn priorityWeight(self: *const PlayerMovement, chunk_dx: i32, chunk_dz: i32) f32 {
        if (!self.has_velocity) return 1.0;

        const cdx: f32 = @floatFromInt(chunk_dx);
        const cdz: f32 = @floatFromInt(chunk_dz);
        const dist = @sqrt(cdx * cdx + cdz * cdz);
        if (dist < 0.001) return 0.5;

        const dot = (cdx * self.dir_x + cdz * self.dir_z) / dist;
        return 1.0 - dot * 0.5;
    }
};

pub const StreamingFrame = struct {
    pc_x: i32,
    pc_z: i32,
    moved: bool,
    target_render_dist: i32,
    render_dist: i32,
};

pub const QueueStats = struct {
    gen_queue: usize,
    mesh_queue: usize,
    upload_queue: usize,
};

pub const LODStreamingCoordinator = struct {
    lod_manager: ?*LODManager = null,
    player_movement: PlayerMovement = .{},
    last_pc: struct { x: i32, z: i32 } = .{ .x = 9999, .z = 9999 },
    render_distance: i32,
    effective_render_dist: i32 = 0,
    startup_stream_radius: i32 = 0,
    startup_mesh_finalized: bool = false,

    const STARTUP_RADIUS_INITIAL = 3;
    const STARTUP_RADIUS_STEP = 2;

    pub fn init(render_distance: i32) LODStreamingCoordinator {
        return .{
            .render_distance = render_distance,
            .startup_stream_radius = @min(render_distance, STARTUP_RADIUS_INITIAL),
        };
    }

    pub fn setRenderDistance(self: *LODStreamingCoordinator, distance: i32) bool {
        if (self.render_distance == distance) return false;

        self.render_distance = distance;
        self.startup_stream_radius = @min(distance, STARTUP_RADIUS_INITIAL);
        self.effective_render_dist = 0;
        self.startup_mesh_finalized = false;
        self.forceRescan();
        return true;
    }

    pub fn setLODManager(self: *LODStreamingCoordinator, lod_manager: ?*LODManager) void {
        self.lod_manager = lod_manager;
        if (lod_manager != null) {
            self.startup_stream_radius = @min(self.render_distance, STARTUP_RADIUS_INITIAL);
            self.effective_render_dist = 0;
        }
    }

    pub fn forceRescan(self: *LODStreamingCoordinator) void {
        self.last_pc = .{ .x = 9999, .z = 9999 };
    }

    pub fn getActiveRenderDistance(self: *const LODStreamingCoordinator) i32 {
        return if (self.effective_render_dist > 0) self.effective_render_dist else self.render_distance;
    }

    pub fn targetRenderDistance(self: *const LODStreamingCoordinator) i32 {
        return if (self.lod_manager) |mgr| @min(self.render_distance, mgr.config.getChunkRenderRadius()) else self.render_distance;
    }

    pub fn beginFrame(self: *LODStreamingCoordinator, storage: *ChunkStorage, gen_queue: *JobQueue, mesh_queue: *JobQueue, player_pos: Vec3, dt: f32, frame_counter: u64) StreamingFrame {
        _ = self.player_movement.update(player_pos, dt);

        const pc = worldToChunkFromFloat(player_pos.x, player_pos.z);
        const moved = pc.chunk_x != self.last_pc.x or pc.chunk_z != self.last_pc.z;
        const target_render_dist = self.targetRenderDistance();

        self.updateStartupRadius(storage, pc.chunk_x, pc.chunk_z, target_render_dist, frame_counter);
        const render_dist = if (self.startup_stream_radius > 0) self.startup_stream_radius else target_render_dist;
        self.effective_render_dist = render_dist;

        if (moved) {
            self.last_pc = .{ .x = pc.chunk_x, .z = pc.chunk_z };
            gen_queue.updatePlayerPos(pc.chunk_x, pc.chunk_z) catch {};
            mesh_queue.updatePlayerPos(pc.chunk_x, pc.chunk_z) catch {};
        }

        return .{
            .pc_x = pc.chunk_x,
            .pc_z = pc.chunk_z,
            .moved = moved,
            .target_render_dist = target_render_dist,
            .render_dist = render_dist,
        };
    }

    pub fn updateLOD(self: *LODStreamingCoordinator, player_pos: Vec3, storage: *ChunkStorage) void {
        const lod_mgr = self.lod_manager orelse return;
        const velocity = Vec3.init(
            self.player_movement.dir_x * self.player_movement.speed,
            0,
            self.player_movement.dir_z * self.player_movement.speed,
        );
        lod_mgr.update(player_pos, velocity, ChunkStorage.isChunkRenderable, storage) catch |err| {
            log.log.warn("LOD update error (non-fatal): {}", .{err});
        };
    }

    pub fn isStartupBusy(self: *const LODStreamingCoordinator, stats: QueueStats, target_render_dist: i32) bool {
        const startup_target = if (self.lod_manager) |mgr|
            @min(target_render_dist, mgr.config.getChunkRenderRadius())
        else
            target_render_dist;

        if (self.getActiveRenderDistance() < startup_target) return true;
        return stats.gen_queue > 0 or stats.mesh_queue > 0 or stats.upload_queue > 0;
    }

    fn updateStartupRadius(self: *LODStreamingCoordinator, storage: *ChunkStorage, pc_x: i32, pc_z: i32, target_render_dist: i32, frame_counter: u64) void {
        if (target_render_dist <= 0) {
            self.startup_stream_radius = 0;
            return;
        }

        if (self.startup_stream_radius <= 0) {
            self.startup_stream_radius = @min(target_render_dist, STARTUP_RADIUS_INITIAL);
            return;
        }

        if (self.startup_stream_radius >= target_render_dist) {
            self.startup_stream_radius = target_render_dist;
            return;
        }

        if (frame_counter % 30 != 0) return;

        var total_in_radius: u32 = 0;
        var ready_in_radius: u32 = 0;

        storage.chunks_mutex.lockShared();
        defer storage.chunks_mutex.unlockShared();

        var cz = pc_z - self.startup_stream_radius;
        while (cz <= pc_z + self.startup_stream_radius) : (cz += 1) {
            var cx = pc_x - self.startup_stream_radius;
            while (cx <= pc_x + self.startup_stream_radius) : (cx += 1) {
                const dx = cx - pc_x;
                const dz = cz - pc_z;
                if (dx * dx + dz * dz > self.startup_stream_radius * self.startup_stream_radius) continue;

                total_in_radius += 1;
                if (storage.chunks.get(.{ .x = cx, .z = cz })) |data| {
                    if (data.chunk.state == .renderable or data.render.mesh.solid_allocation != null or data.render.mesh.cutout_allocation != null or data.render.mesh.fluid_allocation != null) {
                        ready_in_radius += 1;
                    }
                }
            }
        }

        if (total_in_radius == 0) return;
        if (ready_in_radius * 100 < total_in_radius * 85) return;

        self.startup_stream_radius = @min(target_render_dist, self.startup_stream_radius + STARTUP_RADIUS_STEP);
        log.log.info("STARTUP_STREAM_RADIUS: expanded to {} / {}", .{ self.startup_stream_radius, target_render_dist });
    }
};
