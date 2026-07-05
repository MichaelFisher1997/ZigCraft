//! WorldLOD - Unified LOD subsystem combining LODManager and LODRenderer.
//!
//! This struct encapsulates the entire LOD system lifecycle, simplifying
//! World's LOD handling from two separate fields to a single unified interface.
//!
//! ## Architecture
//!
//! ```
//! WorldLOD
//!   ├── LODRenderer (GPU draw resources, instance buffers)
//!   └── LODManager (chunk generation, meshing, state management)
//!        └── LODGPUBridge → callbacks to LODRenderer's RHI
//! ```
//!
//! The renderer owns GPU buffers and provides callback interfaces.
//! The manager orchestrates LOD chunk lifecycle using those interfaces.

const std = @import("std");
const lod_chunk = @import("lod_chunk.zig");
const ILODConfig = lod_chunk.ILODConfig;
const LODLevel = lod_chunk.LODLevel;

const LODManager = @import("lod_manager.zig").LODManager;
const LODStats = @import("lod_manager.zig").LODStats;
const lod_gpu = @import("lod_upload_queue.zig");
const ChunkChecker = lod_gpu.ChunkChecker;
const LODRenderLayer = lod_gpu.LODRenderLayer;
const MeshMap = lod_gpu.MeshMap;
const RegionMap = lod_gpu.RegionMap;

const math = @import("engine-math");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const LODGenerator = @import("lod_generator.zig").LODGenerator;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const log = @import("engine-core").log;

pub fn WorldLOD(comptime RHI: type) type {
    const LODRenderer = @import("lod_renderer.zig").LODRenderer(RHI);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        manager: *LODManager,
        renderer: *LODRenderer,

        pub fn init(
            allocator: std.mem.Allocator,
            rhi: RHI,
            config: ILODConfig,
            generator: LODGenerator,
            atlas: *const TextureAtlas,
        ) !*Self {
            const renderer = try LODRenderer.init(allocator, rhi);
            errdefer renderer.deinit();

            const gpu_bridge = renderer.createGPUBridge();
            const render_iface = renderer.toInterface();

            const manager = try LODManager.init(allocator, config, gpu_bridge, render_iface, generator, atlas);
            errdefer manager.deinit();

            const lod = try allocator.create(Self);
            lod.* = .{
                .allocator = allocator,
                .manager = manager,
                .renderer = renderer,
            };

            const radii = config.getRadii();
            log.log.info("WorldLOD initialized (horizon radius: {} chunks)", .{radii[LODLevel.count - 1]});

            return lod;
        }

        pub fn deinit(self: *Self) void {
            self.manager.deinit();
            self.renderer.deinit();
            self.allocator.destroy(self);
        }

        pub fn pause(self: *Self) void {
            self.manager.pause();
        }

        pub fn unpause(self: *Self) void {
            self.manager.unpause();
        }

        pub fn enableCache(self: *Self, save_dir_path: []const u8) !void {
            try self.manager.enableCache(save_dir_path);
        }

        pub fn update(
            self: *Self,
            player_pos: Vec3,
            player_velocity: Vec3,
            chunk_checker: ?ChunkChecker,
            checker_ctx: ?*anyopaque,
        ) !void {
            try self.manager.update(player_pos, player_velocity, chunk_checker, checker_ctx);
        }

        pub fn render(
            self: *Self,
            view_proj: Mat4,
            camera_pos: Vec3,
            chunk_checker: ?ChunkChecker,
            checker_ctx: ?*anyopaque,
            use_frustum: bool,
            layer: LODRenderLayer,
        ) void {
            self.manager.render(view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, null, layer);
        }

        pub fn setLOD0Radius(self: *Self, radius: i32) void {
            self.manager.mutex.lock();
            defer self.manager.mutex.unlock();
            self.manager.config.setLOD0Radius(radius);
            log.log.info("LOD0 radius updated: {}", .{radius});
        }

        pub fn setChunkRenderRadius(self: *Self, radius: i32) void {
            self.manager.mutex.lock();
            defer self.manager.mutex.unlock();
            self.manager.config.setChunkRenderRadius(radius);
            log.log.info("Chunk render radius updated: {}", .{radius});
        }

        pub fn setRadii(self: *Self, radii: [LODLevel.count]i32) void {
            self.manager.mutex.lock();
            defer self.manager.mutex.unlock();
            self.manager.config.setRadii(radii);
            log.log.info("LOD radii updated: {any}", .{radii});
        }

        pub fn setActiveLODCount(self: *Self, count: u32) void {
            self.manager.mutex.lock();
            defer self.manager.mutex.unlock();
            self.manager.config.setActiveLODCount(count);
            log.log.info("Active LOD count updated: {}", .{self.manager.config.getActiveLODCount()});
        }

        pub fn getStats(self: *const Self) LODStats {
            return self.manager.getStats();
        }

        pub fn isInRange(self: *const Self, chunk_x: i32, chunk_z: i32) bool {
            return self.manager.isInRange(chunk_x, chunk_z);
        }

        pub fn getLODForDistance(self: *const Self, chunk_x: i32, chunk_z: i32) LODLevel {
            return self.manager.getLODForDistance(chunk_x, chunk_z);
        }

        pub fn getRadii(self: *const Self) [LODLevel.count]i32 {
            self.manager.mutex.lockShared();
            defer self.manager.mutex.unlockShared();
            return self.manager.config.getRadii();
        }
    };
}
