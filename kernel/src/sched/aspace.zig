const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const maplist = @import("maplist.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("proc.zig");
const state = @import("state.zig");
const vfs = @import("../fs/vfs.zig");
const virt = @import("../lib/virt.zig");
const vmm = @import("../mm/vmm.zig");

const max_mmap: usize = 32 * 1024 * 1024;

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
    releaseUserPages(space, base, state.stack_size, false);
}

// Linux-style `brk`: rdi=0 returns the current break; otherwise set it.
// The stored break is byte-granular; mapping is page-aligned.
pub fn setBrk(addr: usize) error{ Invalid, OutOfMemory }!usize {
    state.expectInit();
    const process = cpu.currentProcess();
    if (addr == 0) return process.brk;

    const old = process.brk;
    if (process.brk_start == 0 or addr < process.brk_start) return error.Invalid;
    if (addr > process.mmap_next or addr > process.user_stack_next) return error.OutOfMemory;
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
        releaseUserPages(&process.vmm, new_pg, old_pg - new_pg, false);
    }
    return addr;
}

fn mapPages(space: *vmm.VMM, addr: usize, size: usize, flags: vmm.Flags) error{OutOfMemory}!void {
    var mapped: usize = 0;
    errdefer releaseUserPages(space, addr, mapped, false);
    while (mapped < size) : (mapped += pmm.page_size) {
        const phys = pmm.alloc(1) orelse return error.OutOfMemory;
        space.map(addr + mapped, phys, pmm.page_size, flags) catch {
            pmm.free(phys, 1);
            return error.OutOfMemory;
        };
    }
}

// One shootdown covers this many leaves. The phys list sits on the kernel stack.
const release_chunk: usize = 64;

/// Clear leaves and empty parent entries, shoot the range down, then free.
/// `sparse` skips holes (anonymous maps fault in on first touch).
/// `free_frames` is false when the caller still owns the leaf frames and
/// will free them after this returns.
fn dropRange(space: *vmm.VMM, addr: usize, size: usize, sparse: bool, free_frames: bool) void {
    var off: usize = 0;
    while (off < size) {
        const chunk = @min(size - off, release_chunk * pmm.page_size);
        var physes: [release_chunk]usize = undefined;
        // A chunk spans at most two page tables, plus the directory levels.
        var tables: [8]usize = undefined;
        var n_frames: usize = 0;
        var n_tables: usize = 0;
        var cleared = false;
        var i: usize = 0;
        while (i < chunk) : (i += pmm.page_size) {
            const phys = space.clearLeaf(addr + off + i) catch {
                if (sparse) continue;
                @panic("user page unmap");
            };
            cleared = true;
            if (free_frames) {
                physes[n_frames] = phys;
                n_frames += 1;
            }
            var got: [3]usize = undefined;
            const k = space.detachEmpty(addr + off + i, &got);
            for (got[0..k]) |table| {
                if (n_tables >= tables.len) @panic("page table batch");
                tables[n_tables] = table;
                n_tables += 1;
            }
        }
        // Parents are already not present. Remote cores drop cached walks
        // before either the leaves or the tables are reused.
        if (cleared) cpu.shootdown(addr + off, chunk);
        if (free_frames) {
            for (physes[0..n_frames]) |phys| pmm.free(phys, 1);
        }
        for (tables[0..n_tables]) |phys| pmm.free(phys, 1);
        off += chunk;
    }
}

fn releaseUserPages(space: *vmm.VMM, addr: usize, size: usize, sparse: bool) void {
    dropRange(space, addr, size, sparse, true);
}

/// Unmap an eager user range (stack, ELF). Leaf frames stay allocated; the
/// caller frees them after this returns, which is after the shootdown.
pub fn unmapEager(space: *vmm.VMM, addr: usize, size: usize) void {
    std.debug.assert(std.mem.isAligned(addr, pmm.page_size));
    std.debug.assert(std.mem.isAligned(size, pmm.page_size));
    dropRange(space, addr, size, false, false);
}

fn dropMap(space: *vmm.VMM, map: maplist.Map) void {
    releaseUserPages(space, map.base, map.size, true);
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

fn install(process: *proc.Process, size: usize, writable: bool) error{OutOfMemory}!usize {
    const base = try reserve(process, size);
    process.maps.append(.{
        .base = base,
        .size = size,
        .writable = writable,
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
    return install(process, size, writable);
}

/// Copy an owned file into private pages. Bytes past the end stay zero.
/// A later write to the file does not change this mapping.
pub fn mapFile(node: *vfs.Node, len: usize, writable: bool) error{ Invalid, OutOfMemory, Io }!usize {
    state.expectInit();
    const process = cpu.currentProcess();
    if (process.pid == state.kernel_pid) @panic("mmap kernel process");
    if (node.bytes() != null or node.isDir()) return error.Invalid;

    const size = try pageBytes(len);
    const base = try install(process, size, writable);
    errdefer if (maplist.remove(&process.maps, &process.mmap_next, base, size)) |old| {
        dropMap(&process.vmm, old);
    };

    const flags = userFlags(writable);
    var done: usize = 0;
    while (done < size) : (done += pmm.page_size) {
        const phys = pmm.alloc(1) orelse return error.OutOfMemory;
        const bytes = virt.toHH([*]u8, phys)[0..pmm.page_size];
        _ = node.readAt(done, bytes) catch |err| {
            pmm.free(phys, 1);
            return err;
        };
        process.vmm.map(base + done, phys, pmm.page_size, flags) catch {
            pmm.free(phys, 1);
            return error.OutOfMemory;
        };
    }
    return base;
}

pub fn releaseMappings(process: *proc.Process) void {
    for (process.maps.slice()) |m| dropMap(&process.vmm, m);
    process.maps.len = 0;
}

/// Allocate the zero page for a reservation. False when `addr` is outside
/// one, the access writes a read-only reservation, or the allocator is empty.
/// A page another core already filled is success: the fault retries.
pub fn fillUserPage(addr: usize, write: bool) bool {
    const process = cpu.currentProcess();
    const page = std.mem.alignBackward(usize, addr, pmm.page_size);
    const map = maplist.find(&process.maps, page) orelse return false;
    if (write and !map.writable) return false;
    if (process.vmm.virtToPhys(page)) |_| return true else |_| {}

    const phys = pmm.alloc(1) orelse return false;
    process.vmm.map(page, phys, pmm.page_size, userFlags(map.writable)) catch {
        pmm.free(phys, 1);
        return false;
    };
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
    dropMap(&process.vmm, old);
}

pub fn dropAddressSpace(space: *vmm.VMM) void {
    // A core still in this root switches to the kernel page tables first.
    cpu.evacuate(space.pt_addr_phys);
    // Unlink before the process object is destroyed. A deferred PML4 free
    // no longer has the VMM.
    space.releaseClone();
    if (space.isCurrent()) {
        deferPtFree(space.pt_addr_phys);
    } else {
        space.destroy();
    }
}

pub fn reapDoomedPt() void {
    const cur = cpu.current();
    const phys = cur.doomed_pt orelse return;
    if (vmm.readCR3() == phys) return;
    cur.doomed_pt = null;
    vmm.destroyPhys(phys);
}

fn deferPtFree(pt_phys: usize) void {
    const cur = cpu.current();
    if (cur.doomed_pt) |old| {
        vmm.destroyPhys(old);
    }
    cur.doomed_pt = pt_phys;
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
