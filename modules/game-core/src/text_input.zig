const std = @import("std");
const Key = @import("engine-core").interfaces.Key;
const IRawInputProvider = @import("engine-input").IRawInputProvider;

pub fn handleTextTyping(text_input: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, input: IRawInputProvider, max_len: usize) !void {
    if (input.isKeyPressed(.backspace)) {
        if (text_input.items.len > 0) _ = text_input.pop();
    }
    const shift = input.isKeyDown(.left_shift) or input.isKeyDown(.right_shift);
    const letters = [_]Key{ .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z };
    inline for (letters) |key| if (input.isKeyPressed(key) and text_input.items.len < max_len) {
        var ch: u8 = @intCast(@intFromEnum(key));
        if (shift) ch = std.ascii.toUpper(ch);
        try text_input.append(allocator, ch);
    };
    const digits = [_]Key{ .@"0", .@"1", .@"2", .@"3", .@"4", .@"5", .@"6", .@"7", .@"8", .@"9" };
    inline for (digits) |key| if (input.isKeyPressed(key) and text_input.items.len < max_len) try text_input.append(allocator, @intCast(@intFromEnum(key)));
    if (input.isKeyPressed(.space) and text_input.items.len < max_len) try text_input.append(allocator, ' ');
}
