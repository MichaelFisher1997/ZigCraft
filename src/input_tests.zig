//! Tests for Input key state consistency, including allocation-failure paths.
//!
//! Covers the fix for the issue where `keys_down` and `keys_pressed` could
//! disagree when `put()` failed mid-operation, leaving a key reported as held
//! but not pressed (or vice versa). The release path had the same problem
//! between `keys_down` and `keys_released`.

const std = @import("std");
const testing = std.testing;
const Input = @import("engine-input").Input;

test "recordKeyDown registers key as both pressed and down" {
    var input = Input.init(testing.allocator);
    defer input.deinit();

    input.recordKeyDown(.w);

    try testing.expect(input.isKeyDown(.w));
    try testing.expect(input.isKeyPressed(.w));
}

test "recordKeyDown stays consistent when keys_pressed put fails" {
    // fail_index = 0 -> the very first allocation (keys_pressed.put) fails.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var input = Input.init(failing.allocator());
    defer input.deinit();

    input.recordKeyDown(.w);

    // Press could not be recorded: neither held nor pressed, and no stuck key.
    try testing.expect(!input.isKeyDown(.w));
    try testing.expect(!input.isKeyPressed(.w));
}

test "recordKeyDown rolls back keys_pressed when keys_down put fails" {
    // fail_index = 1 -> keys_pressed.put succeeds (alloc 0), keys_down.put fails (alloc 1).
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var input = Input.init(failing.allocator());
    defer input.deinit();

    input.recordKeyDown(.w);

    try testing.expect(!input.isKeyDown(.w));
    try testing.expect(!input.isKeyPressed(.w));
}

test "recordKeyUp keeps key held when keys_released put fails" {
    // fail_index = 2 -> key down allocates keys_pressed (0) and keys_down (1);
    // the key-up keys_released.put (alloc 2) then fails.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    var input = Input.init(failing.allocator());
    defer input.deinit();

    input.recordKeyDown(.w);
    input.beginFrame();
    input.recordKeyUp(.w);

    // Release could not be recorded: key remains held and is not marked released.
    try testing.expect(input.isKeyDown(.w));
    try testing.expect(!input.isKeyReleased(.w));
}

test "recordKeyUp clears down and marks released on success" {
    var input = Input.init(testing.allocator);
    defer input.deinit();

    input.recordKeyDown(.w);
    input.beginFrame();
    input.recordKeyUp(.w);

    try testing.expect(!input.isKeyDown(.w));
    try testing.expect(input.isKeyReleased(.w));
}
