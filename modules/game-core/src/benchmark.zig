const std = @import("std");
const fs = @import("fs");

const Player = @import("player.zig").Player;
const Vec3 = @import("engine-math").Vec3;
const GpuTimingResults = @import("engine-rhi").GpuTimingResults;
const WorldStats = @import("engine-ui").WorldStats;

pub const Waypoint = struct {
    pos: Vec3,
    look: Vec3,
    duration: f32,
};

pub const BENCH_PATH = [_]Waypoint{
    .{ .pos = Vec3.init(8, 100, 8), .look = Vec3.init(1, 0, 0), .duration = 5.0 },
    .{ .pos = Vec3.init(200, 150, 200), .look = Vec3.init(0, -0.3, 1), .duration = 10.0 },
    .{ .pos = Vec3.init(-500, 80, 300), .look = Vec3.init(1, 0, -1), .duration = 10.0 },
    .{ .pos = Vec3.init(-900, 120, -200), .look = Vec3.init(0.2, -0.7, 0.1), .duration = 10.0 },
    .{ .pos = Vec3.init(300, 90, -800), .look = Vec3.init(-1, 0.25, 0.2), .duration = 10.0 },
    .{ .pos = Vec3.init(900, 160, 700), .look = Vec3.init(0.3, -0.9, -0.1), .duration = 15.0 },
};

pub const FrameSample = struct {
    cpu_ms: f32,
    fps: f32,
    gpu_shadow_ms: f32,
    gpu_opaque_ms: f32,
    gpu_total_ms: f32,
    draw_calls: u32,
    vertices: u64,
    chunks_rendered: u32,
    gpu_memory_mb: f32,
};

pub const SloThresholds = struct {
    fps_p1_min: f64,
    max_frame_ms: f64,
    draw_calls_max: f64,
    vertices_max: f64,
    gpu_memory_mb_max: f64,
};

pub const Summary = struct {
    min: f64,
    avg: f64,
    max: f64,
    p1: f64,
    p5: f64,
    p50: f64,
    p95: f64,
    p99: f64,
};

pub const GpuSummary = struct {
    shadow_avg: f64,
    opaque_avg: f64,
    total_avg: f64,
};

pub const BenchmarkResults = struct {
    preset: []const u8,
    render_distance: i32,
    gpu_memory_mb_avg: f64,
    gpu_memory_mb_max: f64,
    frames: u32,
    duration_s: f32,
    fps: Summary,
    max_frame_ms: f64,
    cpu_ms_avg: f64,
    gpu_ms: GpuSummary,
    draw_calls_avg: f64,
    vertices_avg: f64,
    chunks_rendered_avg: f64,
};

pub const BenchmarkRunner = struct {
    allocator: std.mem.Allocator,
    preset: []const u8,
    render_distance: i32,
    duration_s: f32,
    output_path: []const u8,
    start_ms: i64,
    elapsed_s: f32 = 0,
    samples: std.ArrayListUnmanaged(FrameSample) = .empty,

    pub fn init(allocator: std.mem.Allocator, preset: []const u8, render_distance: i32, duration_s: f32, output_path: []const u8) !BenchmarkRunner {
        var runner = BenchmarkRunner{
            .allocator = allocator,
            .preset = preset,
            .render_distance = render_distance,
            .duration_s = duration_s,
            .output_path = output_path,
            .start_ms = nowMs(),
            .elapsed_s = 0,
            .samples = .empty,
        };

        const estimate_frames = @max(@as(usize, 64), @as(usize, @intFromFloat(@ceil(duration_s * 120.0))));
        try runner.samples.ensureTotalCapacity(allocator, estimate_frames);
        return runner;
    }

    pub fn deinit(self: *BenchmarkRunner) void {
        self.samples.deinit(self.allocator);
    }

    pub fn applyPose(self: *const BenchmarkRunner, player: *Player) void {
        const pose = poseAtTime(self.elapsed_s);
        player.fly_mode = true;
        player.can_fly = true;
        player.noclip = true;
        player.velocity = Vec3.zero;
        player.is_grounded = false;
        player.position = pose.pos.sub(Vec3.init(0, Player.EYE_HEIGHT, 0));
        player.camera.position = pose.pos;
        player.camera.setYawPitch(yawFromLook(pose.look), pitchFromLook(pose.look));
        player.target_block = null;
    }

    pub fn recordFrame(self: *BenchmarkRunner, dt: f32, fps: f32, gpu: GpuTimingResults, world_stats: ?WorldStats, draw_calls: u32, gpu_memory_mb: f32) !void {
        const shadow_avg = averageArray(&gpu.shadow_pass_ms);
        const chunks_rendered = if (world_stats) |ws| ws.chunks_rendered else 0;
        const vertices = if (world_stats) |ws| ws.vertices_rendered else 0;
        const frame_fps = if (dt > 0.000001) 1.0 / dt else fps;

        try self.samples.append(self.allocator, .{
            .cpu_ms = dt * 1000.0,
            .fps = frame_fps,
            .gpu_shadow_ms = shadow_avg,
            .gpu_opaque_ms = gpu.opaque_pass_ms,
            .gpu_total_ms = gpu.total_gpu_ms,
            .draw_calls = draw_calls,
            .vertices = vertices,
            .chunks_rendered = chunks_rendered,
            .gpu_memory_mb = gpu_memory_mb,
        });
        self.elapsed_s += dt;
    }

    pub fn isComplete(self: *const BenchmarkRunner) bool {
        return wallElapsedSeconds(self) >= self.duration_s;
    }

    pub fn writeResults(self: *const BenchmarkRunner) !void {
        const results = try self.makeResults();
        const json = try results_json(results, self.allocator);
        defer self.allocator.free(json);

        if (fs.path.dirname(self.output_path)) |dir| {
            try fs.cwd().makePath(dir);
        }

        var file = try fs.cwd().createFile(self.output_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(json);

        try enforceSlo(results);
    }

    pub fn makeResults(self: *const BenchmarkRunner) !BenchmarkResults {
        const fps_values = try self.collectField(fpsField);
        defer self.allocator.free(fps_values);

        var cpu_sum: f64 = 0;
        var shadow_sum: f64 = 0;
        var opaque_sum: f64 = 0;
        var total_sum: f64 = 0;
        var draw_sum: f64 = 0;
        var vertices_sum: f64 = 0;
        var chunks_sum: f64 = 0;
        var memory_sum: f64 = 0;
        var memory_max: f64 = 0;
        var max_frame_ms: f64 = 0;

        for (self.samples.items) |sample| {
            cpu_sum += sample.cpu_ms;
            max_frame_ms = @max(max_frame_ms, sample.cpu_ms);
            shadow_sum += sample.gpu_shadow_ms;
            opaque_sum += sample.gpu_opaque_ms;
            total_sum += sample.gpu_total_ms;
            draw_sum += @floatFromInt(sample.draw_calls);
            vertices_sum += @floatFromInt(sample.vertices);
            chunks_sum += @floatFromInt(sample.chunks_rendered);
            memory_sum += sample.gpu_memory_mb;
            memory_max = @max(memory_max, sample.gpu_memory_mb);
        }

        const count = @as(f64, @floatFromInt(@max(self.samples.items.len, 1)));
        var fps_summary = try summarizeSeries(self.allocator, fps_values);
        const sampled_s = cpu_sum / 1000.0;
        if (sampled_s > 0.0) {
            fps_summary.avg = @as(f64, @floatFromInt(self.samples.items.len)) / sampled_s;
        }

        return .{
            .preset = self.preset,
            .render_distance = self.render_distance,
            .gpu_memory_mb_avg = memory_sum / count,
            .gpu_memory_mb_max = memory_max,
            .frames = @intCast(self.samples.items.len),
            .duration_s = self.duration_s,
            .fps = fps_summary,
            .max_frame_ms = max_frame_ms,
            .cpu_ms_avg = cpu_sum / count,
            .gpu_ms = .{
                .shadow_avg = shadow_sum / count,
                .opaque_avg = opaque_sum / count,
                .total_avg = total_sum / count,
            },
            .draw_calls_avg = draw_sum / count,
            .vertices_avg = vertices_sum / count,
            .chunks_rendered_avg = chunks_sum / count,
        };
    }

    fn collectField(self: *const BenchmarkRunner, comptime getter: fn (FrameSample) f32) ![]f32 {
        var values = try self.allocator.alloc(f32, self.samples.items.len);
        for (self.samples.items, 0..) |sample, i| {
            values[i] = getter(sample);
        }
        return values;
    }

    fn results_json(results: BenchmarkResults, allocator: std.mem.Allocator) ![]u8 {
        return try std.json.Stringify.valueAlloc(allocator, results, .{ .whitespace = .indent_2 });
    }
};

fn nowMs() i64 {
    return std.Io.Clock.real.now(std.Options.debug_io).toMilliseconds();
}

fn wallElapsedSeconds(self: *const BenchmarkRunner) f32 {
    const elapsed_ms = @max(@as(i64, 0), nowMs() - self.start_ms);
    return @as(f32, @floatFromInt(elapsed_ms)) / 1000.0;
}

pub fn thresholdsForPreset(preset: []const u8) SloThresholds {
    if (std.ascii.eqlIgnoreCase(preset, "low")) return .{ .fps_p1_min = 12, .max_frame_ms = 260, .draw_calls_max = 700, .vertices_max = 3_500_000, .gpu_memory_mb_max = 2200 };
    if (std.ascii.eqlIgnoreCase(preset, "medium")) return .{ .fps_p1_min = 8, .max_frame_ms = 260, .draw_calls_max = 2600, .vertices_max = 6_000_000, .gpu_memory_mb_max = 2400 };
    if (std.ascii.eqlIgnoreCase(preset, "high")) return .{ .fps_p1_min = 6, .max_frame_ms = 260, .draw_calls_max = 3600, .vertices_max = 8_500_000, .gpu_memory_mb_max = 2800 };
    if (std.ascii.eqlIgnoreCase(preset, "ultra")) return .{ .fps_p1_min = 4, .max_frame_ms = 260, .draw_calls_max = 4500, .vertices_max = 12_000_000, .gpu_memory_mb_max = 3400 };
    if (std.ascii.eqlIgnoreCase(preset, "extreme")) return .{ .fps_p1_min = 3, .max_frame_ms = 260, .draw_calls_max = 5500, .vertices_max = 16_000_000, .gpu_memory_mb_max = 4096 };
    return .{ .fps_p1_min = 6, .max_frame_ms = 260, .draw_calls_max = 3600, .vertices_max = 8_500_000, .gpu_memory_mb_max = 2800 };
}

fn enforceSlo(results: BenchmarkResults) !void {
    const thresholds = thresholdsForPreset(results.preset);
    var failed = false;

    if (results.fps.p1 < thresholds.fps_p1_min) {
        std.log.err("benchmark SLO breach: {s} p1 FPS {d:.2} < {d:.2}", .{ results.preset, results.fps.p1, thresholds.fps_p1_min });
        failed = true;
    }
    if (results.max_frame_ms > thresholds.max_frame_ms) {
        std.log.err("benchmark SLO breach: {s} max frame {d:.2}ms > {d:.2}ms", .{ results.preset, results.max_frame_ms, thresholds.max_frame_ms });
        failed = true;
    }
    if (results.draw_calls_avg > thresholds.draw_calls_max) {
        std.log.err("benchmark SLO breach: {s} draw calls avg {d:.2} > {d:.2}", .{ results.preset, results.draw_calls_avg, thresholds.draw_calls_max });
        failed = true;
    }
    if (results.vertices_avg > thresholds.vertices_max) {
        std.log.err("benchmark SLO breach: {s} vertices avg {d:.2} > {d:.2}", .{ results.preset, results.vertices_avg, thresholds.vertices_max });
        failed = true;
    }
    if (results.gpu_memory_mb_max > thresholds.gpu_memory_mb_max) {
        std.log.err("benchmark SLO breach: {s} GPU memory max {d:.2}MB > {d:.2}MB", .{ results.preset, results.gpu_memory_mb_max, thresholds.gpu_memory_mb_max });
        failed = true;
    }

    if (failed) return error.BenchmarkSloBreach;
}

fn fpsField(sample: FrameSample) f32 {
    return sample.fps;
}

fn summarizeSeries(allocator: std.mem.Allocator, values: []f32) !Summary {
    if (values.len == 0) {
        return .{ .min = 0, .avg = 0, .max = 0, .p1 = 0, .p5 = 0, .p50 = 0, .p95 = 0, .p99 = 0 };
    }

    const sorted = try allocator.dupe(f32, values);
    defer allocator.free(sorted);
    std.sort.block(f32, sorted, {}, lessThan);

    var sum: f64 = 0;
    for (sorted) |value| sum += value;

    return .{
        .min = sorted[0],
        .avg = sum / @as(f64, @floatFromInt(sorted.len)),
        .max = sorted[sorted.len - 1],
        .p1 = percentile(sorted, 0.01),
        .p5 = percentile(sorted, 0.05),
        .p50 = percentile(sorted, 0.50),
        .p95 = percentile(sorted, 0.95),
        .p99 = percentile(sorted, 0.99),
    };
}

fn percentile(sorted: []const f32, p: f64) f64 {
    if (sorted.len == 0) return 0;
    if (sorted.len == 1) return sorted[0];

    const clamped = std.math.clamp(p, 0.0, 1.0);
    const pos = clamped * @as(f64, @floatFromInt(sorted.len - 1));
    const lower: usize = @intFromFloat(@floor(pos));
    const upper = @min(lower + 1, sorted.len - 1);
    const frac = pos - @as(f64, @floatFromInt(lower));
    return @as(f64, sorted[lower]) * (1.0 - frac) + @as(f64, sorted[upper]) * frac;
}

fn lessThan(_: void, a: f32, b: f32) bool {
    return a < b;
}

fn averageArray(values: []const f32) f32 {
    if (values.len == 0) return 0;
    var sum: f32 = 0;
    for (values) |value| sum += value;
    return sum / @as(f32, @floatFromInt(values.len));
}

fn poseAtTime(time_s: f32) struct { pos: Vec3, look: Vec3 } {
    const total = pathDuration();
    if (total <= 0.0) {
        return .{ .pos = BENCH_PATH[0].pos, .look = BENCH_PATH[0].look.normalize() };
    }

    var t = time_s;
    while (t >= total) t -= total;
    while (t < 0) t += total;
    for (BENCH_PATH, 0..) |waypoint, i| {
        const next = BENCH_PATH[(i + 1) % BENCH_PATH.len];
        if (t <= waypoint.duration or i == BENCH_PATH.len - 1) {
            const segment = @max(waypoint.duration, 0.0001);
            const alpha = std.math.clamp(t / segment, 0.0, 1.0);
            const eased = alpha * alpha * (3.0 - 2.0 * alpha);
            return .{
                .pos = lerpVec3(waypoint.pos, next.pos, eased),
                .look = lerpVec3(waypoint.look, next.look, eased).normalize(),
            };
        }
        t -= waypoint.duration;
    }

    return .{ .pos = BENCH_PATH[0].pos, .look = BENCH_PATH[0].look.normalize() };
}

fn pathDuration() f32 {
    var total: f32 = 0;
    for (BENCH_PATH) |waypoint| total += waypoint.duration;
    return total;
}

fn lerpVec3(a: Vec3, b: Vec3, t: f32) Vec3 {
    return a.add(b.sub(a).scale(t));
}

fn yawFromLook(look: Vec3) f32 {
    return std.math.atan2(look.z, look.x);
}

fn pitchFromLook(look: Vec3) f32 {
    return std.math.asin(std.math.clamp(look.y, -1.0, 1.0));
}
