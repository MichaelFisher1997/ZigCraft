const std = @import("std");
const UISystem = @import("ui_system.zig").UISystem;
const Color = @import("ui_system.zig").Color;
const RenderStats = @import("../../world/world_renderer.zig").RenderStats;
const Font = @import("font.zig");

pub const ChunkStateCounts = struct {
    total: u32 = 0,
    missing: u32 = 0,
    generating: u32 = 0,
    meshing: u32 = 0,
    renderable: u32 = 0,
    other_states: u32 = 0,
    dirty: u32 = 0,
};

pub const ChunkInspectorOverlay = struct {
    enabled: bool = false,

    pub fn toggle(self: *ChunkInspectorOverlay) void {
        self.enabled = !self.enabled;
    }

    pub fn draw(self: *ChunkInspectorOverlay, ui: *UISystem, render_stats: RenderStats, counts: ChunkStateCounts) void {
        if (!self.enabled) return;

        const x: f32 = 10;
        var y: f32 = 10;
        const width: f32 = 260;
        const line_height: f32 = 15;
        const scale: f32 = 1.0;
        const num_lines = 13;
        const padding = 20;

        ui.drawRect(.{ .x = x, .y = y, .width = width, .height = num_lines * line_height + padding }, .{ .r = 0, .g = 0, .b = 0, .a = 0.6 });
        y += 5;

        Font.drawText(ui, "CHUNK INSPECTOR", x + 10, y, scale, Color.white);
        y += line_height + 5;

        Font.drawText(ui, "RENDER STATS", x + 10, y, scale, Color.gray);
        y += line_height;
        drawLine(ui, "TOTAL:", render_stats.chunks_total, x, &y, scale, line_height);
        drawLine(ui, "RENDERED:", render_stats.chunks_rendered, x, &y, scale, line_height);
        drawLine(ui, "CULLED:", render_stats.chunks_culled, x, &y, scale, line_height);
        drawLine(ui, "VERTICES:", render_stats.vertices_rendered, x, &y, scale, line_height);
        y += 5;

        Font.drawText(ui, "STATE DISTRIBUTION", x + 10, y, scale, Color.gray);
        y += line_height;
        drawLine(ui, "MISSING:", counts.missing, x, &y, scale, line_height);
        drawLine(ui, "GENERATING:", counts.generating, x, &y, scale, line_height);
        drawLine(ui, "MESHING:", counts.meshing, x, &y, scale, line_height);
        drawLine(ui, "RENDERABLE:", counts.renderable, x, &y, scale, line_height);
        drawLine(ui, "OTHER:", counts.other_states, x, &y, scale, line_height);
        drawLine(ui, "DIRTY*:", counts.dirty, x, &y, scale, line_height);
        Font.drawText(ui, "* dirty is orthogonal to state", x + 10, y, scale * 0.8, Color.gray);
    }

    fn drawLine(ui: *UISystem, label: []const u8, value: u64, x: f32, y: *f32, scale: f32, line_height: f32) void {
        Font.drawText(ui, label, x + 10, y.*, scale, Color.gray);

        var buf: [32]u8 = undefined;
        const val_str = std.fmt.bufPrint(&buf, "{}", .{value}) catch "0";
        Font.drawText(ui, val_str, x + 160, y.*, scale, Color.white);
        y.* += line_height;
    }
};
