const fb = @import("fb.zig");

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
