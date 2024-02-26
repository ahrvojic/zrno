const std = @import("std");

const fb = @import("fb.zig");

var row: u8 = 0;
var col: u8 = 0;

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var print_buffer: [1024]u8 = undefined;
    var buffer = std.io.fixedBufferStream(&print_buffer);
    var writer = buffer.writer();

    writer.print(fmt, args) catch unreachable;

    for (buffer.getWritten()) |ch| {
        putChar(ch);
    }
}

pub fn putChar(ch: u8) void {
    const fbuf = fb.get();

    switch (ch) {
        '\n' => {
            row += 1;
            col = 0;
        },
        else => {
            fbuf.plotChar(ch, row, col);
            col += 1;
            if (col == fbuf.maxCol) {
                col = 0;
                row += 1;
            }
        },
    }

    if (row == fbuf.maxRow) {
        fbuf.scroll();
        row -= 1;
    }
}
