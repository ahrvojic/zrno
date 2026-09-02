const logger = std.log.scoped(.syscall);

const std = @import("std");

const cpu = @import("cpu.zig");
const ramfs = @import("ramfs.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("../sched/proc.zig");
const sched = @import("../sched/sched.zig");
const tty = @import("../dev/tty.zig");
const user = @import("../user.zig");
const vmm = @import("../mm/vmm.zig");

// int 0x80: rax = number / return, rdi/rsi/rdx = args. Negative rax is -errno.
pub const nr_read: u64 = 0;
pub const nr_write: u64 = 1;
pub const nr_exit: u64 = 2;
pub const nr_yield: u64 = 3;
pub const nr_sleep: u64 = 4;
pub const nr_open: u64 = 5;
pub const nr_close: u64 = 6;
pub const nr_exec: u64 = 7;
pub const nr_wait: u64 = 8;

const max_io: usize = pmm.page_size;
const io_chunk: usize = 256;
const max_path: usize = 128;

const ENOENT: i64 = 2;
const ENOEXEC: i64 = 8;
const EBADF: i64 = 9;
const ECHILD: i64 = 10;
const ENOMEM: i64 = 12;
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
        nr_exec => sys_exec(ctx),
        nr_wait => sys_wait(ctx),
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
            if (i != 0) return errval(EBADF);
            var tmp: [io_chunk]u8 = undefined;
            const want = @min(tmp.len, len);
            const n = tty.read(tmp[0..want]);
            userSpace().copyToUser(addr, tmp[0..n]) catch |err| return copyErr(err);
            return n;
        },
        .file => |*f| {
            if (f.pos >= f.bytes.len) return 0;
            const n = @min(len, f.bytes.len - f.pos);
            userSpace().copyToUser(addr, f.bytes[f.pos..][0..n]) catch |err| return copyErr(err);
            f.pos += n;
            return n;
        },
    }
}

fn sys_write(ctx: *cpu.Context) u64 {
    const fd = ctx.rdi;
    const addr: usize = @intCast(ctx.rsi);
    const len: usize = @intCast(ctx.rdx);
    if (fd != 1 and fd != 2) return errval(EBADF);
    if (len == 0) return 0;
    if (len > max_io) return errval(EINVAL);
    if (!vmm.userRange(addr, len)) return errval(EFAULT);

    var tmp: [io_chunk]u8 = undefined;
    var copied: usize = 0;
    const space = userSpace();
    while (copied < len) {
        const n = @min(tmp.len, len - copied);
        space.copyFromUser(tmp[0..n], addr + copied) catch |err| {
            if (copied == 0) return copyErr(err);
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
    var fd: usize = 3;
    while (fd < proc.max_fds) : (fd += 1) {
        if (fds[fd] == .empty) {
            fds[fd] = .{ .file = .{ .bytes = data, .pos = 0 } };
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
    switch (slot.*) {
        .file => slot.* = .empty,
        else => return errval(EBADF),
    }
    return 0;
}

fn sys_exec(ctx: *cpu.Context) u64 {
    const addr: usize = @intCast(ctx.rdi);
    var buf: [max_path]u8 = undefined;
    const path = copyUserPath(addr, &buf) catch |err| return pathErr(err);
    const pid = user.spawnPath(path) catch |err| return spawnErr(err);
    return pid;
}

fn sys_wait(ctx: *cpu.Context) u64 {
    const code = sched.waitProcess(ctx.rdi) catch |err| return switch (err) {
        error.NoChild => errval(ECHILD),
        error.Invalid => errval(EINVAL),
    };
    return code;
}

fn copyUserPath(addr: usize, buf: *[max_path]u8) error{ Fault, OutOfMemory, NameTooLong }![]const u8 {
    const space = userSpace();
    var n: usize = 0;
    while (n < buf.len) {
        var c: [1]u8 = undefined;
        try space.copyFromUser(c[0..], addr + n);
        if (c[0] == 0) return buf[0..n];
        buf[n] = c[0];
        n += 1;
    }
    return error.NameTooLong;
}

fn currentProcess() *proc.Process {
    const thread = cpu.current().thread orelse @panic("syscall with no thread");
    return thread.parent;
}

fn userSpace() *vmm.VMM {
    return &currentProcess().vmm;
}

fn copyErr(err: error{ Fault, OutOfMemory }) u64 {
    return switch (err) {
        error.Fault => errval(EFAULT),
        error.OutOfMemory => errval(ENOMEM),
    };
}

fn pathErr(err: error{ Fault, OutOfMemory, NameTooLong }) u64 {
    return switch (err) {
        error.Fault => errval(EFAULT),
        error.OutOfMemory => errval(ENOMEM),
        error.NameTooLong => errval(ENAMETOOLONG),
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
