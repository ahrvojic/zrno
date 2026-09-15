const std = @import("std");

const Lock = @import("../lib/lock.zig");
const heap = @import("../mm/heap.zig");
const mem = @import("../lib/mem.zig");
const sched = @import("../sched/sched.zig");

// One slot left empty so head == tail means empty (same wrap as tty).
pub const capacity = mem.page_size;
const Index = std.math.IntFittingRange(0, capacity - 1);
comptime {
    std.debug.assert(@as(usize, std.math.maxInt(Index)) + 1 == capacity);
}

// Shared ring. Each end is a File (pipe_read / pipe_write). Lock rank is
// tty/debug: do not nest with those; never take this while holding sched.
pub const Pipe = struct {
    lock: Lock.SpinLock = .{},
    buf: [capacity]u8 = undefined,
    head: Index = 0,
    tail: Index = 0,
    readers: usize = 0,
    writers: usize = 0,

    pub fn create() error{OutOfMemory}!*Pipe {
        const p = try heap.kernel_heap.allocator().create(Pipe);
        p.* = .{};
        return p;
    }

    pub fn destroy(self: *Pipe) void {
        heap.kernel_heap.allocator().destroy(self);
    }

    // Last reader wakes writers (space); last writer wakes readers (data).
    pub fn detachRead(self: *Pipe) void {
        self.detach(&self.readers, &self.head);
    }

    pub fn detachWrite(self: *Pipe) void {
        self.detach(&self.writers, &self.buf);
    }

    fn detach(self: *Pipe, count: *usize, wake: *const anyopaque) void {
        self.lock.lock();
        if (count.* == 0) @panic("pipe refcount underflow");
        count.* -= 1;
        if (count.* == 0) sched.wakeup(wake);
        const dead = self.readers == 0 and self.writers == 0;
        self.lock.unlock();
        if (dead) self.destroy();
    }

    // Block until at least one byte is queued or all writers have closed.
    pub fn peek(self: *Pipe, out: []u8) usize {
        if (out.len == 0) return 0;
        self.lock.lock();
        defer self.lock.unlock();
        while (true) {
            const n = self.copyOut(out);
            if (n != 0) return n;
            if (self.writers == 0) return 0;
            sched.wait(&self.buf, &self.lock);
        }
    }

    pub fn consume(self: *Pipe, n: usize) void {
        if (n == 0) return;
        self.lock.lock();
        defer self.lock.unlock();
        self.drop(n);
        sched.wakeup(&self.head);
    }

    // Put what fits. If the ring is full, wait for space or no readers (EPIPE).
    pub fn write(self: *Pipe, src: []const u8) error{Broken}!usize {
        if (src.len == 0) return 0;
        self.lock.lock();
        defer self.lock.unlock();
        while (true) {
            if (self.readers == 0) return error.Broken;
            const n = self.put(src);
            if (n != 0) {
                sched.wakeup(&self.buf);
                return n;
            }
            sched.wait(&self.head, &self.lock);
        }
    }

    fn copyOut(self: *const Pipe, out: []u8) usize {
        var idx = self.head;
        for (out, 0..) |*slot, n| {
            if (idx == self.tail) return n;
            slot.* = self.buf[idx];
            idx +%= 1;
        }
        return out.len;
    }

    fn drop(self: *Pipe, n: usize) void {
        for (0..n) |_| {
            if (self.head == self.tail) return;
            self.head +%= 1;
        }
    }

    fn put(self: *Pipe, src: []const u8) usize {
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
};

test "ring fill empty wrap" {
    var p: Pipe = .{};

    try std.testing.expectEqual(5, p.put("hello"));
    var out: [8]u8 = undefined;
    try std.testing.expectEqual(5, p.copyOut(&out));
    try std.testing.expectEqualStrings("hello", out[0..5]);
    p.drop(5);
    try std.testing.expectEqual(0, p.copyOut(&out));

    var one: [1]u8 = .{0xaa};
    var filled: usize = 0;
    while (p.put(&one) == 1) filled += 1;
    try std.testing.expectEqual(capacity - 1, filled);
    try std.testing.expectEqual(0, p.put(&one));
    p.drop(filled);

    p.head = @intCast(capacity - 2);
    p.tail = @intCast(capacity - 2);
    try std.testing.expectEqual(2, p.put("ab"));
    try std.testing.expectEqual(2, p.copyOut(&out));
    try std.testing.expectEqualStrings("ab", out[0..2]);
}
