const logger = std.log.scoped(.syscall);

const std = @import("std");

const cpu = @import("cpu.zig");
const ramfs = @import("ramfs.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("../sched/proc.zig");
const reboot = @import("reboot.zig");
const sched = @import("../sched/sched.zig");
const tty = @import("../dev/tty.zig");
const user = @import("../user.zig");
const vmm = @import("../mm/vmm.zig");

// SYSCALL (int 0x80 still accepted): rax = number / return, rdi/rsi/rdx = args.
// RCX/R11 are clobbered (RIP/RFLAGS). Negative rax is -errno.
pub const nr_read: u64 = 0;
pub const nr_write: u64 = 1;
pub const nr_exit: u64 = 2;
pub const nr_yield: u64 = 3;
pub const nr_sleep: u64 = 4;
pub const nr_open: u64 = 5;
pub const nr_close: u64 = 6;
pub const nr_spawn: u64 = 7; // rdi=path, rsi=argv or 0
pub const nr_wait: u64 = 8; // rdi=pid (0 = any); rsi=status or 0; returns pid
pub const nr_getpid: u64 = 9;
pub const nr_getppid: u64 = 10;
pub const nr_exec: u64 = 11; // replace image, keep pid/fds; rsi=argv or 0
pub const nr_dup: u64 = 12;
pub const nr_brk: u64 = 13; // rdi=0 query; else set program break, return it
pub const nr_mmap: u64 = 14; // rdi=addr (0), rsi=len, rdx=prot; anonymous, NX
pub const nr_reboot: u64 = 15; // never returns

pub const prot_read: u64 = 1;
pub const prot_write: u64 = 2;
pub const prot_exec: u64 = 4;

const max_io: usize = pmm.page_size;
const io_chunk: usize = 256;
const max_path: usize = 128;
const max_argv: usize = 32;
const max_arg: usize = 128;

const ENOENT: i64 = 2;
const E2BIG: i64 = 7;
const ENOEXEC: i64 = 8;
const EBADF: i64 = 9;
const ECHILD: i64 = 10;
const ENOMEM: i64 = 12;
const EACCES: i64 = 13;
const EFAULT: i64 = 14;
const EINVAL: i64 = 22;
const EMFILE: i64 = 24;
const ENAMETOOLONG: i64 = 36;
const ENOSYS: i64 = 38;

pub fn handle(ctx: *cpu.Context) void {
    ctx.rax = dispatch(ctx);
}

fn dispatch(ctx: *cpu.Context) u64 {
    return switch (ctx.rax) {
        nr_read => sys_read(ctx),
        nr_write => sys_write(ctx),
        nr_exit => sys_exit(ctx),
        nr_yield => sys_yield(),
        nr_sleep => sys_sleep(ctx),
        nr_open => sys_open(ctx),
        nr_close => sys_close(ctx),
        nr_spawn => sys_spawn(ctx),
        nr_wait => sys_wait(ctx),
        nr_getpid => sys_getpid(),
        nr_getppid => sys_getppid(),
        nr_exec => sys_exec(ctx),
        nr_dup => sys_dup(ctx),
        nr_brk => sys_brk(ctx),
        nr_mmap => sys_mmap(ctx),
        nr_reboot => reboot.perform(),
        else => errval(ENOSYS),
    };
}

fn sys_read(ctx: *cpu.Context) u64 {
    const fd = ctx.rdi;
    const addr: usize = @intCast(ctx.rsi);
    const len: usize = @intCast(ctx.rdx);
    if (len == 0) return 0;
    if (len > max_io) return errval(EINVAL);
    if (!vmm.userRange(addr, len)) return errval(EFAULT);
    if (fd >= proc.max_fds) return errval(EBADF);

    const i: usize = @intCast(fd);
    const slot = &currentProcess().fds[i];
    switch (slot.*) {
        .empty => return errval(EBADF),
        .tty => {
            var tmp: [io_chunk]u8 = undefined;
            const want = @min(tmp.len, len);
            const n = tty.peek(tmp[0..want]);
            userSpace().copyToUser(addr, tmp[0..n]) catch return errval(EFAULT);
            tty.consume(n);
            return n;
        },
        .file => |*f| {
            if (f.pos >= f.bytes.len) return 0;
            const n = @min(len, f.bytes.len - f.pos);
            userSpace().copyToUser(addr, f.bytes[f.pos..][0..n]) catch return errval(EFAULT);
            f.pos += n;
            return n;
        },
    }
}

fn sys_write(ctx: *cpu.Context) u64 {
    const fd = ctx.rdi;
    const addr: usize = @intCast(ctx.rsi);
    const len: usize = @intCast(ctx.rdx);
    if (len == 0) return 0;
    if (len > max_io) return errval(EINVAL);
    if (!vmm.userRange(addr, len)) return errval(EFAULT);
    if (fd >= proc.max_fds) return errval(EBADF);

    const i: usize = @intCast(fd);
    switch (currentProcess().fds[i]) {
        .empty => return errval(EBADF),
        .file => return errval(EACCES),
        .tty => {},
    }

    var tmp: [io_chunk]u8 = undefined;
    var copied: usize = 0;
    const space = userSpace();
    while (copied < len) {
        const n = @min(tmp.len, len - copied);
        space.copyFromUser(tmp[0..n], addr + copied) catch {
            if (copied == 0) return errval(EFAULT);
            return copied;
        };
        tty.writeBytes(tmp[0..n]);
        copied += n;
    }
    return copied;
}

fn sys_exit(ctx: *cpu.Context) u64 {
    const thread = cpu.current().thread orelse @panic("exit with no thread");
    const process = thread.parent;
    if (process.pid == 0) @panic("kernel process exit");
    const code: u8 = @truncate(ctx.rdi);
    logger.info("pid {d} exit {d}", .{ process.pid, code });
    sched.exitProcess(process, code);
    sched.yield();
    unreachable;
}

fn sys_yield() u64 {
    sched.yield();
    return 0;
}

fn sys_sleep(ctx: *cpu.Context) u64 {
    sched.sleep(ctx.rdi);
    return 0;
}

fn sys_open(ctx: *cpu.Context) u64 {
    const addr: usize = @intCast(ctx.rdi);
    var buf: [max_path]u8 = undefined;
    const path = copyUserPath(addr, &buf) catch |err| return pathErr(err);
    const data = ramfs.lookup(path) orelse return errval(ENOENT);
    const fds = &currentProcess().fds;
    for (fds[3..], 3..) |*slot, fd| {
        if (slot.* == .empty) {
            slot.* = .{ .file = .{ .bytes = data, .pos = 0 } };
            return fd;
        }
    }
    return errval(EMFILE);
}

fn sys_close(ctx: *cpu.Context) u64 {
    const fd = ctx.rdi;
    if (fd >= proc.max_fds) return errval(EBADF);
    const i: usize = @intCast(fd);
    const slot = &currentProcess().fds[i];
    if (slot.* == .empty) return errval(EBADF);
    slot.* = .empty;
    return 0;
}

fn sys_spawn(ctx: *cpu.Context) u64 {
    const addr: usize = @intCast(ctx.rdi);
    var buf: [max_path]u8 = undefined;
    const path = copyUserPath(addr, &buf) catch |err| return pathErr(err);
    var storage: ArgvStorage = .{};
    const argv = copyUserArgv(ctx.rsi, path, &storage) catch |err| return argvErr(err);
    const pid = user.spawnPathArgv(path, argv) catch |err| return spawnErr(err);
    return pid;
}

fn sys_wait(ctx: *cpu.Context) u64 {
    const status_addr: usize = @intCast(ctx.rsi);
    if (status_addr != 0 and !vmm.userRange(status_addr, @sizeOf(u64))) {
        return errval(EFAULT);
    }
    const result = sched.waitProcess(ctx.rdi) catch |err| return switch (err) {
        error.NoChild => errval(ECHILD),
        error.Invalid => errval(EINVAL),
    };
    if (status_addr != 0) {
        var tmp: [@sizeOf(u64)]u8 = undefined;
        std.mem.writeInt(u64, &tmp, result.code, .little);
        userSpace().copyToUser(status_addr, &tmp) catch return errval(EFAULT);
    }
    return result.pid;
}

fn sys_getpid() u64 {
    return currentProcess().pid;
}

fn sys_getppid() u64 {
    return currentProcess().parent;
}

fn sys_exec(ctx: *cpu.Context) u64 {
    const addr: usize = @intCast(ctx.rdi);
    var buf: [max_path]u8 = undefined;
    const path = copyUserPath(addr, &buf) catch |err| return pathErr(err);
    var storage: ArgvStorage = .{};
    const argv = copyUserArgv(ctx.rsi, path, &storage) catch |err| return argvErr(err);
    user.execPath(currentProcess(), ctx, path, argv) catch |err| return spawnErr(err);
    return 0;
}

fn sys_brk(ctx: *cpu.Context) u64 {
    const addr: usize = @intCast(ctx.rdi);
    const brk = sched.setBrk(addr) catch |err| return switch (err) {
        error.Invalid => errval(EINVAL),
        error.OutOfMemory => errval(ENOMEM),
    };
    return brk;
}

fn sys_mmap(ctx: *cpu.Context) u64 {
    const addr: usize = @intCast(ctx.rdi);
    const len: usize = @intCast(ctx.rsi);
    const prot = ctx.rdx;
    if (addr != 0) return errval(EINVAL);
    if (len == 0) return errval(EINVAL);
    if (prot & prot_exec != 0) return errval(EINVAL);
    if (prot & (prot_read | prot_write) == 0) return errval(EINVAL);
    const va = sched.mapAnon(len, prot & prot_write != 0) catch |err| return switch (err) {
        error.Invalid => errval(EINVAL),
        error.OutOfMemory => errval(ENOMEM),
    };
    return va;
}

fn sys_dup(ctx: *cpu.Context) u64 {
    const fd = ctx.rdi;
    if (fd >= proc.max_fds) return errval(EBADF);
    const fds = &currentProcess().fds;
    const i: usize = @intCast(fd);
    if (fds[i] == .empty) return errval(EBADF);
    for (fds, 0..) |*slot, new_fd| {
        if (slot.* == .empty) {
            // Copy the slot; file offsets are per-fd, not a shared POSIX description.
            slot.* = fds[i];
            return new_fd;
        }
    }
    return errval(EMFILE);
}

fn copyUserPath(addr: usize, buf: *[max_path]u8) error{ Fault, NameTooLong }![]const u8 {
    return copyUserCString(addr, buf);
}

fn copyUserCString(addr: usize, buf: []u8) error{ Fault, NameTooLong }![]const u8 {
    const space = userSpace();
    for (0..buf.len) |n| {
        var c: [1]u8 = undefined;
        try space.copyFromUser(c[0..], addr + n);
        if (c[0] == 0) return buf[0..n];
        buf[n] = c[0];
    }
    return error.NameTooLong;
}

const ArgvStorage = struct {
    n: usize = 0,
    bufs: [max_argv][max_arg]u8 = undefined,
    ptrs: [max_argv][]const u8 = undefined,

    fn add(self: *ArgvStorage, s: []const u8) error{ TooMany, NameTooLong }!void {
        if (self.n >= max_argv) return error.TooMany;
        if (s.len >= max_arg) return error.NameTooLong;
        @memcpy(self.bufs[self.n][0..s.len], s);
        self.ptrs[self.n] = self.bufs[self.n][0..s.len];
        self.n += 1;
    }

    fn slice(self: *ArgvStorage) []const []const u8 {
        return self.ptrs[0..self.n];
    }
};

fn copyUserArgv(addr: usize, path: []const u8, storage: *ArgvStorage) error{ Fault, NameTooLong, TooMany }![]const []const u8 {
    if (addr == 0) {
        try storage.add(path);
        return storage.slice();
    }
    if (!vmm.userRange(addr, @sizeOf(u64))) return error.Fault;

    const space = userSpace();
    for (0..max_argv + 1) |i| {
        var ptr_bytes: [@sizeOf(u64)]u8 = undefined;
        try space.copyFromUser(&ptr_bytes, addr + i * @sizeOf(u64));
        const ptr = std.mem.readInt(u64, &ptr_bytes, .little);
        if (ptr == 0) {
            if (i == 0) try storage.add(path);
            return storage.slice();
        }
        if (i == max_argv) return error.TooMany;
        var tmp: [max_arg]u8 = undefined;
        const s = try copyUserCString(@intCast(ptr), &tmp);
        try storage.add(s);
    }
    return error.TooMany;
}

fn currentProcess() *proc.Process {
    const thread = cpu.current().thread orelse @panic("syscall with no thread");
    return thread.parent;
}

fn userSpace() *vmm.VMM {
    return &currentProcess().vmm;
}

fn pathErr(err: error{ Fault, NameTooLong }) u64 {
    return switch (err) {
        error.Fault => errval(EFAULT),
        error.NameTooLong => errval(ENAMETOOLONG),
    };
}

fn argvErr(err: error{ Fault, NameTooLong, TooMany }) u64 {
    return switch (err) {
        error.Fault => errval(EFAULT),
        error.NameTooLong => errval(ENAMETOOLONG),
        error.TooMany => errval(E2BIG),
    };
}

fn spawnErr(err: anyerror) u64 {
    return switch (err) {
        error.NoEnt => errval(ENOENT),
        error.OutOfMemory => errval(ENOMEM),
        else => errval(ENOEXEC),
    };
}

fn errval(errno: i64) u64 {
    return @bitCast(-errno);
}
