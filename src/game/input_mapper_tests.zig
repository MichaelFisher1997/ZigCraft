const std = @import("std");
const testing = std.testing;
const input_mapper_pkg = @import("game-core").input_mapper;
const InputBinding = input_mapper_pkg.InputBinding;
const ActionBinding = input_mapper_pkg.ActionBinding;
const InputMapper = input_mapper_pkg.InputMapper;
const GameAction = input_mapper_pkg.GameAction;
const Key = @import("../engine/core/interfaces.zig").Key;
const MouseButton = @import("../engine/core/interfaces.zig").MouseButton;

test "InputBinding.getName for key" {
    const binding = InputBinding{ .key = .w };
    try testing.expectEqualStrings("W", binding.getName());

    const binding2 = InputBinding{ .key = .space };
    try testing.expectEqualStrings("Space", binding2.getName());

    const binding3 = InputBinding{ .key = .f1 };
    try testing.expectEqualStrings("F1", binding3.getName());
}

test "InputBinding.getName for key_alt" {
    const binding = InputBinding{ .key_alt = .a };
    try testing.expectEqualStrings("A", binding.getName());
}

test "InputBinding.getName for mouse_button" {
    const binding = InputBinding{ .mouse_button = .left };
    try testing.expectEqualStrings("Left Click", binding.getName());

    const binding2 = InputBinding{ .mouse_button = .right };
    try testing.expectEqualStrings("Right Click", binding2.getName());

    const binding3 = InputBinding{ .mouse_button = .middle };
    try testing.expectEqualStrings("Middle Click", binding3.getName());
}

test "InputBinding.getName for none" {
    const binding = InputBinding{ .none = {} };
    try testing.expectEqualStrings("Unbound", binding.getName());
}

test "InputBinding.getName for numpad keys" {
    const binding = InputBinding{ .key = .kp_plus };
    try testing.expectEqualStrings("Numpad +", binding.getName());

    const binding2 = InputBinding{ .key = .kp_minus };
    try testing.expectEqualStrings("Numpad -", binding2.getName());
}

test "InputBinding.eql with .none values" {
    const a = InputBinding{ .none = {} };
    const b = InputBinding{ .none = {} };
    try testing.expect(a.eql(b));
    try testing.expect(b.eql(a));
}

test "InputBinding.eql key vs key_alt same key" {
    const a = InputBinding{ .key = .w };
    const b = InputBinding{ .key_alt = .w };
    try testing.expect(a.eql(b));
    try testing.expect(b.eql(a));
}

test "InputBinding.eql different key types" {
    const a = InputBinding{ .key = .w };
    const b = InputBinding{ .mouse_button = .left };
    try testing.expect(!a.eql(b));
}

test "InputBinding.eql none vs key" {
    const a = InputBinding{ .none = {} };
    const b = InputBinding{ .key = .w };
    try testing.expect(!a.eql(b));
}

test "ActionBinding.init sets primary and none alternate" {
    const binding = ActionBinding.init(.{ .key = .w });
    try testing.expect(binding.primary.eql(InputBinding{ .key = .w }));
    try testing.expect(binding.alternate.eql(InputBinding{ .none = {} }));
}

test "ActionBinding.initWithAlt sets both bindings" {
    const binding = ActionBinding.initWithAlt(.{ .key = .w }, .{ .key_alt = .space });
    try testing.expect(binding.primary.eql(InputBinding{ .key = .w }));
    try testing.expect(binding.alternate.eql(InputBinding{ .key_alt = .space }));
}

test "InputMapper.init sets all default bindings" {
    const mapper = InputMapper.init();
    try testing.expect(mapper.getBinding(.move_forward).primary.eql(InputBinding{ .key = .w }));
    try testing.expect(mapper.getBinding(.jump).primary.eql(InputBinding{ .key = .space }));
    try testing.expect(mapper.getBinding(.interact_primary).primary.eql(InputBinding{ .mouse_button = .left }));
}

test "InputMapper.resetToDefaults restores all bindings" {
    var mapper = InputMapper.init();

    mapper.setBinding(.move_forward, .{ .key = .up });
    mapper.setBinding(.jump, .{ .mouse_button = .right });
    try testing.expect(!mapper.getBinding(.move_forward).primary.eql(InputBinding{ .key = .w }));

    mapper.resetToDefaults();

    try testing.expect(mapper.getBinding(.move_forward).primary.eql(InputBinding{ .key = .w }));
    try testing.expect(mapper.getBinding(.jump).primary.eql(InputBinding{ .key = .space }));
}

test "InputMapper.setBinding updates primary binding" {
    var mapper = InputMapper.init();
    try testing.expect(mapper.getBinding(.move_forward).primary.eql(InputBinding{ .key = .w }));

    mapper.setBinding(.move_forward, .{ .key = .up });
    try testing.expect(mapper.getBinding(.move_forward).primary.eql(InputBinding{ .key = .up }));
}

test "InputMapper.setAlternateBinding updates alternate binding" {
    var mapper = InputMapper.init();
    try testing.expect(mapper.getBinding(.move_forward).alternate.eql(InputBinding{ .none = {} }));

    mapper.setAlternateBinding(.move_forward, .{ .key_alt = .kp_plus });
    try testing.expect(mapper.getBinding(.move_forward).alternate.eql(InputBinding{ .key_alt = .kp_plus }));
}

test "InputMapper.resetActionToDefault restores single action" {
    var mapper = InputMapper.init();

    mapper.setBinding(.move_forward, .{ .key = .up });
    try testing.expect(!mapper.getBinding(.move_forward).primary.eql(InputBinding{ .key = .w }));

    mapper.resetActionToDefault(.move_forward);
    try testing.expect(mapper.getBinding(.move_forward).primary.eql(InputBinding{ .key = .w }));

    try testing.expect(mapper.getBinding(.jump).primary.eql(InputBinding{ .key = .space }));
}

test "InputMapper interface.getBinding returns correct binding" {
    const mapper = InputMapper.init();
    const iface = mapper.interface();

    const binding = iface.getBinding(.jump);
    try testing.expect(binding.primary.eql(InputBinding{ .key = .space }));
}
