//! Quadric-based mesh simplification for LOD terrain.
//!
//! Implements the Quadric Error Metrics (QEM) algorithm (Garland & Heckbert, 1997)
//! for mesh simplification. Iteratively collapses edges based on quadric error cost
//! to produce simplified meshes that preserve silhouettes and geometric features
//! better than uniform downsampling.
//!
//! Memory ownership: All slices returned in `SimplifiedMesh` are owned by the caller
//! and must be freed with the same allocator passed to `simplify()`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const rhi_types = @import("../../engine/graphics/rhi_types.zig");
const Vertex = rhi_types.Vertex;

pub const SimplifiedMesh = struct {
    vertices: []Vertex,
    indices: []u32,
    original_triangle_count: u32,
    simplified_triangle_count: u32,
    error_estimate: f64,
    skipped_collapses: u32,
};

const QuadricMatrix = struct {
    m: [10]f64 = [1]f64{0} ** 10,

    const zero: QuadricMatrix = .{ .m = [1]f64{0} ** 10 };

    fn fromPlane(nx: f64, ny: f64, nz: f64, d: f64) QuadricMatrix {
        return .{ .m = .{
            nx * nx, nx * ny, nx * nz, nx * d,
            ny * ny, ny * nz, ny * d,  nz * nz,
            nz * d,  d * d,
        } };
    }

    fn add(a: QuadricMatrix, b: QuadricMatrix) QuadricMatrix {
        var r: QuadricMatrix = .{};
        for (&r.m, &a.m, &b.m) |*dst, xa, xb| dst.* = xa + xb;
        return r;
    }

    fn evaluate(q: QuadricMatrix, x: f64, y: f64, z: f64) f64 {
        const m = q.m;
        const r0 = m[0] * x + m[1] * y + m[2] * z + m[3];
        const r1 = m[1] * x + m[4] * y + m[5] * z + m[6];
        const r2 = m[2] * x + m[5] * y + m[7] * z + m[8];
        const r3 = m[3] * x + m[6] * y + m[8] * z + m[9];
        return x * r0 + y * r1 + z * r2 + r3;
    }

    const OptimalResult = struct {
        pos: [3]f64,
        solvable: bool,
    };

    fn optimalPosition(q: QuadricMatrix, fa: [3]f64, fb: [3]f64) OptimalResult {
        const m = q.m;
        const a00 = m[0];
        const a01 = m[1];
        const a02 = m[2];
        const a11 = m[4];
        const a12 = m[5];
        const a22 = m[7];
        const b0 = -m[3];
        const b1 = -m[6];
        const b2 = -m[8];

        const det = a00 * (a11 * a22 - a12 * a12) -
            a01 * (a01 * a22 - a12 * a02) +
            a02 * (a01 * a12 - a11 * a02);

        if (@abs(det) < DETERMINANT_EPSILON) {
            return .{
                .pos = .{
                    (fa[0] + fb[0]) * 0.5,
                    (fa[1] + fb[1]) * 0.5,
                    (fa[2] + fb[2]) * 0.5,
                },
                .solvable = false,
            };
        }

        const inv = 1.0 / det;
        const dx = (b0 * (a11 * a22 - a12 * a12) -
            a01 * (b1 * a22 - a12 * b2) +
            a02 * (b1 * a12 - a11 * b2)) * inv;
        const dy = (a00 * (b1 * a22 - a12 * b2) -
            b0 * (a01 * a22 - a12 * a02) +
            a02 * (a01 * b2 - b1 * a02)) * inv;
        const dz = (a00 * (a11 * b2 - b1 * a12) -
            a01 * (a01 * b2 - b1 * a02) +
            b0 * (a01 * a12 - a11 * a02)) * inv;

        return .{ .pos = .{ dx, dy, dz }, .solvable = true };
    }
};

const DETERMINANT_EPSILON: f64 = 1e-10;

fn edgeKey(v1: u32, v2: u32) u64 {
    const lo = @min(v1, v2);
    const hi = @max(v1, v2);
    return (@as(u64, @intCast(lo)) << 32) | @as(u64, @intCast(hi));
}

const EdgeEntry = struct {
    v1: u32,
    v2: u32,
    cost: f64,
    version: u32,
};

fn compareEdges(_: void, a: EdgeEntry, b: EdgeEntry) std.math.Order {
    if (a.cost < b.cost) return .lt;
    if (a.cost > b.cost) return .gt;
    return .eq;
}

pub const QuadricSimplifier = struct {
    pub fn simplify(
        allocator: Allocator,
        vertices: []const Vertex,
        indices: []const u32,
        target_triangles: u32,
    ) !SimplifiedMesh {
        if (indices.len % 3 != 0) return error.InvalidIndexCount;
        const num_triangles: u32 = @intCast(indices.len / 3);

        if (vertices.len == 0 or num_triangles == 0) {
            return .{
                .vertices = &.{},
                .indices = &.{},
                .original_triangle_count = 0,
                .simplified_triangle_count = 0,
                .error_estimate = 0,
                .skipped_collapses = 0,
            };
        }

        if (target_triangles >= num_triangles) {
            const out_v = try allocator.dupe(Vertex, vertices);
            errdefer allocator.free(out_v);
            const out_i = try allocator.dupe(u32, indices);
            errdefer allocator.free(out_i);
            return .{
                .vertices = out_v,
                .indices = out_i,
                .original_triangle_count = num_triangles,
                .simplified_triangle_count = num_triangles,
                .error_estimate = 0,
                .skipped_collapses = 0,
            };
        }

        const n: u32 = @intCast(vertices.len);

        var pos = try allocator.alloc([3]f64, n);
        defer allocator.free(pos);
        for (pos, vertices) |*p, v| {
            p.* = .{
                @floatCast(v.pos[0]),
                @floatCast(v.pos[1]),
                @floatCast(v.pos[2]),
            };
        }

        var active = try allocator.alloc(bool, n);
        defer allocator.free(active);
        @memset(active, true);

        var quadrics = try allocator.alloc(QuadricMatrix, n);
        defer allocator.free(quadrics);
        @memset(quadrics, QuadricMatrix.zero);

        var tris = try allocator.alloc([3]u32, num_triangles);
        defer allocator.free(tris);
        for (tris, 0..) |*t, i| {
            t.* = .{ indices[i * 3], indices[i * 3 + 1], indices[i * 3 + 2] };
        }

        var tri_active = try allocator.alloc(bool, num_triangles);
        defer allocator.free(tri_active);
        @memset(tri_active, true);

        computeQuadrics(quadrics, pos, tris, tri_active);

        var edge_versions = std.AutoHashMap(u64, u32).init(allocator);
        defer edge_versions.deinit();

        var heap = std.PriorityQueue(EdgeEntry, void, compareEdges).init(allocator, {});
        defer heap.deinit();

        {
            var edge_set = std.AutoHashMap(u64, void).init(allocator);
            defer edge_set.deinit();

            for (tris, 0..) |tri, ti| {
                if (!tri_active[ti]) continue;
                const pairs = [3][2]u32{
                    .{ tri[0], tri[1] },
                    .{ tri[1], tri[2] },
                    .{ tri[2], tri[0] },
                };
                for (&pairs) |pair| {
                    if (pair[0] == pair[1]) continue;
                    const key = edgeKey(pair[0], pair[1]);
                    if (edge_set.contains(key)) continue;
                    try edge_set.put(key, {});

                    const combined = QuadricMatrix.add(quadrics[pair[0]], quadrics[pair[1]]);
                    const result = combined.optimalPosition(pos[pair[0]], pos[pair[1]]);
                    const cost = @max(QuadricMatrix.evaluate(combined, result.pos[0], result.pos[1], result.pos[2]), 0);

                    try edge_versions.put(key, 0);
                    try heap.add(.{
                        .v1 = pair[0],
                        .v2 = pair[1],
                        .cost = cost,
                        .version = 0,
                    });
                }
            }
        }

        var neighbor_buf = try allocator.alloc(u32, n);
        defer allocator.free(neighbor_buf);

        var current_tri_count = num_triangles;
        var max_error: f64 = 0;
        var skipped_collapses: u32 = 0;

        while (current_tri_count > target_triangles) {
            var entry: ?EdgeEntry = null;
            while (heap.removeOrNull()) |e| {
                if (!active[e.v1] or !active[e.v2]) continue;
                if (e.v1 == e.v2) continue;
                const key = edgeKey(e.v1, e.v2);
                const ver = edge_versions.get(key) orelse continue;
                if (e.version != ver) continue;
                if (!canCollapse(tris, tri_active, e.v1, e.v2)) continue;
                entry = e;
                break;
            }

            const e = entry orelse break;

            const combined = QuadricMatrix.add(quadrics[e.v1], quadrics[e.v2]);
            const result = combined.optimalPosition(pos[e.v1], pos[e.v2]);

            if (wouldFlipNormal(pos, tris, tri_active, e.v1, e.v2, result.pos)) {
                const mid: [3]f64 = .{
                    (pos[e.v1][0] + pos[e.v2][0]) * 0.5,
                    (pos[e.v1][1] + pos[e.v2][1]) * 0.5,
                    (pos[e.v1][2] + pos[e.v2][2]) * 0.5,
                };
                if (wouldFlipNormal(pos, tris, tri_active, e.v1, e.v2, mid)) {
                    skipped_collapses += 1;
                    continue;
                }
                pos[e.v1] = mid;
            } else {
                pos[e.v1] = result.pos;
            }

            const cost = @max(QuadricMatrix.evaluate(combined, pos[e.v1][0], pos[e.v1][1], pos[e.v1][2]), 0);
            if (cost > max_error) max_error = cost;

            quadrics[e.v1] = combined;
            active[e.v2] = false;

            var neighbor_count: usize = 0;

            for (tris, 0..) |tri, ti| {
                if (!tri_active[ti]) continue;
                var has_v1 = false;
                var has_v2 = false;
                for (tri) |v| {
                    if (v == e.v1) has_v1 = true;
                    if (v == e.v2) has_v2 = true;
                }

                if (has_v1 and has_v2) {
                    tri_active[ti] = false;
                    current_tri_count -= 1;
                } else if (has_v2) {
                    for (tri) |v| {
                        if (v != e.v1 and v != e.v2) {
                            addUnique(neighbor_buf, &neighbor_count, v);
                        }
                    }
                    for (0..3) |j| {
                        if (tris[ti][j] == e.v2) tris[ti][j] = e.v1;
                    }
                }
            }

            for (tris, 0..) |tri, ti| {
                if (!tri_active[ti]) continue;
                var has_v1 = false;
                for (tri) |v| {
                    if (v == e.v1) {
                        has_v1 = true;
                        break;
                    }
                }
                if (!has_v1) continue;
                for (tri) |v| {
                    if (v != e.v1) {
                        addUnique(neighbor_buf, &neighbor_count, v);
                    }
                }
            }

            for (neighbor_buf[0..neighbor_count]) |neighbor| {
                if (!active[neighbor]) continue;
                if (neighbor == e.v1) continue;
                const key = edgeKey(e.v1, neighbor);
                const new_combined = QuadricMatrix.add(quadrics[e.v1], quadrics[neighbor]);
                const new_result = new_combined.optimalPosition(pos[e.v1], pos[neighbor]);
                const new_cost = @max(new_combined.evaluate(new_result.pos[0], new_result.pos[1], new_result.pos[2]), 0);
                const cur_ver = edge_versions.get(key) orelse 0;
                const new_ver = cur_ver + 1;
                try edge_versions.put(key, new_ver);
                try heap.add(.{
                    .v1 = e.v1,
                    .v2 = neighbor,
                    .cost = new_cost,
                    .version = new_ver,
                });
            }
        }

        return collectResults(allocator, vertices, pos, active, tris, tri_active, num_triangles, current_tri_count, max_error, skipped_collapses);
    }
};

fn computeQuadrics(
    quadrics: []QuadricMatrix,
    pos: []const [3]f64,
    tris: []const [3]u32,
    tri_active: []const bool,
) void {
    for (tris, 0..) |tri, ti| {
        if (!tri_active[ti]) continue;

        const p0 = pos[tri[0]];
        const p1 = pos[tri[1]];
        const p2 = pos[tri[2]];

        const e1x = p1[0] - p0[0];
        const e1y = p1[1] - p0[1];
        const e1z = p1[2] - p0[2];
        const e2x = p2[0] - p0[0];
        const e2y = p2[1] - p0[1];
        const e2z = p2[2] - p0[2];

        const nx = e1y * e2z - e1z * e2y;
        const ny = e1z * e2x - e1x * e2z;
        const nz = e1x * e2y - e1y * e2x;

        const len = @sqrt(nx * nx + ny * ny + nz * nz);
        if (len < 1e-20) continue;

        const inv_len = 1.0 / len;
        const nnx = nx * inv_len;
        const nny = ny * inv_len;
        const nnz = nz * inv_len;

        const d = -(nnx * p0[0] + nny * p0[1] + nnz * p0[2]);
        const q = QuadricMatrix.fromPlane(nnx, nny, nnz, d);
        quadrics[tri[0]] = QuadricMatrix.add(quadrics[tri[0]], q);
        quadrics[tri[1]] = QuadricMatrix.add(quadrics[tri[1]], q);
        quadrics[tri[2]] = QuadricMatrix.add(quadrics[tri[2]], q);
    }
}

fn canCollapse(
    tris: []const [3]u32,
    tri_active: []const bool,
    v1: u32,
    v2: u32,
) bool {
    const MAX_VALENCE: usize = 512;
    var link_edge: [MAX_VALENCE]u32 = undefined;
    var link_edge_len: usize = 0;
    var link_v1: [MAX_VALENCE]u32 = undefined;
    var link_v1_len: usize = 0;
    var link_v2: [MAX_VALENCE]u32 = undefined;
    var link_v2_len: usize = 0;

    for (tris, 0..) |tri, ti| {
        if (!tri_active[ti]) continue;

        const has_v1 = tri[0] == v1 or tri[1] == v1 or tri[2] == v1;
        const has_v2 = tri[0] == v2 or tri[1] == v2 or tri[2] == v2;

        if (!has_v1 and !has_v2) continue;

        for (tri) |v| {
            if (v == v1 or v == v2) continue;

            if (has_v1 and has_v2) {
                if (!addToSetChecked(&link_edge, &link_edge_len, v)) return true;
            }
            if (has_v1) {
                if (!addToSetChecked(&link_v1, &link_v1_len, v)) return true;
            }
            if (has_v2) {
                if (!addToSetChecked(&link_v2, &link_v2_len, v)) return true;
            }
        }
    }

    for (link_v1[0..link_v1_len]) |n1| {
        for (link_v2[0..link_v2_len]) |n2| {
            if (n1 != n2) continue;
            var found = false;
            for (link_edge[0..link_edge_len]) |le| {
                if (le == n1) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
    }

    return true;
}

fn addToSetChecked(buf: []u32, len: *usize, val: u32) bool {
    for (buf[0..len.*]) |v| {
        if (v == val) return true;
    }
    if (len.* >= buf.len) return false;
    buf[len.*] = val;
    len.* += 1;
    return true;
}

fn addUnique(buf: []u32, len: *usize, val: u32) void {
    std.debug.assert(len.* < buf.len);
    for (buf[0..len.*]) |v| {
        if (v == val) return;
    }
    buf[len.*] = val;
    len.* += 1;
}

fn wouldFlipNormal(
    pos: []const [3]f64,
    tris: []const [3]u32,
    tri_active: []const bool,
    v1: u32,
    v2: u32,
    new_pos: [3]f64,
) bool {
    for (tris, 0..) |tri, ti| {
        if (!tri_active[ti]) continue;

        const has_v1 = tri[0] == v1 or tri[1] == v1 or tri[2] == v1;
        const has_v2 = tri[0] == v2 or tri[1] == v2 or tri[2] == v2;
        if (!has_v1 or has_v2) continue;

        var old_pts: [3][3]f64 = undefined;
        var new_pts: [3][3]f64 = undefined;

        for (tri, 0..) |v, j| {
            if (v == v1) {
                old_pts[j] = pos[v1];
                new_pts[j] = new_pos;
            } else {
                old_pts[j] = pos[v];
                new_pts[j] = pos[v];
            }
        }

        const old_n = triNormal(old_pts[0], old_pts[1], old_pts[2]);
        const new_n = triNormal(new_pts[0], new_pts[1], new_pts[2]);
        const dot = old_n[0] * new_n[0] + old_n[1] * new_n[1] + old_n[2] * new_n[2];
        if (dot < 0) return true;
    }
    return false;
}

fn triNormal(a: [3]f64, b: [3]f64, c: [3]f64) [3]f64 {
    const e1x = b[0] - a[0];
    const e1y = b[1] - a[1];
    const e1z = b[2] - a[2];
    const e2x = c[0] - a[0];
    const e2y = c[1] - a[1];
    const e2z = c[2] - a[2];
    const nx = e1y * e2z - e1z * e2y;
    const ny = e1z * e2x - e1x * e2z;
    const nz = e1x * e2y - e1y * e2x;
    const len = @sqrt(nx * nx + ny * ny + nz * nz);
    if (len < 1e-20) return .{ 0, 0, 0 };
    const inv = 1.0 / len;
    return .{ nx * inv, ny * inv, nz * inv };
}

fn collectResults(
    allocator: Allocator,
    original_vertices: []const Vertex,
    pos: []const [3]f64,
    active: []const bool,
    tris: []const [3]u32,
    tri_active: []const bool,
    num_tris: u32,
    current_tri_count: u32,
    max_error: f64,
    skipped: u32,
) !SimplifiedMesh {
    const n = active.len;

    var remap = try allocator.alloc(u32, n);
    defer allocator.free(remap);

    var vertex_count: u32 = 0;
    for (active, 0..) |is_active, i| {
        if (is_active) {
            remap[i] = vertex_count;
            vertex_count += 1;
        } else {
            remap[i] = std.math.maxInt(u32);
        }
    }

    if (vertex_count == 0) {
        return .{
            .vertices = &.{},
            .indices = &.{},
            .original_triangle_count = num_tris,
            .simplified_triangle_count = 0,
            .error_estimate = max_error,
            .skipped_collapses = skipped,
        };
    }

    const out_verts = try allocator.alloc(Vertex, vertex_count);
    var vi: u32 = 0;
    for (active, 0..) |is_active, i| {
        if (!is_active) continue;
        out_verts[vi] = original_vertices[i];
        out_verts[vi].pos = .{
            @floatCast(pos[i][0]),
            @floatCast(pos[i][1]),
            @floatCast(pos[i][2]),
        };
        vi += 1;
    }

    const index_count: usize = @as(usize, @intCast(current_tri_count)) * 3;
    if (index_count == 0) {
        allocator.free(out_verts);
        return .{
            .vertices = &.{},
            .indices = &.{},
            .original_triangle_count = num_tris,
            .simplified_triangle_count = 0,
            .error_estimate = max_error,
            .skipped_collapses = skipped,
        };
    }

    const out_indices = try allocator.alloc(u32, index_count);
    var ii: usize = 0;
    for (tris, 0..) |tri, ti| {
        if (ti >= num_tris) break;
        if (!tri_active[ti]) continue;
        out_indices[ii] = remap[tri[0]];
        out_indices[ii + 1] = remap[tri[1]];
        out_indices[ii + 2] = remap[tri[2]];
        ii += 3;
    }

    return .{
        .vertices = out_verts[0..vertex_count],
        .indices = out_indices[0..ii],
        .original_triangle_count = num_tris,
        .simplified_triangle_count = current_tri_count,
        .error_estimate = max_error,
        .skipped_collapses = skipped,
    };
}

fn makeVertex(x: f32, y: f32, z: f32) Vertex {
    return .{
        .pos = .{ x, y, z },
        .color = .{ 1.0, 1.0, 1.0 },
        .normal = .{ 0.0, 1.0, 0.0 },
        .uv = .{ 0.0, 0.0 },
        .tile_id = -1.0,
        .skylight = 1.0,
        .blocklight = .{ 0.0, 0.0, 0.0 },
        .ao = 1.0,
    };
}

fn createCube(allocator: Allocator) !struct { vertices: []Vertex, indices: []u32 } {
    const verts = try allocator.alloc(Vertex, 8);
    verts[0] = makeVertex(0, 0, 0);
    verts[1] = makeVertex(1, 0, 0);
    verts[2] = makeVertex(1, 1, 0);
    verts[3] = makeVertex(0, 1, 0);
    verts[4] = makeVertex(0, 0, 1);
    verts[5] = makeVertex(1, 0, 1);
    verts[6] = makeVertex(1, 1, 1);
    verts[7] = makeVertex(0, 1, 1);

    const idx = try allocator.dupe(u32, &[_]u32{
        4, 5, 6, 4, 6, 7,
        1, 0, 3, 1, 3, 2,
        5, 1, 2, 5, 2, 6,
        0, 4, 7, 0, 7, 3,
        7, 6, 2, 7, 2, 3,
        0, 1, 5, 0, 5, 4,
    });

    return .{ .vertices = verts, .indices = idx };
}

fn createSphere(allocator: Allocator, lat_divs: u32, lon_divs: u32) !struct { vertices: []Vertex, indices: []u32 } {
    const num_rings = lat_divs - 1;
    const num_verts: usize = 2 + @as(usize, num_rings) * lon_divs;

    const verts = try allocator.alloc(Vertex, num_verts);

    verts[0] = makeVertex(0.0, 1.0, 0.0);

    var vi: usize = 1;
    for (1..lat_divs) |ring| {
        const phi = std.math.pi * @as(f64, @floatFromInt(ring)) / @as(f64, @floatFromInt(lat_divs));
        for (0..lon_divs) |seg| {
            const theta = 2.0 * std.math.pi * @as(f64, @floatFromInt(seg)) / @as(f64, @floatFromInt(lon_divs));
            const x: f32 = @floatCast(@sin(phi) * @cos(theta));
            const y: f32 = @floatCast(@cos(phi));
            const z: f32 = @floatCast(@sin(phi) * @sin(theta));
            verts[vi] = makeVertex(x, y, z);
            vi += 1;
        }
    }

    verts[vi] = makeVertex(0.0, -1.0, 0.0);

    const south_pole_idx: u32 = @intCast(num_verts - 1);
    const num_tris: usize = @as(usize, lon_divs) * 2 + @as(usize, num_rings - 1) * @as(usize, lon_divs) * 2;
    const indices = try allocator.alloc(u32, num_tris * 3);
    var ii: usize = 0;

    for (0..lon_divs) |seg| {
        const next_seg = @as(u32, @intCast((seg + 1) % lon_divs));
        const seg_u32: u32 = @intCast(seg);
        indices[ii] = 0;
        indices[ii + 1] = 1 + seg_u32;
        indices[ii + 2] = 1 + next_seg;
        ii += 3;
    }

    for (0..@intCast(num_rings - 1)) |ring| {
        const ring_u32: u32 = @intCast(ring);
        for (0..lon_divs) |seg| {
            const next_seg = @as(u32, @intCast((seg + 1) % lon_divs));
            const seg_u32: u32 = @intCast(seg);
            const curr = 1 + ring_u32 * lon_divs + seg_u32;
            const curr_next = 1 + ring_u32 * lon_divs + next_seg;
            const below = 1 + (ring_u32 + 1) * lon_divs + seg_u32;
            const below_next = 1 + (ring_u32 + 1) * lon_divs + next_seg;

            indices[ii] = curr;
            indices[ii + 1] = below;
            indices[ii + 2] = below_next;
            ii += 3;

            indices[ii] = curr;
            indices[ii + 1] = below_next;
            indices[ii + 2] = curr_next;
            ii += 3;
        }
    }

    const last_ring_start: u32 = 1 + @as(u32, @intCast(num_rings - 1)) * lon_divs;
    for (0..lon_divs) |seg| {
        const next_seg = @as(u32, @intCast((seg + 1) % lon_divs));
        const seg_u32: u32 = @intCast(seg);
        indices[ii] = south_pole_idx;
        indices[ii + 1] = last_ring_start + next_seg;
        indices[ii + 2] = last_ring_start + seg_u32;
        ii += 3;
    }

    return .{ .vertices = verts, .indices = indices[0..ii] };
}

test "simplify cube 12 to 4 triangles" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cube = try createCube(allocator);
    defer {
        allocator.free(cube.vertices);
        allocator.free(cube.indices);
    }

    const result = try QuadricSimplifier.simplify(allocator, cube.vertices, cube.indices, 4);
    defer {
        allocator.free(result.vertices);
        allocator.free(result.indices);
    }

    try testing.expectEqual(@as(u32, 12), result.original_triangle_count);
    try testing.expect(result.simplified_triangle_count <= 4);
    try testing.expect(result.error_estimate >= 0);
    try testing.expect(result.indices.len % 3 == 0);
}

test "simplify sphere preserves shape" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const sphere = try createSphere(allocator, 10, 20);
    defer {
        allocator.free(sphere.vertices);
        allocator.free(sphere.indices);
    }

    const original_tris: u32 = @intCast(sphere.indices.len / 3);
    const target = original_tris / 2;

    const result = try QuadricSimplifier.simplify(allocator, sphere.vertices, sphere.indices, target);
    defer {
        allocator.free(result.vertices);
        allocator.free(result.indices);
    }

    try testing.expect(result.simplified_triangle_count <= target);
    try testing.expect(result.simplified_triangle_count > 0);

    for (result.vertices) |v| {
        const dist = @sqrt(v.pos[0] * v.pos[0] + v.pos[1] * v.pos[1] + v.pos[2] * v.pos[2]);
        try testing.expect(dist < 2.0);
    }
}

test "no-op when target >= actual triangles" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cube = try createCube(allocator);
    defer {
        allocator.free(cube.vertices);
        allocator.free(cube.indices);
    }

    const result = try QuadricSimplifier.simplify(allocator, cube.vertices, cube.indices, 20);
    defer {
        allocator.free(result.vertices);
        allocator.free(result.indices);
    }

    try testing.expectEqual(@as(u32, 12), result.simplified_triangle_count);
    try testing.expectEqualSlices(u32, cube.indices, result.indices);
    try testing.expectEqual(@as(u32, 0), @as(u32, @intFromFloat(result.error_estimate)));
}

test "target zero triangles does not crash" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cube = try createCube(allocator);
    defer {
        allocator.free(cube.vertices);
        allocator.free(cube.indices);
    }

    const result = try QuadricSimplifier.simplify(allocator, cube.vertices, cube.indices, 0);
    defer {
        allocator.free(result.vertices);
        allocator.free(result.indices);
    }

    try testing.expect(result.simplified_triangle_count < 12);
    try testing.expect(result.error_estimate >= 0);
}

test "single triangle input produces single triangle output" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const verts = try allocator.alloc(Vertex, 3);
    defer allocator.free(verts);
    verts[0] = makeVertex(0, 0, 0);
    verts[1] = makeVertex(1, 0, 0);
    verts[2] = makeVertex(0, 1, 0);

    const indices = try allocator.dupe(u32, &[_]u32{ 0, 1, 2 });
    defer allocator.free(indices);

    const result = try QuadricSimplifier.simplify(allocator, verts, indices, 1);
    defer {
        allocator.free(result.vertices);
        allocator.free(result.indices);
    }

    try testing.expectEqual(@as(u32, 1), result.simplified_triangle_count);
    try testing.expectEqual(@as(usize, 3), result.indices.len);
}

test "empty mesh returns empty result" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = try QuadricSimplifier.simplify(allocator, &.{}, &.{}, 0);
    try testing.expectEqual(@as(usize, 0), result.vertices.len);
    try testing.expectEqual(@as(usize, 0), result.indices.len);
}

test "performance simplify mesh" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const sphere = try createSphere(allocator, 20, 40);
    defer {
        allocator.free(sphere.vertices);
        allocator.free(sphere.indices);
    }

    const original_tris: u32 = @intCast(sphere.indices.len / 3);
    const target = original_tris / 4;

    const start = std.time.Instant.now() catch return;
    const result = try QuadricSimplifier.simplify(allocator, sphere.vertices, sphere.indices, target);
    const end = std.time.Instant.now() catch return;
    const elapsed_ns = end.since(start);
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    defer {
        allocator.free(result.vertices);
        allocator.free(result.indices);
    }

    try testing.expect(result.simplified_triangle_count <= target);
    try testing.expect(elapsed_ms < 2000.0);
}
