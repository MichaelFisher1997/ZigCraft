//! Debug UI facade.
//!
//! Dear ImGui renders the default debug menu when available. The immediate-mode
//! bitmap/atlas overlay remains as the non-ImGui fallback.

const DebugMenuOverlay = @import("debug_menu.zig").DebugMenuOverlay;
const DebugFeature = @import("debug_menu.zig").DebugFeature;
const FEATURE_INFOS = @import("debug_menu.zig").FEATURE_INFOS;
const UISystem = @import("ui_system.zig").UISystem;
const imgui_backend = @import("imgui/imgui_backend.zig");

pub const DebugUI = struct {
    menu: DebugMenuOverlay = .{},

    pub fn toggleMenu(self: *DebugUI) void {
        self.menu.toggle();
    }

    pub fn menuEnabled(self: *const DebugUI) bool {
        return self.menu.enabled;
    }

    pub fn drawMenu(
        self: *DebugUI,
        ui: *UISystem,
        feature_states: [DebugFeature.count]bool,
        mouse_x: f32,
        mouse_y: f32,
        mouse_clicked: bool,
        ui_scale: f32,
        scroll_delta_y: f32,
        imgui: ?*imgui_backend.Backend,
    ) ?DebugMenuOverlay.ClickResult {
        if (imgui_backend.available) return self.drawImguiMenu(feature_states, imgui);
        return self.menu.draw(ui, feature_states, mouse_x, mouse_y, mouse_clicked, ui_scale, scroll_delta_y);
    }

    fn drawImguiMenu(self: *DebugUI, feature_states: [DebugFeature.count]bool, imgui: ?*imgui_backend.Backend) ?DebugMenuOverlay.ClickResult {
        if (!self.menu.enabled) return null;
        const backend = imgui orelse return null;

        const c = imgui_backend.c;
        backend.markDrawCommands();
        _ = c.ZigCraft_ImGui_Begin("ZigCraft Debug");
        c.ZigCraft_ImGui_TextUnformatted("Debug features");

        var result: ?DebugMenuOverlay.ClickResult = null;
        for (FEATURE_INFOS, 0..) |info, feature_idx| {
            var state = feature_states[feature_idx];
            if (c.ZigCraft_ImGui_Checkbox(info.label.ptr, &state)) {
                result = .{ .feature = @enumFromInt(feature_idx) };
            }
            c.ZigCraft_ImGui_SameLine();
            c.ZigCraft_ImGui_TextUnformatted(info.hotkey.ptr);
        }

        c.ZigCraft_ImGui_End();
        return result;
    }
};
