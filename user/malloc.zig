const sys = @import("sys.zig");

const align_size: usize = 16;
const page_size: usize = 0x1000;

const Header = struct {
    size: usize,
    next: ?*Header,
};

const header_size: usize = (@sizeOf(Header) + align_size - 1) & ~(align_size - 1);

var heap_cur: usize = 0;
var free_head: ?*Header = null;

fn alignUp(n: usize) usize {
    const a: usize = align_size - 1;
    if (n > ~@as(usize, 0) - a) return 0;
    return (n + a) & ~a;
}

fn payload(h: *Header) [*]u8 {
    return @ptrFromInt(@intFromPtr(h) + header_size);
}

fn headerOf(p: [*]u8) *Header {
    return @ptrFromInt(@intFromPtr(p) - header_size);
}

fn tryCoalesce(left: *Header, right: *Header) bool {
    const left_end = @intFromPtr(left) + header_size + left.size;
    if (left_end != @intFromPtr(right)) return false;
    left.size += header_size + right.size;
    left.next = right.next;
    return true;
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
    if (prev) |p| {
        p.next = block;
        if (tryCoalesce(p, block)) {
            if (it) |n| _ = tryCoalesce(p, n);
            return;
        }
    } else {
        free_head = block;
    }
    if (it) |n| _ = tryCoalesce(block, n);
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
                if (prev) |p| p.next = split else free_head = split;
            } else {
                if (prev) |p| p.next = h.next else free_head = h.next;
            }
            h.next = null;
            return h;
        }
        prev = h;
        it = h.next;
    }
    return null;
}

fn moreCore(need: usize) bool {
    const chunk = alignUp(need);
    if (chunk < need) return false;
    const grow_by = (chunk + page_size - 1) & ~(page_size - 1);
    if (grow_by < chunk) return false;

    if (heap_cur == 0) {
        const cur = sys.brk(0);
        if (cur <= 0) return false;
        heap_cur = @intCast(cur);
    }
    if (heap_cur > ~@as(usize, 0) - grow_by) return false;

    const next = heap_cur + grow_by;
    const got = sys.brk(next);
    if (got < 0 or @as(usize, @intCast(got)) != next) return false;

    const h: *Header = @ptrFromInt(heap_cur);
    h.size = grow_by - header_size;
    h.next = null;
    heap_cur = next;
    insertFree(h);
    return true;
}

pub fn malloc(n: usize) ?[*]u8 {
    if (n == 0) return null;
    const payload_n = alignUp(n);
    if (payload_n < n) return null;
    const need = header_size + payload_n;
    if (need < payload_n) return null;

    if (take(payload_n)) |h| return payload(h);
    if (!moreCore(need)) return null;
    const h = take(payload_n) orelse return null;
    return payload(h);
}

pub fn free(ptr: ?[*]u8) void {
    const p = ptr orelse return;
    insertFree(headerOf(p));
}
