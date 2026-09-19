const logger = std.log.scoped(.syscall);

const std = @import("std");

const cpu = @import("cpu.zig");
const exec = @import("../sched/exec.zig");
const file = @import("../fs/file.zig");
const pmm = @import("../mm/pmm.zig");
const pipe = @import("../fs/pipe.zig");
const proc = @import("../sched/proc.zig");
const ramfs = @import("../fs/ramfs.zig");
const reboot = @import("reboot.zig");
const sched = @import("../sched/sched.zig");
const tty = @import("../dev/tty.zig");
const vmm = @import("../mm/vmm.zig");

// SYSCALL: rax = number / return, rdi/rsi/rdx/r10/r8/r9 = args.
// RCX/R11 are clobbered (RIP/RFLAGS). Negative rax is -errno.
pub const nr_read: u64 = 0;
pub const nr_write: u64 = 1;
pub const nr_exit: u64 = 2;
pub const nr_yield: u64 = 3;
pub const nr_sleep: u64 = 4;
pub const nr_open: u64 = 5;
pub const nr_close: u64 = 6;
pub const nr_spawn: u64 = 7; // rdi=path, rsi=argv or 0, rdx/r10/r8=stdin/stdout/stderr
pub const nr_wait: u64 = 8; // rdi=pid (0 = any); rsi=status or 0; returns pid
pub const nr_getpid: u64 = 9;
pub const nr_getppid: u64 = 10;
pub const nr_exec: u64 = 11; // replace image, keep pid/fds; rsi=argv or 0
pub const nr_brk: u64 = 12; // rdi=0 query; else set program break, return it
pub const nr_mmap: u64 = 13; // rdi=addr (0), rsi=len, rdx=prot; anonymous, NX
pub const nr_reboot: u64 = 14; // never returns
pub const nr_poweroff: u64 = 15; // never returns
pub const nr_pipe: u64 = 16; // rdi = *[2]i64 {read, write}
pub const nr_getdents: u64 = 17; // rdi=fd, rsi=buf, rdx=len; returns bytes

pub const prot_read: u64 = 1;
pub const prot_write: u64 = 2;
pub const prot_exec: u64 = 4;

// Packed dirent. 128 bytes; name is NUL-terminated.
pub const dirent_name_max: usize = 120;
pub const Dirent = extern struct {
    size: u64,
    name: [dirent_name_max]u8,
};
comptime {
    std.debug.assert(@sizeOf(Dirent) == 128);
    std.debug.assert(ramfs.max_name < dirent_name_max);
}

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
const ENOTDIR: i64 = 20;
const EISDIR: i64 = 21;
const EINVAL: i64 = 22;
const EMFILE: i64 = 24;
const EPIPE: i64 = 32;
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
        nr_brk => sys_brk(ctx),
        nr_mmap => sys_mmap(ctx),
        nr_reboot => reboot.perform(),
        nr_poweroff => reboot.poweroff(),
        nr_pipe => sys_pipe(ctx),
        nr_getdents => sys_getdents(ctx),
        else => errval(ENOSYS),
    };
}

fn sys_read(ctx: *cpu.Context) u64 {
    const addr: usize = @intCast(ctx.rsi);
    const len: usize = @intCast(ctx.rdx);
    if (checkIo(addr, len)) |r| return r;
    const f = fdFile(ctx.rdi) orelse return errval(EBADF);
    switch (f.kind) {
        .tty => {
            var tmp: [io_chunk]u8 = undefined;
            const n = tty.peek(tmp[0..@min(tmp.len, len)]);
            userSpace().copyToUser(addr, tmp[0..n]) catch return errval(EFAULT);
            tty.consume(n);
            return n;
        },
        .file => |*open| {
            if (open.pos >= open.bytes.len) return 0;
            const n = @min(len, open.bytes.len - open.pos);
            userSpace().copyToUser(addr, open.bytes[open.pos..][0..n]) catch return errval(EFAULT);
            open.pos += n;
            return n;
        },
        .dir => return errval(EISDIR),
        .pipe_write => return errval(EBADF),
        .pipe_read => |p| {
            var tmp: [io_chunk]u8 = undefined;
            const n = p.peek(tmp[0..@min(tmp.len, len)]);
            userSpace().copyToUser(addr, tmp[0..n]) catch return errval(EFAULT);
            p.consume(n);
            return n;
        },
    }
}

fn sys_write(ctx: *cpu.Context) u64 {
    const addr: usize = @intCast(ctx.rsi);
    const len: usize = @intCast(ctx.rdx);
    if (checkIo(addr, len)) |r| return r;
    const f = fdFile(ctx.rdi) orelse return errval(EBADF);
    switch (f.kind) {
        .file => return errval(EACCES),
        .dir => return errval(EISDIR),
        .pipe_read => return errval(EBADF),
        .pipe_write => |p| {
            var tmp: [io_chunk]u8 = undefined;
            const n = @min(tmp.len, len);
            userSpace().copyFromUser(tmp[0..n], addr) catch return errval(EFAULT);
            return p.write(tmp[0..n]) catch return errval(EPIPE);
        },
        .tty => {
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
        },
    }
}

fn sys_exit(ctx: *cpu.Context) u64 {
    const process = currentProcess();
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
    var buf: [max_path]u8 = undefined;
    const path = copyUserCString(@intCast(ctx.rdi), &buf) catch |err| return pathErr(err);
    const kind: file.File.Kind = if (ramfs.isRoot(path))
        .{ .dir = .{ .pos = 0 } }
    else
        .{ .file = .{ .bytes = ramfs.lookup(path) orelse return errval(ENOENT), .pos = 0 } };
    const fd = firstFreeFd(0) orelse return errval(EMFILE);
    currentProcess().fds[fd] = file.File.create(kind) catch return errval(ENOMEM);
    return fd;
}

fn sys_close(ctx: *cpu.Context) u64 {
    const slot = fdSlot(ctx.rdi) orelse return errval(EBADF);
    const f = slot.* orelse return errval(EBADF);
    slot.* = null;
    f.release();
    return 0;
}

fn sys_spawn(ctx: *cpu.Context) u64 {
    var buf: [max_path]u8 = undefined;
    const path = copyUserCString(@intCast(ctx.rdi), &buf) catch |err| return pathErr(err);
    var storage: ArgvStorage = .{};
    const argv = copyUserArgv(ctx.rsi, path, &storage) catch |err| return argvErr(err);
    return exec.spawnPathArgv(path, argv, ctx.rdx, ctx.r10, ctx.r8) catch |err| return spawnErr(err);
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
        var code: u64 = result.code;
        userSpace().copyToUser(status_addr, std.mem.asBytes(&code)) catch return errval(EFAULT);
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
    var buf: [max_path]u8 = undefined;
    const path = copyUserCString(@intCast(ctx.rdi), &buf) catch |err| return pathErr(err);
    var storage: ArgvStorage = .{};
    const argv = copyUserArgv(ctx.rsi, path, &storage) catch |err| return argvErr(err);
    exec.execPath(currentProcess(), ctx, path, argv) catch |err| return spawnErr(err);
    return 0;
}

fn sys_brk(ctx: *cpu.Context) u64 {
    return sched.setBrk(@intCast(ctx.rdi)) catch |err| mmErr(err);
}

fn sys_mmap(ctx: *cpu.Context) u64 {
    const addr: usize = @intCast(ctx.rdi);
    const len: usize = @intCast(ctx.rsi);
    const prot = ctx.rdx;
    if (addr != 0) return errval(EINVAL);
    if (len == 0) return errval(EINVAL);
    if (prot & prot_exec != 0) return errval(EINVAL);
    if (prot & (prot_read | prot_write) == 0) return errval(EINVAL);
    return sched.mapAnon(len, prot & prot_write != 0) catch |err| mmErr(err);
}

fn sys_getdents(ctx: *cpu.Context) u64 {
    const f = fdFile(ctx.rdi) orelse return errval(EBADF);
    const dir = switch (f.kind) {
        .dir => |*d| d,
        else => return errval(ENOTDIR),
    };
    const addr: usize = @intCast(ctx.rsi);
    const len: usize = @intCast(ctx.rdx);
    if (checkIo(addr, len)) |r| return r;
    if (len < @sizeOf(Dirent)) return errval(EINVAL);

    const ents = ramfs.entries();
    var copied: usize = 0;
    const space = userSpace();
    while (dir.pos < ents.len) {
        if (copied + @sizeOf(Dirent) > len) break;
        const e = ents[dir.pos];
        var de: Dirent = .{ .size = e.data.len, .name = @splat(0) };
        const n = @min(e.name().len, de.name.len - 1);
        @memcpy(de.name[0..n], e.name()[0..n]);
        space.copyToUser(addr + copied, std.mem.asBytes(&de)) catch {
            if (copied == 0) return errval(EFAULT);
            return copied;
        };
        copied += @sizeOf(Dirent);
        dir.pos += 1;
    }
    return copied;
}

fn sys_pipe(ctx: *cpu.Context) u64 {
    const addr: usize = @intCast(ctx.rdi);
    if (!vmm.userRange(addr, 2 * @sizeOf(i64))) return errval(EFAULT);
    const pair = twoFreeFds() orelse return errval(EMFILE);
    const p = pipe.Pipe.create() catch return errval(ENOMEM);
    const r = file.File.create(.{ .pipe_read = p }) catch {
        p.destroy();
        return errval(ENOMEM);
    };
    const w = file.File.create(.{ .pipe_write = p }) catch {
        r.release();
        return errval(ENOMEM);
    };
    var fds_out: [2]i64 = .{ @intCast(pair[0]), @intCast(pair[1]) };
    userSpace().copyToUser(addr, std.mem.asBytes(&fds_out)) catch {
        r.release();
        w.release();
        return errval(EFAULT);
    };
    const fds = &currentProcess().fds;
    fds[pair[0]] = r;
    fds[pair[1]] = w;
    return 0;
}

fn firstFreeFd(start: usize) ?usize {
    const fds = &currentProcess().fds;
    for (fds[start..], start..) |slot, fd| {
        if (slot == null) return fd;
    }
    return null;
}

fn twoFreeFds() ?[2]usize {
    const a = firstFreeFd(0) orelse return null;
    const b = firstFreeFd(a + 1) orelse return null;
    return .{ a, b };
}

fn copyUserCString(addr: usize, buf: []u8) error{ Fault, NameTooLong }![]const u8 {
    const space = userSpace();
    for (0..buf.len) |n| {
        try space.copyFromUser(buf[n .. n + 1], addr + n);
        if (buf[n] == 0) return buf[0..n];
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

    const space = userSpace();
    for (0..max_argv + 1) |i| {
        var ptr: u64 = undefined;
        try space.copyFromUser(std.mem.asBytes(&ptr), addr + i * @sizeOf(u64));
        if (ptr == 0) {
            if (i == 0) try storage.add(path);
            return storage.slice();
        }
        if (i == max_argv) return error.TooMany;
        var tmp: [max_arg]u8 = undefined;
        try storage.add(try copyUserCString(@intCast(ptr), &tmp));
    }
    unreachable;
}

fn currentProcess() *proc.Process {
    const thread = cpu.current().thread orelse @panic("syscall with no thread");
    return thread.parent;
}

fn fdSlot(fd: u64) ?*file.Fd {
    if (fd >= file.max_fds) return null;
    return &currentProcess().fds[@intCast(fd)];
}

fn fdFile(fd: u64) ?*file.File {
    const slot = fdSlot(fd) orelse return null;
    return slot.*;
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

fn spawnErr(err: exec.SpawnError) u64 {
    return switch (err) {
        error.NoEnt => errval(ENOENT),
        error.OutOfMemory => errval(ENOMEM),
        error.BadElf => errval(ENOEXEC),
        error.BadFd => errval(EBADF),
    };
}

fn mmErr(err: error{ Invalid, OutOfMemory }) u64 {
    return switch (err) {
        error.Invalid => errval(EINVAL),
        error.OutOfMemory => errval(ENOMEM),
    };
}

fn checkIo(addr: usize, len: usize) ?u64 {
    if (len == 0) return 0;
    if (len > max_io) return errval(EINVAL);
    if (!vmm.userRange(addr, len)) return errval(EFAULT);
    return null;
}

fn errval(errno: i64) u64 {
    return @bitCast(-errno);
}
