const std = @import("std");
const testing = std.testing;
const Inventory = @import("game-core").Inventory;
const BlockType = @import("world-core").BlockType;

test "Inventory.initEmpty creates empty inventory" {
    const inv = Inventory.initEmpty();

    try testing.expectEqual(@as(u8, 0), inv.selected_slot);

    // All slots should be null
    for (inv.slots) |slot| {
        try testing.expect(slot == null);
    }
}

test "Inventory.getSelectedBlock returns null when slot is empty" {
    const inv = Inventory.initEmpty();
    const block = inv.getSelectedBlock();
    try testing.expect(block == null);
}

test "Inventory.getSelectedBlock returns block type when slot has item" {
    var inv = Inventory.initEmpty();
    inv.slots[0] = .{ .block_type = .stone, .count = 32 };

    const block = inv.getSelectedBlock();
    try testing.expect(block != null);
    try testing.expectEqual(BlockType.stone, block.?);
}

test "Inventory.getSelectedStack returns null when slot is empty" {
    const inv = Inventory.initEmpty();
    const stack = inv.getSelectedStack();
    try testing.expect(stack == null);
}

test "Inventory.getSelectedStack returns stack when slot has item" {
    var inv = Inventory.initEmpty();
    inv.slots[0] = .{ .block_type = .dirt, .count = 16 };

    const stack = inv.getSelectedStack();
    try testing.expect(stack != null);
    try testing.expectEqual(BlockType.dirt, stack.?.block_type);
    try testing.expectEqual(@as(u8, 16), stack.?.count);
}

test "Inventory.getSlot returns null for empty slot" {
    const inv = Inventory.initEmpty();
    const slot = inv.getSlot(5);
    try testing.expect(slot == null);
}

test "Inventory.getSlot returns stack for occupied slot" {
    var inv = Inventory.initEmpty();
    inv.slots[5] = .{ .block_type = .grass, .count = 64 };

    const slot = inv.getSlot(5);
    try testing.expect(slot != null);
    try testing.expectEqual(BlockType.grass, slot.?.block_type);
    try testing.expectEqual(@as(u8, 64), slot.?.count);
}

test "Inventory.getSlot returns null for out of bounds" {
    const inv = Inventory.initEmpty();
    try testing.expect(inv.getSlot(Inventory.TOTAL_SLOTS) == null);
    try testing.expect(inv.getSlot(255) == null);
}

test "Inventory.setSlot sets item in slot" {
    var inv = Inventory.initEmpty();

    inv.setSlot(10, .{ .block_type = .cobblestone, .count = 32 });

    const slot = inv.getSlot(10);
    try testing.expect(slot != null);
    try testing.expectEqual(BlockType.cobblestone, slot.?.block_type);
    try testing.expectEqual(@as(u8, 32), slot.?.count);
}

test "Inventory.setSlot clears slot when null" {
    var inv = Inventory.initEmpty();
    inv.slots[5] = .{ .block_type = .stone, .count = 10 };

    inv.setSlot(5, null);

    try testing.expect(inv.getSlot(5) == null);
}

test "Inventory.setSlot ignores out of bounds" {
    var inv = Inventory.initEmpty();
    inv.setSlot(Inventory.TOTAL_SLOTS, .{ .block_type = .stone, .count = 1 });
    // Should not crash and should not modify any slot
    for (inv.slots) |slot| {
        try testing.expect(slot == null);
    }
}

test "Inventory.removeFromSelected removes partial stack" {
    var inv = Inventory.initEmpty();
    inv.slots[0] = .{ .block_type = .stone, .count = 10 };

    const removed = inv.removeFromSelected(3);

    try testing.expectEqual(@as(u8, 3), removed);
    try testing.expectEqual(@as(u8, 7), inv.slots[0].?.count);
}

test "Inventory.removeFromSelected removes entire stack" {
    var inv = Inventory.initEmpty();
    inv.slots[0] = .{ .block_type = .stone, .count = 5 };

    const removed = inv.removeFromSelected(10);

    try testing.expectEqual(@as(u8, 5), removed);
    try testing.expect(inv.slots[0] == null);
}

test "Inventory.removeFromSelected returns 0 when slot is empty" {
    var inv = Inventory.initEmpty();

    const removed = inv.removeFromSelected(5);

    try testing.expectEqual(@as(u8, 0), removed);
}

test "Inventory.swapSlots swaps two slots" {
    var inv = Inventory.initEmpty();
    inv.slots[0] = .{ .block_type = .stone, .count = 10 };
    inv.slots[1] = .{ .block_type = .dirt, .count = 20 };

    inv.swapSlots(0, 1);

    try testing.expectEqual(BlockType.dirt, inv.slots[0].?.block_type);
    try testing.expectEqual(@as(u8, 20), inv.slots[0].?.count);
    try testing.expectEqual(BlockType.stone, inv.slots[1].?.block_type);
    try testing.expectEqual(@as(u8, 10), inv.slots[1].?.count);
}

test "Inventory.swapSlots with empty slot" {
    var inv = Inventory.initEmpty();
    inv.slots[0] = .{ .block_type = .stone, .count = 10 };

    inv.swapSlots(0, 1);

    try testing.expect(inv.slots[0] == null);
    try testing.expectEqual(BlockType.stone, inv.slots[1].?.block_type);
}

test "Inventory.swapSlots ignores out of bounds" {
    var inv = Inventory.initEmpty();
    inv.slots[0] = .{ .block_type = .stone, .count = 10 };

    inv.swapSlots(0, Inventory.TOTAL_SLOTS);

    // Should not have changed
    try testing.expectEqual(BlockType.stone, inv.slots[0].?.block_type);
}

test "Inventory.hasItem returns true when item exists" {
    var inv = Inventory.initEmpty();
    inv.slots[5] = .{ .block_type = .gold_ore, .count = 1 };

    try testing.expect(inv.hasItem(.gold_ore));
}

test "Inventory.hasItem returns false when item does not exist" {
    var inv = Inventory.initEmpty();
    inv.slots[0] = .{ .block_type = .stone, .count = 10 };

    try testing.expect(!inv.hasItem(.gold_ore));
}

test "Inventory.hasItem returns false for empty inventory" {
    const inv = Inventory.initEmpty();
    try testing.expect(!inv.hasItem(.stone));
}

test "Inventory.countItem sums all stacks" {
    var inv = Inventory.initEmpty();
    inv.slots[0] = .{ .block_type = .stone, .count = 10 };
    inv.slots[5] = .{ .block_type = .stone, .count = 20 };
    inv.slots[10] = .{ .block_type = .dirt, .count = 5 };

    const stone_count = inv.countItem(.stone);
    const dirt_count = inv.countItem(.dirt);

    try testing.expectEqual(@as(u32, 30), stone_count);
    try testing.expectEqual(@as(u32, 5), dirt_count);
}

test "Inventory.countItem returns 0 for missing item" {
    const inv = Inventory.initEmpty();
    try testing.expectEqual(@as(u32, 0), inv.countItem(.gold_ore));
}

test "Inventory.isFull returns false for empty inventory" {
    const inv = Inventory.initEmpty();
    try testing.expect(!inv.isFull());
}

test "Inventory.isFull returns false when slots available" {
    var inv = Inventory.initEmpty();
    // Fill all but one slot to max
    for (0..Inventory.TOTAL_SLOTS - 1) |i| {
        inv.slots[i] = .{ .block_type = .stone, .count = 64 };
    }
    inv.slots[Inventory.TOTAL_SLOTS - 1] = .{ .block_type = .stone, .count = 30 };

    try testing.expect(!inv.isFull());
}

test "Inventory.isFull returns true when all slots full" {
    var inv = Inventory.initEmpty();
    for (&inv.slots) |*slot| {
        slot.* = .{ .block_type = .stone, .count = 64 };
    }

    try testing.expect(inv.isFull());
}

test "Inventory.isFull returns false when slots have space" {
    var inv = Inventory.initEmpty();
    for (&inv.slots) |*slot| {
        slot.* = .{ .block_type = .stone, .count = 63 }; // One short of max
    }

    try testing.expect(!inv.isFull());
}

test "Inventory.clear removes all items" {
    var inv = Inventory.initEmpty();
    inv.slots[0] = .{ .block_type = .stone, .count = 10 };
    inv.slots[5] = .{ .block_type = .dirt, .count = 20 };

    inv.clear();

    for (inv.slots) |slot| {
        try testing.expect(slot == null);
    }
}

test "Inventory.addItem fills empty slot" {
    var inv = Inventory.initEmpty();

    const result = inv.addItem(.stone, 32);

    try testing.expect(result);
    try testing.expectEqual(@as(u8, 32), inv.slots[0].?.count);
    try testing.expectEqual(BlockType.stone, inv.slots[0].?.block_type);
}

test "Inventory.addItem stacks with existing" {
    var inv = Inventory.initEmpty();
    inv.slots[0] = .{ .block_type = .stone, .count = 32 };

    const result = inv.addItem(.stone, 16);

    try testing.expect(result);
    try testing.expectEqual(@as(u8, 48), inv.slots[0].?.count);
}

test "Inventory.addItem fills multiple slots when needed" {
    var inv = Inventory.initEmpty();
    inv.slots[0] = .{ .block_type = .stone, .count = 60 }; // 4 space left

    // Try to add 20 more
    const result = inv.addItem(.stone, 20);

    try testing.expect(result);
    try testing.expectEqual(@as(u8, 64), inv.slots[0].?.count); // Filled to max
    try testing.expectEqual(@as(u8, 16), inv.slots[1].?.count); // Remainder in next slot
}

test "Inventory.addItem exceeds max stack creates new stack" {
    var inv = Inventory.initEmpty();

    // Add more than max stack
    const result = inv.addItem(.stone, 80); // Max is 64

    try testing.expect(result);
    try testing.expectEqual(@as(u8, 64), inv.slots[0].?.count);
    try testing.expectEqual(@as(u8, 16), inv.slots[1].?.count);
}

test "Inventory.addItem returns false when inventory full" {
    var inv = Inventory.initEmpty();
    // Fill all slots with different items
    for (&inv.slots) |*slot| {
        slot.* = .{ .block_type = .dirt, .count = 64 };
    }

    const result = inv.addItem(.stone, 1);

    try testing.expect(!result);
}

test "Inventory.addItem partial fill when not enough space" {
    var inv = Inventory.initEmpty();
    // Fill almost all slots
    for (0..Inventory.TOTAL_SLOTS - 1) |i| {
        inv.slots[i] = .{ .block_type = .dirt, .count = 64 };
    }
    // Last slot has some space
    inv.slots[Inventory.TOTAL_SLOTS - 1] = .{ .block_type = .stone, .count = 60 };

    // Try to add 10, but only 4 fit
    const result = inv.addItem(.stone, 10);

    try testing.expect(!result); // Not all items were added
    try testing.expectEqual(@as(u8, 64), inv.slots[Inventory.TOTAL_SLOTS - 1].?.count);
}

test "Inventory constants are valid" {
    try testing.expectEqual(@as(u8, 9), Inventory.HOTBAR_SIZE);
    try testing.expectEqual(@as(u8, 27), Inventory.MAIN_SIZE);
    try testing.expectEqual(@as(u8, 36), Inventory.TOTAL_SLOTS);
}

test "Inventory.ItemStack.MAX_STACK is reasonable" {
    try testing.expectEqual(@as(u8, 64), Inventory.ItemStack.MAX_STACK);
}

test "Inventory.scrollSelection single step wraps correctly" {
    var inv = Inventory.initEmpty();

    inv.selectSlot(0);
    inv.scrollSelection(1);
    try testing.expectEqual(@as(u8, 8), inv.selected_slot);

    inv.scrollSelection(-1);
    try testing.expectEqual(@as(u8, 0), inv.selected_slot);
}

test "Inventory.init fills hotbar with correct count" {
    const inv = Inventory.init();

    for (0..9) |i| {
        try testing.expect(inv.slots[i] != null);
        try testing.expectEqual(@as(u8, 64), inv.slots[i].?.count);
    }

    for (9..36) |i| {
        if (inv.slots[i]) |stack| {
            try testing.expectEqual(@as(u8, 64), stack.count);
        }
    }
}
