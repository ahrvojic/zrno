const cpu = @import("sys/cpu.zig");
const elf = @import("sys/elf.zig");
const heap = @import("mm/heap.zig");
const pmm = @import("mm/pmm.zig");
const proc = @import("sched/proc.zig");
const ramfs = @import("sys/ramfs.zig");
const sched = @import("sched/sched.zig");
const virt = @import("lib/virt.zig");
const vmm = @import("mm/vmm.zig");

pub const SpawnError = error{ NoEnt, OutOfMemory, BadElf };

pub fn spawnPath(path: []const u8) SpawnError!u64 {
    const argv = [_][]const u8{path};
    return spawnPathArgv(path, &argv);
}

pub fn spawnPathArgv(path: []const u8, argv: []const []const u8) SpawnError!u64 {
    const image = ramfs.lookup(path) orelse return error.NoEnt;
    const process = sched.startProcess(heap.kernel_heap.allocator(), true) catch |err| return spawnFail(err);
    errdefer sched.abortProcess(process, 1);

    var space: VmmSpace = .{ .vmm = &process.vmm };
    const loaded = elf.load(&space, image) catch |err| return spawnFail(err);
    process.brk_start = loaded.brk;
    process.brk = loaded.brk;
    _ = sched.startUserThread(process, loaded.entry, argv, true) catch |err| return spawnFail(err);
    return process.pid;
}

pub fn execPath(process: *proc.Process, ctx: *cpu.Context, path: []const u8, argv: []const []const u8) SpawnError!void {
    const image = ramfs.lookup(path) orelse return error.NoEnt;
    var new_vmm = vmm.VMM.cloneKernel() catch |err| return spawnFail(err);
    errdefer new_vmm.destroy();

    var space: VmmSpace = .{ .vmm = &new_vmm };
    const loaded = elf.load(&space, image) catch |err| return spawnFail(err);
    sched.execReplace(process, ctx, new_vmm, loaded.entry, loaded.brk, argv) catch |err| return spawnFail(err);
}

fn spawnFail(err: anyerror) SpawnError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadElf,
    };
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
