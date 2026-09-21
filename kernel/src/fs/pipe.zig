const Lock = @import("../lib/lock.zig");
const Ring = @import("../lib/ring.zig").Ring;
const heap = @import("../mm/heap.zig");
const mem = @import("../lib/mem.zig");
const sched = @import("../sched/sched.zig");

// One slot left empty so head == tail means empty (same wrap as tty).
pub const capacity = mem.page_size;

// Shared ring. Each end is a File (pipe_read / pipe_write). Lock rank is
// tty/debug: do not nest with those; never take this while holding sched.
pub const Pipe = struct {
    lock: Lock.SpinLock = .{},
    ring: Ring(capacity) = .{},
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
        self.detach(&self.readers, &self.ring.head);
    }

    pub fn detachWrite(self: *Pipe) void {
        self.detach(&self.writers, &self.ring.buf);
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
            const n = self.ring.copyOut(out);
            if (n != 0) return n;
            if (self.writers == 0) return 0;
            sched.wait(&self.ring.buf, &self.lock);
        }
    }

    pub fn consume(self: *Pipe, n: usize) void {
        if (n == 0) return;
        self.lock.lock();
        defer self.lock.unlock();
        self.ring.drop(n);
        sched.wakeup(&self.ring.head);
    }

    // Put what fits. If the ring is full, wait for space or no readers (EPIPE).
    pub fn write(self: *Pipe, src: []const u8) error{Broken}!usize {
        if (src.len == 0) return 0;
        self.lock.lock();
        defer self.lock.unlock();
        while (true) {
            if (self.readers == 0) return error.Broken;
            const n = self.ring.put(src);
            if (n != 0) {
                sched.wakeup(&self.ring.buf);
                return n;
            }
            sched.wait(&self.ring.head, &self.lock);
        }
    }
};
