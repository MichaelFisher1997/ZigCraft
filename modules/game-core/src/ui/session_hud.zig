const std = @import("std");

const UISystem = @import("engine-ui").UISystem;
const Color = @import("engine-ui").Color;
const Font = @import("engine-ui").font;
const TextureAtlas = @import("engine-graphics").TextureAtlas;
const hotbar = @import("hotbar.zig");
const region_pkg = @import("world-worldgen").region;
const worldToChunkFromFloat = @import("world-core").worldToChunkFromFloat;

pub fn draw(session: anytype, ui: *UISystem, atlas: *const TextureAtlas, active_pack: ?[]const u8, fps: f32, screen_w: f32, screen_h: f32, mouse_x: f32, mouse_y: f32, mouse_clicked: bool) !void {
    const world = session.world.interface();
    const telemetry = world.telemetry();

    if (session.map_controller.show_map) {
        try session.map_controller.draw(ui, screen_w, screen_h, &session.world_map, &session.world_map_texture, telemetry.getGenerator(), session.camera.position);
        return;
    }

    if (session.debug_show_fps) {
        ui.drawRect(.{ .x = 10, .y = 10, .width = 80, .height = 30 }, Color.rgba(0, 0, 0, 0.7));
        Font.drawNumber(ui, @intFromFloat(fps), 15, 15, Color.white);
    }

    const stats = telemetry.getStats();
    const rs = telemetry.getRenderStats();
    const pc = worldToChunkFromFloat(session.camera.position.x, session.camera.position.z);
    const hy: f32 = 50.0;
    const fault_count = session.rhi.query().getFaultCount();
    const hud_h: f32 = if (fault_count > 0) 230 else 210;
    ui.drawRect(.{ .x = 10, .y = hy, .width = 220, .height = hud_h }, Color.rgba(0, 0, 0, 0.6));
    Font.drawText(ui, "POS:", 15, hy + 5, 1.5, Color.white);
    Font.drawNumber(ui, pc.chunk_x, 120, hy + 5, Color.white);
    Font.drawNumber(ui, pc.chunk_z, 170, hy + 5, Color.white);
    Font.drawText(ui, "CHUNKS:", 15, hy + 25, 1.5, Color.white);
    Font.drawNumber(ui, @intCast(stats.chunks_loaded), 140, hy + 25, Color.white);
    Font.drawText(ui, "VISIBLE:", 15, hy + 45, 1.5, Color.white);
    Font.drawNumber(ui, @intCast(rs.chunks_rendered), 140, hy + 45, Color.white);

    if (telemetry.getLODStats()) |ls| {
        Font.drawText(ui, "LODS:", 15, hy + 65, 1.5, Color.rgba(0.5, 0.8, 1.0, 1.0));
        Font.drawNumber(ui, @intCast(ls.totalLoaded()), 140, hy + 65, Color.rgba(0.5, 0.8, 1.0, 1.0));
    }

    Font.drawText(ui, "QUEUED GEN:", 15, hy + 85, 1.5, Color.white);
    Font.drawNumber(ui, @intCast(stats.gen_queue), 140, hy + 85, Color.white);
    Font.drawText(ui, "QUEUED MESH:", 15, hy + 105, 1.5, Color.white);
    Font.drawNumber(ui, @intCast(stats.mesh_queue), 140, hy + 105, Color.white);
    Font.drawText(ui, "PENDING UP:", 15, hy + 125, 1.5, Color.white);
    Font.drawNumber(ui, @intCast(stats.upload_queue), 140, hy + 125, Color.white);
    const h = session.atmosphere.getHours();
    const hr = @as(i32, @intFromFloat(h));
    const mn = @as(i32, @intFromFloat((h - @as(f32, @floatFromInt(hr))) * 60.0));
    Font.drawText(ui, "TIME:", 15, hy + 145, 1.5, Color.white);
    Font.drawNumber(ui, hr, 100, hy + 145, Color.white);
    Font.drawText(ui, ":", 125, hy + 145, 1.5, Color.white);
    Font.drawNumber(ui, mn, 140, hy + 145, Color.white);
    Font.drawText(ui, "SUN:", 15, hy + 165, 1.5, Color.white);
    Font.drawNumber(ui, @intFromFloat(session.atmosphere.sun_intensity * 100.0), 100, hy + 165, Color.white);

    const px_i: i32 = @intFromFloat(session.camera.position.x);
    const pz_i: i32 = @intFromFloat(session.camera.position.z);
    const region = telemetry.getRegionInfo(px_i, pz_i);
    const c3 = region_pkg.getRoleColor(region.role);
    Font.drawText(ui, "ROLE:", 15, hy + 185, 1.5, Color.rgba(c3[0], c3[1], c3[2], 1.0));
    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "{s}", .{@tagName(region.role)}) catch "???";
    Font.drawText(ui, label, 100, hy + 165, 1.5, Color.white);

    if (fault_count > 0) {
        var buf_f: [32]u8 = undefined;
        const fault_text = std.fmt.bufPrint(&buf_f, "GPU FAULTS: {d}", .{fault_count}) catch "GPU FAULTS: ???";
        Font.drawText(ui, fault_text, 15, hy + 185, 1.5, Color.red);
    }

    if (session.debug_show_block_info) {
        if (session.player.target_block) |target| {
            const block_type = telemetry.getBlock(target.x, target.y, target.z);
            const tiles = atlas.getTilesForBlock(@intFromEnum(block_type));
            const ux = screen_w - 390;
            var uy: f32 = 10;
            const panel_height: f32 = 130;
            ui.drawRect(.{ .x = ux - 10, .y = uy, .width = 390, .height = panel_height }, Color.rgba(0, 0, 0, 0.7));
            var buf2: [160]u8 = undefined;
            const pos_text = std.fmt.bufPrint(&buf2, "BLOCK: {s} FACE:{s} ({}, {}, {})", .{ @tagName(block_type), @tagName(target.face), target.x, target.y, target.z }) catch "BLOCK: ???";
            Font.drawText(ui, pos_text, ux, uy + 5, 1.5, Color.white);
            uy += 25;
            const face_offset = target.face.getOffset();
            const face_x = target.x + face_offset.x;
            const face_y = target.y + face_offset.y;
            const face_z = target.z + face_offset.z;
            const target_light = telemetry.getDebugLightInfo(target.x, target.y, target.z);
            const face_light = telemetry.getDebugLightInfo(face_x, face_y, face_z);
            const target_light_text = if (target_light) |l| std.fmt.bufPrint(&buf2, "TARGET S:{} B:{}", .{ l.sky, l.block }) catch "TARGET: ???" else "TARGET: missing";
            Font.drawText(ui, target_light_text, ux, uy + 5, 1.5, Color.white);
            uy += 25;
            const face_light_text = if (face_light) |l| std.fmt.bufPrint(&buf2, "FACE AIR S:{} B:{} ({}, {}, {})", .{ l.sky, l.block, face_x, face_y, face_z }) catch "FACE AIR: ???" else "FACE AIR: missing";
            Font.drawText(ui, face_light_text, ux, uy + 5, 1.5, Color.white);
            uy += 25;
            const tiles_text = std.fmt.bufPrint(&buf2, "TILES: T:{} B:{} S:{}", .{ tiles.top, tiles.bottom, tiles.side }) catch "TILES: ???";
            Font.drawText(ui, tiles_text, ux, uy + 5, 1.5, Color.white);
            uy += 25;
            const pack_name = if (active_pack) |ap| ap else "Default";
            const pack_text = std.fmt.bufPrint(&buf2, "PACK: {s}", .{pack_name}) catch "PACK: ???";
            Font.drawText(ui, pack_text, ux, uy + 5, 1.5, Color.white);
        }
    }

    if (!session.inventory_ui_state.visible) {
        const cx = screen_w / 2.0;
        const cy = screen_h / 2.0;
        ui.drawRect(.{ .x = cx - 10, .y = cy - 1, .width = 20, .height = 2 }, Color.white);
        ui.drawRect(.{ .x = cx - 1, .y = cy - 10, .width = 2, .height = 20 }, Color.white);
    }

    if (!session.inventory_ui_state.visible) hotbar.drawDefault(ui, &session.inventory, screen_w, screen_h);

    if (session.inventory_ui_state.visible) {
        const time_action = session.inventory_ui_state.draw(ui, &session.inventory, mouse_x, mouse_y, mouse_clicked, screen_w, screen_h);
        if (time_action) |time_idx| {
            const times = [_]f32{ 0.0, 0.25, 0.5, 0.75 };
            if (time_idx < 4) session.atmosphere.setTimeOfDay(times[time_idx]);
        }
    }

    if (session.creative_mode) {
        Font.drawText(ui, "CREATIVE", screen_w - 100, 10, 1.5, Color.rgba(100, 200, 255, 200));
        if (session.player.fly_mode) Font.drawText(ui, "FLYING", screen_w - 80, 25, 1.5, Color.rgba(150, 255, 150, 200));
    }
}
