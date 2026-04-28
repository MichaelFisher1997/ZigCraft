const std = @import("std");
const settings_pkg = @import("settings.zig");
const Settings = settings_pkg.Settings;
const RHI = @import("../engine/graphics/rhi.zig").RHI;
const log = @import("engine-core").log;

pub const SettingsManager = struct {
    allocator: std.mem.Allocator,
    settings: Settings,

    pub fn init(allocator: std.mem.Allocator) !SettingsManager {
        log.log.info("Initializing settings system...", .{});

        settings_pkg.initPresets(allocator) catch |err| {
            log.log.warn("Failed to initialize presets: {}, proceeding with defaults", .{err});
        };

        const settings = settings_pkg.persistence.load(allocator);

        return .{
            .allocator = allocator,
            .settings = settings,
        };
    }

    pub fn deinit(self: *SettingsManager) void {
        settings_pkg.persistence.deinit(&self.settings, self.allocator);
        settings_pkg.deinitPresets(self.allocator);
    }

    pub fn save(self: *const SettingsManager) void {
        settings_pkg.persistence.save(&self.settings, self.allocator);
    }

    pub fn applyToRHI(self: *const SettingsManager, rhi: *RHI) void {
        settings_pkg.apply_logic.applyToRHI(&self.settings, rhi);
    }

    pub fn ptr(self: *SettingsManager) *Settings {
        return &self.settings;
    }

    pub fn constPtr(self: *const SettingsManager) *const Settings {
        return &self.settings;
    }
};
