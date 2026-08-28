const std = @import("std");

pub const min_size: usize = 16;
pub const max_size: usize = 1024 * 1024 * 1024;

const min_log2 = std.math.log2_int(usize, min_size);
const max_log2 = std.math.log2_int(usize, max_size);
pub const class_count = max_log2 - min_log2 + 1;

pub const FreeNode = struct {
    next: ?*FreeNode,
};

/// Power-of-two size-class heap over a virtual window. Does not map or unmap
/// pages and does not take locks; the kernel wrapper serializes callers.
pub const Heap = struct {
    base: u64,
    end: u64,
    curr: u64,
    classes: [class_count]?*FreeNode = @splat(null),

    pub fn init(base: u64, size: u64) Heap {
        return .{
            .base = base,
            .end = base + size,
            .curr = base,
        };
    }

    pub fn alloc(self: *Heap, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const class = classSize(len, alignment) orelse return null;
        const i = classIndex(class);
        if (self.classes[i]) |node| {
            self.classes[i] = node.next;
            return @ptrCast(node);
        }

        const aligned = std.mem.alignForward(u64, self.curr, class);
        if (aligned >= self.end or self.end - aligned < class) {
            return null;
        }

        self.curr = aligned + class;
        return @ptrFromInt(aligned);
    }

    pub fn free(self: *Heap, buf: []u8, alignment: std.mem.Alignment) void {
        const class = classSize(buf.len, alignment) orelse @panic("heap free of invalid size");
        const addr = @intFromPtr(buf.ptr);
        if (addr < self.base or addr >= self.end or self.end - addr < class) {
            @panic("heap free of pointer outside heap");
        }
        if (!std.mem.isAligned(addr, class)) {
            @panic("heap free of misaligned pointer");
        }

        const node: *FreeNode = @ptrCast(@alignCast(buf.ptr));
        const i = classIndex(class);
        node.next = self.classes[i];
        self.classes[i] = node;
    }
};

/// Round `len`/`alignment` up to a power-of-two size class, or null if it
/// cannot fit in the 1 GiB window.
pub fn classSize(len: usize, alignment: std.mem.Alignment) ?usize {
    const need = @max(len, @max(alignment.toByteUnits(), min_size));
    const class = std.math.ceilPowerOfTwo(usize, need) catch return null;
    if (class > max_size) return null;
    return class;
}

pub fn classIndex(class: usize) usize {
    return @ctz(class) - min_log2;
}

test "classSize rounds to power of two" {
    try std.testing.expectEqual(@as(usize, 16), classSize(1, .@"1").?);
    try std.testing.expectEqual(@as(usize, 16), classSize(16, .@"8").?);
    try std.testing.expectEqual(@as(usize, 32), classSize(17, .@"8").?);
    try std.testing.expectEqual(@as(usize, 64), classSize(8, .@"64").?);
    try std.testing.expectEqual(@as(usize, max_size), classSize(max_size, .@"1").?);
    try std.testing.expect(classSize(max_size + 1, .@"1") == null);
}

test "classIndex matches size class" {
    try std.testing.expectEqual(@as(usize, 0), classIndex(16));
    try std.testing.expectEqual(@as(usize, 1), classIndex(32));
    try std.testing.expectEqual(class_count - 1, classIndex(max_size));
}

test "free reuses the same size class without bumping" {
    var backing: [4096]u8 align(4096) = undefined;
    var h = Heap.init(@intFromPtr(&backing), backing.len);

    const p1 = h.alloc(17, .@"1") orelse return error.TestUnexpectedResult;
    const addr1 = @intFromPtr(p1);
    const bump = h.curr;
    h.free(p1[0..17], .@"1");

    const p2 = h.alloc(17, .@"1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(addr1, @intFromPtr(p2));
    try std.testing.expectEqual(bump, h.curr);
}

test "distinct size classes do not share freelists" {
    var backing: [4096]u8 align(4096) = undefined;
    var h = Heap.init(@intFromPtr(&backing), backing.len);

    const small = h.alloc(16, .@"1") orelse return error.TestUnexpectedResult;
    const large = h.alloc(64, .@"1") orelse return error.TestUnexpectedResult;
    const small_addr = @intFromPtr(small);
    h.free(small[0..16], .@"1");

    const large2 = h.alloc(64, .@"1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(@intFromPtr(large2) != small_addr);
    h.free(large[0..64], .@"1");
    h.free(large2[0..64], .@"1");
}

test "free of never-touched object" {
    var backing: [4096]u8 align(4096) = undefined;
    var h = Heap.init(@intFromPtr(&backing), backing.len);

    const Dummy = struct { x: u64, y: u64, z: u64 };
    const p = h.alloc(@sizeOf(Dummy), .fromByteUnits(@alignOf(Dummy))) orelse return error.TestUnexpectedResult;
    h.free(p[0..@sizeOf(Dummy)], .fromByteUnits(@alignOf(Dummy)));
    const q = h.alloc(@sizeOf(Dummy), .fromByteUnits(@alignOf(Dummy))) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromPtr(p), @intFromPtr(q));
}

test "exhaustion returns null instead of wrapping" {
    var backing: [64]u8 align(64) = undefined;
    var h = Heap.init(@intFromPtr(&backing), backing.len);

    const p1 = h.alloc(32, .@"1") orelse return error.TestUnexpectedResult;
    const p2 = h.alloc(32, .@"1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(h.alloc(32, .@"1") == null);
    h.free(p1[0..32], .@"1");
    h.free(p2[0..32], .@"1");
}
