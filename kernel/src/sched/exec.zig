const cpu = @import("../sys/cpu.zig");
const elf = @import("../sys/elf.zig");
const file = @import("../fs/file.zig");
const heap = @import("../mm/heap.zig");
const pmm = @import("../mm/pmm.zig");
const vfs = @import("../fs/vfs.zig");
const sched = @import("sched.zig");
const virt = @import("../lib/virt.zig");
const vmm = @import("../mm/vmm.zig");

pub const SpawnError = error{ NoEnt, OutOfMemory, BadElf, BadFd };

pub fn spawnPath(path: []const u8) SpawnError!u64 {
    const argv = [_][]const u8{path};
    return spawn(path, &argv, null);
}

pub fn spawnPathArgv(path: []const u8, argv: []const []const u8, stdin: u64, stdout: u64, stderr: u64) SpawnError!u64 {
    return spawn(path, argv, .{ stdin, stdout, stderr });
}

fn spawn(path: []const u8, argv: []const []const u8, stdio: ?[3]u64) SpawnError!u64 {
    const process = sched.startProcess(true) catch |err| return spawnFail(err);
    errdefer sched.abortProcess(process, 1);

    if (stdio) |fds| {
        const t = cpu.currentThread();
        file.installStdioFrom(&process.fds, &t.parent.fds, fds) catch |err| return spawnFail(err);
    } else {
        file.installStdio(&process.fds) catch |err| return spawnFail(err);
    }

    const loaded = try loadPath(&process.vmm, process.cwd, path);
    process.brk_start = loaded.brk;
    process.brk = loaded.brk;
    _ = sched.startUserThread(process, loaded.entry, argv, true) catch |err| return spawnFail(err);
    return process.pid;
}

fn loadPath(vm: *vmm.VMM, cwd: *vfs.Node, path: []const u8) SpawnError!elf.Loaded {
    const node = vfs.walkFrom(cwd, path) catch return error.NoEnt;
    if (node.isDir()) return error.NoEnt;
    var space: VmmSpace = .{ .vmm = vm };
    if (node.bytes()) |image| return elf.load(&space, image) catch |err| spawnFail(err);
    const n = node.size();
    if (n == 0) return elf.load(&space, &.{}) catch |err| spawnFail(err);
    const image = heap.kernel_heap.allocator().alloc(u8, n) catch return error.OutOfMemory;
    defer heap.kernel_heap.allocator().free(image);
    _ = node.readAt(0, image);
    return elf.load(&space, image) catch |err| spawnFail(err);
}

const Fail = error{
    OutOfMemory,
    BadFd,
    BadElf,
    WritableExecutable,
    OutOfRange,
    AlreadyMapped,
    PTENotFound,
};

fn spawnFail(err: Fail) SpawnError {
    return switch (err) {
        // Page-table allocation reports PTENotFound.
        error.OutOfMemory, error.PTENotFound => error.OutOfMemory,
        error.BadFd => error.BadFd,
        error.BadElf, error.WritableExecutable, error.OutOfRange, error.AlreadyMapped => error.BadElf,
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
