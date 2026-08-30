const logger = std.log.scoped(.syscall);

const std = @import("std");

const cpu = @import("cpu.zig");
const pmm = @import("../mm/pmm.zig");
const sched = @import("../sched/sched.zig");
const tty = @import("../dev/tty.zig");
const vmm = @import("../mm/vmm.zig");

// int 0x80: rax = number / return, rdi/rsi/rdx = args. Negative rax is -errno.
pub const nr_read: u64 = 0;
pub const nr_write: u64 = 1;
pub const nr_exit: u64 = 2;
pub const nr_yield: u64 = 3;
pub const nr_sleep: u64 = 4;

const max_io: u64 = pmm.page_size;
const io_chunk: usize = 256;

const EBADF: i64 = 9;
const ENOMEM: i64 = 12;
const EFAULT: i64 = 14;
const EINVAL: i64 = 22;
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
        else => errval(ENOSYS),
    };
}

fn sys_read(ctx: *cpu.Context) u64 {
    const fd = ctx.rdi;
    const addr = ctx.rsi;
    const len = ctx.rdx;
    if (fd != 0) return errval(EBADF);
    if (len == 0) return 0;
    if (len > max_io) return errval(EINVAL);
    if (!vmm.userRange(addr, len)) return errval(EFAULT);

    var tmp: [io_chunk]u8 = undefined;
    const want = @min(tmp.len, len);
    const n = tty.read(tmp[0..want]);
    userSpace().copyToUser(addr, tmp[0..n]) catch |err| return copyErr(err);
    return n;
}

fn sys_write(ctx: *cpu.Context) u64 {
    const fd = ctx.rdi;
    const addr = ctx.rsi;
    const len = ctx.rdx;
    if (fd != 1 and fd != 2) return errval(EBADF);
    if (len == 0) return 0;
    if (len > max_io) return errval(EINVAL);
    if (!vmm.userRange(addr, len)) return errval(EFAULT);

    var tmp: [io_chunk]u8 = undefined;
    var copied: u64 = 0;
    const space = userSpace();
    while (copied < len) {
        const n: usize = @intCast(@min(tmp.len, len - copied));
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

fn userSpace() *vmm.VMM {
    const thread = cpu.current().thread orelse @panic("syscall with no thread");
    return &thread.parent.vmm;
}

fn copyErr(err: error{ Fault, OutOfMemory }) u64 {
    return switch (err) {
        error.Fault => errval(EFAULT),
        error.OutOfMemory => errval(ENOMEM),
    };
}

fn errval(errno: i64) u64 {
    return @bitCast(-errno);
}
