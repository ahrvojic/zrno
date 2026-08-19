const std = @import("std");

const video = @import("video.zig");

var row: u64 = 0;
var col: u64 = 0;

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var print_buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&print_buffer);

    writer.print(fmt, args) catch {};

    for (writer.buffered()) |ch| {
        putChar(ch);
    }
}

pub fn putChar(ch: u8) void {
    if (!video.isReady()) return;

    switch (ch) {
        '\n' => {
            row += 1;
            col = 0;
        },
        else => {
            video.fb.plotChar(ch, row, col);
            col += 1;
            if (col == video.fb.maxCol) {
                col = 0;
                row += 1;
            }
        },
    }

    if (row == video.fb.maxRow) {
        video.fb.scroll();
        row -= 1;
    }
}
