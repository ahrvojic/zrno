const std = @import("std");

/// One-empty-slot wrapping byte ring. `head == tail` is empty.
pub fn Ring(comptime capacity: usize) type {
    const Index = std.math.IntFittingRange(0, capacity - 1);
    comptime {
        std.debug.assert(@as(usize, std.math.maxInt(Index)) + 1 == capacity);
    }

    return struct {
        const Self = @This();

        buf: [capacity]u8 = undefined,
        head: Index = 0,
        tail: Index = 0,

        pub fn empty(self: *const Self) bool {
            return self.head == self.tail;
        }

        /// Bytes that can still be `put` (capacity minus one, minus used).
        pub fn room(self: *const Self) usize {
            return capacity - 1 - @as(usize, self.tail -% self.head);
        }

        pub fn copyOut(self: *const Self, out: []u8) usize {
            return self.copyOutUntil(out, null);
        }

        /// Copy until `out` is full, the ring is empty, or `stop` is copied.
        pub fn copyOutUntil(self: *const Self, out: []u8, stop: ?u8) usize {
            if (stop) |s| {
                var idx = self.head;
                for (out, 0..) |*slot, n| {
                    if (idx == self.tail) return n;
                    slot.* = self.buf[idx];
                    idx +%= 1;
                    if (slot.* == s) return n + 1;
                }
                return out.len;
            }
            const have: usize = self.tail -% self.head;
            const n = @min(out.len, have);
            if (n == 0) return 0;
            const head: usize = self.head;
            const first = @min(n, capacity - head);
            @memcpy(out[0..first], self.buf[head..][0..first]);
            if (n > first) @memcpy(out[first..n], self.buf[0 .. n - first]);
            return n;
        }

        pub fn drop(self: *Self, n: usize) void {
            const have: usize = self.tail -% self.head;
            self.head +%= @intCast(@min(n, have));
        }

        pub fn put(self: *Self, src: []const u8) usize {
            const n = @min(src.len, self.room());
            if (n == 0) return 0;
            const tail: usize = self.tail;
            const first = @min(n, capacity - tail);
            @memcpy(self.buf[tail..][0..first], src[0..first]);
            if (n > first) @memcpy(self.buf[0 .. n - first], src[first..n]);
            self.tail +%= @intCast(n);
            return n;
        }

        pub fn putByte(self: *Self, ch: u8) void {
            _ = self.put(&.{ch});
        }
    };
}

test "ring fill empty wrap" {
    const R = Ring(8);
    var r: R = .{};

    try std.testing.expectEqual(5, r.put("hello"));
    var out: [8]u8 = undefined;
    try std.testing.expectEqual(5, r.copyOut(&out));
    try std.testing.expectEqualStrings("hello", out[0..5]);
    r.drop(5);
    try std.testing.expectEqual(0, r.copyOut(&out));

    var one: [1]u8 = .{0xaa};
    var filled: usize = 0;
    while (r.put(&one) == 1) filled += 1;
    try std.testing.expectEqual(7, filled);
    try std.testing.expectEqual(0, r.put(&one));
    r.drop(filled);

    // Spans the end: 6,7 then 0,1,2.
    r.head = 6;
    r.tail = 6;
    try std.testing.expectEqual(5, r.put("abcde"));
    try std.testing.expectEqual(5, r.copyOut(&out));
    try std.testing.expectEqualStrings("abcde", out[0..5]);
    r.drop(3);
    try std.testing.expectEqual(2, r.copyOut(&out));
    try std.testing.expectEqualStrings("de", out[0..2]);
    r.drop(2);
    try std.testing.expect(r.empty());
}
