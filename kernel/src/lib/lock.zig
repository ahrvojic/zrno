//! IRQ-safe spinlock: a second context on this CPU (timer, keyboard, `#PF`)
//! cannot run the critical section, and neither can another CPU.
//!
//! `lock` disables interrupts on this CPU, then spins on `state` until it
//! can swap unlocked → locked. `unlock` stores unlocked, then restores
//! interrupts. Interrupt disable is nested (`cpu.pushCli` / `popCli`):
//! unlocking an inner lock must not `sti` while an outer lock is still held.
//!
//! Acquire in this order, never the reverse:
//! sched → tty or debug → vmm → heap → pmm → apic or ps2.
//! tty and debug are the same rank (do not nest them); same for apic and ps2.
//!
//! `sched.wait` / `sched.wakeup` are the exception: they take sched while a
//! lower-rank lock (`held`) is already held. Never take a lower-rank lock
//! while already holding sched.
//!
//! `#PF` takes vmm then pmm (user demand paging). The kernel heap is HHDM
//! slabs and does not fault; it may take pmm. Touching a not-yet-mapped
//! user page while holding vmm or pmm deadlocks this CPU.

const std = @import("std");

const cpu = @import("../sys/cpu.zig");

const unlocked: u32 = 0;
const locked: u32 = 1;

pub const SpinLock = struct {
    state: std.atomic.Value(u32) = .init(unlocked),

    pub fn lock(self: *@This()) void {
        cpu.pushCli();
        while (self.state.cmpxchgWeak(unlocked, locked, .acquire, .monotonic) != null) {
            while (self.state.load(.monotonic) != 0) {
                cpu.pause();
            }
        }
    }

    pub fn unlock(self: *@This()) void {
        self.state.store(unlocked, .release);
        cpu.popCli();
    }
};
