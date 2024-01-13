const debug = @import("../sys/debug.zig");
const fb = @import("fb.zig");

const maxRow: u8 = 25;
const maxCol: u8 = 80;

var row: u8 = 0;
var col: u8 = 0;

pub fn print(string: []const u8) void {
    for (string) |ch| {
        putChar(ch);
    }
}

pub fn println(string: []const u8) callconv(.Inline) void {
    print(string);
    putChar('\n');
}

pub fn putChar(ch: u8) void {
    switch (ch) {
        '\n' => {
            row += 1;
            col = 0;
            // TODO: scroll
        },
        else => {
            fb.get().plotChar(ch, row, col);
            col += 1;
            if (col == maxCol) {
                col = 0;
                row += 1;
                // TODO: scroll
            }
        },
    }
}
