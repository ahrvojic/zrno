const std = @import("std");

pub fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]T = undefined,
        len: usize = 0,

        pub fn append(self: *Self, item: T) error{Overflow}!void {
            if (self.len >= capacity) return error.Overflow;
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn swapRemove(self: *Self, index: usize) T {
            std.debug.assert(index < self.len);
            const item = self.buffer[index];
            self.len -= 1;
            if (index != self.len) self.buffer[index] = self.buffer[self.len];
            return item;
        }

        pub fn slice(self: *Self) []T {
            return self.buffer[0..self.len];
        }

        pub fn constSlice(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }
    };
}

test "append and slice" {
    var a = BoundedArray(u8, 4){};
    try a.append(1);
    try a.append(2);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, a.constSlice());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, a.slice());
}

test "swapRemove last and middle" {
    var a = BoundedArray(u8, 4){};
    try a.append(1);
    try a.append(2);
    try a.append(3);
    try std.testing.expectEqual(3, a.swapRemove(2));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, a.constSlice());
    try std.testing.expectEqual(1, a.swapRemove(0));
    try std.testing.expectEqualSlices(u8, &.{2}, a.constSlice());
}

test "append at capacity is Overflow" {
    var a = BoundedArray(u8, 2){};
    try a.append(1);
    try a.append(2);
    try std.testing.expectError(error.Overflow, a.append(3));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, a.constSlice());
}

