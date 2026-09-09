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

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.buffer[self.len];
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

        pub fn resize(self: *Self, new_len: usize) error{Overflow}!void {
            if (new_len > capacity) return error.Overflow;
            self.len = new_len;
        }
    };
}

test "append pop slice" {
    var a = BoundedArray(u8, 4){};
    try a.append(1);
    try a.append(2);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, a.constSlice());
    try std.testing.expectEqual(@as(u8, 2), a.pop().?);
    try std.testing.expectEqualSlices(u8, &.{1}, a.slice());
    try std.testing.expectEqual(@as(u8, 1), a.pop().?);
    try std.testing.expect(a.pop() == null);
}

test "swapRemove last and middle" {
    var a = BoundedArray(u8, 4){};
    try a.append(1);
    try a.append(2);
    try a.append(3);
    try std.testing.expectEqual(@as(u8, 3), a.swapRemove(2));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, a.constSlice());
    try std.testing.expectEqual(@as(u8, 1), a.swapRemove(0));
    try std.testing.expectEqualSlices(u8, &.{2}, a.constSlice());
}

test "append at capacity is Overflow" {
    var a = BoundedArray(u8, 2){};
    try a.append(1);
    try a.append(2);
    try std.testing.expectError(error.Overflow, a.append(3));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, a.constSlice());
}

test "resize zero clears; overflow is rejected" {
    var a = BoundedArray(u8, 2){};
    try a.append(1);
    try a.resize(0);
    try std.testing.expectEqual(@as(usize, 0), a.constSlice().len);
    try std.testing.expectError(error.Overflow, a.resize(3));
}
