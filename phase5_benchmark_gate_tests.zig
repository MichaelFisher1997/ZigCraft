//! Machine-checkable Phase 5 benchmark policy contract.
//!
//! Runtime thresholds live in `game-core/benchmark.zig`; the benchmark and LOD
//! quality-control documents are checked against that source of truth here.

const std = @import("std");
const benchmark = @import("game-core").benchmark;
const rhi = @import("engine-rhi");

const BENCHMARK_DOC = @embedFile("docs/benchmarks/README.md");
const LOD_QUALITY_DOC = @embedFile("docs/lod-quality-controls.md");

const ScenarioContract = struct {
    name: []const u8,
    scenario: benchmark.Scenario,
};

const SCENARIOS = [_]ScenarioContract{
    .{ .name = "stationary", .scenario = .stationary },
    .{ .name = "traversal", .scenario = .traversal },
    .{ .name = "rapid-turn", .scenario = .rapid_turn },
    .{ .name = "teleport-eviction", .scenario = .teleport_eviction },
};

test "Phase 5 recognizes exactly the four documented bounded scenarios" {
    try std.testing.expectEqual(@as(usize, SCENARIOS.len), @typeInfo(benchmark.Scenario).@"enum".fields.len);
    try std.testing.expect(std.mem.indexOf(u8, BENCHMARK_DOC, "deterministic, bounded camera path") != null);

    for (SCENARIOS) |contract| {
        const parsed = try benchmark.Scenario.parse(contract.name);
        try std.testing.expectEqual(contract.scenario, parsed);
        try std.testing.expectEqualStrings(contract.name, parsed.name());
    }

    try std.testing.expectError(error.InvalidBenchmarkScenario, benchmark.Scenario.parse("unbounded"));
}

test "Phase 5 benchmark SLO table matches runtime thresholds" {
    const presets = [_][]const u8{ "low", "medium", "high", "ultra", "extreme" };

    for (presets) |preset| {
        const documented = try benchmarkSloRow(preset);
        const runtime = benchmark.thresholdsForPreset(preset);

        try std.testing.expectEqual(runtime.fps_p1_min, documented[0]);
        try std.testing.expectEqual(runtime.max_frame_ms, documented[1]);
        try std.testing.expectEqual(runtime.draw_calls_max, documented[2]);
        try std.testing.expectEqual(runtime.vertices_max, documented[3]);
        try std.testing.expectEqual(runtime.gpu_memory_mb_max, documented[4]);
    }
}

test "Phase 5 LOD preset budget table matches runtime configuration" {
    inline for (@typeInfo(rhi.RenderDistancePreset).@"enum".fields) |field| {
        const preset: rhi.RenderDistancePreset = @enumFromInt(field.value);
        const documented = try lodBudgetRow(field.name);
        const runtime = rhi.getPresetConfig(preset);

        try std.testing.expectEqual(runtime.horizon_radius, documented.horizon_radius);
        try std.testing.expectEqual(runtime.horizontal_detail, documented.horizontal_detail);
        try std.testing.expectEqual(runtime.vertical_span_budget, documented.vertical_span_budget);
        try std.testing.expectEqual(runtime.memory_budget_mb, documented.memory_budget_mb);
        try std.testing.expectEqual(runtime.lod_store_size_cap_mb, documented.store_size_cap_mb);
        try std.testing.expectEqual(runtime.max_uploads_per_frame, documented.max_uploads_per_frame);
    }
}

fn benchmarkSloRow(preset: []const u8) ![5]f64 {
    const row = findTableRow(BENCHMARK_DOC, preset) orelse return error.DocumentedPresetMissing;
    if (row.count != 6) return error.InvalidDocumentedPreset;
    const cells = row.cells[0..row.count];

    return .{
        try parseDocumentNumber(cells[1]),
        try parseDocumentNumber(cells[2]),
        try parseDocumentNumber(cells[3]),
        try parseDocumentNumber(cells[4]),
        try parseDocumentNumber(cells[5]),
    };
}

const LodBudget = struct {
    horizon_radius: i32,
    horizontal_detail: [5]u32,
    vertical_span_budget: u8,
    memory_budget_mb: u32,
    store_size_cap_mb: u32,
    max_uploads_per_frame: u32,
};

fn lodBudgetRow(preset: []const u8) !LodBudget {
    const row = findTableRow(LOD_QUALITY_DOC, preset) orelse return error.DocumentedPresetMissing;
    if (row.count != 7) return error.InvalidDocumentedPreset;
    const cells = row.cells[0..row.count];

    return .{
        .horizon_radius = @intFromFloat(try parseDocumentNumber(cells[1])),
        .horizontal_detail = try parseDetailBudget(cells[2]),
        .vertical_span_budget = @intFromFloat(try parseDocumentNumber(cells[3])),
        .memory_budget_mb = @intFromFloat(try parseDocumentNumber(cells[4])),
        .store_size_cap_mb = @intFromFloat(try parseDocumentNumber(cells[5])),
        .max_uploads_per_frame = @intFromFloat(try parseDocumentNumber(cells[6])),
    };
}

const TableRow = struct {
    cells: [8][]const u8,
    count: usize,
};

/// Returns a Markdown table's cells, excluding its leading and trailing pipes.
fn findTableRow(document: []const u8, preset: []const u8) ?TableRow {
    var lines = std.mem.splitScalar(u8, document, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "|")) continue;

        var cells: [8][]const u8 = undefined;
        var count: usize = 0;
        var fields = std.mem.splitScalar(u8, trimmed, '|');
        _ = fields.next(); // Leading pipe.
        while (fields.next()) |field| {
            const cell = std.mem.trim(u8, field, " \t\r");
            if (cell.len == 0) continue; // Trailing pipe.
            if (count == cells.len) break;
            cells[count] = cell;
            count += 1;
        }

        if (count > 0 and std.ascii.eqlIgnoreCase(cells[0], preset)) return .{ .cells = cells, .count = count };
    }
    return null;
}

/// Accepts human-readable table values such as `3,500,000` and `2,200 MB`.
fn parseDocumentNumber(value: []const u8) !f64 {
    var normalized: [64]u8 = undefined;
    var len: usize = 0;
    for (value) |byte| {
        if (std.ascii.isDigit(byte) or byte == '.' or byte == '-') {
            if (len == normalized.len) return error.DocumentedNumberTooLong;
            normalized[len] = byte;
            len += 1;
        }
    }
    if (len == 0) return error.InvalidDocumentedNumber;
    return std.fmt.parseFloat(f64, normalized[0..len]);
}

fn parseDetailBudget(value: []const u8) ![5]u32 {
    var detail: [5]u32 = undefined;
    var fields = std.mem.splitScalar(u8, value, '/');
    for (&detail) |*entry| {
        const field = fields.next() orelse return error.InvalidDetailBudget;
        entry.* = @intFromFloat(try parseDocumentNumber(field));
    }
    if (fields.next() != null) return error.InvalidDetailBudget;
    return detail;
}
