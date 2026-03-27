const std = @import("std");
const AudioSystem = @import("../engine/audio/system.zig").AudioSystem;

pub const AudioSystemManager = struct {
    audio_system: *AudioSystem,

    pub fn init(allocator: std.mem.Allocator) !*AudioSystemManager {
        const self = try allocator.create(AudioSystemManager);
        errdefer allocator.destroy(self);

        self.* = .{
            .audio_system = try AudioSystem.init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *AudioSystemManager) void {
        self.audio_system.deinit();
        const allocator = self.audio_system.allocator;
        allocator.destroy(self);
    }

    pub fn update(self: *AudioSystemManager) void {
        self.audio_system.update();
    }
};
