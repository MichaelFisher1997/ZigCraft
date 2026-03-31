const std = @import("std");
const testing = std.testing;
const input_mapper = @import("input_mapper.zig");
const InputMapper = input_mapper.InputMapper;
const GameAction = input_mapper.GameAction;
const InputBinding = input_mapper.InputBinding;
const MovementVector = input_mapper.MovementVector;
const IRawInputProvider = @import("../engine/input/interfaces.zig").IRawInputProvider;
const MousePosition = @import("../engine/input/interfaces.zig").MousePosition;
const ScrollDelta = @import("../engine/input/interfaces.zig").ScrollDelta;
const Key = @import("../engine/core/interfaces.zig").Key;
const MouseButton = @import("../engine/core/interfaces.zig").MouseButton;

// ============================================================================
// Mock Input Provider
// ============================================================================

const MockInputState = struct {
    keys_down: std.AutoHashMapUnmanaged(Key, void) = .empty,
    keys_pressed: std.AutoHashMapUnmanaged(Key, void) = .empty,
    keys_released: std.AutoHashMapUnmanaged(Key, void) = .empty,
    mouse_down: [8]bool = [_]bool{false} ** 8,
    mouse_pressed: [8]bool = [_]bool{false} ** 8,
    mouse_released: [8]bool = [_]bool{false} ** 8,
    mouse_captured: bool = false,
    mouse_delta: MousePosition = .{ .x = 0, .y = 0 },
    mouse_position: MousePosition = .{ .x = 0, .y = 0 },
    scroll_delta: ScrollDelta = .{ .x = 0, .y = 0 },
    window_width: u32 = 1920,
    window_height: u32 = 1080,
    should_quit: bool = false,

    pub fn setKeyDown(self: *MockInputState, key: Key) void {
        self.keys_down.put(testing.allocator, key, {}) catch unreachable;
    }

    pub fn setKeyPressed(self: *MockInputState, key: Key) void {
        self.keys_pressed.put(testing.allocator, key, {}) catch unreachable;
    }

    pub fn setKeyReleased(self: *MockInputState, key: Key) void {
        self.keys_released.put(testing.allocator, key, {}) catch unreachable;
    }

    pub fn clear(self: *MockInputState) void {
        self.keys_down.clearRetainingCapacity();
        self.keys_pressed.clearRetainingCapacity();
        self.keys_released.clearRetainingCapacity();
        @memset(&self.mouse_down, false);
        @memset(&self.mouse_pressed, false);
        @memset(&self.mouse_released, false);
    }

    pub fn deinit(self: *MockInputState) void {
        self.keys_down.deinit(testing.allocator);
        self.keys_pressed.deinit(testing.allocator);
        self.keys_released.deinit(testing.allocator);
    }
};

const MockInputProvider = struct {
    state: *MockInputState,

    pub fn provider(self: *MockInputProvider) IRawInputProvider {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    const VTABLE = IRawInputProvider.VTable{
        .isKeyDown = isKeyDown_impl,
        .isKeyPressed = isKeyPressed_impl,
        .isKeyReleased = isKeyReleased_impl,
        .isMouseButtonDown = isMouseButtonDown_impl,
        .isMouseButtonPressed = isMouseButtonPressed_impl,
        .isMouseButtonReleased = isMouseButtonReleased_impl,
        .getMouseDelta = getMouseDelta_impl,
        .getMousePosition = getMousePosition_impl,
        .getScrollDelta = getScrollDelta_impl,
        .getWindowWidth = getWindowWidth_impl,
        .getWindowHeight = getWindowHeight_impl,
        .shouldQuit = shouldQuit_impl,
        .setShouldQuit = setShouldQuit_impl,
        .isMouseCaptured = isMouseCaptured_impl,
        .setMouseCapture = setMouseCapture_impl,
    };

    fn isKeyDown_impl(ptr: *anyopaque, key: Key) bool {
        const self: *MockInputProvider = @ptrCast(@alignCast(ptr));
        return self.state.keys_down.contains(key);
    }

    fn isKeyPressed_impl(ptr: *anyopaque, key: Key) bool {
        const self: *MockInputProvider = @ptrCast(@alignCast(ptr));
        return self.state.keys_pressed.contains(key);
    }

    fn isKeyReleased_impl(ptr: *anyopaque, key: Key) bool {
        const self: *MockInputProvider = @ptrCast(@alignCast(ptr));
        return self.state.keys_released.contains(key);
    }

    fn isMouseButtonDown_impl(ptr: *anyopaque, button: MouseButton) bool {
        const self: *MockInputProvider = @ptrCast(@alignCast(ptr));
        return self.state.mouse_down[@intFromEnum(button)];
    }

    fn isMouseButtonPressed_impl(ptr: *anyopaque, button: MouseButton) bool {
        const self: *MockInputProvider = @ptrCast(@alignCast(ptr));
        return self.state.mouse_pressed[@intFromEnum(button)];
    }

    fn isMouseButtonReleased_impl(ptr: *anyopaque, button: MouseButton) bool {
        const self: *MockInputProvider = @ptrCast(@alignCast(ptr));
        return self.state.mouse_released[@intFromEnum(button)];
    }

    fn getMouseDelta_impl(ptr: *anyopaque) MousePosition {
        const self: *MockInputProvider = @ptrCast(@alignCast(ptr));
        return self.state.mouse_delta;
    }

    fn getMousePosition_impl(ptr: *anyopaque) MousePosition {
        const self: *MockInputProvider = @ptrCast(@alignCast(ptr));
        return self.state.mouse_position;
    }

    fn getScrollDelta_impl(ptr: *anyopaque) ScrollDelta {
        const self: *MockInputProvider = @ptrCast(@alignCast(ptr));
        return self.state.scroll_delta;
    }

    fn getWindowWidth_impl(ptr: *anyopaque) u32 {
        const self: *MockInputProvider = @ptrCast(@alignCast(ptr));
        return self.state.window_width;
    }

    fn getWindowHeight_impl(ptr: *anyopaque) u32 {
        const self: *MockInputProvider = @ptrCast(@alignCast(ptr));
        return self.state.window_height;
    }

    fn shouldQuit_impl(ptr: *anyopaque) bool {
        const self: *MockInputProvider = @ptrCast(@alignCast(ptr));
        return self.state.should_quit;
    }

    fn setShouldQuit_impl(ptr: *anyopaque, quit: bool) void {
        const self: *MockInputProvider = @ptrCast(@alignCast(ptr));
        self.state.should_quit = quit;
    }

    fn isMouseCaptured_impl(ptr: *anyopaque) bool {
        const self: *MockInputProvider = @ptrCast(@alignCast(ptr));
        return self.state.mouse_captured;
    }

    fn setMouseCapture_impl(ptr: *anyopaque, window: ?*anyopaque, capture: bool) void {
        _ = window;
        const self: *MockInputProvider = @ptrCast(@alignCast(ptr));
        self.state.mouse_captured = capture;
    }
};

// ============================================================================
// Movement Vector Tests
// ============================================================================

test "InputMapper.getMovementVector returns zero when no keys pressed" {
    var state = MockInputState{};
    defer state.deinit();
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    const vec = mapper.getMovementVector(provider.provider());

    try testing.expectEqual(@as(f32, 0), vec.x);
    try testing.expectEqual(@as(f32, 0), vec.z);
}

test "InputMapper.getMovementVector forward only" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyDown(.w);
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    const vec = mapper.getMovementVector(provider.provider());

    try testing.expectEqual(@as(f32, 0), vec.x);
    try testing.expectEqual(@as(f32, 1), vec.z);
}

test "InputMapper.getMovementVector backward only" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyDown(.s);
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    const vec = mapper.getMovementVector(provider.provider());

    try testing.expectEqual(@as(f32, 0), vec.x);
    try testing.expectEqual(@as(f32, -1), vec.z);
}

test "InputMapper.getMovementVector left only" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyDown(.a);
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    const vec = mapper.getMovementVector(provider.provider());

    try testing.expectEqual(@as(f32, -1), vec.x);
    try testing.expectEqual(@as(f32, 0), vec.z);
}

test "InputMapper.getMovementVector right only" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyDown(.d);
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    const vec = mapper.getMovementVector(provider.provider());

    try testing.expectEqual(@as(f32, 1), vec.x);
    try testing.expectEqual(@as(f32, 0), vec.z);
}

test "InputMapper.getMovementVector diagonal forward-right" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyDown(.w);
    state.setKeyDown(.d);
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    const vec = mapper.getMovementVector(provider.provider());

    // Both components should be positive for forward-right
    try testing.expect(vec.x > 0);
    try testing.expect(vec.z > 0);
}

test "InputMapper.getMovementVector diagonal backward-left" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyDown(.s);
    state.setKeyDown(.a);
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    const vec = mapper.getMovementVector(provider.provider());

    // Both components should be negative for backward-left
    try testing.expect(vec.x < 0);
    try testing.expect(vec.z < 0);
}

test "InputMapper.getMovementVector opposite keys cancel out" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyDown(.w);
    state.setKeyDown(.s);
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    const vec = mapper.getMovementVector(provider.provider());

    try testing.expectEqual(@as(f32, 0), vec.z);
}

test "InputMapper.getMovementVector all four keys pressed" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyDown(.w);
    state.setKeyDown(.a);
    state.setKeyDown(.s);
    state.setKeyDown(.d);
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    const vec = mapper.getMovementVector(provider.provider());

    // Should cancel out to zero
    try testing.expectEqual(@as(f32, 0), vec.x);
    try testing.expectEqual(@as(f32, 0), vec.z);
}

// ============================================================================
// Action State Tests
// ============================================================================

test "InputMapper.isActionActive with key binding" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyDown(.space);
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    try testing.expect(mapper.isActionActive(provider.provider(), .jump));
}

test "InputMapper.isActionActive with mouse binding" {
    var state = MockInputState{};
    defer state.deinit();
    state.mouse_down[@intFromEnum(MouseButton.left)] = true;
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    try testing.expect(mapper.isActionActive(provider.provider(), .interact_primary));
}

test "InputMapper.isActionActive returns false when not pressed" {
    var state = MockInputState{};
    defer state.deinit();
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    try testing.expect(!mapper.isActionActive(provider.provider(), .jump));
}

test "InputMapper.isActionPressed detects key press" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyPressed(.space);
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    try testing.expect(mapper.isActionPressed(provider.provider(), .jump));
}

test "InputMapper.isActionPressed detects mouse press" {
    var state = MockInputState{};
    defer state.deinit();
    state.mouse_pressed[@intFromEnum(MouseButton.right)] = true;
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    try testing.expect(mapper.isActionPressed(provider.provider(), .interact_secondary));
}

test "InputMapper.isActionReleased detects key release" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyReleased(.escape);
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    try testing.expect(mapper.isActionReleased(provider.provider(), .pause));
}

test "InputMapper.isActionReleased detects mouse release" {
    var state = MockInputState{};
    defer state.deinit();
    state.mouse_released[@intFromEnum(MouseButton.left)] = true;
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    try testing.expect(mapper.isActionReleased(provider.provider(), .interact_primary));
}

// ============================================================================
// Alternate Binding Tests
// ============================================================================

test "InputMapper.isActionActive with alternate key binding" {
    var state = MockInputState{};
    defer state.deinit();
    var mapper = InputMapper.init();

    // map_zoom_in has alternate binding: plus OR kp_plus
    // We'll use a different action with alt binding for testing
    // Let's test by setting an alternate binding manually
    mapper.setAlternateBinding(.jump, .{ .key = .enter });

    state.setKeyDown(.enter);
    var provider = MockInputProvider{ .state = &state };

    try testing.expect(mapper.isActionActive(provider.provider(), .jump));
}

test "InputMapper.isActionPressed with alternate key binding" {
    var state = MockInputState{};
    defer state.deinit();
    var mapper = InputMapper.init();

    mapper.setAlternateBinding(.jump, .{ .key = .enter });

    state.setKeyPressed(.enter);
    var provider = MockInputProvider{ .state = &state };

    try testing.expect(mapper.isActionPressed(provider.provider(), .jump));
}

test "InputMapper.isActionActive either binding works" {
    var state = MockInputState{};
    defer state.deinit();
    var mapper = InputMapper.init();

    mapper.setAlternateBinding(.jump, .{ .key = .enter });

    // Test with primary binding
    state.setKeyDown(.space);
    var provider1 = MockInputProvider{ .state = &state };
    try testing.expect(mapper.isActionActive(provider1.provider(), .jump));

    // Reset and test with alternate
    state.clear();
    state.setKeyDown(.enter);
    var provider2 = MockInputProvider{ .state = &state };
    try testing.expect(mapper.isActionActive(provider2.provider(), .jump));
}

// ============================================================================
// None Binding Tests
// ============================================================================

test "InputMapper.isActionActive with none binding returns false" {
    var state = MockInputState{};
    defer state.deinit();
    var provider = MockInputProvider{ .state = &state };
    var mapper = InputMapper.init();

    // fly action has .none binding by default
    try testing.expect(!mapper.isActionActive(provider.provider(), .fly));
}

test "InputMapper.isActionPressed with none binding returns false" {
    var state = MockInputState{};
    defer state.deinit();
    var provider = MockInputProvider{ .state = &state };
    var mapper = InputMapper.init();

    try testing.expect(!mapper.isActionPressed(provider.provider(), .fly));
}

test "InputMapper.isActionReleased with none binding returns false" {
    var state = MockInputState{};
    defer state.deinit();
    var provider = MockInputProvider{ .state = &state };
    var mapper = InputMapper.init();

    try testing.expect(!mapper.isActionReleased(provider.provider(), .fly));
}

// ============================================================================
// Binding Management Tests
// ============================================================================

test "InputMapper.setBinding changes primary binding" {
    var mapper = InputMapper.init();

    // Change jump from space to enter
    mapper.setBinding(.jump, .{ .key = .enter });

    var state = MockInputState{};
    defer state.deinit();
    state.setKeyDown(.enter);
    var provider = MockInputProvider{ .state = &state };

    try testing.expect(mapper.isActionActive(provider.provider(), .jump));
}

test "InputMapper.setAlternateBinding adds alternate binding" {
    var mapper = InputMapper.init();

    // Add alternate binding for jump (space is primary, add enter as alt)
    mapper.setAlternateBinding(.jump, .{ .key = .enter });

    var state = MockInputState{};
    defer state.deinit();
    state.setKeyDown(.enter);
    var provider = MockInputProvider{ .state = &state };

    try testing.expect(mapper.isActionActive(provider.provider(), .jump));
}

test "InputMapper.resetToDefaults restores all bindings" {
    var mapper = InputMapper.init();

    // Change a binding
    mapper.setBinding(.jump, .{ .key = .enter });

    // Reset
    mapper.resetToDefaults();

    var state = MockInputState{};
    defer state.deinit();
    state.setKeyDown(.space);
    var provider = MockInputProvider{ .state = &state };

    // Jump should work with space again
    try testing.expect(mapper.isActionActive(provider.provider(), .jump));
}

// ============================================================================
// InputBinding.getName Tests
// ============================================================================

test "InputBinding.getName for letter keys" {
    const binding = InputBinding{ .key = .a };
    try testing.expectEqualStrings("A", binding.getName());
}

test "InputBinding.getName for number keys" {
    const binding = InputBinding{ .key = .@"1" };
    try testing.expectEqualStrings("1", binding.getName());
}

test "InputBinding.getName for special keys" {
    try testing.expectEqualStrings("Space", (InputBinding{ .key = .space }).getName());
    try testing.expectEqualStrings("Escape", (InputBinding{ .key = .escape }).getName());
    try testing.expectEqualStrings("Enter", (InputBinding{ .key = .enter }).getName());
    try testing.expectEqualStrings("Tab", (InputBinding{ .key = .tab }).getName());
}

test "InputBinding.getName for modifier keys" {
    try testing.expectEqualStrings("Left Shift", (InputBinding{ .key = .left_shift }).getName());
    try testing.expectEqualStrings("Left Ctrl", (InputBinding{ .key = .left_ctrl }).getName());
}

test "InputBinding.getName for function keys" {
    try testing.expectEqualStrings("F1", (InputBinding{ .key = .f1 }).getName());
    try testing.expectEqualStrings("F12", (InputBinding{ .key = .f12 }).getName());
}

test "InputBinding.getName for arrow keys" {
    try testing.expectEqualStrings("Up", (InputBinding{ .key = .up }).getName());
    try testing.expectEqualStrings("Down", (InputBinding{ .key = .down }).getName());
    try testing.expectEqualStrings("Left", (InputBinding{ .key = .left_arrow }).getName());
    try testing.expectEqualStrings("Right", (InputBinding{ .key = .right_arrow }).getName());
}

test "InputBinding.getName for mouse buttons" {
    try testing.expectEqualStrings("Left Click", (InputBinding{ .mouse_button = .left }).getName());
    try testing.expectEqualStrings("Right Click", (InputBinding{ .mouse_button = .right }).getName());
    try testing.expectEqualStrings("Middle Click", (InputBinding{ .mouse_button = .middle }).getName());
}

test "InputBinding.getName for none binding" {
    const binding = InputBinding{ .none = {} };
    try testing.expectEqualStrings("Unbound", binding.getName());
}

test "InputBinding.getName for key_alt binding" {
    // key_alt should display same as key
    const binding = InputBinding{ .key_alt = .space };
    try testing.expectEqualStrings("Space", binding.getName());
}

// ============================================================================
// IInputMapper Interface Tests
// ============================================================================

test "IInputMapper.interface creates valid interface" {
    var mapper = InputMapper.init();
    const iface = mapper.interface();

    try testing.expect(iface.ptr == @as(*const anyopaque, @ptrCast(&mapper)));
}

test "IInputMapper.getBinding through interface" {
    var mapper = InputMapper.init();
    const iface = mapper.interface();

    const binding = iface.getBinding(.jump);

    // Default jump binding is space
    try testing.expect(binding.primary.key == .space);
}

test "IInputMapper.isActionActive through interface" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyDown(.space);
    var provider = MockInputProvider{ .state = &state };
    var mapper = InputMapper.init();
    const iface = mapper.interface();

    try testing.expect(iface.isActionActive(provider.provider(), .jump));
}

test "IInputMapper.isActionPressed through interface" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyPressed(.escape);
    var provider = MockInputProvider{ .state = &state };
    var mapper = InputMapper.init();
    const iface = mapper.interface();

    try testing.expect(iface.isActionPressed(provider.provider(), .pause));
}

test "IInputMapper.isActionReleased through interface" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyReleased(.space);
    var provider = MockInputProvider{ .state = &state };
    var mapper = InputMapper.init();
    const iface = mapper.interface();

    try testing.expect(iface.isActionReleased(provider.provider(), .jump));
}

test "IInputMapper.getMovementVector through interface" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyDown(.w);
    var provider = MockInputProvider{ .state = &state };
    var mapper = InputMapper.init();
    const iface = mapper.interface();

    const vec = iface.getMovementVector(provider.provider());

    try testing.expectEqual(@as(f32, 0), vec.x);
    try testing.expectEqual(@as(f32, 1), vec.z);
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "InputMapper with multiple actions active simultaneously" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyDown(.w); // move_forward
    state.setKeyDown(.space); // jump
    state.mouse_down[@intFromEnum(MouseButton.left)] = true; // interact_primary
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    try testing.expect(mapper.isActionActive(provider.provider(), .move_forward));
    try testing.expect(mapper.isActionActive(provider.provider(), .jump));
    try testing.expect(mapper.isActionActive(provider.provider(), .interact_primary));
}

test "InputMapper preserves state across multiple calls" {
    var state = MockInputState{};
    defer state.deinit();
    state.setKeyDown(.w);
    var provider = MockInputProvider{ .state = &state };
    const mapper = InputMapper.init();

    // Multiple calls should return same result
    const vec1 = mapper.getMovementVector(provider.provider());
    const vec2 = mapper.getMovementVector(provider.provider());

    try testing.expectEqual(vec1.x, vec2.x);
    try testing.expectEqual(vec1.z, vec2.z);
}

test "InputBinding.eql treats key and key_alt as equivalent" {
    const key_binding = InputBinding{ .key = .space };
    const key_alt_binding = InputBinding{ .key_alt = .space };

    try testing.expect(key_binding.eql(key_alt_binding));
    try testing.expect(key_alt_binding.eql(key_binding));
}

test "InputBinding.eql different keys are not equal" {
    const binding1 = InputBinding{ .key = .space };
    const binding2 = InputBinding{ .key = .enter };

    try testing.expect(!binding1.eql(binding2));
}

test "InputBinding.eql same mouse buttons are equal" {
    const binding1 = InputBinding{ .mouse_button = .left };
    const binding2 = InputBinding{ .mouse_button = .left };

    try testing.expect(binding1.eql(binding2));
}

test "InputBinding.eql different mouse buttons are not equal" {
    const binding1 = InputBinding{ .mouse_button = .left };
    const binding2 = InputBinding{ .mouse_button = .right };

    try testing.expect(!binding1.eql(binding2));
}

test "InputBinding.eql none bindings are equal" {
    const binding1 = InputBinding{ .none = {} };
    const binding2 = InputBinding{ .none = {} };

    try testing.expect(binding1.eql(binding2));
}

test "InputBinding.eql cross-type comparisons" {
    const key_binding = InputBinding{ .key = .space };
    const mouse_binding = InputBinding{ .mouse_button = .left };
    const none_binding = InputBinding{ .none = {} };

    try testing.expect(!key_binding.eql(mouse_binding));
    try testing.expect(!key_binding.eql(none_binding));
    try testing.expect(!mouse_binding.eql(none_binding));
}
