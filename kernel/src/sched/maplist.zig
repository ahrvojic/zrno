const std = @import("std");

const BoundedArray = @import("../lib/bounded_array.zig").BoundedArray;

pub const max_maps = 32;

pub const Map = struct {
    base: usize,
    size: usize,
    writable: bool = false,
};

pub const List = BoundedArray(Map, max_maps);

/// Drop the mapping `addr`/`size`. When `next` sits on that base, the
/// mapping is the lowest one, so the cursor moves up to its end. A hole
/// left by an older mapping stays a hole.
pub fn remove(list: *List, next: *usize, addr: usize, size: usize) bool {
    for (list.slice(), 0..) |m, i| {
        if (m.base != addr or m.size != size) continue;
        _ = list.swapRemove(i);
        if (next.* == addr) next.* = addr + size;
        return true;
    }
    return false;
}

pub fn find(list: *const List, addr: usize) ?Map {
    for (list.constSlice()) |m| {
        if (addr >= m.base and addr - m.base < m.size) return m;
    }
    return null;
}

test "munmap rewinds only the lowest mapping" {
    var list: List = .{};
    var next: usize = 0x5000;
    try list.append(.{ .base = 0x4000, .size = 0x1000 });
    next = 0x4000;
    try list.append(.{ .base = 0x2000, .size = 0x2000 });
    next = 0x2000;

    try std.testing.expect(!remove(&list, &next, 0x4000, 0x2000));
    try std.testing.expectEqual(0x2000, next);

    try std.testing.expect(remove(&list, &next, 0x4000, 0x1000));
    try std.testing.expectEqual(0x2000, next);
    try std.testing.expectEqual(1, list.len);

    try std.testing.expect(remove(&list, &next, 0x2000, 0x2000));
    try std.testing.expectEqual(0x4000, next);
    try std.testing.expectEqual(0, list.len);
    try std.testing.expect(!remove(&list, &next, 0x2000, 0x2000));
}

test "find hits the interior and misses the ends" {
    var list: List = .{};
    try list.append(.{ .base = 0x2000, .size = 0x2000 });
    try std.testing.expect(find(&list, 0x1fff) == null);
    try std.testing.expect(find(&list, 0x2000) != null);
    try std.testing.expect(find(&list, 0x3fff) != null);
    try std.testing.expect(find(&list, 0x4000) == null);
}
