const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const frame = @import("../mm/frame.zig");
const heap = @import("../mm/heap.zig");
const maplist = @import("maplist.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("proc.zig");
const state = @import("state.zig");
const vfs = @import("../fs/vfs.zig");
const vmm = @import("../mm/vmm.zig");

// Cap on `brk - brk_start`. Prevents a single call from allocating up to mmap.
const max_heap: usize = 32 * 1024 * 1024;
const max_mmap: usize = 32 * 1024 * 1024;

// Unique PML4 of a process that died while CR3 still pointed at it.
// Freed on the next `schedule` that is no longer using that root.
var doomed_pt_phys: ?usize = null;

pub fn takeUserStack(parent: *proc.Process) error{OutOfMemory}!usize {
    if (parent.user_stack_next < state.user_stack_slot) return error.OutOfMemory;
    const slot_lo = parent.user_stack_next - state.user_stack_slot;
    if (slot_lo < parent.brk or slot_lo < state.user_mmap_top) return error.OutOfMemory;
    parent.user_stack_next = slot_lo;
    return slot_lo + pmm.page_size;
}

// Rewinds the cursor when `base` is the newest slot. An older slot stays a
// hole until process exit; the caller frees the frames.
pub fn releaseUserStack(parent: *proc.Process, base: usize) void {
    if (parent.user_stack_next == base - pmm.page_size) {
        parent.user_stack_next = base + state.stack_size;
    }
}

pub fn unmapUserStack(space: *vmm.VMM, base: usize) void {
    unmapPages(space, base, state.stack_size);
}

// Linux-style `brk`: rdi=0 returns the current break; otherwise set it.
// The stored break is byte-granular; mapping is page-aligned.
pub fn setBrk(addr: usize) error{ Invalid, OutOfMemory }!usize {
    state.expectInit();
    const process = cpu.currentProcess();
    if (addr == 0) return process.brk;

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
    if (old_pg == new_pg) return addr;

    if (addr > old) {
        mapPages(&process.vmm, old_pg, new_pg - old_pg, userFlags(true)) catch {
            process.brk = old;
            return error.OutOfMemory;
        };
    } else {
        unmapPages(&process.vmm, new_pg, old_pg - new_pg);
    }
    return addr;
}

fn mapPages(space: *vmm.VMM, addr: usize, size: usize, flags: vmm.Flags) error{OutOfMemory}!void {
    var mapped: usize = 0;
    errdefer unmapPages(space, addr, mapped);
    while (mapped < size) : (mapped += pmm.page_size) {
        const phys = pmm.alloc(1) orelse return error.OutOfMemory;
        space.map(addr + mapped, phys, pmm.page_size, flags) catch {
            pmm.free(phys, 1);
            return error.OutOfMemory;
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

fn dropFrames(space: *vmm.VMM, map: maplist.Map) void {
    for (map.pages, 0..) |slot, i| {
        const fr = slot orelse continue;
        space.unmap(map.base + i * pmm.page_size, pmm.page_size) catch @panic("user page unmap");
        fr.release();
    }
    heap.kernel_heap.allocator().free(map.pages);
}

fn pageBytes(len: usize) error{Invalid}!usize {
    if (len == 0 or len > std.math.maxInt(usize) - (pmm.page_size - 1)) return error.Invalid;
    return std.mem.alignForward(usize, len, pmm.page_size);
}

fn reserve(process: *proc.Process, size: usize) error{OutOfMemory}!usize {
    const old = process.mmap_next;
    if (old < size) return error.OutOfMemory;
    const base = old - size;
    if (base < process.brk or state.user_mmap_top - base > max_mmap) return error.OutOfMemory;
    return base;
}

fn userFlags(writable: bool) vmm.Flags {
    return .{
        .present = true,
        .writable = writable,
        .user = true,
        .noexec = true,
    };
}

fn frameSlots(n: usize) error{OutOfMemory}![]?*frame.Frame {
    const slots = heap.kernel_heap.allocator().alloc(?*frame.Frame, n) catch return error.OutOfMemory;
    @memset(slots, null);
    return slots;
}

fn install(
    process: *proc.Process,
    size: usize,
    writable: bool,
    shared: bool,
    pages: []?*frame.Frame,
) error{OutOfMemory}!usize {
    errdefer heap.kernel_heap.allocator().free(pages);
    const base = try reserve(process, size);
    process.maps.append(.{
        .base = base,
        .size = size,
        .writable = writable,
        .shared = shared,
        .pages = pages,
    }) catch return error.OutOfMemory;
    process.mmap_next = base;
    return base;
}

// Anonymous mmap. The kernel picks the address (`addr` hint must be 0).
// The range is only reserved; the first access allocates a zero page. NX.
// Grows down from `user_mmap_top`.
pub fn mapAnon(len: usize, writable: bool) error{ Invalid, OutOfMemory }!usize {
    state.expectInit();
    const process = cpu.currentProcess();
    if (process.pid == state.kernel_pid) @panic("mmap kernel process");

    const size = try pageBytes(len);
    const pages = try frameSlots(size / pmm.page_size);
    return install(process, size, writable, false, pages);
}

/// Map the owned file's frames into this process. The file keeps its
/// references, so `munmap` leaves the bytes in place.
pub fn mapFile(node: *vfs.Node, len: usize, writable: bool) error{ Invalid, OutOfMemory }!usize {
    state.expectInit();
    const process = cpu.currentProcess();
    if (process.pid == state.kernel_pid) @panic("mmap kernel process");

    const size = try pageBytes(len);
    const pages = try frameSlots(size / pmm.page_size);
    const base = try install(process, size, writable, true, pages);

    var done: usize = 0;
    errdefer if (maplist.remove(&process.maps, &process.mmap_next, base, size)) |old| {
        dropFrames(&process.vmm, old);
    };
    const flags = userFlags(writable);
    while (done < size) : (done += pmm.page_size) {
        const fr = node.retainPage(done) orelse return error.Invalid;
        process.vmm.map(base + done, fr.phys, pmm.page_size, flags) catch {
            fr.release();
            return error.OutOfMemory;
        };
        pages[done / pmm.page_size] = fr;
    }
    return base;
}

pub fn releaseMappings(process: *proc.Process) void {
    for (process.maps.slice()) |m| dropFrames(&process.vmm, m);
    process.maps.len = 0;
}

/// Allocate the zero page for an anonymous reservation. False when `addr`
/// is outside one, the page is a file mapping, the access writes a
/// read-only reservation, or the allocator is empty. The frame is zeroed.
pub fn fillUserPage(addr: usize, write: bool) bool {
    const process = cpu.currentProcess();
    const page = std.mem.alignBackward(usize, addr, pmm.page_size);
    const map = maplist.find(&process.maps, page) orelse return false;
    if (map.shared or (write and !map.writable)) return false;
    const slot = (page - map.base) / pmm.page_size;
    if (map.pages[slot] != null) return false;

    const fr = frame.alloc() orelse return false;
    process.vmm.map(page, fr.phys, pmm.page_size, userFlags(map.writable)) catch {
        fr.release();
        return false;
    };
    map.pages[slot] = fr;
    return true;
}

/// Inverse of `mapAnon`. `len` is rounded the same way. The address must be
/// a mapping that was handed out, whole. The cursor rewinds only when this
/// mapping is the lowest one.
pub fn unmapAnon(addr: usize, len: usize) error{Invalid}!void {
    state.expectInit();
    const process = cpu.currentProcess();
    if (process.pid == state.kernel_pid) @panic("munmap kernel process");

    if (!std.mem.isAligned(addr, pmm.page_size)) return error.Invalid;
    const size = pageBytes(len) catch return error.Invalid;

    const old = maplist.remove(&process.maps, &process.mmap_next, addr, size) orelse return error.Invalid;
    dropFrames(&process.vmm, old);
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
