//! One kernel lock. A core takes it on the way into the kernel and drops it
//! only when the next context runs with interrupts on: a user thread, or the
//! idle halt. `sched.wait` does not drop it. The parked thread holds nothing;
//! the core that stays in the kernel keeps the lock.
//!
//! The spin loop services this core's TLB request and leaves a dying address
//! space. IF is clear while spinning, so those IPIs are not delivered here.
//! A shootdown IPI only wakes a core in user mode or in `hlt`, and its handler
//! does not take this lock. The holder writes the request and waits until
//! the word is 0.

const std = @import("std");

const cpu = @import("cpu.zig");

var locked: std.atomic.Value(u32) = .init(0);
var owner: std.atomic.Value(usize) = .init(0);

pub fn acquire() void {
    const me = @intFromPtr(cpu.current());
    if (tryLock(me)) return;
    if (owner.load(.acquire) == me) @panic("kernel lock re-entered");
    while (true) {
        cpu.pause();
        if (tryLock(me)) return;
        if (owner.load(.acquire) == me) @panic("kernel lock re-entered");
    }
}

fn tryLock(me: usize) bool {
    const self = cpu.current();
    self.serviceTlb();
    // A dying address space is left before this core takes the lock.
    _ = cpu.abandon(self);
    // `swap` is `xchg`. The lock word is 0 free, 1 taken.
    if (locked.swap(1, .acquire) != 0) return false;
    owner.store(me, .release);
    return true;
}

pub fn release() void {
    if (owner.load(.acquire) != @intFromPtr(cpu.current())) @panic("kernel lock not held");
    owner.store(0, .monotonic);
    locked.store(0, .release);
}

// Naked `idleThread` has no Zig frame. These are the calls in that loop.
export fn lockAcquire() callconv(.c) void {
    acquire();
}

export fn lockRelease() callconv(.c) void {
    release();
}
