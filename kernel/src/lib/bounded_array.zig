pub fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]T = undefined,
        len: usize = 0,

        pub fn init(len: usize) error{Overflow}!Self {
            if (len > capacity) return error.Overflow;
            return .{ .len = len };
        }

        pub fn append(self: *Self, item: T) error{Overflow}!void {
            if (self.len >= capacity) return error.Overflow;
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn get(self: *const Self, i: usize) T {
            return self.buffer[i];
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
