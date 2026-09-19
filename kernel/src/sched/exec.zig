const cpu = @import("../sys/cpu.zig");
const elf = @import("../sys/elf.zig");
const file = @import("../fs/file.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("proc.zig");
const ramfs = @import("../fs/ramfs.zig");
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
    const image = ramfs.lookup(path) orelse return error.NoEnt;
    const process = sched.startProcess(true) catch |err| return spawnFail(err);
    errdefer sched.abortProcess(process, 1);

    if (stdio) |fds| {
        const t = cpu.current().thread orelse @panic("user spawn with no thread");
        file.installStdioFrom(&process.fds, &t.parent.fds, fds) catch |err| return spawnFail(err);
    } else {
        file.installStdio(&process.fds) catch |err| return spawnFail(err);
    }

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
        error.BadFd => error.BadFd,
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
