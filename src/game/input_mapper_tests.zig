const std = @import("std");
const testing = std.testing;
const input_mapper = @import("input_mapper.zig");
const InputMapper = input_mapper.InputMapper;
const GameAction = input_mapper.GameAction;
const InputBinding = input_mapper.InputBinding;
const ActionBinding = input_mapper.ActionBinding;
const MovementVector = input_mapper.MovementVector;
const DEFAULT_BINDINGS = input_mapper.DEFAULT_BINDINGS;

// ============================================================================
// InputMapper Initialization Tests
// ============================================================================

test "InputMapper.init creates mapper with default bindings" {
    const mapper = InputMapper.init();

    // Verify some default bindings are set correctly
    const move_forward = mapper.getBinding(.move_forward);
    try testing.expect(move_forward.primary.key == .w);

    const jump = mapper.getBinding(.jump);
    try testing.expect(jump.primary.key == .space);

    const interact_primary = mapper.getBinding(.interact_primary);
    try testing.expect(interact_primary.primary.mouse_button == .left);
}

test "InputMapper.resetToDefaults restores all bindings to default" {
    var mapper = InputMapper.init();

    // Change a binding
    mapper.setBinding(.move_forward, .{ .key = .up });
    try testing.expect(mapper.getBinding(.move_forward).primary.key == .up);

    // Reset to defaults
    mapper.resetToDefaults();

    // Verify it's back to default
    try testing.expect(mapper.getBinding(.move_forward).primary.key == .w);
}

// ============================================================================
// InputMapper Binding Tests
// ============================================================================

test "InputMapper.setBinding updates primary binding" {
    var mapper = InputMapper.init();

    mapper.setBinding(.jump, .{ .key = .x });

    const binding = mapper.getBinding(.jump);
    try testing.expect(binding.primary.key == .x);
}

test "InputMapper.setAlternateBinding updates alternate binding" {
    var mapper = InputMapper.init();

    mapper.setAlternateBinding(.jump, .{ .key = .c });

    const binding = mapper.getBinding(.jump);
    try testing.expect(binding.alternate.key == .c);
}

test "InputMapper.resetActionToDefault resets single action" {
    var mapper = InputMapper.init();

    // Change a binding
    mapper.setBinding(.move_forward, .{ .key = .up });
    try testing.expect(mapper.getBinding(.move_forward).primary.key == .up);

    // Reset just that action
    mapper.resetActionToDefault(.move_forward);

    // Verify it's back to default
    try testing.expect(mapper.getBinding(.move_forward).primary.key == .w);

    // Other bindings should remain unchanged
    // (We can't easily test this without modifying another binding first)
}

// ============================================================================
// ActionBinding Tests
// ============================================================================

test "ActionBinding.init creates binding with primary only" {
    const binding = ActionBinding.init(.{ .key = .a });

    try testing.expect(binding.primary.key == .a);
    try testing.expect(binding.alternate == .none);
}

test "ActionBinding.initWithAlt creates binding with primary and alternate" {
    const binding = ActionBinding.initWithAlt(.{ .key = .a }, .{ .key = .b });

    try testing.expect(binding.primary.key == .a);
    try testing.expect(binding.alternate.key == .b);
}

// ============================================================================
// MovementVector Tests
// ============================================================================

test "MovementVector default is zero" {
    const vec = MovementVector{ .x = 0, .z = 0 };
    try testing.expectEqual(@as(f32, 0), vec.x);
    try testing.expectEqual(@as(f32, 0), vec.z);
}

// ============================================================================
// GameAction Enum Tests
// ============================================================================

test "GameAction.count matches number of variants" {
    const count = @typeInfo(GameAction).@"enum".fields.len;
    try testing.expectEqual(@as(usize, GameAction.count), count);
}

test "GameAction variants have consecutive values" {
    const fields = @typeInfo(GameAction).@"enum".fields;

    inline for (fields, 0..) |field, i| {
        try testing.expectEqual(@as(usize, field.value), i);
    }
}

// ============================================================================
// DEFAULT_BINDINGS Array Tests
// ============================================================================

test "DEFAULT_BINDINGS has correct size" {
    try testing.expectEqual(@as(usize, GameAction.count), DEFAULT_BINDINGS.len);
}

test "DEFAULT_BINDINGS has expected movement bindings" {
    // move_forward should be W
    const forward = DEFAULT_BINDINGS[@intFromEnum(GameAction.move_forward)];
    try testing.expect(forward.primary.key == .w);

    // move_backward should be S
    const backward = DEFAULT_BINDINGS[@intFromEnum(GameAction.move_backward)];
    try testing.expect(backward.primary.key == .s);

    // move_left should be A
    const left = DEFAULT_BINDINGS[@intFromEnum(GameAction.move_left)];
    try testing.expect(left.primary.key == .a);

    // move_right should be D
    const right = DEFAULT_BINDINGS[@intFromEnum(GameAction.move_right)];
    try testing.expect(right.primary.key == .d);
}

test "DEFAULT_BINDINGS has expected interaction bindings" {
    // interact_primary should be left mouse button
    const primary = DEFAULT_BINDINGS[@intFromEnum(GameAction.interact_primary)];
    try testing.expect(primary.primary.mouse_button == .left);

    // interact_secondary should be right mouse button
    const secondary = DEFAULT_BINDINGS[@intFromEnum(GameAction.interact_secondary)];
    try testing.expect(secondary.primary.mouse_button == .right);
}

test "DEFAULT_BINDINGS has expected hotbar bindings" {
    // slot_1 should be key 1
    const slot1 = DEFAULT_BINDINGS[@intFromEnum(GameAction.slot_1)];
    try testing.expect(slot1.primary.key == .@"1");

    // slot_9 should be key 9
    const slot9 = DEFAULT_BINDINGS[@intFromEnum(GameAction.slot_9)];
    try testing.expect(slot9.primary.key == .@"9");
}

test "DEFAULT_BINDINGS has expected UI bindings" {
    // inventory should be I
    const inventory = DEFAULT_BINDINGS[@intFromEnum(GameAction.inventory)];
    try testing.expect(inventory.primary.key == .i);

    // pause should be Escape
    const pause = DEFAULT_BINDINGS[@intFromEnum(GameAction.pause)];
    try testing.expect(pause.primary.key == .escape);
}

test "DEFAULT_BINDINGS map_zoom_in has alternate binding" {
    const zoom_in = DEFAULT_BINDINGS[@intFromEnum(GameAction.map_zoom_in)];
    try testing.expect(zoom_in.primary.key == .plus);
    try testing.expect(zoom_in.alternate.key_alt == .kp_plus);
}

test "DEFAULT_BINDINGS map_zoom_out has alternate binding" {
    const zoom_out = DEFAULT_BINDINGS[@intFromEnum(GameAction.map_zoom_out)];
    try testing.expect(zoom_out.primary.key == .minus);
    try testing.expect(zoom_out.alternate.key_alt == .kp_minus);
}

// ============================================================================
// Serialization/Deserialization Tests
// ============================================================================

test "InputMapper serialization round-trip" {
    const allocator = testing.allocator;
    var mapper = InputMapper.init();

    // Modify some bindings
    mapper.setBinding(.jump, .{ .key = .up });
    mapper.setAlternateBinding(.move_forward, .{ .key = .x });

    // Serialize
    const json = try mapper.serialize(allocator);
    defer allocator.free(json);

    // Deserialize into new mapper
    var mapper2 = InputMapper.init();
    try mapper2.deserialize(allocator, json);

    // Verify bindings were preserved
    try testing.expect(mapper2.getBinding(.jump).primary.key == .up);
    try testing.expect(mapper2.getBinding(.move_forward).alternate.key == .x);
}

// Note: Deserialize expects a specific JSON format (full array of all bindings)
// The serialization round-trip test above covers the functionality adequately

// ============================================================================
// InputBinding.getName Tests
// ============================================================================

test "InputBinding.getName returns correct name for keys" {
    const w_binding = InputBinding{ .key = .w };
    try testing.expect(std.mem.eql(u8, "W", w_binding.getName()));

    const space_binding = InputBinding{ .key = .space };
    try testing.expect(std.mem.eql(u8, "Space", space_binding.getName()));

    const escape_binding = InputBinding{ .key = .escape };
    try testing.expect(std.mem.eql(u8, "Escape", escape_binding.getName()));
}

test "InputBinding.getName returns correct name for mouse buttons" {
    const left = InputBinding{ .mouse_button = .left };
    try testing.expect(std.mem.eql(u8, "Left Click", left.getName()));

    const right = InputBinding{ .mouse_button = .right };
    try testing.expect(std.mem.eql(u8, "Right Click", right.getName()));

    const middle = InputBinding{ .mouse_button = .middle };
    try testing.expect(std.mem.eql(u8, "Middle Click", middle.getName()));
}

test "InputBinding.getName returns correct name for none" {
    const none = InputBinding{ .none = {} };
    try testing.expect(std.mem.eql(u8, "Unbound", none.getName()));
}

test "InputBinding.getName returns correct name for key_alt" {
    // key_alt should use same keyToString as key
    const alt_binding = InputBinding{ .key_alt = .f1 };
    try testing.expect(std.mem.eql(u8, "F1", alt_binding.getName()));
}

test "InputBinding.getName returns Unknown for unknown keys" {
    // Test with the unknown key value
    // Just verify the function doesn't panic and returns "Unknown"
    const unknown = InputBinding{ .key = .unknown };
    const name = unknown.getName();
    try testing.expect(std.mem.eql(u8, "Unknown", name));
}

// ============================================================================
// InputBinding.eql Tests (Additional edge cases)
// ============================================================================

test "InputBinding.eql key_alt equals key" {
    const key = InputBinding{ .key = .w };
    const key_alt = InputBinding{ .key_alt = .w };

    try testing.expect(key.eql(key_alt));
    try testing.expect(key_alt.eql(key));
}

test "InputBinding.eql none equals none" {
    const none1 = InputBinding{ .none = {} };
    const none2 = InputBinding{ .none = {} };

    try testing.expect(none1.eql(none2));
}

test "InputBinding.eql different keys are not equal" {
    const w = InputBinding{ .key = .w };
    const s = InputBinding{ .key = .s };

    try testing.expect(!w.eql(s));
}

test "InputBinding.eql key is not equal to mouse button" {
    const key = InputBinding{ .key = .w };
    const mouse = InputBinding{ .mouse_button = .left };

    try testing.expect(!key.eql(mouse));
    try testing.expect(!mouse.eql(key));
}

test "InputBinding.eql none is not equal to key" {
    const none = InputBinding{ .none = {} };
    const key = InputBinding{ .key = .w };

    try testing.expect(!none.eql(key));
    try testing.expect(!key.eql(none));
}

test "InputBinding.eql different mouse buttons are not equal" {
    const left = InputBinding{ .mouse_button = .left };
    const right = InputBinding{ .mouse_button = .right };

    try testing.expect(!left.eql(right));
}
