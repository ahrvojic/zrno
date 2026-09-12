const std = @import("std");

const BoundedArray = @import("../lib/bounded_array.zig").BoundedArray;
const pmm = @import("../mm/pmm.zig");
const state = @import("state.zig");
const vmm = @import("../mm/vmm.zig");

// Kernel stacks live in the cloned higher half (not HHDM) so an unmapped
// guard page under each stack is possible. PML4 510: below the kernel
// image, above HHDM.
const kstack_region_base: usize = 0xffff_ff00_0000_0000;
const kstack_region_end: usize = kstack_region_base + (1024 * 1024 * 1024);
const kstack_slot: usize = state.stack_size + pmm.page_size;

comptime {
    std.debug.assert(kstack_region_base % pmm.page_size == 0);
    std.debug.assert(kstack_slot % pmm.page_size == 0);
    std.debug.assert(kstack_region_base >= 0xffff_8000_0000_0000);
    std.debug.assert(kstack_region_end <= 0xffff_ffff_8000_0000);
}

// Kernel stack of a thread that died while running on it. Unmapped and
// freed on the next `switchLocked` that is no longer executing on that stack.
const DoomedStack = struct { phys: usize, base: usize };
var doomed_stack: ?DoomedStack = null;
var kstack_next: usize = kstack_region_base;
// Recycled stack VAs below `kstack_next` (high-water; guard-page check).
const max_kstack_free = 256;
var kstack_free: BoundedArray(usize, max_kstack_free) = .{};

pub const KernelStack = struct { phys: usize, base: usize };

pub fn alloc() !KernelStack {
    const phys = pmm.alloc(state.stack_pages) orelse return error.OutOfMemory;
    errdefer pmm.free(phys, state.stack_pages);

    state.lock.lock();
    defer state.lock.unlock();
    const base = try takeSlotLocked();
    errdefer releaseSlotLocked(base);
    try vmm.kernel_vmm.map(base, phys, state.stack_size, .{
        .present = true,
        .writable = true,
        .noexec = true,
    });
    return .{ .phys = phys, .base = base };
}

pub fn free(phys: usize, base: usize) void {
    unmap(phys, base);
    state.lock.lock();
    defer state.lock.unlock();
    releaseSlotLocked(base);
}

pub fn freeLocked(phys: usize, base: usize) void {
    unmap(phys, base);
    releaseSlotLocked(base);
}

pub fn deferFree(stack_phys: usize, stack_base: usize) void {
    if (doomed_stack) |old| {
        freeLocked(old.phys, old.base);
    }
    doomed_stack = .{ .phys = stack_phys, .base = stack_base };
}

pub fn reapDoomed() void {
    const doomed = doomed_stack orelse return;
    if (rspInStack(doomed.base)) return;
    doomed_stack = null;
    freeLocked(doomed.phys, doomed.base);
}

/// True when `addr` is the unmapped page under a kernel stack.
pub fn isGuard(addr: usize) bool {
    if (addr < kstack_region_base or addr >= kstack_next) return false;
    const off = addr - kstack_region_base;
    return off % kstack_slot < pmm.page_size;
}

fn unmap(phys: usize, base: usize) void {
    vmm.kernel_vmm.unmap(base, state.stack_size) catch @panic("unmap kernel stack");
    pmm.free(phys, state.stack_pages);
}

fn takeSlotLocked() error{OutOfMemory}!usize {
    if (kstack_free.pop()) |base| return base;
    if (kstack_next >= kstack_region_end or kstack_region_end - kstack_next < kstack_slot) {
        return error.OutOfMemory;
    }
    const slot = kstack_next;
    kstack_next += kstack_slot;
    return slot + pmm.page_size;
}

fn releaseSlotLocked(base: usize) void {
    const slot = base - pmm.page_size;
    if (slot + kstack_slot == kstack_next) {
        kstack_next = slot;
        while (kstack_next > kstack_region_base) {
            const top = kstack_next - kstack_slot + pmm.page_size;
            if (!removeFree(top)) break;
            kstack_next -= kstack_slot;
        }
        return;
    }
    // Holes under a live high-water slot. Dropping the VA would leak the slot.
    kstack_free.append(base) catch @panic("kstack free list full");
}

fn removeFree(base: usize) bool {
    for (kstack_free.constSlice(), 0..) |b, i| {
        if (b == base) {
            _ = kstack_free.swapRemove(i);
            return true;
        }
    }
    return false;
}

fn rspInStack(stack_base: usize) bool {
    const rsp = asm volatile (
        \\movq %%rsp, %[rsp]
        : [rsp] "=r" (-> usize),
    );
    return rsp >= stack_base and rsp < stack_base + state.stack_size;
}
