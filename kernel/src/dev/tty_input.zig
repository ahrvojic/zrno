const std = @import("std");

// Wrapping indices fill the ring iff maxInt(InIndex)+1 == in_capacity.
const in_capacity = 256;
const InIndex = std.math.IntFittingRange(0, in_capacity - 1);
comptime {
    std.debug.assert(@as(usize, std.math.maxInt(InIndex)) + 1 == in_capacity);
}

const line_capacity = 128;

fn isInputChar(ch: u8) bool {
    return ch == '\n' or ch == '\x08' or (ch >= 0x20 and ch <= 0x7e);
}

// Cooked TTY input: edit a line, commit on '\n' into the readable ring.
pub const Input = struct {
    line_buf: [line_capacity]u8 = undefined,
    line_len: usize = 0,
    in_buf: [in_capacity]u8 = undefined,
    in_head: InIndex = 0,
    in_tail: InIndex = 0,

    pub fn empty(self: *const Input) bool {
        return self.in_head == self.in_tail;
    }

    pub fn feed(self: *Input, ch: u8) ?u8 {
        if (!isInputChar(ch)) return null;
        switch (ch) {
            '\x08' => {
                if (self.line_len == 0) return null;
                self.line_len -= 1;
                return '\x08';
            },
            '\n' => {
                self.commit();
                return '\n';
            },
            else => {
                if (self.line_len == line_capacity) return null;
                self.line_buf[self.line_len] = ch;
                self.line_len += 1;
                return ch;
            },
        }
    }

    pub fn copyOut(self: *const Input, out: []u8) usize {
        var idx = self.in_head;
        for (out, 0..) |*slot, n| {
            if (idx == self.in_tail) return n;
            slot.* = self.in_buf[idx];
            idx +%= 1;
            if (slot.* == '\n') return n + 1;
        }
        return out.len;
    }

    pub fn drop(self: *Input, n: usize) void {
        for (0..n) |_| {
            if (self.in_head == self.in_tail) return;
            self.in_head +%= 1;
        }
    }

    fn commit(self: *Input) void {
        if (self.line_len + 1 > self.ringFree()) {
            self.line_len = 0;
            return;
        }
        for (self.line_buf[0..self.line_len]) |c| self.put(c);
        self.put('\n');
        self.line_len = 0;
    }

    fn put(self: *Input, ch: u8) void {
        const next = self.in_tail +% 1;
        if (next == self.in_head) return;
        self.in_buf[self.in_tail] = ch;
        self.in_tail = next;
    }

    fn ringFree(self: *const Input) usize {
        return in_capacity - 1 - @as(usize, self.in_tail -% self.in_head);
    }
};

test "no read until newline" {
    var in: Input = .{};
    try std.testing.expectEqual(@as(?u8, 'h'), in.feed('h'));
    try std.testing.expectEqual(@as(?u8, 'i'), in.feed('i'));
    var out: [8]u8 = undefined;
    try std.testing.expectEqual(0, in.copyOut(&out));
    try std.testing.expectEqual(@as(?u8, '\n'), in.feed('\n'));
    try std.testing.expectEqual(3, in.copyOut(&out));
    try std.testing.expectEqualStrings("hi\n", out[0..3]);
}

test "backspace edits the line not the ring" {
    var in: Input = .{};
    try std.testing.expectEqual(null, in.feed('\x08'));
    _ = in.feed('h');
    _ = in.feed('i');
    try std.testing.expectEqual(@as(?u8, '\x08'), in.feed('\x08'));
    _ = in.feed('e');
    _ = in.feed('y');
    _ = in.feed('\n');
    var out: [8]u8 = undefined;
    try std.testing.expectEqual(4, in.copyOut(&out));
    try std.testing.expectEqualStrings("hey\n", out[0..4]);
}

test "copyOut can split a long line" {
    var in: Input = .{};
    for ("hello") |c| _ = in.feed(c);
    _ = in.feed('\n');
    var out: [3]u8 = undefined;
    try std.testing.expectEqual(3, in.copyOut(&out));
    try std.testing.expectEqualStrings("hel", &out);
    in.drop(3);
    try std.testing.expectEqual(3, in.copyOut(&out));
    try std.testing.expectEqualStrings("lo\n", &out);
}

test "copyOut stops at newline" {
    var in: Input = .{};
    _ = in.feed('a');
    _ = in.feed('\n');
    _ = in.feed('b');
    _ = in.feed('\n');
    var out: [8]u8 = undefined;
    try std.testing.expectEqual(2, in.copyOut(&out));
    try std.testing.expectEqualStrings("a\n", out[0..2]);
    in.drop(2);
    try std.testing.expectEqual(2, in.copyOut(&out));
    try std.testing.expectEqualStrings("b\n", out[0..2]);
}

test "full line is dropped when the ring has no space" {
    var in: Input = .{};
    var one: [1]u8 = .{'x'};
    const filled = in_capacity - 1;
    for (0..filled) |_| _ = in.feed('\n');
    _ = in.feed('z');
    _ = in.feed('\n');
    in.drop(filled);
    try std.testing.expectEqual(0, in.copyOut(&one));
}

test "line overflow drops extra printables" {
    var in: Input = .{};
    for (0..line_capacity) |_| {
        try std.testing.expectEqual(@as(?u8, 'a'), in.feed('a'));
    }
    try std.testing.expectEqual(null, in.feed('b'));
    _ = in.feed('\n');
    var out: [line_capacity + 1]u8 = undefined;
    try std.testing.expectEqual(line_capacity + 1, in.copyOut(&out));
    try std.testing.expectEqual('\n', out[line_capacity]);
}

test "ring wrap still commits a line" {
    var in: Input = .{};
    in.in_head = @intCast(in_capacity - 2);
    in.in_tail = @intCast(in_capacity - 2);
    _ = in.feed('a');
    _ = in.feed('b');
    _ = in.feed('\n');
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(3, in.copyOut(&out));
    try std.testing.expectEqualStrings("ab\n", out[0..3]);
}
