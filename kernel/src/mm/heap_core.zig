const std = @import("std");

pub const min_size: usize = 16;
pub const page_size: usize = 4096;
pub const max_size: usize = 1024 * 1024 * 1024;

const min_log2 = std.math.log2_int(usize, min_size);
const page_log2 = std.math.log2_int(usize, page_size);
pub const slab_class_count = page_log2 - min_log2 + 1;

pub const FreeNode = struct {
    next: ?*FreeNode,
};

/// Power-of-two size-class heap. Classes up to a page are carved from
/// page-sized slabs; larger requests are a contiguous run of pages.
///
/// `Pages` must provide:
///   alloc(self: Pages, n: usize) ?[*]u8
///   free(self: Pages, ptr: [*]u8, n: usize) void
/// and must return already-mapped memory. Store a pointer when the page
/// source has identity (tests, per-process accounting); a zero-size
/// struct when it is global (kernel PMM).
pub fn Heap(comptime Pages: type) type {
    return struct {
        const Self = @This();

        pages: Pages,
        classes: [slab_class_count]?*FreeNode = @splat(null),

        pub fn init(pages: Pages) Self {
            return .{ .pages = pages };
        }

        pub fn alloc(self: *Self, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
            const class = classSize(len, alignment) orelse return null;
            if (class <= page_size) {
                const i = classIndex(class);
                if (self.classes[i]) |node| {
                    self.classes[i] = node.next;
                    return @ptrCast(node);
                }
                return self.refill(class);
            }
            return self.pages.alloc(class / page_size);
        }

        pub fn free(self: *Self, buf: []u8, alignment: std.mem.Alignment) void {
            const class = classSize(buf.len, alignment) orelse @panic("heap free of invalid size");
            const addr = @intFromPtr(buf.ptr);
            if (!std.mem.isAligned(addr, class)) {
                @panic("heap free of misaligned pointer");
            }

            if (class <= page_size) {
                const node: *FreeNode = @ptrCast(@alignCast(buf.ptr));
                const i = classIndex(class);
                node.next = self.classes[i];
                self.classes[i] = node;
                return;
            }

            self.pages.free(buf.ptr, class / page_size);
        }

        fn refill(self: *Self, class: usize) ?[*]u8 {
            const slab = self.pages.alloc(1) orelse return null;
            const i = classIndex(class);
            var off: usize = class;
            while (off < page_size) : (off += class) {
                const node: *FreeNode = @ptrFromInt(@intFromPtr(slab) + off);
                node.next = self.classes[i];
                self.classes[i] = node;
            }
            return slab;
        }
    };
}

/// Round `len`/`alignment` up to a power-of-two size class, or null if it
/// exceeds `max_size`.
pub fn classSize(len: usize, alignment: std.mem.Alignment) ?usize {
    const need = @max(len, @max(alignment.toByteUnits(), min_size));
    const class = std.math.ceilPowerOfTwo(usize, need) catch return null;
    if (class > max_size) return null;
    return class;
}

/// Map a slab size class (power of two in [min_size, page_size]) to `classes[]`.
/// `@ctz(class)` is `log2(class)` for a power of two; subtracting `min_log2`
/// shifts 16 → 0, 32 → 1, …, 4096 → `slab_class_count - 1`.
pub fn classIndex(class: usize) usize {
    return @ctz(class) - min_log2;
}

const TestPages = struct {
    buf: []u8,
    used: usize = 0,
    allocs: usize = 0,
    frees: usize = 0,

    fn alloc(self: *TestPages, pages: usize) ?[*]u8 {
        const n = pages * page_size;
        if (self.used + n > self.buf.len) return null;
        const p = self.buf[self.used..].ptr;
        self.used += n;
        self.allocs += 1;
        return p;
    }

    fn free(self: *TestPages, ptr: [*]u8, pages: usize) void {
        _ = ptr;
        self.used -= pages * page_size;
        self.frees += 1;
    }
};

const TestHeap = Heap(*TestPages);

test "classSize rounds to power of two" {
    try std.testing.expectEqual(@as(usize, 16), classSize(1, .@"1").?);
    try std.testing.expectEqual(@as(usize, 16), classSize(16, .@"8").?);
    try std.testing.expectEqual(@as(usize, 32), classSize(17, .@"8").?);
    try std.testing.expectEqual(@as(usize, 64), classSize(8, .@"64").?);
    try std.testing.expectEqual(@as(usize, page_size), classSize(page_size, .@"1").?);
    try std.testing.expectEqual(@as(usize, page_size * 2), classSize(page_size + 1, .@"1").?);
    try std.testing.expectEqual(@as(usize, max_size), classSize(max_size, .@"1").?);
    try std.testing.expect(classSize(max_size + 1, .@"1") == null);
}

test "classIndex matches slab size class" {
    try std.testing.expectEqual(@as(usize, 0), classIndex(16));
    try std.testing.expectEqual(@as(usize, 1), classIndex(32));
    try std.testing.expectEqual(slab_class_count - 1, classIndex(page_size));
}

test "free reuses the same size class without a new slab" {
    var backing: [page_size]u8 align(page_size) = undefined;
    var pages: TestPages = .{ .buf = &backing };
    var h = TestHeap.init(&pages);

    const p1 = h.alloc(17, .@"1") orelse return error.TestUnexpectedResult;
    const addr1 = @intFromPtr(p1);
    try std.testing.expectEqual(@as(usize, 1), pages.allocs);
    h.free(p1[0..17], .@"1");

    const p2 = h.alloc(17, .@"1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(addr1, @intFromPtr(p2));
    try std.testing.expectEqual(@as(usize, 1), pages.allocs);
}

test "distinct size classes do not share freelists" {
    var backing: [page_size * 2]u8 align(page_size) = undefined;
    var pages: TestPages = .{ .buf = &backing };
    var h = TestHeap.init(&pages);

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
    var backing: [page_size]u8 align(page_size) = undefined;
    var pages: TestPages = .{ .buf = &backing };
    var h = TestHeap.init(&pages);

    const Dummy = struct { x: u64, y: u64, z: u64 };
    const p = h.alloc(@sizeOf(Dummy), .fromByteUnits(@alignOf(Dummy))) orelse return error.TestUnexpectedResult;
    h.free(p[0..@sizeOf(Dummy)], .fromByteUnits(@alignOf(Dummy)));
    const q = h.alloc(@sizeOf(Dummy), .fromByteUnits(@alignOf(Dummy))) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromPtr(p), @intFromPtr(q));
}

test "slab exhausts after objects-per-page plus one without a second page" {
    var backing: [page_size]u8 align(page_size) = undefined;
    var pages: TestPages = .{ .buf = &backing };
    var h = TestHeap.init(&pages);

    const class: usize = 32;
    const per_page = page_size / class;
    var i: usize = 0;
    while (i < per_page) : (i += 1) {
        _ = h.alloc(class, .@"1") orelse return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 1), pages.allocs);
    try std.testing.expect(h.alloc(class, .@"1") == null);
}

test "large allocation is a page run and free returns it" {
    var backing: [page_size * 4]u8 align(page_size * 2) = undefined;
    var pages: TestPages = .{ .buf = &backing };
    var h = TestHeap.init(&pages);

    const p = h.alloc(page_size + 1, .@"1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), pages.allocs);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(p), page_size));
    h.free(p[0 .. page_size + 1], .@"1");
    try std.testing.expectEqual(@as(usize, 1), pages.frees);

    const q = h.alloc(page_size + 1, .@"1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromPtr(p), @intFromPtr(q));
}
