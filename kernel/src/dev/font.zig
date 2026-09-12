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
    try std.testing.expectEqual(@as(usize, builtin.height) * 256, builtin.bytes.len);
}
