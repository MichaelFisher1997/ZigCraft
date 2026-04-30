const std = @import("std");
const testing = std.testing;
const screen_module = @import("game-ui").screen;
const ScreenManager = screen_module.ScreenManager;
const IScreen = screen_module.IScreen;
const UISystem = @import("../engine/ui/ui_system.zig").UISystem;

const MockState = struct {
    deinit_count: usize = 0,
    enter_count: usize = 0,
    exit_count: usize = 0,
    update_count: usize = 0,
    draw_count: usize = 0,
};

const MockScreen = struct {
    state: *MockState,

    pub fn make(self: *MockScreen) IScreen {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    const VTABLE = IScreen.VTable{
        .deinit = deinit_impl,
        .update = update_impl,
        .draw = draw_impl,
        .onEnter = onEnter_impl,
        .onExit = onExit_impl,
        .getWorldStats = null,
    };

    fn deinit_impl(ptr: *anyopaque) void {
        const self: *MockScreen = @ptrCast(@alignCast(ptr));
        self.state.deinit_count += 1;
    }

    fn update_impl(ptr: *anyopaque, dt: f32) anyerror!void {
        const self: *MockScreen = @ptrCast(@alignCast(ptr));
        _ = dt;
        self.state.update_count += 1;
    }

    fn draw_impl(ptr: *anyopaque, ui: *UISystem) anyerror!void {
        const self: *MockScreen = @ptrCast(@alignCast(ptr));
        _ = ui;
        self.state.draw_count += 1;
    }

    fn onEnter_impl(ptr: *anyopaque) void {
        const self: *MockScreen = @ptrCast(@alignCast(ptr));
        self.state.enter_count += 1;
    }

    fn onExit_impl(ptr: *anyopaque) void {
        const self: *MockScreen = @ptrCast(@alignCast(ptr));
        self.state.exit_count += 1;
    }
};

test "ScreenManager.init creates empty manager" {
    const allocator = testing.allocator;
    const manager = ScreenManager.init(allocator);

    try testing.expectEqual(@as(usize, 0), manager.stack.items.len);
    try testing.expect(manager.next_screen == null);
}

test "ScreenManager.deinit with no screens" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);

    var state = MockState{};
    var mock_screen: MockScreen = .{ .state = &state };
    _ = &mock_screen;

    manager.deinit();

    try testing.expectEqual(@as(usize, 0), state.deinit_count);
}

test "ScreenManager.pushScreen schedules push" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);
    defer manager.deinit();

    var state = MockState{};
    var mock_screen: MockScreen = .{ .state = &state };
    const screen = MockScreen.make(&mock_screen);

    manager.pushScreen(screen);

    try testing.expect(manager.next_screen != null);
}

test "ScreenManager.popScreen schedules pop" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);
    defer manager.deinit();

    manager.popScreen();

    try testing.expect(manager.next_screen != null);
}

test "ScreenManager.setScreen schedules replace" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);
    defer manager.deinit();

    var state = MockState{};
    var mock_screen: MockScreen = .{ .state = &state };
    const screen = MockScreen.make(&mock_screen);

    manager.setScreen(screen);

    try testing.expect(manager.next_screen != null);
}

test "ScreenManager.update processes push" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);
    defer manager.deinit();

    var state = MockState{};
    var mock_screen: MockScreen = .{ .state = &state };
    const screen = MockScreen.make(&mock_screen);

    manager.pushScreen(screen);
    try manager.update(0.016);

    try testing.expectEqual(@as(usize, 1), manager.stack.items.len);
    try testing.expectEqual(@as(usize, 1), state.enter_count);
    try testing.expect(manager.next_screen == null);
}

test "ScreenManager.update processes pop" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);

    var state = MockState{};
    var mock_screen: MockScreen = .{ .state = &state };
    const screen = MockScreen.make(&mock_screen);

    manager.pushScreen(screen);
    try manager.update(0.016);

    manager.popScreen();
    try manager.update(0.016);

    try testing.expectEqual(@as(usize, 0), manager.stack.items.len);
    try testing.expectEqual(@as(usize, 1), state.exit_count);
    try testing.expectEqual(@as(usize, 1), state.deinit_count);

    manager.deinit();
}

test "ScreenManager.update processes replace" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);

    var state1 = MockState{};
    var state2 = MockState{};

    var mock_screen1: MockScreen = .{ .state = &state1 };
    const screen1 = MockScreen.make(&mock_screen1);

    manager.pushScreen(screen1);
    try manager.update(0.016);

    try testing.expectEqual(@as(usize, 1), state1.enter_count);

    var mock_screen2: MockScreen = .{ .state = &state2 };
    const screen2 = MockScreen.make(&mock_screen2);

    manager.setScreen(screen2);
    try manager.update(0.016);

    try testing.expectEqual(@as(usize, 1), state1.exit_count);
    try testing.expectEqual(@as(usize, 1), state1.deinit_count);
    try testing.expectEqual(@as(usize, 1), state2.enter_count);
    try testing.expectEqual(@as(usize, 1), manager.stack.items.len);

    manager.deinit();
}

test "ScreenManager.update calls update on current screen" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);
    defer manager.deinit();

    var state = MockState{};
    var mock_screen: MockScreen = .{ .state = &state };
    const screen = MockScreen.make(&mock_screen);

    manager.pushScreen(screen);
    try manager.update(0.016);

    try manager.update(0.016);

    try testing.expectEqual(@as(usize, 2), state.update_count);
}

test "ScreenManager.update with empty stack does nothing" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);
    defer manager.deinit();

    // Should not crash
    try manager.update(0.016);
    try testing.expectEqual(@as(usize, 0), manager.stack.items.len);
}

test "ScreenManager.pop with empty stack does nothing" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);
    defer manager.deinit();

    manager.popScreen();
    try manager.update(0.016);

    try testing.expectEqual(@as(usize, 0), manager.stack.items.len);
}

test "ScreenManager multiple push operations" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);
    defer manager.deinit();

    var state1 = MockState{};
    var state2 = MockState{};
    var mock_screen1: MockScreen = .{ .state = &state1 };
    var mock_screen2: MockScreen = .{ .state = &state2 };
    const screen1 = MockScreen.make(&mock_screen1);
    const screen2 = MockScreen.make(&mock_screen2);

    manager.pushScreen(screen1);
    try manager.update(0.016);
    try testing.expectEqual(@as(usize, 1), state1.enter_count);

    manager.pushScreen(screen2);
    try manager.update(0.016);

    try testing.expectEqual(@as(usize, 1), state1.exit_count);
    try testing.expectEqual(@as(usize, 1), state2.enter_count);
    try testing.expectEqual(@as(usize, 2), manager.stack.items.len);

    manager.popScreen();
    try manager.update(0.016);

    try testing.expectEqual(@as(usize, 1), state2.deinit_count);
    try testing.expectEqual(@as(usize, 2), state1.enter_count);
    try testing.expectEqual(@as(usize, 1), manager.stack.items.len);
}

test "ScreenManager replacing pending screen cleans up" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);
    defer manager.deinit();

    var state1 = MockState{};
    var state2 = MockState{};
    var mock_screen1: MockScreen = .{ .state = &state1 };
    var mock_screen2: MockScreen = .{ .state = &state2 };
    const screen1 = MockScreen.make(&mock_screen1);
    const screen2 = MockScreen.make(&mock_screen2);

    manager.pushScreen(screen1);

    manager.setScreen(screen2);

    try testing.expectEqual(@as(usize, 1), state1.deinit_count);

    try manager.update(0.016);
    try testing.expectEqual(@as(usize, 1), state2.enter_count);
}

test "IScreen.deinit calls vtable function" {
    var state = MockState{};
    var mock_screen: MockScreen = .{ .state = &state };
    const screen = MockScreen.make(&mock_screen);

    screen.deinit();

    try testing.expectEqual(@as(usize, 1), state.deinit_count);
}

test "IScreen.onEnter calls vtable function" {
    var state = MockState{};
    var mock_screen: MockScreen = .{ .state = &state };
    const screen = MockScreen.make(&mock_screen);

    screen.onEnter();

    try testing.expectEqual(@as(usize, 1), state.enter_count);
}

test "IScreen.onExit calls vtable function" {
    var state = MockState{};
    var mock_screen: MockScreen = .{ .state = &state };
    const screen = MockScreen.make(&mock_screen);

    screen.onExit();

    try testing.expectEqual(@as(usize, 1), state.exit_count);
}

test "IScreen.getWorldStats returns null when not implemented" {
    var state = MockState{};
    var mock_screen: MockScreen = .{ .state = &state };
    const screen = MockScreen.make(&mock_screen);

    const stats = screen.getWorldStats();
    try testing.expect(stats == null);
}
