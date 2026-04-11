const std = @import("std");
const testing = std.testing;
const input_mapper = @import("input_mapper.zig");
const InputBinding = input_mapper.InputBinding;
const ActionBinding = input_mapper.ActionBinding;
const InputMapper = input_mapper.InputMapper;
const GameAction = input_mapper.GameAction;
const MovementVector = input_mapper.MovementVector;
const DEFAULT_BINDINGS = input_mapper.DEFAULT_BINDINGS;

test "ActionBinding.init creates binding with primary and none alternate" {
    const binding = ActionBinding.init(.{ .key = .w });

    try testing.expect(binding.primary.key == .w);
    try testing.expect(binding.alternate == .none);
}

test "ActionBinding.initWithAlt creates binding with both bindings" {
    const binding = ActionBinding.initWithAlt(.{ .key = .w }, .{ .key_alt = .up });

    try testing.expect(binding.primary.key == .w);
    try testing.expect(binding.alternate.key_alt == .up);
}

test "InputBinding.getName returns correct names for keys" {
    {
        const b = InputBinding{ .key = .w };
        try testing.expectEqualStrings("W", b.getName());
    }
    {
        const b = InputBinding{ .key = .a };
        try testing.expectEqualStrings("A", b.getName());
    }
    {
        const b = InputBinding{ .key = .s };
        try testing.expectEqualStrings("S", b.getName());
    }
    {
        const b = InputBinding{ .key = .d };
        try testing.expectEqualStrings("D", b.getName());
    }
    {
        const b = InputBinding{ .key = .space };
        try testing.expectEqualStrings("Space", b.getName());
    }
    {
        const b = InputBinding{ .key = .escape };
        try testing.expectEqualStrings("Escape", b.getName());
    }
    {
        const b = InputBinding{ .key = .enter };
        try testing.expectEqualStrings("Enter", b.getName());
    }
    {
        const b = InputBinding{ .key = .left_shift };
        try testing.expectEqualStrings("Left Shift", b.getName());
    }
    {
        const b = InputBinding{ .key = .right_shift };
        try testing.expectEqualStrings("Right Shift", b.getName());
    }
    {
        const b = InputBinding{ .key = .left_ctrl };
        try testing.expectEqualStrings("Left Ctrl", b.getName());
    }
    {
        const b = InputBinding{ .key = .f1 };
        try testing.expectEqualStrings("F1", b.getName());
    }
    {
        const b = InputBinding{ .key = .f12 };
        try testing.expectEqualStrings("F12", b.getName());
    }
    {
        const b = InputBinding{ .key = .tab };
        try testing.expectEqualStrings("Tab", b.getName());
    }
    {
        const b = InputBinding{ .key = .backspace };
        try testing.expectEqualStrings("Backspace", b.getName());
    }
}

test "InputBinding.getName returns correct names for mouse buttons" {
    {
        const b = InputBinding{ .mouse_button = .left };
        try testing.expectEqualStrings("Left Click", b.getName());
    }
    {
        const b = InputBinding{ .mouse_button = .right };
        try testing.expectEqualStrings("Right Click", b.getName());
    }
    {
        const b = InputBinding{ .mouse_button = .middle };
        try testing.expectEqualStrings("Middle Click", b.getName());
    }
}

test "InputBinding.getName returns Unbound for none" {
    const b: InputBinding = .{ .none = {} };
    try testing.expectEqualStrings("Unbound", b.getName());
}

test "InputBinding.getName returns Unknown for unhandled keys" {
    {
        const b = InputBinding{ .key = .plus };
        try testing.expectEqualStrings("+", b.getName());
    }
    {
        const b = InputBinding{ .key = .minus };
        try testing.expectEqualStrings("-", b.getName());
    }
}

test "InputBinding.eql returns true for identical bindings" {
    const b1 = InputBinding{ .key = .w };
    const b2 = InputBinding{ .key = .w };
    try testing.expect(b1.eql(b2));
}

test "InputBinding.eql returns true for key and key_alt with same key" {
    const b1 = InputBinding{ .key = .w };
    const b2 = InputBinding{ .key_alt = .w };
    try testing.expect(b1.eql(b2));
    try testing.expect(b2.eql(b1));
}

test "InputBinding.eql returns false for different key bindings" {
    const b1 = InputBinding{ .key = .w };
    const b2 = InputBinding{ .key = .s };
    try testing.expect(!b1.eql(b2));
}

test "InputBinding.eql returns false for key vs mouse" {
    const key_binding = InputBinding{ .key = .w };
    const mouse_binding = InputBinding{ .mouse_button = .left };
    try testing.expect(!key_binding.eql(mouse_binding));
}

test "InputBinding.eql returns true for none to none" {
    const b1: InputBinding = .{ .none = {} };
    const b2: InputBinding = .{ .none = {} };
    try testing.expect(b1.eql(b2));
}

test "InputBinding.eql returns false for none vs actual binding" {
    const none: InputBinding = .{ .none = {} };
    const key: InputBinding = .{ .key = .w };
    try testing.expect(!none.eql(key));
    try testing.expect(!key.eql(none));
}

test "DEFAULT_BINDINGS has correct count for all GameAction values" {
    try testing.expectEqual(@as(usize, GameAction.count), DEFAULT_BINDINGS.len);
}

test "DEFAULT_BINDINGS movement bindings are WASD" {
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.move_forward)].primary.key == .w);
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.move_backward)].primary.key == .s);
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.move_left)].primary.key == .a);
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.move_right)].primary.key == .d);
}

test "DEFAULT_BINDINGS jump and crouch are space and shift" {
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.jump)].primary.key == .space);
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.crouch)].primary.key == .left_shift);
}

test "DEFAULT_BINDINGS interact bindings are mouse buttons" {
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.interact_primary)].primary.mouse_button == .left);
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.interact_secondary)].primary.mouse_button == .right);
}

test "DEFAULT_BINDINGS hotbar slots are 1-9" {
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.slot_1)].primary.key == .@"1");
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.slot_2)].primary.key == .@"2");
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.slot_3)].primary.key == .@"3");
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.slot_4)].primary.key == .@"4");
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.slot_5)].primary.key == .@"5");
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.slot_6)].primary.key == .@"6");
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.slot_7)].primary.key == .@"7");
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.slot_8)].primary.key == .@"8");
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.slot_9)].primary.key == .@"9");
}

test "DEFAULT_BINDINGS inventory is I" {
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.inventory)].primary.key == .i);
}

test "DEFAULT_BINDINGS pause is Escape" {
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.pause)].primary.key == .escape);
}

test "DEFAULT_BINDINGS fly action is unbound" {
    try testing.expect(DEFAULT_BINDINGS[@intFromEnum(GameAction.fly)].primary == .none);
}

test "InputMapper.init creates mapper with default bindings" {
    const mapper = InputMapper.init();

    try testing.expect(mapper.getBinding(.move_forward).primary.key == .w);
    try testing.expect(mapper.getBinding(.jump).primary.key == .space);
}

test "InputMapper.setBinding updates primary binding" {
    var mapper = InputMapper.init();

    mapper.setBinding(.move_forward, .{ .key = .up });

    try testing.expect(mapper.getBinding(.move_forward).primary.key == .up);
}

test "InputMapper.setAlternateBinding updates alternate binding" {
    var mapper = InputMapper.init();

    mapper.setAlternateBinding(.move_forward, .{ .key_alt = .kp_plus });

    try testing.expect(mapper.getBinding(.move_forward).alternate.key_alt == .kp_plus);
}

test "InputMapper.resetToDefaults restores all bindings" {
    var mapper = InputMapper.init();

    mapper.setBinding(.move_forward, .{ .key = .up });
    mapper.setBinding(.jump, .{ .key = .x });
    mapper.resetToDefaults();

    try testing.expect(mapper.getBinding(.move_forward).primary.key == .w);
    try testing.expect(mapper.getBinding(.jump).primary.key == .space);
}

test "InputMapper.resetActionToDefault restores single action" {
    var mapper = InputMapper.init();

    mapper.setBinding(.move_forward, .{ .key = .up });
    try testing.expect(mapper.getBinding(.move_forward).primary.key == .up);

    mapper.resetActionToDefault(.move_forward);
    try testing.expect(mapper.getBinding(.move_forward).primary.key == .w);
    try testing.expect(mapper.getBinding(.jump).primary.key == .space);
}

test "InputMapper.interface returns IInputMapper with correct vtable" {
    var mapper = InputMapper.init();
    const iface = mapper.interface();

    try testing.expect(@as(*anyopaque, @ptrCast(&mapper)) == iface.ptr);
}

test "MovementVector has x and z components" {
    const mv = MovementVector{ .x = 1.0, .z = -1.0 };
    try testing.expectEqual(@as(f32, 1.0), mv.x);
    try testing.expectEqual(@as(f32, -1.0), mv.z);
}
