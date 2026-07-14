const std = @import("std");
const UISystem = @import("ui_system.zig").UISystem;
const Color = @import("ui_system.zig").Color;
const Font = @import("font.zig");

pub const ChunkRenderStats = struct {
    chunks_total: u32 = 0,
    chunks_rendered: u32 = 0,
    chunks_culled: u32 = 0,
    vertices_rendered: u64 = 0,
};

pub const ChunkStateCounts = @import("world-core").ChunkStateCounts;
pub const WorldStateData = @import("world-core").WorldStateData;

pub const ChunkInspectorOverlay = struct {
    enabled: bool = false,

    pub fn toggle(self: *ChunkInspectorOverlay) void {
        self.enabled = !self.enabled;
    }

    /// Submits inspector draw calls to an active caller-owned UI pass.
    /// The caller must pair `ui.begin()` and `ui.end()` around this call.
    pub fn draw(self: *ChunkInspectorOverlay, ui: *UISystem, render_stats: ChunkRenderStats, counts: ChunkStateCounts, world_state: WorldStateData) void {
        if (!self.enabled) return;

        const x: f32 = 12;
        var y: f32 = 12;
        const width: f32 = 300;
        const line_height: f32 = 15;
        const scale: f32 = 1.0;
        const padding = 26;

        const final_y = calcHeight(render_stats, counts, world_state, line_height);
        drawPanel(ui, x, y, width, final_y - y + padding);
        y += 10;

        Font.drawText(ui, "CHUNK INSPECTOR", x + 14, y, scale, Color.rgba(1.0, 0.93, 0.76, 1.0));
        y += line_height + 5;

        Font.drawText(ui, "RENDER STATS", x + 14, y, scale, Color.rgba(0.44, 0.76, 0.94, 1.0));
        y += line_height;
        drawLine(ui, "TOTAL:", render_stats.chunks_total, x, &y, scale, line_height);
        drawLine(ui, "RENDERED:", render_stats.chunks_rendered, x, &y, scale, line_height);
        drawLine(ui, "CULLED:", render_stats.chunks_culled, x, &y, scale, line_height);
        drawLine(ui, "VERTICES:", render_stats.vertices_rendered, x, &y, scale, line_height);
        y += 5;

        Font.drawText(ui, "STATE DISTRIBUTION", x + 14, y, scale, Color.rgba(0.44, 0.76, 0.94, 1.0));
        y += line_height;
        drawLine(ui, "MISSING:", counts.missing, x, &y, scale, line_height);
        drawLine(ui, "GENERATING:", counts.generating, x, &y, scale, line_height);
        drawLine(ui, "MESHING:", counts.meshing, x, &y, scale, line_height);
        drawLine(ui, "RENDERABLE:", counts.renderable, x, &y, scale, line_height);
        drawLine(ui, "OTHER:", counts.other_states, x, &y, scale, line_height);
        drawLine(ui, "DIRTY*:", counts.dirty, x, &y, scale, line_height);
        y += 5;

        Font.drawText(ui, "STREAMING STATUS", x + 14, y, scale, Color.rgba(0.44, 0.76, 0.94, 1.0));
        y += line_height;
        drawLine(ui, "GEN QUEUE:", world_state.gen_queue, x, &y, scale, line_height);
        drawLine(ui, "MESH QUEUE:", world_state.mesh_queue, x, &y, scale, line_height);
        drawLine(ui, "UPLOAD QUEUE:", world_state.upload_queue, x, &y, scale, line_height);
        y += 5;

        Font.drawText(ui, "WORLD INFO", x + 14, y, scale, Color.rgba(0.95, 0.62, 0.24, 1.0));
        y += line_height;
        drawLine(ui, "GENERATOR:", world_state.generator_name, x, &y, scale, line_height);
        drawLine(ui, "SEED:", world_state.seed, x, &y, scale, line_height);
    }

    fn calcHeight(_: ChunkRenderStats, _: ChunkStateCounts, _: WorldStateData, line_height: f32) f32 {
        var y: f32 = 0;
        y += line_height + 5;
        y += line_height;
        y += 4 * line_height;
        y += 5;
        y += line_height;
        y += 6 * line_height;
        y += 5;
        y += line_height;
        y += 3 * line_height;
        y += 5;
        y += line_height;
        y += 2 * line_height;
        return y;
    }

    fn drawLine(ui: *UISystem, label: []const u8, value: anytype, x: f32, y: *f32, scale: f32, line_height: f32) void {
        Font.drawText(ui, label, x + 14, y.*, scale, Color.rgba(0.62, 0.74, 0.84, 0.92));

        if (@TypeOf(value) == []const u8) {
            Font.drawText(ui, value, x + 174, y.*, scale, Color.rgba(0.92, 0.97, 1.0, 1.0));
        } else {
            var buf: [64]u8 = undefined;
            const val_str = std.fmt.bufPrint(&buf, "{}", .{value}) catch "0";
            Font.drawText(ui, val_str, x + 174, y.*, scale, Color.rgba(0.92, 0.97, 1.0, 1.0));
        }
        y.* += line_height;
    }

    fn drawPanel(ui: *UISystem, x: f32, y: f32, width: f32, height: f32) void {
        ui.drawRect(.{ .x = x, .y = y, .width = width, .height = height }, Color.rgba(0.010, 0.020, 0.030, 0.78));
        ui.drawRect(.{ .x = x, .y = y, .width = 5.0, .height = height }, Color.rgba(0.95, 0.62, 0.24, 0.92));
        ui.drawRect(.{ .x = x, .y = y, .width = width, .height = 28.0 }, Color.rgba(0.10, 0.20, 0.28, 0.62));
        ui.drawRectOutline(.{ .x = x, .y = y, .width = width, .height = height }, Color.rgba(0.42, 0.66, 0.82, 0.68), 1.0);
    }
};
