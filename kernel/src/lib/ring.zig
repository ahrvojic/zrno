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
            var idx = self.head;
            for (out, 0..) |*slot, n| {
                if (idx == self.tail) return n;
                slot.* = self.buf[idx];
                idx +%= 1;
                if (stop) |s| {
                    if (slot.* == s) return n + 1;
                }
            }
            return out.len;
        }

        pub fn drop(self: *Self, n: usize) void {
            for (0..n) |_| {
                if (self.head == self.tail) return;
                self.head +%= 1;
            }
        }

        pub fn put(self: *Self, src: []const u8) usize {
            var n: usize = 0;
            while (n < src.len) {
                const next = self.tail +% 1;
                if (next == self.head) break;
                self.buf[self.tail] = src[n];
                self.tail = next;
                n += 1;
            }
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

    r.head = 6;
    r.tail = 6;
    try std.testing.expectEqual(2, r.put("ab"));
    try std.testing.expectEqual(2, r.copyOut(&out));
    try std.testing.expectEqualStrings("ab", out[0..2]);
}
