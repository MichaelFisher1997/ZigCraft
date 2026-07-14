//! Hotbar widget for displaying and selecting inventory items.
//!
//! Renders the bottom hotbar UI with 9 slots, showing selected blocks
//! and highlighting the currently selected slot.

const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const Color = @import("engine-ui").Color;
const Font = @import("engine-ui").font;
const Inventory = @import("../inventory.zig").Inventory;
const block_registry = @import("world-core").block_registry;

/// Hotbar rendering configuration
pub const HotbarConfig = struct {
    /// Size of each slot in pixels
    slot_size: f32 = 44,
    /// Padding between slots
    slot_padding: f32 = 4,
    /// Margin from bottom of screen
    bottom_margin: f32 = 10,
    /// Border thickness
    border_thickness: f32 = 2,
    /// Inner margin for block icon
    icon_margin: f32 = 6,
    /// Minimum horizontal margin from either screen edge.
    horizontal_margin: f32 = 10,
};

const HotbarLayout = struct {
    config: HotbarConfig,
    start_x: f32,
    y: f32,
    total_width: f32,
};

fn calculateLayout(screen_width: f32, screen_height: f32, config: HotbarConfig) HotbarLayout {
    const slot_count = @as(f32, @floatFromInt(Inventory.HOTBAR_SIZE));
    const gap_count = @as(f32, @floatFromInt(Inventory.HOTBAR_SIZE - 1));
    const requested_width = slot_count * config.slot_size + gap_count * config.slot_padding;
    const available_width = @max(0.0, screen_width - 2.0 * config.horizontal_margin);
    const scale = if (requested_width > available_width and requested_width > 0.0)
        available_width / requested_width
    else
        1.0;
    const fitted_config = HotbarConfig{
        .slot_size = config.slot_size * scale,
        .slot_padding = config.slot_padding * scale,
        .bottom_margin = config.bottom_margin * scale,
        .border_thickness = config.border_thickness * scale,
        .icon_margin = config.icon_margin * scale,
        .horizontal_margin = config.horizontal_margin,
    };
    const total_width = slot_count * fitted_config.slot_size + gap_count * fitted_config.slot_padding;

    return .{
        .config = fitted_config,
        .start_x = (screen_width - total_width) / 2.0,
        .y = screen_height - fitted_config.slot_size - fitted_config.bottom_margin,
        .total_width = total_width,
    };
}

fn rgba8(r: u8, g: u8, b: u8, a: u8) Color {
    const scale = 1.0 / 255.0;
    return Color.rgba(
        @as(f32, @floatFromInt(r)) * scale,
        @as(f32, @floatFromInt(g)) * scale,
        @as(f32, @floatFromInt(b)) * scale,
        @as(f32, @floatFromInt(a)) * scale,
    );
}

/// Draw the hotbar at the bottom center of the screen.
pub fn draw(
    ui: *UISystem,
    inventory: *const Inventory,
    screen_width: f32,
    screen_height: f32,
    config: HotbarConfig,
) void {
    const layout = calculateLayout(screen_width, screen_height, config);

    // Draw each slot
    for (0..Inventory.HOTBAR_SIZE) |i| {
        const slot_index: u8 = @intCast(i);
        const x = layout.start_x + @as(f32, @floatFromInt(i)) * (layout.config.slot_size + layout.config.slot_padding);
        const is_selected = slot_index == inventory.selected_slot;

        drawSlot(ui, x, layout.y, layout.config.slot_size, is_selected, inventory.slots[i], layout.config);

        // Draw slot number
        var num_buf: [2]u8 = undefined;
        const num_text = std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch "?";
        Font.drawText(ui, num_text, x + 2, layout.y + 2, 1.5, rgba8(200, 200, 200, 180));
    }
}

/// Draw a single inventory slot.
fn drawSlot(
    ui: *UISystem,
    x: f32,
    y: f32,
    size: f32,
    selected: bool,
    item: ?Inventory.ItemStack,
    config: HotbarConfig,
) void {
    // Background color
    const bg_color = if (selected)
        rgba8(180, 180, 180, 220)
    else
        rgba8(40, 40, 40, 200);

    // Draw slot background
    ui.drawRect(.{ .x = x, .y = y, .width = size, .height = size }, bg_color);

    // Draw border
    const border_color = if (selected)
        rgba8(255, 255, 255, 255)
    else
        rgba8(80, 80, 80, 255);

    ui.drawRectOutline(
        .{ .x = x, .y = y, .width = size, .height = size },
        border_color,
        config.border_thickness,
    );

    // Draw block icon if slot has an item
    if (item) |stack| {
        const rgb = block_registry.getBlockDefinition(stack.block_type).default_color;
        const icon_color = Color.rgba(rgb[0], rgb[1], rgb[2], 1.0);

        const icon_size = size - config.icon_margin * 2;
        ui.drawRect(
            .{
                .x = x + config.icon_margin,
                .y = y + config.icon_margin,
                .width = icon_size,
                .height = icon_size,
            },
            icon_color,
        );

        // Draw stack count if > 1
        if (stack.count > 1) {
            var count_buf: [4]u8 = undefined;
            const count_text = std.fmt.bufPrint(&count_buf, "{d}", .{stack.count}) catch "?";
            Font.drawText(
                ui,
                count_text,
                x + size - 14,
                y + size - 12,
                1.5,
                Color.white,
            );
        }
    }
}

/// Draw the hotbar with default configuration.
pub fn drawDefault(
    ui: *UISystem,
    inventory: *const Inventory,
    screen_width: f32,
    screen_height: f32,
) void {
    draw(ui, inventory, screen_width, screen_height, .{});
}

test "hotbar layout keeps the default size when it fits" {
    const testing = std.testing;
    const layout = calculateLayout(1_000, 600, .{});

    try testing.expectEqual(@as(f32, 428.0), layout.total_width);
    try testing.expectEqual(@as(f32, 286.0), layout.start_x);
    try testing.expectEqual(@as(f32, 44.0), layout.config.slot_size);
}

test "hotbar layout fits narrow screens within its margins" {
    const testing = std.testing;
    const layout = calculateLayout(320, 240, .{});

    try testing.expectApproxEqAbs(@as(f32, 300.0), layout.total_width, 0.000_001);
    try testing.expectApproxEqAbs(@as(f32, 10.0), layout.start_x, 0.000_001);
    try testing.expect(layout.start_x + layout.total_width <= 310.0);
    try testing.expect(layout.config.slot_size < (HotbarConfig{}).slot_size);
}

test "rgba8 normalizes hotbar colors" {
    const testing = std.testing;
    const color = rgba8(40, 80, 255, 200);

    try testing.expectApproxEqAbs(@as(f32, 40.0 / 255.0), color.r, 0.000_001);
    try testing.expectApproxEqAbs(@as(f32, 80.0 / 255.0), color.g, 0.000_001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), color.b, 0.000_001);
    try testing.expectApproxEqAbs(@as(f32, 200.0 / 255.0), color.a, 0.000_001);
}
