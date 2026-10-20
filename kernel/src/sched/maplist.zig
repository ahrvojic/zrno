const std = @import("std");

/// One anonymous mapping. The node is allocated from the kernel heap by the
/// caller. The list has no fixed capacity.
pub const Map = struct {
    base: usize,
    size: usize,
    writable: bool = false,
    node: std.DoublyLinkedList.Node = .{},
};

pub const List = struct {
    head: std.DoublyLinkedList = .{},

    pub fn insert(self: *List, map: *Map) void {
        self.head.append(&map.node);
    }

    pub fn find(self: *const List, addr: usize) ?*const Map {
        var node = self.head.first;
        while (node) |n| {
            const map = fromNode(n);
            if (addr >= map.base and addr - map.base < map.size) return map;
            node = n.next;
        }
        return null;
    }

    /// Unlink the mapping `addr`/`size`. When `next` sits on that base, the
    /// mapping is the lowest one, so the cursor moves up to its end. A hole
    /// left by an older mapping stays a hole. The caller frees the node.
    pub fn remove(self: *List, next: *usize, addr: usize, size: usize) ?*Map {
        var node = self.head.first;
        while (node) |n| {
            const map = fromNode(n);
            node = n.next;
            if (map.base != addr or map.size != size) continue;
            self.head.remove(&map.node);
            if (next.* == addr) next.* = addr + size;
            return map;
        }
        return null;
    }

    pub fn pop(self: *List) ?*Map {
        const n = self.head.popFirst() orelse return null;
        return fromNode(n);
    }
};

fn fromNode(n: *std.DoublyLinkedList.Node) *Map {
    return @fieldParentPtr("node", n);
}

test "munmap rewinds only the lowest mapping" {
    var list: List = .{};
    var high: Map = .{ .base = 0x4000, .size = 0x1000 };
    var low: Map = .{ .base = 0x2000, .size = 0x2000 };
    var next: usize = 0x2000;
    list.insert(&high);
    list.insert(&low);

    try std.testing.expect(list.remove(&next, 0x4000, 0x2000) == null);
    try std.testing.expectEqual(0x2000, next);

    try std.testing.expect(list.remove(&next, 0x4000, 0x1000) != null);
    try std.testing.expectEqual(0x2000, next);
    try std.testing.expect(list.find(0x2000) != null);
    try std.testing.expect(list.find(0x4000) == null);

    try std.testing.expect(list.remove(&next, 0x2000, 0x2000) != null);
    try std.testing.expectEqual(0x4000, next);
    try std.testing.expect(list.pop() == null);
    try std.testing.expect(list.remove(&next, 0x2000, 0x2000) == null);
}

test "find hits the interior and misses the ends" {
    var list: List = .{};
    var map: Map = .{ .base = 0x2000, .size = 0x2000 };
    list.insert(&map);
    try std.testing.expect(list.find(0x1fff) == null);
    try std.testing.expect(list.find(0x2000) != null);
    try std.testing.expect(list.find(0x3fff) != null);
    try std.testing.expect(list.find(0x4000) == null);
}

