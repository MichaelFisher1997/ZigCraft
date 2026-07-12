const std = @import("std");
const fs = @import("fs");

const Player = @import("player.zig").Player;
const Vec3 = @import("engine-math").Vec3;
const GpuTimingResults = @import("engine-rhi").GpuTimingResults;
const WorldStats = @import("engine-ui").WorldStats;
const LODProfilingDisplay = @import("engine-ui").LODProfilingDisplay;

pub const Waypoint = struct {
    pos: Vec3,
    look: Vec3,
    duration: f32,
};

pub const BENCHMARK_WORLD_SEED: u64 = 12345;

pub const Scenario = enum {
    stationary,
    traversal,
    rapid_turn,
    teleport_eviction,

    pub fn parse(value: []const u8) !Scenario {
        if (std.mem.eql(u8, value, "stationary")) return .stationary;
        if (std.mem.eql(u8, value, "traversal")) return .traversal;
        if (std.mem.eql(u8, value, "rapid-turn")) return .rapid_turn;
        if (std.mem.eql(u8, value, "teleport-eviction")) return .teleport_eviction;
        return error.InvalidBenchmarkScenario;
    }

    pub fn name(self: Scenario) []const u8 {
        return switch (self) {
            .stationary => "stationary",
            .traversal => "traversal",
            .rapid_turn => "rapid-turn",
            .teleport_eviction => "teleport-eviction",
        };
    }
};

const Pose = struct {
    pos: Vec3,
    look: Vec3,
};

pub const BENCH_PATH = [_]Waypoint{
    .{ .pos = Vec3.init(8, 100, 8), .look = Vec3.init(1, 0, 0), .duration = 5.0 },
    .{ .pos = Vec3.init(200, 150, 200), .look = Vec3.init(0, -0.3, 1), .duration = 10.0 },
    .{ .pos = Vec3.init(-500, 80, 300), .look = Vec3.init(1, 0, -1), .duration = 10.0 },
    .{ .pos = Vec3.init(-900, 120, -200), .look = Vec3.init(0.2, -0.7, 0.1), .duration = 10.0 },
    .{ .pos = Vec3.init(300, 90, -800), .look = Vec3.init(-1, 0.25, 0.2), .duration = 10.0 },
    .{ .pos = Vec3.init(900, 160, 700), .look = Vec3.init(0.3, -0.9, -0.1), .duration = 15.0 },
};

const STATIONARY_PATH = [_]Waypoint{
    .{ .pos = Vec3.init(8, 100, 8), .look = Vec3.init(1, -0.1, 0), .duration = 60.0 },
};

const RAPID_TURN_PATH = [_]Waypoint{
    .{ .pos = Vec3.init(8, 100, 8), .look = Vec3.init(1, 0, 0), .duration = 1.0 },
    .{ .pos = Vec3.init(8, 100, 8), .look = Vec3.init(0.2, -0.2, 1), .duration = 1.0 },
    .{ .pos = Vec3.init(8, 100, 8), .look = Vec3.init(-1, 0.1, 0), .duration = 1.0 },
    .{ .pos = Vec3.init(8, 100, 8), .look = Vec3.init(-0.2, 0.2, -1), .duration = 1.0 },
};

const TELEPORT_EVICTION_PATH = [_]Waypoint{
    .{ .pos = Vec3.init(8, 100, 8), .look = Vec3.init(1, -0.1, 0), .duration = 4.0 },
    .{ .pos = Vec3.init(1_536, 140, 512), .look = Vec3.init(-1, -0.2, 0), .duration = 4.0 },
    .{ .pos = Vec3.init(-1_536, 120, 1_024), .look = Vec3.init(0, -0.1, -1), .duration = 4.0 },
    .{ .pos = Vec3.init(-1_024, 160, -1_536), .look = Vec3.init(1, -0.3, 0.2), .duration = 4.0 },
    .{ .pos = Vec3.init(1_024, 110, -1_024), .look = Vec3.init(0.1, -0.1, 1), .duration = 4.0 },
};

pub const FrameSample = struct {
    cpu_ms: f32,
    fps: f32,
    gpu_shadow_ms: f32,
    gpu_opaque_ms: f32,
    gpu_lod_terrain_ms: f32,
    gpu_lod_water_ms: f32,
    gpu_total_ms: f32,
    draw_calls: u32,
    vertices: u64,
    chunks_rendered: u32,
    gpu_memory_mb: f32,
    lod: LODFrameSample = .{},
};

/// One benchmark-frame delta derived from world-lod's cumulative telemetry.
/// Pending upload and deferred deletion byte values are gauges, not counters.
pub const LODFrameSample = struct {
    enabled: bool = false,
    cpu_ms: f64 = 0,
    scheduling_ms: f64 = 0,
    cache_ms: f64 = 0,
    generation_dispatch_ms: f64 = 0,
    state_transition_ms: f64 = 0,
    upload_prep_ms: f64 = 0,
    upload_submission_ms: f64 = 0,
    visibility_ms: f64 = 0,
    coverage_ms: f64 = 0,
    eviction_ms: f64 = 0,
    worker_generation_ms: f64 = 0,
    worker_mesh_construction_ms: f64 = 0,
    upload_bytes: u64 = 0,
    pending_cpu_upload_bytes: u64 = 0,
    staging_pressure_count: u64 = 0,
    visible_count: u64 = 0,
    rejected_count: u64 = 0,
    coverage_count: u64 = 0,
    deferred_deletion_bytes: u64 = 0,
    wait_idle_count: u64 = 0,
    wait_idle_ms: f64 = 0,
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
    lod_terrain_avg: f64,
    lod_water_avg: f64,
    total_avg: f64,
};

pub const TimingTotalAverage = struct {
    total_ms: f64,
    avg_ms: f64,
};

pub const LODCpuCategories = struct {
    scheduling: TimingTotalAverage,
    cache: TimingTotalAverage,
    generation_dispatch: TimingTotalAverage,
    state_transition: TimingTotalAverage,
    upload_prep: TimingTotalAverage,
    upload_submission: TimingTotalAverage,
    visibility: TimingTotalAverage,
    coverage: TimingTotalAverage,
    eviction: TimingTotalAverage,
};

pub const LODWorkerSummary = struct {
    generation_total_ms: f64,
    mesh_construction_total_ms: f64,
};

pub const ByteGaugeSummary = struct {
    avg_bytes: f64,
    max_bytes: u64,
    last_bytes: u64,
};

pub const LODMemorySummary = struct {
    upload_total_bytes: u64,
    upload_avg_bytes: f64,
    pending_cpu_upload_bytes: ByteGaugeSummary,
    deferred_deletion_bytes: ByteGaugeSummary,
};

pub const LODVisibilitySummary = struct {
    visible_total: u64,
    rejected_total: u64,
    coverage_total: u64,
};

pub const LODPressureSummary = struct {
    staging_pressure_total: u64,
    wait_idle_count_total: u64,
    wait_idle_ms_total: f64,
    wait_idle_ms_avg: f64,
};

pub const LODBenchmarkSummary = struct {
    profiling_enabled: bool,
    cpu_frame_ms: Summary,
    cpu_categories: LODCpuCategories,
    workers: LODWorkerSummary,
    memory_bytes: LODMemorySummary,
    visibility: LODVisibilitySummary,
    pressure: LODPressureSummary,
};

pub const WorstFrame = struct {
    frame_index: u32,
    frame_ms: f64,
    gpu_total_ms: f64,
    gpu_lod_terrain_ms: f64,
    gpu_lod_water_ms: f64,
    dominant_gpu_pass: []const u8,
    dominant_gpu_pass_ms: f64,
    lod_cpu_ms: f64,
    dominant_lod_cpu_category: []const u8,
    dominant_lod_cpu_category_ms: f64,
    lod_worker_generation_ms: f64,
    lod_worker_mesh_construction_ms: f64,
    lod_upload_bytes: u64,
    lod_pending_cpu_upload_bytes: u64,
    lod_deferred_deletion_bytes: u64,
    lod_visible_count: u64,
    lod_rejected_count: u64,
    lod_coverage_count: u64,
    lod_wait_idle_count: u64,
    lod_wait_idle_ms: f64,
    lod_staging_pressure_count: u64,
};

pub const BenchmarkResults = struct {
    preset: []const u8,
    scenario: []const u8,
    world_seed: u64,
    build: BuildMetadata,
    render_distance: i32,
    gpu_memory_mb_avg: f64,
    gpu_memory_mb_max: f64,
    frames: u32,
    duration_s: f32,
    fps: Summary,
    frame_ms: Summary,
    max_frame_ms: f64,
    cpu_ms_avg: f64,
    gpu_ms: GpuSummary,
    draw_calls_avg: f64,
    vertices_avg: f64,
    chunks_rendered_avg: f64,
    worst_frame: WorstFrame,
    lod: LODBenchmarkSummary,
};

pub const BuildMetadata = struct {
    mode: []const u8,
    headless: bool = true,
    resolution: [2]u32 = .{ 1920, 1080 },
};

pub const BenchmarkRunner = struct {
    allocator: std.mem.Allocator,
    preset: []const u8,
    scenario: Scenario,
    render_distance: i32,
    duration_s: f32,
    world_seed: u64,
    build: BuildMetadata,
    output_path: []const u8,
    start_ms: i64,
    elapsed_s: f32 = 0,
    sampled_s: f32 = 0,
    warmup_s: f32 = 1.0,
    samples: std.ArrayListUnmanaged(FrameSample) = .empty,
    previous_lod_profiling: ?LODProfilingDisplay = null,

    pub fn init(
        allocator: std.mem.Allocator,
        preset: []const u8,
        scenario_name: []const u8,
        render_distance: i32,
        duration_s: f32,
        world_seed: u64,
        build_mode: []const u8,
        output_path: []const u8,
    ) !BenchmarkRunner {
        var runner = BenchmarkRunner{
            .allocator = allocator,
            .preset = preset,
            .scenario = try Scenario.parse(scenario_name),
            .render_distance = render_distance,
            .duration_s = duration_s,
            .world_seed = world_seed,
            .build = .{ .mode = build_mode },
            .output_path = output_path,
            .start_ms = nowMs(),
            .elapsed_s = 0,
            .sampled_s = 0,
            .warmup_s = 1.0,
            .samples = .empty,
            .previous_lod_profiling = null,
        };

        const estimate_frames = @max(@as(usize, 64), @as(usize, @intFromFloat(@ceil(duration_s * 120.0))));
        try runner.samples.ensureTotalCapacity(allocator, estimate_frames);
        return runner;
    }

    pub fn deinit(self: *BenchmarkRunner) void {
        self.samples.deinit(self.allocator);
    }

    pub fn applyPose(self: *const BenchmarkRunner, player: *Player) void {
        const pose = poseAtTime(self.scenario, @max(self.elapsed_s - self.warmup_s, 0.0));
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
        self.elapsed_s += dt;
        const profiling = if (world_stats) |ws| blk: {
            if (ws.lod) |ls| break :blk ls.profiling;
            break :blk null;
        } else null;
        const lod = lodFrameDelta(profiling, &self.previous_lod_profiling);
        if (self.elapsed_s < self.warmup_s) return;

        const shadow_avg = averageArray(&gpu.shadow_pass_ms);
        const chunks_rendered = if (world_stats) |ws| ws.chunks_rendered else 0;
        const vertices = if (world_stats) |ws| ws.vertices_rendered else 0;
        const frame_fps = if (dt > 0.000001) 1.0 / dt else fps;

        try self.samples.append(self.allocator, .{
            .cpu_ms = dt * 1000.0,
            .fps = frame_fps,
            .gpu_shadow_ms = shadow_avg,
            .gpu_opaque_ms = gpu.opaque_pass_ms,
            .gpu_lod_terrain_ms = gpu.lod_terrain_pass_ms,
            .gpu_lod_water_ms = gpu.lod_water_pass_ms,
            .gpu_total_ms = gpu.total_gpu_ms,
            .draw_calls = draw_calls,
            .vertices = vertices,
            .chunks_rendered = chunks_rendered,
            .gpu_memory_mb = gpu_memory_mb,
            .lod = lod,
        });
        self.sampled_s += dt;
    }

    pub fn isComplete(self: *const BenchmarkRunner) bool {
        return self.sampled_s >= self.duration_s or wallElapsedSeconds(self) >= self.duration_s + self.warmup_s + 30.0;
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
        const frame_ms_values = try self.collectField(frameMsField);
        defer self.allocator.free(frame_ms_values);
        const lod_cpu_values = try self.collectLodCpuValues();
        defer self.allocator.free(lod_cpu_values);

        var cpu_sum: f64 = 0;
        var shadow_sum: f64 = 0;
        var opaque_sum: f64 = 0;
        var lod_terrain_sum: f64 = 0;
        var lod_water_sum: f64 = 0;
        var total_sum: f64 = 0;
        var draw_sum: f64 = 0;
        var vertices_sum: f64 = 0;
        var chunks_sum: f64 = 0;
        var memory_sum: f64 = 0;
        var memory_max: f64 = 0;
        var max_frame_ms: f64 = 0;
        var lod_profiling_enabled = false;
        var lod_scheduling_ms: f64 = 0;
        var lod_cache_ms: f64 = 0;
        var lod_generation_dispatch_ms: f64 = 0;
        var lod_state_transition_ms: f64 = 0;
        var lod_upload_prep_ms: f64 = 0;
        var lod_upload_submission_ms: f64 = 0;
        var lod_visibility_ms: f64 = 0;
        var lod_coverage_ms: f64 = 0;
        var lod_eviction_ms: f64 = 0;
        var lod_worker_generation_ms: f64 = 0;
        var lod_worker_mesh_construction_ms: f64 = 0;
        var lod_upload_bytes: u64 = 0;
        var lod_pending_cpu_upload_bytes_sum: f64 = 0;
        var lod_pending_cpu_upload_bytes_max: u64 = 0;
        var lod_pending_cpu_upload_bytes_last: u64 = 0;
        var lod_deferred_deletion_bytes_sum: f64 = 0;
        var lod_deferred_deletion_bytes_max: u64 = 0;
        var lod_deferred_deletion_bytes_last: u64 = 0;
        var lod_staging_pressure_count: u64 = 0;
        var lod_visible_count: u64 = 0;
        var lod_rejected_count: u64 = 0;
        var lod_coverage_count: u64 = 0;
        var lod_wait_idle_count: u64 = 0;
        var lod_wait_idle_ms: f64 = 0;
        var worst_frame = WorstFrame{
            .frame_index = 0,
            .frame_ms = 0,
            .gpu_total_ms = 0,
            .gpu_lod_terrain_ms = 0,
            .gpu_lod_water_ms = 0,
            .dominant_gpu_pass = "none",
            .dominant_gpu_pass_ms = 0,
            .lod_cpu_ms = 0,
            .dominant_lod_cpu_category = "none",
            .dominant_lod_cpu_category_ms = 0,
            .lod_worker_generation_ms = 0,
            .lod_worker_mesh_construction_ms = 0,
            .lod_upload_bytes = 0,
            .lod_pending_cpu_upload_bytes = 0,
            .lod_deferred_deletion_bytes = 0,
            .lod_visible_count = 0,
            .lod_rejected_count = 0,
            .lod_coverage_count = 0,
            .lod_wait_idle_count = 0,
            .lod_wait_idle_ms = 0,
            .lod_staging_pressure_count = 0,
        };

        for (self.samples.items, 0..) |sample, index| {
            cpu_sum += sample.cpu_ms;
            if (sample.cpu_ms > max_frame_ms) {
                max_frame_ms = sample.cpu_ms;
                worst_frame = worstFrameForSample(index, sample);
            }
            shadow_sum += sample.gpu_shadow_ms;
            opaque_sum += sample.gpu_opaque_ms;
            lod_terrain_sum += sample.gpu_lod_terrain_ms;
            lod_water_sum += sample.gpu_lod_water_ms;
            total_sum += sample.gpu_total_ms;
            draw_sum += @floatFromInt(sample.draw_calls);
            vertices_sum += @floatFromInt(sample.vertices);
            chunks_sum += @floatFromInt(sample.chunks_rendered);
            memory_sum += sample.gpu_memory_mb;
            memory_max = @max(memory_max, sample.gpu_memory_mb);

            const lod = sample.lod;
            lod_profiling_enabled = lod_profiling_enabled or lod.enabled;
            lod_scheduling_ms += lod.scheduling_ms;
            lod_cache_ms += lod.cache_ms;
            lod_generation_dispatch_ms += lod.generation_dispatch_ms;
            lod_state_transition_ms += lod.state_transition_ms;
            lod_upload_prep_ms += lod.upload_prep_ms;
            lod_upload_submission_ms += lod.upload_submission_ms;
            lod_visibility_ms += lod.visibility_ms;
            lod_coverage_ms += lod.coverage_ms;
            lod_eviction_ms += lod.eviction_ms;
            lod_worker_generation_ms += lod.worker_generation_ms;
            lod_worker_mesh_construction_ms += lod.worker_mesh_construction_ms;
            lod_upload_bytes +|= lod.upload_bytes;
            lod_pending_cpu_upload_bytes_sum += @floatFromInt(lod.pending_cpu_upload_bytes);
            lod_pending_cpu_upload_bytes_max = @max(lod_pending_cpu_upload_bytes_max, lod.pending_cpu_upload_bytes);
            lod_pending_cpu_upload_bytes_last = lod.pending_cpu_upload_bytes;
            lod_deferred_deletion_bytes_sum += @floatFromInt(lod.deferred_deletion_bytes);
            lod_deferred_deletion_bytes_max = @max(lod_deferred_deletion_bytes_max, lod.deferred_deletion_bytes);
            lod_deferred_deletion_bytes_last = lod.deferred_deletion_bytes;
            lod_staging_pressure_count +|= lod.staging_pressure_count;
            lod_visible_count +|= lod.visible_count;
            lod_rejected_count +|= lod.rejected_count;
            lod_coverage_count +|= lod.coverage_count;
            lod_wait_idle_count +|= lod.wait_idle_count;
            lod_wait_idle_ms += lod.wait_idle_ms;
        }

        const count = @as(f64, @floatFromInt(@max(self.samples.items.len, 1)));
        var fps_summary = try summarizeSeries(self.allocator, fps_values);
        const frame_ms_summary = try summarizeSeries(self.allocator, frame_ms_values);
        const lod_cpu_summary = try summarizeSeries(self.allocator, lod_cpu_values);
        const sampled_s = cpu_sum / 1000.0;
        if (sampled_s > 0.0) {
            fps_summary.avg = @as(f64, @floatFromInt(self.samples.items.len)) / sampled_s;
        }

        return .{
            .preset = self.preset,
            .scenario = self.scenario.name(),
            .world_seed = self.world_seed,
            .build = self.build,
            .render_distance = self.render_distance,
            .gpu_memory_mb_avg = memory_sum / count,
            .gpu_memory_mb_max = memory_max,
            .frames = @intCast(self.samples.items.len),
            .duration_s = self.duration_s,
            .fps = fps_summary,
            .frame_ms = frame_ms_summary,
            .max_frame_ms = max_frame_ms,
            .cpu_ms_avg = cpu_sum / count,
            .gpu_ms = .{
                .shadow_avg = shadow_sum / count,
                .opaque_avg = opaque_sum / count,
                .lod_terrain_avg = lod_terrain_sum / count,
                .lod_water_avg = lod_water_sum / count,
                .total_avg = total_sum / count,
            },
            .draw_calls_avg = draw_sum / count,
            .vertices_avg = vertices_sum / count,
            .chunks_rendered_avg = chunks_sum / count,
            .worst_frame = worst_frame,
            .lod = .{
                .profiling_enabled = lod_profiling_enabled,
                .cpu_frame_ms = lod_cpu_summary,
                .cpu_categories = .{
                    .scheduling = timingTotalAverage(lod_scheduling_ms, count),
                    .cache = timingTotalAverage(lod_cache_ms, count),
                    .generation_dispatch = timingTotalAverage(lod_generation_dispatch_ms, count),
                    .state_transition = timingTotalAverage(lod_state_transition_ms, count),
                    .upload_prep = timingTotalAverage(lod_upload_prep_ms, count),
                    .upload_submission = timingTotalAverage(lod_upload_submission_ms, count),
                    .visibility = timingTotalAverage(lod_visibility_ms, count),
                    .coverage = timingTotalAverage(lod_coverage_ms, count),
                    .eviction = timingTotalAverage(lod_eviction_ms, count),
                },
                .workers = .{
                    .generation_total_ms = lod_worker_generation_ms,
                    .mesh_construction_total_ms = lod_worker_mesh_construction_ms,
                },
                .memory_bytes = .{
                    .upload_total_bytes = lod_upload_bytes,
                    .upload_avg_bytes = @as(f64, @floatFromInt(lod_upload_bytes)) / count,
                    .pending_cpu_upload_bytes = .{
                        .avg_bytes = lod_pending_cpu_upload_bytes_sum / count,
                        .max_bytes = lod_pending_cpu_upload_bytes_max,
                        .last_bytes = lod_pending_cpu_upload_bytes_last,
                    },
                    .deferred_deletion_bytes = .{
                        .avg_bytes = lod_deferred_deletion_bytes_sum / count,
                        .max_bytes = lod_deferred_deletion_bytes_max,
                        .last_bytes = lod_deferred_deletion_bytes_last,
                    },
                },
                .visibility = .{
                    .visible_total = lod_visible_count,
                    .rejected_total = lod_rejected_count,
                    .coverage_total = lod_coverage_count,
                },
                .pressure = .{
                    .staging_pressure_total = lod_staging_pressure_count,
                    .wait_idle_count_total = lod_wait_idle_count,
                    .wait_idle_ms_total = lod_wait_idle_ms,
                    .wait_idle_ms_avg = lod_wait_idle_ms / count,
                },
            },
        };
    }

    fn collectField(self: *const BenchmarkRunner, comptime getter: fn (FrameSample) f32) ![]f32 {
        var values = try self.allocator.alloc(f32, self.samples.items.len);
        for (self.samples.items, 0..) |sample, i| {
            values[i] = getter(sample);
        }
        return values;
    }

    fn collectLodCpuValues(self: *const BenchmarkRunner) ![]f32 {
        var values = try self.allocator.alloc(f32, self.samples.items.len);
        for (self.samples.items, 0..) |sample, i| {
            values[i] = @floatCast(sample.lod.cpu_ms);
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

fn baselineRenderDistanceForPreset(preset: []const u8) i32 {
    if (std.ascii.eqlIgnoreCase(preset, "low")) return 6;
    if (std.ascii.eqlIgnoreCase(preset, "medium")) return 10;
    if (std.ascii.eqlIgnoreCase(preset, "high")) return 12;
    if (std.ascii.eqlIgnoreCase(preset, "ultra")) return 14;
    if (std.ascii.eqlIgnoreCase(preset, "extreme")) return 16;
    return 12;
}

fn thresholdsForResults(results: BenchmarkResults) SloThresholds {
    var thresholds = thresholdsForPreset(results.preset);
    const baseline = baselineRenderDistanceForPreset(results.preset);
    if (results.render_distance > baseline) {
        const extra_chunks: f64 = @floatFromInt(results.render_distance - baseline);
        thresholds.draw_calls_max *= 1.0 + extra_chunks * 0.05;
    }
    return thresholds;
}

fn enforceSlo(results: BenchmarkResults) !void {
    const thresholds = thresholdsForResults(results);
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

test "benchmark draw-call SLO scales for render-distance override" {
    const base = thresholdsForPreset("medium");
    const results = BenchmarkResults{
        .preset = "medium",
        .scenario = "traversal",
        .world_seed = BENCHMARK_WORLD_SEED,
        .build = .{ .mode = "Debug" },
        .render_distance = 22,
        .gpu_memory_mb_avg = 0,
        .gpu_memory_mb_max = 0,
        .frames = 0,
        .duration_s = 0,
        .fps = .{ .min = 0, .avg = 0, .max = 0, .p1 = 0, .p5 = 0, .p50 = 0, .p95 = 0, .p99 = 0 },
        .frame_ms = .{ .min = 0, .avg = 0, .max = 0, .p1 = 0, .p5 = 0, .p50 = 0, .p95 = 0, .p99 = 0 },
        .max_frame_ms = 0,
        .cpu_ms_avg = 0,
        .gpu_ms = .{ .shadow_avg = 0, .opaque_avg = 0, .lod_terrain_avg = 0, .lod_water_avg = 0, .total_avg = 0 },
        .draw_calls_avg = 0,
        .vertices_avg = 0,
        .chunks_rendered_avg = 0,
        .worst_frame = .{
            .frame_index = 0,
            .frame_ms = 0,
            .gpu_total_ms = 0,
            .gpu_lod_terrain_ms = 0,
            .gpu_lod_water_ms = 0,
            .dominant_gpu_pass = "none",
            .dominant_gpu_pass_ms = 0,
            .lod_cpu_ms = 0,
            .dominant_lod_cpu_category = "none",
            .dominant_lod_cpu_category_ms = 0,
            .lod_worker_generation_ms = 0,
            .lod_worker_mesh_construction_ms = 0,
            .lod_upload_bytes = 0,
            .lod_pending_cpu_upload_bytes = 0,
            .lod_deferred_deletion_bytes = 0,
            .lod_visible_count = 0,
            .lod_rejected_count = 0,
            .lod_coverage_count = 0,
            .lod_wait_idle_count = 0,
            .lod_wait_idle_ms = 0,
            .lod_staging_pressure_count = 0,
        },
        .lod = .{
            .profiling_enabled = false,
            .cpu_frame_ms = .{ .min = 0, .avg = 0, .max = 0, .p1 = 0, .p5 = 0, .p50 = 0, .p95 = 0, .p99 = 0 },
            .cpu_categories = .{
                .scheduling = .{ .total_ms = 0, .avg_ms = 0 },
                .cache = .{ .total_ms = 0, .avg_ms = 0 },
                .generation_dispatch = .{ .total_ms = 0, .avg_ms = 0 },
                .state_transition = .{ .total_ms = 0, .avg_ms = 0 },
                .upload_prep = .{ .total_ms = 0, .avg_ms = 0 },
                .upload_submission = .{ .total_ms = 0, .avg_ms = 0 },
                .visibility = .{ .total_ms = 0, .avg_ms = 0 },
                .coverage = .{ .total_ms = 0, .avg_ms = 0 },
                .eviction = .{ .total_ms = 0, .avg_ms = 0 },
            },
            .workers = .{ .generation_total_ms = 0, .mesh_construction_total_ms = 0 },
            .memory_bytes = .{
                .upload_total_bytes = 0,
                .upload_avg_bytes = 0,
                .pending_cpu_upload_bytes = .{ .avg_bytes = 0, .max_bytes = 0, .last_bytes = 0 },
                .deferred_deletion_bytes = .{ .avg_bytes = 0, .max_bytes = 0, .last_bytes = 0 },
            },
            .visibility = .{ .visible_total = 0, .rejected_total = 0, .coverage_total = 0 },
            .pressure = .{ .staging_pressure_total = 0, .wait_idle_count_total = 0, .wait_idle_ms_total = 0, .wait_idle_ms_avg = 0 },
        },
    };
    const adjusted = thresholdsForResults(results);

    try std.testing.expect(adjusted.draw_calls_max > base.draw_calls_max);
    try std.testing.expectEqual(base.gpu_memory_mb_max, adjusted.gpu_memory_mb_max);
    try std.testing.expectEqual(base.fps_p1_min, adjusted.fps_p1_min);
}

test "benchmark reports LOD GPU timing, frame percentiles, and worst-frame attribution" {
    var runner = try BenchmarkRunner.init(std.testing.allocator, "medium", "traversal", 12, 1, BENCHMARK_WORLD_SEED, "Debug", "unused.json");
    defer runner.deinit();

    try runner.samples.append(std.testing.allocator, .{
        .cpu_ms = 10,
        .fps = 100,
        .gpu_shadow_ms = 1,
        .gpu_opaque_ms = 2,
        .gpu_lod_terrain_ms = 3,
        .gpu_lod_water_ms = 4,
        .gpu_total_ms = 8,
        .draw_calls = 10,
        .vertices = 100,
        .chunks_rendered = 1,
        .gpu_memory_mb = 100,
    });
    try runner.samples.append(std.testing.allocator, .{
        .cpu_ms = 20,
        .fps = 50,
        .gpu_shadow_ms = 1,
        .gpu_opaque_ms = 2,
        .gpu_lod_terrain_ms = 9,
        .gpu_lod_water_ms = 4,
        .gpu_total_ms = 16,
        .draw_calls = 20,
        .vertices = 200,
        .chunks_rendered = 2,
        .gpu_memory_mb = 200,
    });

    const results = try runner.makeResults();
    try std.testing.expectApproxEqAbs(@as(f64, 15), results.frame_ms.p50, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 19.5), results.frame_ms.p95, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 8), results.gpu_ms.lod_terrain_avg, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 4), results.gpu_ms.lod_water_avg, 0.001);
    try std.testing.expectEqual(@as(u32, 1), results.worst_frame.frame_index);
    try std.testing.expectEqualStrings("lod_terrain", results.worst_frame.dominant_gpu_pass);
    try std.testing.expectApproxEqAbs(@as(f64, 9), results.worst_frame.dominant_gpu_pass_ms, 0.001);
    try std.testing.expectEqualStrings("traversal", results.scenario);
    try std.testing.expectEqual(BENCHMARK_WORLD_SEED, results.world_seed);
    try std.testing.expectEqualStrings("Debug", results.build.mode);
}

test "benchmark projects LOD profiling deltas and accepts cumulative counter resets" {
    const Test = struct {
        fn world(profiling: LODProfilingDisplay) WorldStats {
            return .{
                .chunks_total = 0,
                .chunks_rendered = 0,
                .chunks_culled = 0,
                .vertices_rendered = 0,
                .gen_queue = 0,
                .mesh_queue = 0,
                .upload_queue = 0,
                .lod = .{
                    .loaded = .{ 0, 0, 0, 0, 0 },
                    .memory_used_mb = 0,
                    .profiling = profiling,
                },
            };
        }
    };

    var runner = try BenchmarkRunner.init(std.testing.allocator, "medium", "traversal", 12, 1, BENCHMARK_WORLD_SEED, "Debug", "unused.json");
    defer runner.deinit();
    runner.warmup_s = 0;
    const gpu = std.mem.zeroes(GpuTimingResults);

    try runner.recordFrame(0.01, 100, gpu, Test.world(.{
        .enabled = true,
        .update_ms = 10,
        .scheduling_ms = 5,
        .cache_ms = 1,
        .generation_dispatch_ms = 2,
        .state_transition_ms = 1,
        .upload_prep_ms = 1,
        .upload_submission_ms = 1,
        .visibility_ms = 1,
        .coverage_ms = 1,
        .eviction_ms = 1,
        .worker_generation_ms = 8,
        .worker_mesh_construction_ms = 4,
        .upload_bytes = 100,
        .pending_cpu_upload_bytes = 10,
        .staging_pressure_count = 3,
        .visible_count = 10,
        .rejected_count = 4,
        .coverage_count = 6,
        .deferred_deletion_bytes = 30,
        .wait_idle_count = 5,
        .wait_idle_ms = 3,
    }), 0, 0);
    try runner.recordFrame(0.02, 50, gpu, Test.world(.{
        .enabled = true,
        .update_ms = 12,
        .scheduling_ms = 7,
        .cache_ms = 2,
        .generation_dispatch_ms = 3,
        .state_transition_ms = 2,
        .upload_prep_ms = 3,
        .upload_submission_ms = 4,
        .visibility_ms = 3,
        .coverage_ms = 2,
        .eviction_ms = 2,
        .worker_generation_ms = 12,
        .worker_mesh_construction_ms = 6,
        .upload_bytes = 150,
        .pending_cpu_upload_bytes = 20,
        .staging_pressure_count = 4,
        .visible_count = 13,
        .rejected_count = 5,
        .coverage_count = 8,
        .deferred_deletion_bytes = 40,
        .wait_idle_count = 6,
        .wait_idle_ms = 5,
    }), 0, 0);
    try runner.recordFrame(0.03, 33, gpu, Test.world(.{
        .enabled = true,
        .update_ms = 1,
        .scheduling_ms = 0.5,
        .cache_ms = 4,
        .generation_dispatch_ms = 0.25,
        .state_transition_ms = 0.5,
        .upload_prep_ms = 0.25,
        .upload_submission_ms = 0.25,
        .visibility_ms = 0.5,
        .coverage_ms = 0.25,
        .eviction_ms = 0.5,
        .worker_generation_ms = 3,
        .worker_mesh_construction_ms = 2,
        .upload_bytes = 20,
        .pending_cpu_upload_bytes = 5,
        .staging_pressure_count = 2,
        .visible_count = 2,
        .rejected_count = 1,
        .coverage_count = 3,
        .deferred_deletion_bytes = 8,
        .wait_idle_count = 2,
        .wait_idle_ms = 0.5,
    }), 0, 0);

    const results = try runner.makeResults();
    try std.testing.expect(results.lod.profiling_enabled);
    try std.testing.expectApproxEqAbs(@as(f64, 1), results.lod.cpu_frame_ms.p50, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.9), results.lod.cpu_frame_ms.p95, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), results.lod.cpu_categories.scheduling.total_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 5), results.lod.cpu_categories.cache.total_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 7), results.lod.workers.generation_total_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 4), results.lod.workers.mesh_construction_total_ms, 0.001);
    try std.testing.expectEqual(@as(u64, 70), results.lod.memory_bytes.upload_total_bytes);
    try std.testing.expectEqual(@as(u64, 20), results.lod.memory_bytes.pending_cpu_upload_bytes.max_bytes);
    try std.testing.expectEqual(@as(u64, 8), results.lod.memory_bytes.deferred_deletion_bytes.last_bytes);
    try std.testing.expectEqual(@as(u64, 5), results.lod.visibility.visible_total);
    try std.testing.expectEqual(@as(u64, 2), results.lod.visibility.rejected_total);
    try std.testing.expectEqual(@as(u64, 5), results.lod.visibility.coverage_total);
    try std.testing.expectEqual(@as(u64, 3), results.lod.pressure.wait_idle_count_total);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), results.lod.pressure.wait_idle_ms_total, 0.001);
    try std.testing.expectEqual(@as(u64, 3), results.lod.pressure.staging_pressure_total);
    try std.testing.expectEqual(@as(u32, 2), results.worst_frame.frame_index);
    try std.testing.expectEqualStrings("cache", results.worst_frame.dominant_lod_cpu_category);
    try std.testing.expectEqual(@as(u64, 20), results.worst_frame.lod_upload_bytes);
}

test "benchmark scenarios have stable bounded poses" {
    try std.testing.expectEqual(Scenario.traversal, try Scenario.parse("traversal"));
    try std.testing.expectEqual(Scenario.teleport_eviction, try Scenario.parse("teleport-eviction"));
    try std.testing.expectError(error.InvalidBenchmarkScenario, Scenario.parse("unbounded"));

    const stationary_a = poseAtTime(.stationary, 0);
    const stationary_b = poseAtTime(.stationary, 37);
    try std.testing.expectApproxEqAbs(stationary_a.pos.x, stationary_b.pos.x, 0.0001);
    try std.testing.expectApproxEqAbs(stationary_a.pos.z, stationary_b.pos.z, 0.0001);

    const teleport_a = poseAtTime(.teleport_eviction, 3.9);
    const teleport_b = poseAtTime(.teleport_eviction, 4.0);
    try std.testing.expectApproxEqAbs(@as(f32, 8), teleport_a.pos.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1_536), teleport_b.pos.x, 0.0001);

    const rapid_turn_a = poseAtTime(.rapid_turn, 0);
    const rapid_turn_b = poseAtTime(.rapid_turn, 1);
    try std.testing.expect(rapid_turn_a.look.z < rapid_turn_b.look.z);
}

fn fpsField(sample: FrameSample) f32 {
    return sample.fps;
}

fn frameMsField(sample: FrameSample) f32 {
    return sample.cpu_ms;
}

fn timingTotalAverage(total_ms: f64, frame_count: f64) TimingTotalAverage {
    return .{ .total_ms = total_ms, .avg_ms = total_ms / frame_count };
}

/// Calculates a per-frame telemetry sample. A reduced cumulative value means
/// the LOD collector reset, so the current value is used instead of underflowing.
fn lodFrameDelta(current: ?LODProfilingDisplay, previous: *?LODProfilingDisplay) LODFrameSample {
    const snapshot = current orelse {
        previous.* = null;
        return .{};
    };
    const last = previous.*;
    previous.* = snapshot;

    const gauges = struct {
        pending_cpu_upload_bytes: u64,
        deferred_deletion_bytes: u64,
    }{
        .pending_cpu_upload_bytes = snapshot.pending_cpu_upload_bytes,
        .deferred_deletion_bytes = snapshot.deferred_deletion_bytes,
    };
    if (!snapshot.enabled or last == null or !last.?.enabled) {
        return .{
            .enabled = snapshot.enabled,
            .pending_cpu_upload_bytes = gauges.pending_cpu_upload_bytes,
            .deferred_deletion_bytes = gauges.deferred_deletion_bytes,
        };
    }

    const prior = last.?;
    return .{
        .enabled = true,
        // Manager update and render visibility work are separate main-thread
        // scopes. Coverage is nested in visibility and is not added again.
        .cpu_ms = cumulativeTimingDelta(snapshot.update_ms, prior.update_ms) + cumulativeTimingDelta(snapshot.visibility_ms, prior.visibility_ms),
        .scheduling_ms = cumulativeTimingDelta(snapshot.scheduling_ms, prior.scheduling_ms),
        .cache_ms = cumulativeTimingDelta(snapshot.cache_ms, prior.cache_ms),
        .generation_dispatch_ms = cumulativeTimingDelta(snapshot.generation_dispatch_ms, prior.generation_dispatch_ms),
        .state_transition_ms = cumulativeTimingDelta(snapshot.state_transition_ms, prior.state_transition_ms),
        .upload_prep_ms = cumulativeTimingDelta(snapshot.upload_prep_ms, prior.upload_prep_ms),
        .upload_submission_ms = cumulativeTimingDelta(snapshot.upload_submission_ms, prior.upload_submission_ms),
        .visibility_ms = cumulativeTimingDelta(snapshot.visibility_ms, prior.visibility_ms),
        .coverage_ms = cumulativeTimingDelta(snapshot.coverage_ms, prior.coverage_ms),
        .eviction_ms = cumulativeTimingDelta(snapshot.eviction_ms, prior.eviction_ms),
        .worker_generation_ms = cumulativeTimingDelta(snapshot.worker_generation_ms, prior.worker_generation_ms),
        .worker_mesh_construction_ms = cumulativeTimingDelta(snapshot.worker_mesh_construction_ms, prior.worker_mesh_construction_ms),
        .upload_bytes = cumulativeCounterDelta(snapshot.upload_bytes, prior.upload_bytes),
        .pending_cpu_upload_bytes = gauges.pending_cpu_upload_bytes,
        .staging_pressure_count = cumulativeCounterDelta(snapshot.staging_pressure_count, prior.staging_pressure_count),
        .visible_count = cumulativeCounterDelta(snapshot.visible_count, prior.visible_count),
        .rejected_count = cumulativeCounterDelta(snapshot.rejected_count, prior.rejected_count),
        .coverage_count = cumulativeCounterDelta(snapshot.coverage_count, prior.coverage_count),
        .deferred_deletion_bytes = gauges.deferred_deletion_bytes,
        .wait_idle_count = cumulativeCounterDelta(snapshot.wait_idle_count, prior.wait_idle_count),
        .wait_idle_ms = cumulativeTimingDelta(snapshot.wait_idle_ms, prior.wait_idle_ms),
    };
}

fn cumulativeTimingDelta(current: f64, previous: f64) f64 {
    if (!std.math.isFinite(current) or current < 0) return 0;
    if (!std.math.isFinite(previous) or previous < 0 or current < previous) return current;
    return current - previous;
}

fn cumulativeCounterDelta(current: u64, previous: u64) u64 {
    return if (current < previous) current else current - previous;
}

fn worstFrameForSample(index: usize, sample: FrameSample) WorstFrame {
    var dominant_gpu_pass: []const u8 = "shadow";
    var dominant_gpu_pass_ms = sample.gpu_shadow_ms;
    if (sample.gpu_opaque_ms > dominant_gpu_pass_ms) {
        dominant_gpu_pass = "opaque";
        dominant_gpu_pass_ms = sample.gpu_opaque_ms;
    }
    if (sample.gpu_lod_terrain_ms > dominant_gpu_pass_ms) {
        dominant_gpu_pass = "lod_terrain";
        dominant_gpu_pass_ms = sample.gpu_lod_terrain_ms;
    }
    if (sample.gpu_lod_water_ms > dominant_gpu_pass_ms) {
        dominant_gpu_pass = "lod_water";
        dominant_gpu_pass_ms = sample.gpu_lod_water_ms;
    }

    const lod_attribution = dominantLodCpuCategory(sample.lod);

    return .{
        .frame_index = @intCast(index),
        .frame_ms = sample.cpu_ms,
        .gpu_total_ms = sample.gpu_total_ms,
        .gpu_lod_terrain_ms = sample.gpu_lod_terrain_ms,
        .gpu_lod_water_ms = sample.gpu_lod_water_ms,
        .dominant_gpu_pass = dominant_gpu_pass,
        .dominant_gpu_pass_ms = dominant_gpu_pass_ms,
        .lod_cpu_ms = sample.lod.cpu_ms,
        .dominant_lod_cpu_category = lod_attribution.name,
        .dominant_lod_cpu_category_ms = lod_attribution.ms,
        .lod_worker_generation_ms = sample.lod.worker_generation_ms,
        .lod_worker_mesh_construction_ms = sample.lod.worker_mesh_construction_ms,
        .lod_upload_bytes = sample.lod.upload_bytes,
        .lod_pending_cpu_upload_bytes = sample.lod.pending_cpu_upload_bytes,
        .lod_deferred_deletion_bytes = sample.lod.deferred_deletion_bytes,
        .lod_visible_count = sample.lod.visible_count,
        .lod_rejected_count = sample.lod.rejected_count,
        .lod_coverage_count = sample.lod.coverage_count,
        .lod_wait_idle_count = sample.lod.wait_idle_count,
        .lod_wait_idle_ms = sample.lod.wait_idle_ms,
        .lod_staging_pressure_count = sample.lod.staging_pressure_count,
    };
}

fn dominantLodCpuCategory(sample: LODFrameSample) struct { name: []const u8, ms: f64 } {
    var name: []const u8 = "none";
    var ms: f64 = 0;
    const candidates = [_]struct { name: []const u8, ms: f64 }{
        .{ .name = "scheduling", .ms = sample.scheduling_ms },
        .{ .name = "cache", .ms = sample.cache_ms },
        .{ .name = "generation_dispatch", .ms = sample.generation_dispatch_ms },
        .{ .name = "state_transition", .ms = sample.state_transition_ms },
        .{ .name = "upload_prep", .ms = sample.upload_prep_ms },
        .{ .name = "upload_submission", .ms = sample.upload_submission_ms },
        .{ .name = "visibility", .ms = sample.visibility_ms },
        .{ .name = "coverage", .ms = sample.coverage_ms },
        .{ .name = "eviction", .ms = sample.eviction_ms },
    };
    for (candidates) |candidate| {
        if (candidate.ms > ms) {
            name = candidate.name;
            ms = candidate.ms;
        }
    }
    return .{ .name = name, .ms = ms };
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

fn poseAtTime(scenario: Scenario, time_s: f32) Pose {
    return switch (scenario) {
        .stationary => poseAtWaypoints(&STATIONARY_PATH, time_s, true),
        // Keep traversal byte-for-byte equivalent to the benchmark path that
        // predated scenarios so its existing baseline remains meaningful.
        .traversal => poseAtWaypoints(&BENCH_PATH, time_s, true),
        .rapid_turn => poseAtWaypoints(&RAPID_TURN_PATH, time_s, true),
        // Eviction pressure requires discontinuous player movement rather
        // than interpolation between distant locations.
        .teleport_eviction => poseAtWaypoints(&TELEPORT_EVICTION_PATH, time_s, false),
    };
}

fn poseAtWaypoints(path: []const Waypoint, time_s: f32, interpolate: bool) Pose {
    const total = pathDuration(path);
    if (total <= 0.0) {
        return .{ .pos = path[0].pos, .look = path[0].look.normalize() };
    }

    var t = time_s;
    while (t >= total) t -= total;
    while (t < 0) t += total;
    for (path, 0..) |waypoint, i| {
        const next = path[(i + 1) % path.len];
        const in_segment = if (interpolate) t <= waypoint.duration else t < waypoint.duration;
        if (in_segment or i == path.len - 1) {
            if (!interpolate) {
                return .{ .pos = waypoint.pos, .look = waypoint.look.normalize() };
            }
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

    return .{ .pos = path[0].pos, .look = path[0].look.normalize() };
}

fn pathDuration(path: []const Waypoint) f32 {
    var total: f32 = 0;
    for (path) |waypoint| total += waypoint.duration;
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
