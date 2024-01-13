const debug = @import("../sys/debug.zig");
const fb = @import("fb.zig");

var row: u8 = 0;
var col: u8 = 0;

pub fn print(string: []const u8) void {
    for (string) |ch| {
        putChar(ch);
    }
}

fn putChar(ch: u8) void {
    switch (ch) {
        '\n' => {
            row += 1;
            col = 0;
            // TODO: scroll
        },
        else => {
            fb.get().plotChar(ch, row, col);
            col += 1;
            // TODO: wrap/scroll
        },
    }
}
