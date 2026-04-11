const std = @import("std");
const testing = std.testing;
const input_mapper = @import("input_mapper.zig");
const InputMapper = input_mapper.InputMapper;
const InputBinding = input_mapper.InputBinding;
const ActionBinding = input_mapper.ActionBinding;
const GameAction = input_mapper.GameAction;
const Key = @import("../engine/core/interfaces.zig").Key;
const MouseButton = @import("../engine/core/interfaces.zig").MouseButton;

test "InputBinding.getName for key binding" {
    const binding = InputBinding{ .key = .w };
    try testing.expectEqualStrings("W", binding.getName());

    const binding2 = InputBinding{ .key = .space };
    try testing.expectEqualStrings("Space", binding2.getName());

    const binding3 = InputBinding{ .key = .f1 };
    try testing.expectEqualStrings("F1", binding3.getName());

    const binding4 = InputBinding{ .key = .escape };
    try testing.expectEqualStrings("Escape", binding4.getName());
}

test "InputBinding.getName for key_alt binding" {
    const binding = InputBinding{ .key_alt = .a };
    try testing.expectEqualStrings("A", binding.getName());

    const binding2 = InputBinding{ .key_alt = .kp_plus };
    try testing.expectEqualStrings("Numpad +", binding2.getName());
}

test "InputBinding.getName for mouse button binding" {
    const binding = InputBinding{ .mouse_button = .left };
    try testing.expectEqualStrings("Left Click", binding.getName());

    const binding2 = InputBinding{ .mouse_button = .right };
    try testing.expectEqualStrings("Right Click", binding2.getName());

    const binding3 = InputBinding{ .mouse_button = .middle };
    try testing.expectEqualStrings("Middle Click", binding3.getName());
}

test "InputBinding.getName for none binding" {
    const binding = InputBinding{ .none = {} };
    try testing.expectEqualStrings("Unbound", binding.getName());
}

test "InputBinding eql is bidirectional for key and key_alt" {
    const b1 = InputBinding{ .key = .w };
    const b2 = InputBinding{ .key_alt = .w };

    try testing.expect(b1.eql(b2));
    try testing.expect(b2.eql(b1));
}

test "InputBinding eql returns false for different keys" {
    const b1 = InputBinding{ .key = .w };
    const b2 = InputBinding{ .key = .s };

    try testing.expect(!b1.eql(b2));
}

test "InputBinding eql returns false for different binding types" {
    const key_binding = InputBinding{ .key = .w };
    const mouse_binding = InputBinding{ .mouse_button = .left };

    try testing.expect(!key_binding.eql(mouse_binding));
}

test "InputBinding eql none binding" {
    const none1 = InputBinding{ .none = {} };
    const none2 = InputBinding{ .none = {} };

    try testing.expect(none1.eql(none2));
    try testing.expect(!none1.eql(.{ .key = .w }));
}

test "ActionBinding.init creates binding with primary only" {
    const binding = ActionBinding.init(.{ .key = .w });

    try testing.expectEqual(.w, binding.primary.key);
    try testing.expect(binding.alternate == .none);
}

test "ActionBinding.initWithAlt creates binding with both" {
    const binding = ActionBinding.initWithAlt(.{ .key = .plus }, .{ .key_alt = .kp_plus });

    try testing.expectEqual(.plus, binding.primary.key);
    try testing.expectEqual(.kp_plus, binding.alternate.key_alt);
}

test "InputMapper.init creates mapper with default bindings" {
    const mapper = InputMapper.init();

    const forward_binding = mapper.getBinding(.move_forward);
    try testing.expectEqual(.w, forward_binding.primary.key);
}

test "InputMapper.init has correct binding count" {
    const mapper = InputMapper.init();

    inline for (0..GameAction.count) |i| {
        const action: GameAction = @enumFromInt(i);
        _ = mapper.getBinding(action);
    }
}

test "InputMapper.resetToDefaults restores original bindings" {
    var mapper = InputMapper.init();

    mapper.setBinding(.move_forward, .{ .key = .up });
    try testing.expectEqual(.up, mapper.getBinding(.move_forward).primary.key);

    mapper.resetToDefaults();
    try testing.expectEqual(.w, mapper.getBinding(.move_forward).primary.key);
}

test "InputMapper.resetActionToDefault restores single action" {
    var mapper = InputMapper.init();

    mapper.setBinding(.move_forward, .{ .key = .up });
    try testing.expectEqual(.up, mapper.getBinding(.move_forward).primary.key);

    mapper.setBinding(.move_backward, .{ .key = .down });
    try testing.expectEqual(.down, mapper.getBinding(.move_backward).primary.key);

    mapper.resetActionToDefault(.move_forward);

    try testing.expectEqual(.w, mapper.getBinding(.move_forward).primary.key);
    try testing.expectEqual(.down, mapper.getBinding(.move_backward).primary.key);
}

test "InputMapper.setBinding updates primary binding" {
    var mapper = InputMapper.init();

    mapper.setBinding(.jump, .{ .key = .enter });

    try testing.expectEqual(.enter, mapper.getBinding(.jump).primary.key);
    try testing.expect(mapper.getBinding(.jump).alternate == .none);
}

test "InputMapper.setAlternateBinding updates alternate binding" {
    var mapper = InputMapper.init();

    mapper.setAlternateBinding(.move_forward, .{ .key_alt = .up });

    try testing.expectEqual(.w, mapper.getBinding(.move_forward).primary.key);
    try testing.expectEqual(.up, mapper.getBinding(.move_forward).alternate.key_alt);
}

test "InputMapper.setBinding and setAlternateBinding together" {
    var mapper = InputMapper.init();

    mapper.setBinding(.move_forward, .{ .key = .up });
    mapper.setAlternateBinding(.move_forward, .{ .key_alt = .kp_plus });

    const binding = mapper.getBinding(.move_forward);
    try testing.expectEqual(.up, binding.primary.key);
    try testing.expectEqual(.kp_plus, binding.alternate.key_alt);
}

test "DEFAULT_BINDINGS movement actions have expected keys" {
    try testing.expectEqual(.w, input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.move_forward)].primary.key);
    try testing.expectEqual(.s, input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.move_backward)].primary.key);
    try testing.expectEqual(.a, input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.move_left)].primary.key);
    try testing.expectEqual(.d, input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.move_right)].primary.key);
}

test "DEFAULT_BINDINGS jump and crouch bindings" {
    try testing.expectEqual(.space, input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.jump)].primary.key);
    try testing.expectEqual(.left_shift, input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.crouch)].primary.key);
    try testing.expectEqual(.left_ctrl, input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.sprint)].primary.key);
}

test "DEFAULT_BINDINGS interaction bindings are mouse buttons" {
    try testing.expectEqual(.left, input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.interact_primary)].primary.mouse_button);
    try testing.expectEqual(.right, input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.interact_secondary)].primary.mouse_button);
}

test "DEFAULT_BINDINGS hotbar slot bindings are number keys" {
    try testing.expectEqual(.@"1", input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.slot_1)].primary.key);
    try testing.expectEqual(.@"2", input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.slot_2)].primary.key);
    try testing.expectEqual(.@"9", input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.slot_9)].primary.key);
}

test "DEFAULT_BINDINGS menu bindings" {
    try testing.expectEqual(.i, input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.inventory)].primary.key);
    try testing.expectEqual(.escape, input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.pause)].primary.key);
}

test "DEFAULT_BINDINGS toggle bindings are function keys" {
    try testing.expectEqual(.f12, input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.toggle_creative)].primary.key);
    try testing.expectEqual(.f3, input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.toggle_debug_menu)].primary.key);
    try testing.expectEqual(.f4, input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.toggle_timing_overlay)].primary.key);
}

test "DEFAULT_BINDINGS fly action has no binding" {
    const fly_binding = input_mapper.DEFAULT_BINDINGS[@intFromEnum(GameAction.fly)];
    try testing.expect(fly_binding.primary == .none);
}

test "InputMapper interface returns correct vtable" {
    const mapper = InputMapper.init();
    const iface = mapper.interface();

    try testing.expect(iface.ptr == @as(*anyopaque, @ptrFromInt(@intFromPtr(&mapper))));
}

test "InputBinding equality handles all mouse button variants" {
    const left1 = InputBinding{ .mouse_button = .left };
    const left2 = InputBinding{ .mouse_button = .left };
    const right = InputBinding{ .mouse_button = .right };

    try testing.expect(left1.eql(left2));
    try testing.expect(!left1.eql(right));
}

test "InputBinding keyToString handles all letter keys" {
    const binding_a = input_mapper.InputBinding{ .key = .a };
    const binding_z = input_mapper.InputBinding{ .key = .z };
    try testing.expectEqualStrings("A", binding_a.getName());
    try testing.expectEqualStrings("Z", binding_z.getName());
}

test "InputBinding keyToString handles number keys" {
    const binding_0 = input_mapper.InputBinding{ .key = .@"0" };
    const binding_9 = input_mapper.InputBinding{ .key = .@"9" };
    try testing.expectEqualStrings("0", binding_0.getName());
    try testing.expectEqualStrings("9", binding_9.getName());
}

test "InputBinding keyToString handles arrow keys" {
    const left = input_mapper.InputBinding{ .key = .left_arrow };
    const right = input_mapper.InputBinding{ .key = .right_arrow };
    const up = input_mapper.InputBinding{ .key = .up };
    const down = input_mapper.InputBinding{ .key = .down };
    try testing.expectEqualStrings("Left", left.getName());
    try testing.expectEqualStrings("Right", right.getName());
    try testing.expectEqualStrings("Up", up.getName());
    try testing.expectEqualStrings("Down", down.getName());
}

test "InputBinding keyToString handles modifier keys" {
    const lshift = input_mapper.InputBinding{ .key = .left_shift };
    const rshift = input_mapper.InputBinding{ .key = .right_shift };
    const lctrl = input_mapper.InputBinding{ .key = .left_ctrl };
    const rctrl = input_mapper.InputBinding{ .key = .right_ctrl };
    try testing.expectEqualStrings("Left Shift", lshift.getName());
    try testing.expectEqualStrings("Right Shift", rshift.getName());
    try testing.expectEqualStrings("Left Ctrl", lctrl.getName());
    try testing.expectEqualStrings("Right Ctrl", rctrl.getName());
}

test "InputBinding keyToString handles special keys" {
    const enter = input_mapper.InputBinding{ .key = .enter };
    const tab = input_mapper.InputBinding{ .key = .tab };
    const backspace = input_mapper.InputBinding{ .key = .backspace };
    const plus = input_mapper.InputBinding{ .key = .plus };
    const minus = input_mapper.InputBinding{ .key = .minus };
    try testing.expectEqualStrings("Enter", enter.getName());
    try testing.expectEqualStrings("Tab", tab.getName());
    try testing.expectEqualStrings("Backspace", backspace.getName());
    try testing.expectEqualStrings("+", plus.getName());
    try testing.expectEqualStrings("-", minus.getName());
}
