//! Runtime diagnostics used by the world renderer CPU cull path.

const std = @import("std");
const log = @import("engine-core").log;
const runtime_env = @import("engine-core").runtime_env;
const ChunkData = @import("world-meshing").ChunkData;
const ChunkStorage = @import("world-meshing").ChunkStorage;

pub const CpuCullDiagnostics = struct {
    diag_min_x: i32 = 0,
    diag_min_z: i32 = 0,
    diag_max_x: i32 = 0,
    diag_max_z: i32 = 0,
    diag_region_enabled: bool = false,
    not_renderable: u32 = 0,
    not_in_storage: u32 = 0,
    missing_in_circle: u32 = 0,
    missing_cx: i32 = 0,
    missing_cz: i32 = 0,
    frustum_culled: u32 = 0,
    visible_no_mesh: u32 = 0,
    visible_zero_verts: u32 = 0,
    first_no_mesh_cx: i32 = 0,
    first_no_mesh_cz: i32 = 0,
    first_zero_verts_cx: i32 = 0,
    first_zero_verts_cz: i32 = 0,

    pub fn init() CpuCullDiagnostics {
        var diagnostics = CpuCullDiagnostics{};
        if (runtime_env.getenv("ZIGCRAFT_DIAGNOSE_REGION")) |region_str| {
            var parts = std.mem.splitScalar(u8, region_str, ',');
            if (parts.next()) |x1| diagnostics.diag_min_x = std.fmt.parseInt(i32, x1, 10) catch 0;
            if (parts.next()) |z1| diagnostics.diag_min_z = std.fmt.parseInt(i32, z1, 10) catch 0;
            if (parts.next()) |x2| diagnostics.diag_max_x = std.fmt.parseInt(i32, x2, 10) catch 0;
            if (parts.next()) |z2| diagnostics.diag_max_z = std.fmt.parseInt(i32, z2, 10) catch 0;
            diagnostics.diag_region_enabled = true;
        }
        return diagnostics;
    }

    pub fn recordVisible(self: *CpuCullDiagnostics, cx: i64, cz: i64, data: *ChunkData) void {
        if (self.diag_region_enabled and cx >= self.diag_min_x and cx <= self.diag_max_x and cz >= self.diag_min_z and cz <= self.diag_max_z) {
            var block_type_counts = std.mem.zeroes([256]u32);
            for (data.chunk.blocks) |block| {
                block_type_counts[@intFromEnum(block)] += 1;
            }
            var buf: [4096]u8 = undefined;
            var len: usize = 0;
            for (block_type_counts, 0..) |count, i| {
                if (count > 0 and len < buf.len - 30) {
                    const written = std.fmt.bufPrint(buf[len..], "{}:{},", .{ i, count }) catch unreachable;
                    len += written.len;
                }
            }
            log.log.warn("DIAGNOSE_CHUNK ({},{}): block_counts=[{s}] verts={}", .{
                cx, cz, buf[0..len],
                (if (data.render.mesh.solid_allocation) |a| a.count else 0) +
                    (if (data.render.mesh.cutout_allocation) |a| a.count else 0) +
                    (if (data.render.mesh.fluid_allocation) |a| a.count else 0),
            });
        }

        if (data.render.mesh.solid_allocation == null and data.render.mesh.cutout_allocation == null and data.render.mesh.fluid_allocation == null) {
            self.visible_no_mesh += 1;
            if (self.visible_no_mesh == 1) {
                self.first_no_mesh_cx = @intCast(cx);
                self.first_no_mesh_cz = @intCast(cz);
            }
        } else {
            const solid_verts = if (data.render.mesh.solid_allocation) |a| a.count else 0;
            const cutout_verts = if (data.render.mesh.cutout_allocation) |a| a.count else 0;
            const fluid_verts = if (data.render.mesh.fluid_allocation) |a| a.count else 0;
            if (solid_verts + cutout_verts + fluid_verts == 0) {
                self.visible_zero_verts += 1;
                if (self.visible_zero_verts == 1) {
                    self.first_zero_verts_cx = @intCast(cx);
                    self.first_zero_verts_cz = @intCast(cz);
                }
            }
        }
    }

    pub fn recordFrustumCulled(self: *CpuCullDiagnostics) void {
        self.frustum_culled += 1;
    }

    pub fn recordNotRenderable(self: *CpuCullDiagnostics, cx: i64, cz: i64, dist_sq: i64, r_dist: i64) void {
        self.not_renderable += 1;
        self.recordMissingIfInCircle(cx, cz, dist_sq, r_dist);
    }

    pub fn recordNotInStorage(self: *CpuCullDiagnostics, cx: i64, cz: i64, dist_sq: i64, r_dist: i64) void {
        self.recordMissingIfInCircle(cx, cz, dist_sq, r_dist);
        self.not_in_storage += 1;
    }

    pub fn logFrame(self: CpuCullDiagnostics, storage: *ChunkStorage, visible_count: usize, pc_x: i64, pc_z: i64, r_dist: i64, render_frame_count: u64, startup_diagnostic_seconds: u32) void {
        if (startup_diagnostic_seconds == 0 and self.missing_in_circle > 0 and render_frame_count % 60 == 0) {
            if (storage.chunks.get(.{ .x = self.missing_cx, .z = self.missing_cz })) |d| {
                log.log.debug("CPU_CULL_GAP: missing_in_circle={} last_missing=({},{}) state={} has_alloc={} pc=({},{}) rd={}", .{
                    self.missing_in_circle,      self.missing_cx,                                                                                                             self.missing_cz,
                    @intFromEnum(d.chunk.state), d.render.mesh.solid_allocation != null or d.render.mesh.cutout_allocation != null or d.render.mesh.fluid_allocation != null, pc_x,
                    pc_z,                        r_dist,
                });
            } else {
                log.log.debug("CPU_CULL_GAP: missing_in_circle={} last_missing=({},{}) NOT_IN_STORAGE pc=({},{}) rd={}", .{
                    self.missing_in_circle, self.missing_cx, self.missing_cz, pc_x, pc_z, r_dist,
                });
            }
        }

        if (startup_diagnostic_seconds == 0 and render_frame_count % 300 == 0) {
            log.log.info("CPU_CULL: visible={} with_mesh={} no_mesh={} zero_verts={} frustum_culled={} not_renderable={} not_in_storage={} missing_circle={}", .{
                visible_count,
                visible_count - @as(usize, self.visible_no_mesh),
                self.visible_no_mesh,
                self.visible_zero_verts,
                self.frustum_culled,
                self.not_renderable,
                self.not_in_storage,
                self.missing_in_circle,
            });
            if (self.visible_no_mesh > 0) {
                log.log.warn("  {} visible chunks have NO mesh data! first=({},{})", .{ self.visible_no_mesh, self.first_no_mesh_cx, self.first_no_mesh_cz });
            }
            if (self.visible_zero_verts > 0) {
                log.log.warn("  {} visible chunks have ZERO vertices! first=({},{})", .{ self.visible_zero_verts, self.first_zero_verts_cx, self.first_zero_verts_cz });
            }

            self.logBoundaryChunks(storage, pc_x, pc_z, r_dist);
        }
    }

    fn recordMissingIfInCircle(self: *CpuCullDiagnostics, cx: i64, cz: i64, dist_sq: i64, r_dist: i64) void {
        if (dist_sq <= r_dist * r_dist) {
            self.missing_in_circle += 1;
            self.missing_cx = @intCast(cx);
            self.missing_cz = @intCast(cz);
        }
    }

    fn logBoundaryChunks(self: CpuCullDiagnostics, storage: *ChunkStorage, pc_x: i64, pc_z: i64, r_dist: i64) void {
        _ = self;
        var boundary_renderable: u32 = 0;
        var boundary_missing: u32 = 0;
        var boundary_buf: [4096]u8 = undefined;
        var boundary_len: usize = 0;
        var bz: i64 = pc_z - r_dist;
        while (bz <= pc_z + r_dist) : (bz += 1) {
            var bx: i64 = pc_x - r_dist;
            while (bx <= pc_x + r_dist) : (bx += 1) {
                const bdx = bx - pc_x;
                const bdz = bz - pc_z;
                const bdist = bdx * bdx + bdz * bdz;
                if (bdist >= (r_dist - 1) * (r_dist - 1) and bdist <= r_dist * r_dist) {
                    if (storage.chunks.get(.{ .x = @as(i32, @intCast(bx)), .z = @as(i32, @intCast(bz)) })) |data| {
                        if (data.render.mesh.solid_allocation != null or data.render.mesh.cutout_allocation != null or data.render.mesh.fluid_allocation != null) {
                            boundary_renderable += 1;
                        } else {
                            boundary_missing += 1;
                            if (boundary_len < boundary_buf.len - 20) {
                                const written = std.fmt.bufPrint(boundary_buf[boundary_len..], "({},{}) ", .{ bx, bz }) catch unreachable;
                                boundary_len += written.len;
                            }
                        }
                    } else {
                        boundary_missing += 1;
                        if (boundary_len < boundary_buf.len - 20) {
                            const written = std.fmt.bufPrint(boundary_buf[boundary_len..], "({},{})! ", .{ bx, bz }) catch unreachable;
                            boundary_len += written.len;
                        }
                    }
                }
            }
        }
        if (boundary_missing > 0) {
            log.log.warn("  BOUNDARY: {}/{} boundary chunks have NO mesh. Missing: {s}", .{ boundary_missing, boundary_renderable + boundary_missing, boundary_buf[0..boundary_len] });
        }
    }
};
