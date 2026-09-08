const std = @import("std");

pub const Font = struct {
    width: u8,
    height: u8,
    bytes: []const u8,

    pub fn glyph(self: *const Font, i: usize) []const u8 {
        const row = i * self.height;
        const len = row + self.height;
        return self.bytes[row..len];
    }
};

// https://github.com/viler-int10h/vga-text-mode-fonts/blob/master/FONTS/SYSTEM/OS2/437_US.F16
pub const builtin: Font = .{
    .width = 8,
    .height = 16,
    .bytes = @embedFile("437_US.F16"),
};

test "font size" {
    try std.testing.expectEqual(@as(usize, 256) * builtin.height, builtin.bytes.len);
}

test "glyph retrieval" {
    try std.testing.expectEqualSlices(u8, builtin.bytes[0..16], builtin.glyph(0));
    try std.testing.expectEqualSlices(u8, builtin.bytes[16..32], builtin.glyph(1));
    try std.testing.expectEqualSlices(u8, builtin.bytes[32..48], builtin.glyph(2));
}
