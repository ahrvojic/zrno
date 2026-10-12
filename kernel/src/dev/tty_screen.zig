const std = @import("std");

pub const Cell = struct {
    ch: u8,
    row: usize,
    col: usize,
};

pub const Paint = struct {
    scroll: bool = false,
    cell: ?Cell = null,
};

// Framebuffer cursor. `pending` means (row, col) already holds the glyph
// that filled the row; the next glyph opens a row.
pub const Screen = struct {
    row: usize = 0,
    col: usize = 0,
    pending: bool = false,
    // Soft wraps above this row that still belong to the current line.
    // A newline or carriage return clears it, so backspace does not erase
    // a line that a later write already left.
    wraps: usize = 0,

    pub fn put(self: *Screen, ch: u8, rows: usize, cols: usize) Paint {
        std.debug.assert(rows > 0 and cols > 0);
        switch (ch) {
            '\n' => {
                self.pending = false;
                const scroll = self.advance(rows);
                self.wraps = 0;
                return .{ .scroll = scroll };
            },
            '\r' => {
                self.pending = false;
                self.col = 0;
                self.wraps = 0;
                return .{};
            },
            '\x08' => return self.backspace(cols),
            else => {
                var scroll = false;
                if (self.pending) {
                    self.pending = false;
                    scroll = self.advance(rows);
                    self.wraps += 1;
                }
                const cell = Cell{ .ch = ch, .row = self.row, .col = self.col };
                self.pending = self.col + 1 == cols;
                if (!self.pending) self.col += 1;
                return .{ .scroll = scroll, .cell = cell };
            },
        }
    }

    fn backspace(self: *Screen, cols: usize) Paint {
        if (self.pending) {
            const cell = Cell{ .ch = ' ', .row = self.row, .col = self.col };
            self.pending = false;
            return .{ .cell = cell };
        }
        if (self.col > 0) {
            self.col -= 1;
            return .{ .cell = Cell{ .ch = ' ', .row = self.row, .col = self.col } };
        }
        if (self.wraps == 0 or self.row == 0) return .{};
        self.wraps -= 1;
        self.row -= 1;
        self.col = cols - 1;
        return .{ .cell = Cell{ .ch = ' ', .row = self.row, .col = self.col } };
    }

    fn advance(self: *Screen, rows: usize) bool {
        self.row += 1;
        self.col = 0;
        if (self.row < rows) return false;
        self.row -= 1;
        return true;
    }
};

fn putAll(screen: *Screen, text: []const u8, rows: usize, cols: usize) Paint {
    var last: Paint = .{};
    for (text) |ch| last = screen.put(ch, rows, cols);
    return last;
}

test "backspace erases the previous glyph" {
    var screen: Screen = .{};
    _ = putAll(&screen, "ab", 4, 8);
    try std.testing.expectEqual(Paint{
        .cell = .{ .ch = ' ', .row = 0, .col = 1 },
    }, screen.put('\x08', 4, 8));
    try std.testing.expectEqual(1, screen.col);
    try std.testing.expectEqual(Paint{
        .cell = .{ .ch = ' ', .row = 0, .col = 0 },
    }, screen.put('\x08', 4, 8));
    try std.testing.expectEqual(Paint{}, screen.put('\x08', 4, 8));
    try std.testing.expectEqual(0, screen.col);
}

test "backspace stops at a newline" {
    var screen: Screen = .{};
    _ = putAll(&screen, "ab\n", 4, 8);
    try std.testing.expectEqual(Paint{}, screen.put('\x08', 4, 8));
    try std.testing.expectEqual(1, screen.row);
    try std.testing.expectEqual(0, screen.col);
}

test "backspace clears the cell that filled the row" {
    var screen: Screen = .{};
    _ = putAll(&screen, "abcd", 4, 4);
    try std.testing.expect(screen.pending);
    try std.testing.expectEqual(Paint{
        .cell = .{ .ch = ' ', .row = 0, .col = 3 },
    }, screen.put('\x08', 4, 4));
    try std.testing.expect(!screen.pending);
    try std.testing.expectEqual(3, screen.col);
    try std.testing.expectEqual(Paint{
        .cell = .{ .ch = 'e', .row = 0, .col = 3 },
    }, screen.put('e', 4, 4));
    try std.testing.expect(screen.pending);
}

test "backspace climbs a soft wrap" {
    var screen: Screen = .{};
    _ = putAll(&screen, "abcde", 4, 4);
    try std.testing.expectEqual(1, screen.wraps);
    try std.testing.expectEqual(Paint{
        .cell = .{ .ch = ' ', .row = 1, .col = 0 },
    }, screen.put('\x08', 4, 4));
    try std.testing.expectEqual(Paint{
        .cell = .{ .ch = ' ', .row = 0, .col = 3 },
    }, screen.put('\x08', 4, 4));
    try std.testing.expectEqual(0, screen.wraps);
    try std.testing.expect(!screen.pending);
    try std.testing.expectEqual(0, screen.row);
    try std.testing.expectEqual(3, screen.col);
}

test "backspace climbs a wrap that scrolled" {
    var screen: Screen = .{};
    const paint = putAll(&screen, "abcde", 2, 2);
    try std.testing.expect(paint.scroll);
    try std.testing.expectEqual(1, screen.row);
    // 'e' is the only glyph still on the bottom row.
    try std.testing.expectEqual(Paint{
        .cell = .{ .ch = ' ', .row = 1, .col = 0 },
    }, screen.put('\x08', 2, 2));
    // 'd' scrolled up to the last cell of the top row.
    try std.testing.expectEqual(Paint{
        .cell = .{ .ch = ' ', .row = 0, .col = 1 },
    }, screen.put('\x08', 2, 2));
    try std.testing.expectEqual(Paint{
        .cell = .{ .ch = ' ', .row = 0, .col = 0 },
    }, screen.put('\x08', 2, 2));
    try std.testing.expectEqual(Paint{}, screen.put('\x08', 2, 2));
    try std.testing.expectEqual(0, screen.row);
}

test "carriage return stops backspace at this row" {
    var screen: Screen = .{};
    _ = putAll(&screen, "abcde\r", 4, 4);
    try std.testing.expectEqual(0, screen.wraps);
    try std.testing.expectEqual(Paint{}, screen.put('\x08', 4, 4));
    try std.testing.expectEqual(1, screen.row);
    try std.testing.expectEqual(0, screen.col);
}
