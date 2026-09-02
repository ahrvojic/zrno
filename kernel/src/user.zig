const std = @import("std");

const elf = @import("sys/elf.zig");
const heap = @import("mm/heap.zig");
const pmm = @import("mm/pmm.zig");
const ramfs = @import("sys/ramfs.zig");
const sched = @import("sched/sched.zig");
const virt = @import("lib/virt.zig");
const vmm = @import("mm/vmm.zig");

comptime {
    std.debug.assert(pmm.page_size == elf.page_size);
    std.debug.assert(vmm.user_space_end == elf.user_space_end);
}

pub fn spawnPath(path: []const u8) !u64 {
    const image = ramfs.lookup(path) orelse return error.NoEnt;
    const process = try sched.startProcess(heap.kernel_heap.allocator(), true);
    errdefer sched.abortProcess(process, 1);

    var space: VmmSpace = .{ .vmm = &process.vmm };
    const entry = try elf.load(&space, image);
    _ = try sched.startUserThread(process, entry, 0, true);
    return process.pid;
}

const VmmSpace = struct {
    vmm: *vmm.VMM,

    const Alloc = struct {
        bytes: []u8,
        phys: usize,
    };

    pub fn alloc(_: *VmmSpace, pages: usize) error{OutOfMemory}!Alloc {
        const phys = pmm.alloc(pages) orelse return error.OutOfMemory;
        return .{
            .bytes = virt.toHH([*]u8, phys)[0 .. pages * pmm.page_size],
            .phys = phys,
        };
    }

    pub fn free(_: *VmmSpace, a: Alloc) void {
        pmm.free(a.phys, a.bytes.len / pmm.page_size);
    }

    pub fn map(self: *VmmSpace, vaddr: usize, a: Alloc, flags: elf.MapFlags) !void {
        try self.vmm.map(vaddr, a.phys, a.bytes.len, .{
            .present = true,
            .user = true,
            .writable = flags.writable,
            .noexec = !flags.executable,
        });
    }

    pub fn unmap(self: *VmmSpace, vaddr: usize, size: usize) void {
        self.vmm.unmap(vaddr, size) catch @panic("unmap of mapped elf segment");
    }
};
