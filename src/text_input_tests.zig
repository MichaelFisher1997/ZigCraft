//! Regression tests for `text_input.handleTextTyping`.
//!
//! The audit (#708) claimed `std.ascii.toUpper('a')` returns `'a'` unchanged,
//! implying Shift+letter produced lowercase output. That claim is incorrect — Zig's
//! `std.ascii.toUpper('a')` returns `'A'`. These tests lock in the correct
//! uppercase-on-shift behavior so any future regression (e.g. by switching to a
//! different cast path) is caught immediately.

const std = @import("std");
const testing = std.testing;
const Key = @import("engine-core").interfaces.Key;
const IRawInputProvider = @import("engine-input").IRawInputProvider;
const handleTextTyping = @import("game-core").text_input.handleTextTyping;

/// In-memory mock of `IRawInputProvider` that reports a fixed set of "pressed" keys
/// plus optional left/right shift state. Each VTable method just forwards to the
/// struct's stored sets.
const MockInput = struct {
    pressed: std.AutoHashMap(Key, void),
    shift_down: bool = false,

    fn init(allocator: std.mem.Allocator, shift: bool) MockInput {
        const pressed = std.AutoHashMap(Key, void).init(allocator);
        return .{ .pressed = pressed, .shift_down = shift };
    }

    fn deinit(self: *MockInput) void {
        self.pressed.deinit();
    }

    fn press(self: *MockInput, key: Key) !void {
        try self.pressed.put(key, {});
    }

    fn interface(self: *MockInput) IRawInputProvider {
        return .{ .ptr = self, .vtable = &VTABLE };
    }

    const VTABLE = IRawInputProvider.VTable{
        .isKeyDown = isKeyDown,
        .isKeyPressed = isKeyPressed,
        .isKeyReleased = noopKeyBool,
        .isMouseButtonDown = noopMouseButtonBool,
        .isMouseButtonPressed = noopMouseButtonBool,
        .isMouseButtonReleased = noopMouseButtonBool,
        .getMouseDelta = noopMousePosition,
        .getMousePosition = noopMousePosition,
        .getScrollDelta = noopScroll,
        .getWindowWidth = noopU32,
        .getWindowHeight = noopU32,
        .shouldQuit = noopBool,
        .setShouldQuit = noopSetBool,
        .isMouseCaptured = noopBool,
        .setMouseCapture = noopSetCapture,
    };

    fn isKeyDown(ptr: *anyopaque, key: Key) bool {
        const self: *MockInput = @ptrCast(@alignCast(ptr));
        if ((key == .left_shift or key == .right_shift) and self.shift_down) return true;
        return false;
    }

    fn isKeyPressed(ptr: *anyopaque, key: Key) bool {
        const self: *MockInput = @ptrCast(@alignCast(ptr));
        return self.pressed.contains(key);
    }

    fn noopKeyBool(ptr: *anyopaque, key: Key) bool {
        _ = ptr;
        _ = key;
        return false;
    }
    fn noopMouseButtonBool(ptr: *anyopaque, btn: @import("engine-core").interfaces.MouseButton) bool {
        _ = ptr;
        _ = btn;
        return false;
    }
    fn noopMousePosition(ptr: *anyopaque) @import("engine-input").MousePosition {
        _ = ptr;
        return .{ .x = 0, .y = 0 };
    }
    fn noopScroll(ptr: *anyopaque) @import("engine-input").ScrollDelta {
        _ = ptr;
        return .{ .x = 0, .y = 0 };
    }
    fn noopU32(ptr: *anyopaque) u32 {
        _ = ptr;
        return 0;
    }
    fn noopBool(ptr: *anyopaque) bool {
        _ = ptr;
        return false;
    }
    fn noopSetBool(ptr: *anyopaque, val: bool) void {
        _ = ptr;
        _ = val;
    }
    fn noopSetCapture(ptr: *anyopaque, window: ?*anyopaque, captured: bool) void {
        _ = ptr;
        _ = window;
        _ = captured;
    }
};

test "handleTextTyping produces lowercase letters without shift (regression for #708)" {
    var mock = MockInput.init(testing.allocator, false);
    defer mock.deinit();
    try mock.press(.a);
    try mock.press(.z);

    var text = std.ArrayListUnmanaged(u8).empty;
    defer text.deinit(testing.allocator);

    try handleTextTyping(&text, testing.allocator, mock.interface(), 32);

    try testing.expectEqualStrings("az", text.items);
}

test "handleTextTyping produces uppercase letters with shift (regression for #708)" {
    // The audit's root-cause analysis claimed `std.ascii.toUpper('a') == 'a'` and that
    // Shift produced lowercase. This test asserts the opposite: Shift+letter produces
    // uppercase ASCII. If anyone reworks the cast path in text_input.zig, this test
    // will catch a regression that reintroduces the bug the audit described.
    var mock = MockInput.init(testing.allocator, true);
    defer mock.deinit();
    try mock.press(.a);
    try mock.press(.z);

    var text = std.ArrayListUnmanaged(u8).empty;
    defer text.deinit(testing.allocator);

    try handleTextTyping(&text, testing.allocator, mock.interface(), 32);

    try testing.expectEqualStrings("AZ", text.items);
}

test "handleTextTyping respects max_len" {
    var mock = MockInput.init(testing.allocator, false);
    defer mock.deinit();
    try mock.press(.a);
    try mock.press(.b);
    try mock.press(.c);

    var text = std.ArrayListUnmanaged(u8).empty;
    defer text.deinit(testing.allocator);

    // max_len = 2 means the third press must be dropped.
    try handleTextTyping(&text, testing.allocator, mock.interface(), 2);

    try testing.expectEqualStrings("ab", text.items);
}
