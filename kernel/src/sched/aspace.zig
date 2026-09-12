const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("proc.zig");
const state = @import("state.zig");
const vmm = @import("../mm/vmm.zig");

// Cap on `brk - brk_start`. Prevents a single call from allocating up to mmap.
const max_heap: usize = 32 * 1024 * 1024;
const max_mmap: usize = 32 * 1024 * 1024;
const heap_flags = vmm.Flags{ .present = true, .writable = true, .user = true, .noexec = true };

// Unique PML4 of a process that died while CR3 still pointed at it.
// Freed on the next `switchLocked` that is no longer using that root.
var doomed_pt_phys: ?usize = null;

pub fn takeUserStack(parent: *proc.Process) error{OutOfMemory}!usize {
    state.lock.lock();
    defer state.lock.unlock();
    if (parent.user_stack_next < state.user_stack_slot) return error.OutOfMemory;
    const slot_lo = parent.user_stack_next - state.user_stack_slot;
    if (slot_lo < parent.brk or slot_lo < state.user_mmap_top) return error.OutOfMemory;
    parent.user_stack_next = slot_lo;
    return slot_lo + pmm.page_size;
}

pub fn giveUserStack(parent: *proc.Process, base: usize) void {
    state.lock.lock();
    defer state.lock.unlock();
    if (parent.user_stack_next == base - pmm.page_size) {
        parent.user_stack_next = base + state.stack_size;
    }
}

const BrkChange = struct {
    old: usize,
    addr: usize,
    page_addr: usize,
    page_size: usize,
    grow: bool,
};

// Linux-style `brk`: rdi=0 returns the current break; otherwise set it.
// The stored break is byte-granular; mapping is page-aligned.
pub fn setBrk(addr: usize) error{ Invalid, OutOfMemory }!usize {
    state.expectInit();
    const thr = cpu.current().thread orelse @panic("brk with no thread");
    const process = thr.parent;

    state.lock.lock();
    if (addr == 0) {
        const cur = process.brk;
        state.lock.unlock();
        return cur;
    }
    const change: ?BrkChange = blk: {
        defer state.lock.unlock();
        const old = process.brk;
        if (process.brk_start == 0 or addr < process.brk_start) return error.Invalid;
        if (addr > process.mmap_next or addr > process.user_stack_next or
            addr - process.brk_start > max_heap)
        {
            return error.OutOfMemory;
        }
        const old_pg = std.mem.alignForward(usize, old, pmm.page_size);
        const new_pg = std.mem.alignForward(usize, addr, pmm.page_size);
        process.brk = addr;
        if (old_pg == new_pg) break :blk null;
        break :blk .{
            .old = old,
            .addr = addr,
            .page_addr = if (addr > old) old_pg else new_pg,
            .page_size = if (addr > old) new_pg - old_pg else old_pg - new_pg,
            .grow = addr > old,
        };
    };

    const c = change orelse return addr;

    if (c.grow) {
        mapPages(&process.vmm, c.page_addr, c.page_size, heap_flags) catch {
            state.lock.lock();
            if (process.brk == c.addr) process.brk = c.old;
            state.lock.unlock();
            return error.OutOfMemory;
        };
    } else {
        unmapPages(&process.vmm, c.page_addr, c.page_size);
    }
    return c.addr;
}

fn mapPages(space: *vmm.VMM, addr: usize, size: usize, flags: vmm.Flags) error{OutOfMemory}!void {
    var mapped: usize = 0;
    errdefer unmapPages(space, addr, mapped);
    while (mapped < size) : (mapped += pmm.page_size) {
        const phys = pmm.alloc(1) orelse return error.OutOfMemory;
        space.map(addr + mapped, phys, pmm.page_size, flags) catch |err| {
            pmm.free(phys, 1);
            switch (err) {
                error.AlreadyMapped => @panic("page already mapped"),
                else => return error.OutOfMemory,
            }
        };
    }
}

fn unmapPages(space: *vmm.VMM, addr: usize, size: usize) void {
    var off: usize = 0;
    while (off < size) : (off += pmm.page_size) {
        const phys = space.virtToPhys(addr + off) catch @panic("user page unmap");
        space.unmap(addr + off, pmm.page_size) catch @panic("user page unmap");
        pmm.free(std.mem.alignBackward(usize, phys, pmm.page_size), 1);
    }
}

// Anonymous mmap: kernel picks the address (`addr` hint must be 0 at the
// syscall). Eager map, NX. Grows down from `user_mmap_top`.
pub fn mapAnon(len: usize, writable: bool) error{ Invalid, OutOfMemory }!usize {
    state.expectInit();
    if (len == 0) return error.Invalid;
    const thr = cpu.current().thread orelse @panic("mmap with no thread");
    const process = thr.parent;
    if (process.pid == state.kernel_pid) @panic("mmap kernel process");

    const size = std.mem.alignForward(usize, len, pmm.page_size);
    if (size < len) return error.Invalid;

    state.lock.lock();
    const old = process.mmap_next;
    if (old < size) {
        state.lock.unlock();
        return error.OutOfMemory;
    }
    const base = old - size;
    if (base < process.brk or state.user_mmap_top - base > max_mmap) {
        state.lock.unlock();
        return error.OutOfMemory;
    }
    process.mmap_next = base;
    state.lock.unlock();

    const flags = vmm.Flags{
        .present = true,
        .writable = writable,
        .user = true,
        .noexec = true,
    };
    mapPages(&process.vmm, base, size, flags) catch {
        state.lock.lock();
        if (process.mmap_next == base) process.mmap_next = old;
        state.lock.unlock();
        return error.OutOfMemory;
    };
    return base;
}

pub fn dropAddressSpace(space: *vmm.VMM) void {
    if (space.isCurrent()) {
        deferPtFree(space.pt_addr_phys);
    } else {
        space.destroy();
    }
}

pub fn reapDoomedPt() void {
    const phys = doomed_pt_phys orelse return;
    if (vmm.readCR3() == phys) return;
    doomed_pt_phys = null;
    vmm.destroyPhys(phys);
}

fn deferPtFree(pt_phys: usize) void {
    if (doomed_pt_phys) |old| {
        vmm.destroyPhys(old);
    }
    doomed_pt_phys = pt_phys;
}

/// True when `addr` is the unmapped guard under a mapped user stack of
/// the current process.
pub fn isUserStackGuard(addr: usize) bool {
    const thread = cpu.current().thread orelse return false;
    const lo = thread.parent.user_stack_next;
    if (addr < lo or addr >= state.user_stack_top) return false;
    const aligned = std.mem.alignBackward(usize, addr, pmm.page_size);
    if (aligned < lo) return false;
    return (state.user_stack_top - aligned) % state.user_stack_slot == 0;
}
