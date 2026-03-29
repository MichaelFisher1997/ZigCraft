const std = @import("std");
const testing = std.testing;
const screen_module = @import("screen.zig");
const ScreenManager = screen_module.ScreenManager;
const IScreen = screen_module.IScreen;
const UISystem = @import("../engine/ui/ui_system.zig").UISystem;

// Mock screen implementation for testing
const MockScreen = struct {
    ptr: *anyopaque,
    vtable: *const IScreen.VTable,

    pub fn make(ptr: *MockScreen) IScreen {
        return .{
            .ptr = ptr,
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

    var deinit_count: usize = 0;
    var enter_count: usize = 0;
    var exit_count: usize = 0;
    var update_count: usize = 0;
    var draw_count: usize = 0;

    fn resetCounters() void {
        deinit_count = 0;
        enter_count = 0;
        exit_count = 0;
        update_count = 0;
        draw_count = 0;
    }

    fn deinit_impl(ptr: *anyopaque) void {
        _ = ptr;
        deinit_count += 1;
    }

    fn update_impl(ptr: *anyopaque, dt: f32) anyerror!void {
        _ = ptr;
        _ = dt;
        update_count += 1;
    }

    fn draw_impl(ptr: *anyopaque, ui: *UISystem) anyerror!void {
        _ = ptr;
        _ = ui;
        draw_count += 1;
    }

    fn onEnter_impl(ptr: *anyopaque) void {
        _ = ptr;
        enter_count += 1;
    }

    fn onExit_impl(ptr: *anyopaque) void {
        _ = ptr;
        exit_count += 1;
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

    MockScreen.resetCounters();
    manager.deinit();

    try testing.expectEqual(@as(usize, 0), MockScreen.deinit_count);
}

test "ScreenManager.pushScreen schedules push" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);
    defer manager.deinit();

    var mock_screen: MockScreen = undefined;
    const screen = MockScreen.make(&mock_screen);

    MockScreen.resetCounters();
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

    var mock_screen: MockScreen = undefined;
    const screen = MockScreen.make(&mock_screen);

    manager.setScreen(screen);

    try testing.expect(manager.next_screen != null);
}

test "ScreenManager.update processes push" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);
    defer manager.deinit();

    var mock_screen: MockScreen = undefined;
    const screen = MockScreen.make(&mock_screen);

    MockScreen.resetCounters();
    manager.pushScreen(screen);
    try manager.update(0.016);

    try testing.expectEqual(@as(usize, 1), manager.stack.items.len);
    try testing.expectEqual(@as(usize, 1), MockScreen.enter_count);
    try testing.expect(manager.next_screen == null);
}

test "ScreenManager.update processes pop" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);

    // Push a screen first
    var mock_screen: MockScreen = undefined;
    const screen = MockScreen.make(&mock_screen);

    MockScreen.resetCounters();
    manager.pushScreen(screen);
    try manager.update(0.016);

    // Now pop it
    manager.popScreen();
    try manager.update(0.016);

    try testing.expectEqual(@as(usize, 0), manager.stack.items.len);
    try testing.expectEqual(@as(usize, 1), MockScreen.exit_count);
    try testing.expectEqual(@as(usize, 1), MockScreen.deinit_count);

    manager.deinit();
}

test "ScreenManager.update processes replace" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);

    // Push first screen
    var mock_screen1: MockScreen = undefined;
    const screen1 = MockScreen.make(&mock_screen1);

    MockScreen.resetCounters();
    manager.pushScreen(screen1);
    try manager.update(0.016);

    try testing.expectEqual(@as(usize, 1), MockScreen.enter_count);

    // Replace with second screen
    var mock_screen2: MockScreen = undefined;
    const screen2 = MockScreen.make(&mock_screen2);

    manager.setScreen(screen2);
    try manager.update(0.016);

    // First screen should be deinitialized
    try testing.expectEqual(@as(usize, 1), MockScreen.exit_count);
    try testing.expectEqual(@as(usize, 1), MockScreen.deinit_count);
    // Second screen should have onEnter called
    try testing.expectEqual(@as(usize, 2), MockScreen.enter_count);
    try testing.expectEqual(@as(usize, 1), manager.stack.items.len);

    manager.deinit();
}

test "ScreenManager.update calls update on current screen" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);
    defer manager.deinit();

    var mock_screen: MockScreen = undefined;
    const screen = MockScreen.make(&mock_screen);

    MockScreen.resetCounters();
    manager.pushScreen(screen);
    try manager.update(0.016);

    // Call update again
    try manager.update(0.016);

    try testing.expectEqual(@as(usize, 2), MockScreen.update_count);
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

    var mock_screen1: MockScreen = undefined;
    var mock_screen2: MockScreen = undefined;
    const screen1 = MockScreen.make(&mock_screen1);
    const screen2 = MockScreen.make(&mock_screen2);

    MockScreen.resetCounters();

    // Push first screen
    manager.pushScreen(screen1);
    try manager.update(0.016);
    try testing.expectEqual(@as(usize, 1), MockScreen.enter_count);

    // Push second screen (first should get onExit)
    manager.pushScreen(screen2);
    try manager.update(0.016);

    try testing.expectEqual(@as(usize, 1), MockScreen.exit_count); // First screen exited
    try testing.expectEqual(@as(usize, 2), MockScreen.enter_count); // Second screen entered
    try testing.expectEqual(@as(usize, 2), manager.stack.items.len);

    // Pop second screen (first should get onEnter)
    manager.popScreen();
    try manager.update(0.016);

    try testing.expectEqual(@as(usize, 1), MockScreen.deinit_count); // Second screen deinit
    try testing.expectEqual(@as(usize, 3), MockScreen.enter_count); // First screen re-entered (1 initial + 1 screen2 + 1 re-enter)
    try testing.expectEqual(@as(usize, 1), manager.stack.items.len);
}

test "ScreenManager replacing pending screen cleans up" {
    const allocator = testing.allocator;
    var manager = ScreenManager.init(allocator);
    defer manager.deinit();

    var mock_screen1: MockScreen = undefined;
    var mock_screen2: MockScreen = undefined;
    const screen1 = MockScreen.make(&mock_screen1);
    const screen2 = MockScreen.make(&mock_screen2);

    MockScreen.resetCounters();

    // Queue first screen
    manager.pushScreen(screen1);

    // Replace with second before processing
    manager.setScreen(screen2);

    // First screen should have been cleaned up
    try testing.expectEqual(@as(usize, 1), MockScreen.deinit_count);

    // Process
    try manager.update(0.016);
    try testing.expectEqual(@as(usize, 1), MockScreen.enter_count);
}

test "IScreen.deinit calls vtable function" {
    var mock_screen: MockScreen = undefined;
    const screen = MockScreen.make(&mock_screen);

    MockScreen.resetCounters();
    screen.deinit();

    try testing.expectEqual(@as(usize, 1), MockScreen.deinit_count);
}

test "IScreen.onEnter calls vtable function" {
    var mock_screen: MockScreen = undefined;
    const screen = MockScreen.make(&mock_screen);

    MockScreen.resetCounters();
    screen.onEnter();

    try testing.expectEqual(@as(usize, 1), MockScreen.enter_count);
}

test "IScreen.onExit calls vtable function" {
    var mock_screen: MockScreen = undefined;
    const screen = MockScreen.make(&mock_screen);

    MockScreen.resetCounters();
    screen.onExit();

    try testing.expectEqual(@as(usize, 1), MockScreen.exit_count);
}

test "IScreen.getWorldStats returns null when not implemented" {
    var mock_screen: MockScreen = undefined;
    const screen = MockScreen.make(&mock_screen);

    const stats = screen.getWorldStats();
    try testing.expect(stats == null);
}
