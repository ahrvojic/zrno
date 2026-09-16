const sys = @import("sys.zig");

const align_size: usize = 16;
const page_size: usize = 0x1000;

const Header = struct {
    size: usize,
    next: ?*Header,
};

fn alignUp(n: usize) usize {
    const a: usize = align_size - 1;
    if (n > ~@as(usize, 0) - a) return 0;
    return (n + a) & ~a;
}

const header_size: usize = alignUp(@sizeOf(Header));

var heap_cur: usize = 0;
var free_head: ?*Header = null;

fn payload(h: *Header) [*]u8 {
    return @ptrFromInt(@intFromPtr(h) + header_size);
}

fn headerOf(p: [*]u8) *Header {
    return @ptrFromInt(@intFromPtr(p) - header_size);
}

fn tryCoalesce(left: *Header, right: *Header) void {
    const left_end = @intFromPtr(left) + header_size + left.size;
    if (left_end != @intFromPtr(right)) return;
    left.size += header_size + right.size;
    left.next = right.next;
}

fn insertFree(block: *Header) void {
    var prev: ?*Header = null;
    var it = free_head;
    while (it) |c| {
        if (@intFromPtr(c) >= @intFromPtr(block)) break;
        prev = c;
        it = c.next;
    }

    block.next = it;
    if (it) |n| tryCoalesce(block, n);
    if (prev) |p| {
        p.next = block;
        tryCoalesce(p, block);
    } else {
        free_head = block;
    }
}

fn take(n: usize) ?*Header {
    var prev: ?*Header = null;
    var it = free_head;
    while (it) |h| {
        if (h.size >= n) {
            const rest = h.size - n;
            if (rest >= header_size + align_size) {
                const split: *Header = @ptrFromInt(@intFromPtr(h) + header_size + n);
                split.size = rest - header_size;
                split.next = h.next;
                h.size = n;
                h.next = split;
            }
            if (prev) |p| p.next = h.next else free_head = h.next;
            h.next = null;
            return h;
        }
        prev = h;
        it = h.next;
    }
    return null;
}

fn moreCore(payload_n: usize) ?*Header {
    const need = header_size + payload_n;
    const grow_by = (need + page_size - 1) & ~(page_size - 1);
    if (grow_by < need) return null;

    if (heap_cur == 0) {
        const cur = sys.brk(0);
        if (cur <= 0) return null;
        heap_cur = @intCast(cur);
    }
    if (heap_cur > ~@as(usize, 0) - grow_by) return null;

    const next = heap_cur + grow_by;
    const got = sys.brk(next);
    if (got < 0 or @as(usize, @intCast(got)) != next) return null;

    const h: *Header = @ptrFromInt(heap_cur);
    h.size = grow_by - header_size;
    heap_cur = next;
    insertFree(h);
    return take(payload_n);
}

pub fn malloc(n: usize) ?[]u8 {
    if (n == 0) return null;
    const payload_n = alignUp(n);
    if (payload_n < n) return null;
    if (payload_n > ~@as(usize, 0) - header_size) return null;

    const h = take(payload_n) orelse moreCore(payload_n) orelse return null;
    return payload(h)[0..n];
}

pub fn free(mem: ?[]u8) void {
    const m = mem orelse return;
    insertFree(headerOf(m.ptr));
}
