const logger = std.log.scoped(.syscall);

const std = @import("std");

const cpu = @import("cpu.zig");
const exec = @import("../sched/exec.zig");
const file = @import("../fs/file.zig");
const pmm = @import("../mm/pmm.zig");
const pipe = @import("../fs/pipe.zig");
const vfs = @import("../fs/vfs.zig");
const reboot = @import("reboot.zig");
const sched = @import("../sched/sched.zig");
const state = @import("../sched/state.zig");
const tty = @import("../dev/tty.zig");
const vmm = @import("../mm/vmm.zig");

// SYSCALL: rax = number / return, rdi/rsi/rdx/r10/r8/r9 = args.
// RCX/R11 are clobbered (RIP/RFLAGS). Negative rax is -errno.
// Blocks of 16. Append a new call at the end of its block.
// Same numbers in user/src/lib/sys.zig.
// 0x00 process
pub const nr_exit: u64 = 0x00;
pub const nr_spawn: u64 = 0x01; // rdi/rsi=path, rdx/r10=argv ptr/n, r8=*[3]u64 stdio
pub const nr_wait: u64 = 0x02; // rdi=pid (0 = any); rsi=status or 0; returns pid
pub const nr_getpid: u64 = 0x03;
pub const nr_getppid: u64 = 0x04;
pub const nr_ps: u64 = 0x05; // rdi=buf, rsi=len; returns bytes of PsInfo (one per thread)
// 0x10 thread
pub const nr_thread: u64 = 0x10; // rdi=entry, rsi=arg; new thread in this process, returns tid
pub const nr_thread_exit: u64 = 0x11; // rdi=code; last thread exits the process
pub const nr_gettid: u64 = 0x12;
pub const nr_yield: u64 = 0x13;
pub const nr_wait_word: u64 = 0x14; // rdi=addr, rsi=expected; sleep while the u64 at addr equals it
pub const nr_wake_word: u64 = 0x15; // rdi=addr; wake this process's waiters; returns how many
// 0x20 memory
pub const nr_brk: u64 = 0x20; // rdi=0 query; else set program break, return it
pub const nr_mmap: u64 = 0x21; // rdi=addr (0), rsi=len, rdx=prot; anonymous, NX
pub const nr_munmap: u64 = 0x22; // rdi=addr, rsi=len; one whole mapping from mmap
// 0x30 file
pub const nr_open: u64 = 0x30; // rdi/rsi=path, rdx=flags (0 = read)
pub const nr_close: u64 = 0x31;
pub const nr_read: u64 = 0x32;
pub const nr_write: u64 = 0x33;
pub const nr_lseek: u64 = 0x34; // rdi=fd, rsi=offset i64, rdx=whence; returns pos
pub const nr_pipe: u64 = 0x35; // rdi = *[2]i64 {read, write}
pub const nr_getdents: u64 = 0x36; // rdi=fd, rsi=buf, rdx=len; returns bytes
pub const nr_unlink: u64 = 0x37; // rdi/rsi=path
pub const nr_mkdir: u64 = 0x38; // rdi/rsi=path
pub const nr_rmdir: u64 = 0x39; // rdi/rsi=path; empty directory only
pub const nr_rename: u64 = 0x3a; // rdi/rsi=old path, rdx/r10=new path
pub const nr_chdir: u64 = 0x3b; // rdi/rsi=path
pub const nr_getcwd: u64 = 0x3c; // rdi=buf, rsi=len; returns the path length
// 0x40 clock
pub const nr_sleep: u64 = 0x40;
pub const nr_uptime: u64 = 0x41; // returns ns since boot
// 0x50 machine
pub const nr_reboot: u64 = 0x50; // never returns
pub const nr_poweroff: u64 = 0x51; // never returns

pub const prot_read: u64 = 1;
pub const prot_write: u64 = 2;
pub const prot_exec: u64 = 4;

pub const seek_set: u64 = 0;
pub const seek_cur: u64 = 1;
pub const seek_end: u64 = 2;

// open flags. Zero reads an existing file. Write truncates a ramfs file.
// Create makes a missing file and requires write. Keep, with write, does not
// truncate.
pub const open_write: u64 = 1;
pub const open_create: u64 = 2;
pub const open_keep: u64 = 4;

// Packed dirent. 128 bytes; name is `name_len` bytes, not NUL-terminated.
pub const dirent_name_max: usize = 112;
pub const Dirent = extern struct {
    size: u64,
    name_len: u64,
    name: [dirent_name_max]u8,
};
comptime {
    std.debug.assert(@sizeOf(Dirent) == 128);
    std.debug.assert(vfs.max_name <= dirent_name_max);
}

// Thread state in PsInfo.state. A zombie process has no threads left, so
// it is one row with ps_zombie and tid 0. Same values in user/src/lib/sys.zig.
pub const ps_ready: u64 = 0;
pub const ps_running: u64 = 1;
pub const ps_sleeping: u64 = 2;
pub const ps_waiting: u64 = 3;
pub const ps_zombie: u64 = 4;
pub const PsInfo = extern struct {
    tid: u64,
    pid: u64,
    ppid: u64,
    state: u64,
};
comptime {
    std.debug.assert(@sizeOf(PsInfo) == 32);
}

const max_io: usize = pmm.page_size;
const max_ps = max_io / @sizeOf(PsInfo);
const io_chunk: usize = 256;
const max_path: usize = 128;
const max_argv: usize = state.max_argv;
const max_arg: usize = 128;

const ENOENT: i64 = 2;
const E2BIG: i64 = 7;
const ENOEXEC: i64 = 8;
const EBADF: i64 = 9;
const ECHILD: i64 = 10;
const ENOMEM: i64 = 12;
const EACCES: i64 = 13;
const EFAULT: i64 = 14;
const EEXIST: i64 = 17;
const ENOTDIR: i64 = 20;
const EISDIR: i64 = 21;
const EINVAL: i64 = 22;
const EMFILE: i64 = 24;
const ESPIPE: i64 = 29;
const EROFS: i64 = 30;
const EPIPE: i64 = 32;
const ERANGE: i64 = 34;
const ENAMETOOLONG: i64 = 36;
const ENOSYS: i64 = 38;
const ENOTEMPTY: i64 = 39;

pub fn handle(ctx: *cpu.Context) void {
    ctx.rax = dispatch(ctx);
}

fn dispatch(ctx: *cpu.Context) u64 {
    return switch (ctx.rax) {
        nr_exit => sys_exit(ctx),
        nr_spawn => sys_spawn(ctx),
        nr_wait => sys_wait(ctx),
        nr_getpid => sys_getpid(),
        nr_getppid => sys_getppid(),
        nr_ps => sys_ps(ctx),
        nr_thread => sys_thread(ctx),
        nr_thread_exit => sys_thread_exit(ctx),
        nr_gettid => sys_gettid(),
        nr_yield => sys_yield(),
        nr_wait_word => sys_wait_word(ctx),
        nr_wake_word => sys_wake_word(ctx),
        nr_brk => sys_brk(ctx),
        nr_mmap => sys_mmap(ctx),
        nr_munmap => sys_munmap(ctx),
        nr_open => sys_open(ctx),
        nr_close => sys_close(ctx),
        nr_read => sys_read(ctx),
        nr_write => sys_write(ctx),
        nr_lseek => sys_lseek(ctx),
        nr_pipe => sys_pipe(ctx),
        nr_getdents => sys_getdents(ctx),
        nr_unlink => sysPath(ctx, vfs.unlinkPathFrom),
        nr_mkdir => sysPath(ctx, vfs.mkdirPathFrom),
        nr_rmdir => sysPath(ctx, vfs.rmdirPathFrom),
        nr_rename => sys_rename(ctx),
        nr_chdir => sys_chdir(ctx),
        nr_getcwd => sys_getcwd(ctx),
        nr_sleep => sys_sleep(ctx),
        nr_uptime => sys_uptime(),
        nr_reboot => reboot.perform(),
        nr_poweroff => reboot.poweroff(),
        else => errval(ENOSYS),
    };
}

fn sys_read(ctx: *cpu.Context) u64 {
    const addr: usize = @intCast(ctx.rsi);
    const len: usize = @intCast(ctx.rdx);
    if (checkIo(len)) |r| return r;
    const f = fdFile(ctx.rdi) orelse return errval(EBADF);
    switch (f.kind) {
        .tty => return readPeek(tty, addr, len),
        .file => |*open| {
            const data = open.node.bytes() orelse unreachable;
            if (open.pos >= data.len) return 0;
            const n = @min(len, data.len - open.pos);
            userSpace().copyToUser(addr, data[open.pos..][0..n]) catch return errval(EFAULT);
            open.pos += n;
            return n;
        },
        .dir => return errval(EISDIR),
        .pipe_write => return errval(EBADF),
        .pipe_read => |p| return readPeek(p, addr, len),
    }
}

fn readPeek(src: anytype, addr: usize, len: usize) u64 {
    var tmp: [io_chunk]u8 = undefined;
    const n = src.peek(tmp[0..@min(tmp.len, len)]);
    userSpace().copyToUser(addr, tmp[0..n]) catch return errval(EFAULT);
    src.consume(n);
    return n;
}

fn sys_write(ctx: *cpu.Context) u64 {
    const addr: usize = @intCast(ctx.rsi);
    const len: usize = @intCast(ctx.rdx);
    if (checkIo(len)) |r| return r;
    const f = fdFile(ctx.rdi) orelse return errval(EBADF);
    switch (f.kind) {
        .file => |*open| {
            if (!open.can_write) return errval(EACCES);
            return writeFile(open, addr, len);
        },
        .dir => return errval(EISDIR),
        .pipe_read => return errval(EBADF),
        .pipe_write => |p| return writeUser(addr, len, p),
        .tty => return writeUser(addr, len, TtySink{}),
    }
}

const TtySink = struct {
    fn write(_: @This(), buf: []const u8) error{Broken}!usize {
        tty.writeBytes(buf);
        return buf.len;
    }
};

fn writeUser(addr: usize, len: usize, sink: anytype) u64 {
    var tmp: [io_chunk]u8 = undefined;
    var copied: usize = 0;
    const space = userSpace();
    while (copied < len) {
        const n = @min(tmp.len, len - copied);
        space.copyFromUser(tmp[0..n], addr + copied) catch {
            if (copied == 0) return errval(EFAULT);
            return copied;
        };
        var off: usize = 0;
        while (off < n) {
            const w = sink.write(tmp[off..n]) catch {
                if (copied == 0) return errval(EPIPE);
                return copied;
            };
            off += w;
            copied += w;
        }
    }
    return copied;
}

fn sys_exit(ctx: *cpu.Context) u64 {
    const process = cpu.currentProcess();
    if (process.pid == 0) @panic("kernel process exit");
    const code: u8 = @truncate(ctx.rdi);
    logger.info("pid {d} exit {d}", .{ process.pid, code });
    sched.exitProcess(process, code);
    sched.yield();
    unreachable;
}

fn sys_thread(ctx: *cpu.Context) u64 {
    const process = cpu.currentProcess();
    if (process.pid == state.kernel_pid) return errval(EINVAL);
    const entry: usize = @intCast(ctx.rdi);
    if (!userText(entry)) return errval(EINVAL);
    const thread = sched.createUserThread(process, entry, ctx.rsi) catch return errval(ENOMEM);
    return thread.tid;
}

fn sys_thread_exit(ctx: *cpu.Context) u64 {
    if (cpu.currentProcess().pid == state.kernel_pid) @panic("kernel process exit");
    sched.exitThread(@truncate(ctx.rdi));
}

fn sys_gettid() u64 {
    return cpu.currentThread().tid;
}

fn userText(addr: usize) bool {
    return addr >= pmm.page_size and addr < vmm.user_space_end;
}

fn sys_yield() u64 {
    sched.yield();
    return 0;
}

fn sys_wait_word(ctx: *cpu.Context) u64 {
    const addr = userWord(ctx.rdi) orelse return errval(EINVAL);
    var word: u64 = undefined;
    userSpace().copyFromUser(std.mem.asBytes(&word), addr) catch return errval(EFAULT);
    // Mismatch returns without sleeping. The caller rechecks the word.
    if (word != ctx.rsi) return 0;
    sched.wait(@ptrFromInt(addr));
    return 0;
}

fn sys_wake_word(ctx: *cpu.Context) u64 {
    const addr = userWord(ctx.rdi) orelse return errval(EINVAL);
    return sched.wakeWord(cpu.currentProcess(), addr);
}

fn userWord(raw: u64) ?usize {
    if (cpu.currentProcess().pid == state.kernel_pid) return null;
    const addr: usize = @intCast(raw);
    if (!std.mem.isAligned(addr, @sizeOf(u64))) return null;
    if (!vmm.userRange(addr, @sizeOf(u64))) return null;
    return addr;
}

fn sys_sleep(ctx: *cpu.Context) u64 {
    sched.sleep(ctx.rdi);
    return 0;
}

fn sys_uptime() u64 {
    if (cpu.nsSinceBoot()) |ns| return ns;
    return sched.ticksSinceBoot() * (1_000_000_000 / sched.tick_hz);
}

fn sys_open(ctx: *cpu.Context) u64 {
    var buf: [max_path]u8 = undefined;
    const path = copyUserString(ctx.rdi, ctx.rsi, &buf) catch |err| return switch (err) {
        error.Fault => errval(EFAULT),
        error.NameTooLong => errval(ENAMETOOLONG),
    };
    const flags = ctx.rdx;
    if (flags & ~(open_write | open_create | open_keep) != 0) return errval(EINVAL);
    const want_write = flags & open_write != 0;
    const want_create = flags & open_create != 0;
    const want_keep = flags & open_keep != 0;
    if (want_keep and !want_write) return errval(EINVAL);
    const mode: vfs.Mode = if (!want_write) .read else if (want_keep) .keep else .write;
    const opened = vfs.openPathFrom(cpu.currentProcess().cwd, path, mode, want_create) catch |err| return fsErr(err);
    const kind: file.File.Kind = if (opened.node.isDir())
        .{ .dir = .{ .node = opened.node, .pos = 0 } }
    else
        .{ .file = .{ .node = opened.node, .pos = 0, .can_write = opened.can_write } };
    const fd = firstFreeFd(0) orelse return errval(EMFILE);
    cpu.currentProcess().fds[fd] = file.File.create(kind) catch return errval(ENOMEM);
    return fd;
}

fn sys_rename(ctx: *cpu.Context) u64 {
    var old_buf: [max_path]u8 = undefined;
    var new_buf: [max_path]u8 = undefined;
    const old_path = copyUserString(ctx.rdi, ctx.rsi, &old_buf) catch |err| return switch (err) {
        error.Fault => errval(EFAULT),
        error.NameTooLong => errval(ENAMETOOLONG),
    };
    const new_path = copyUserString(ctx.rdx, ctx.r10, &new_buf) catch |err| return switch (err) {
        error.Fault => errval(EFAULT),
        error.NameTooLong => errval(ENAMETOOLONG),
    };
    vfs.renamePathFrom(cpu.currentProcess().cwd, old_path, new_path) catch |err| return fsErr(err);
    return 0;
}

fn sys_chdir(ctx: *cpu.Context) u64 {
    var buf: [max_path]u8 = undefined;
    const path = copyUserString(ctx.rdi, ctx.rsi, &buf) catch |err| return switch (err) {
        error.Fault => errval(EFAULT),
        error.NameTooLong => errval(ENAMETOOLONG),
    };
    const process = cpu.currentProcess();
    const node = vfs.walkFrom(process.cwd, path) catch |err| return fsErr(err);
    if (!node.isDir()) return errval(ENOTDIR);
    node.retain();
    process.cwd.release();
    process.cwd = node;
    return 0;
}

fn sys_getcwd(ctx: *cpu.Context) u64 {
    var buf: [max_path]u8 = undefined;
    const n = vfs.pathOf(cpu.currentProcess().cwd, &buf) catch |err| return switch (err) {
        error.NoEnt => errval(ENOENT),
        error.NameTooLong => errval(ENAMETOOLONG),
    };
    // A path is at least `/`, so an empty buffer lands here too.
    if (n > ctx.rsi) return errval(ERANGE);
    userSpace().copyToUser(ctx.rdi, buf[0..n]) catch return errval(EFAULT);
    return n;
}

fn sysPath(ctx: *cpu.Context, op: *const fn (*vfs.Node, []const u8) vfs.Error!void) u64 {
    var buf: [max_path]u8 = undefined;
    const path = copyUserString(ctx.rdi, ctx.rsi, &buf) catch |err| return switch (err) {
        error.Fault => errval(EFAULT),
        error.NameTooLong => errval(ENAMETOOLONG),
    };
    op(cpu.currentProcess().cwd, path) catch |err| return fsErr(err);
    return 0;
}

fn sys_close(ctx: *cpu.Context) u64 {
    const slot = fdSlot(ctx.rdi) orelse return errval(EBADF);
    const f = slot.* orelse return errval(EBADF);
    slot.* = null;
    f.release();
    return 0;
}

fn sys_lseek(ctx: *cpu.Context) u64 {
    const f = fdFile(ctx.rdi) orelse return errval(EBADF);
    const open = switch (f.kind) {
        .file => |*o| o,
        .dir => return errval(EISDIR),
        .tty, .pipe_read, .pipe_write => return errval(ESPIPE),
    };
    const base: u64 = switch (ctx.rdx) {
        seek_set => 0,
        seek_cur => open.pos,
        seek_end => open.node.size(),
        else => return errval(EINVAL),
    };
    const base_i = std.math.cast(i64, base) orelse return errval(EINVAL);
    const offset: i64 = @bitCast(ctx.rsi);
    const new_pos = std.math.add(i64, base_i, offset) catch return errval(EINVAL);
    if (new_pos < 0) return errval(EINVAL);
    open.pos = @intCast(new_pos);
    return open.pos;
}

fn sys_spawn(ctx: *cpu.Context) u64 {
    var buf: [max_path]u8 = undefined;
    var storage: ArgvStorage = .{};
    const pa = copyPathArgv(ctx, &buf, &storage) catch |err| return argvErr(err);
    var stdio: [3]u64 = undefined;
    userSpace().copyFromUser(std.mem.asBytes(&stdio), @intCast(ctx.r8)) catch return errval(EFAULT);
    return exec.spawnPathArgv(pa.path, pa.argv, stdio[0], stdio[1], stdio[2]) catch |err| return spawnErr(err);
}

fn sys_wait(ctx: *cpu.Context) u64 {
    const status_addr: usize = @intCast(ctx.rsi);
    // Probe writable before reaping: userRange is not enough (RO/unmapped).
    if (status_addr != 0) {
        var zero: u64 = 0;
        userSpace().copyToUser(status_addr, std.mem.asBytes(&zero)) catch return errval(EFAULT);
    }
    const result = sched.waitProcess(ctx.rdi) catch |err| return switch (err) {
        error.NoChild => errval(ECHILD),
        error.Invalid => errval(EINVAL),
    };
    if (status_addr != 0) {
        var code: u64 = result.code;
        userSpace().copyToUser(status_addr, std.mem.asBytes(&code)) catch return result.pid;
    }
    return result.pid;
}

fn sys_getpid() u64 {
    return cpu.currentProcess().pid;
}

fn sys_getppid() u64 {
    return cpu.currentProcess().parent;
}

fn psState(snap: sched.PsSnap) u64 {
    const status = snap.status orelse return ps_zombie;
    return switch (status) {
        .ready => ps_ready,
        .running => ps_running,
        .sleeping => ps_sleeping,
        .waiting => ps_waiting,
    };
}

fn sys_ps(ctx: *cpu.Context) u64 {
    const addr: usize = @intCast(ctx.rdi);
    const len: usize = @intCast(ctx.rsi);
    // checkIo returns 0 for len == 0, and callers treat 0 as the end of the list.
    if (len < @sizeOf(PsInfo)) return errval(EINVAL);
    if (checkIo(len)) |r| return r;

    var snap: [max_ps]sched.PsSnap = undefined;
    const n = sched.snapshotPs(snap[0..@min(snap.len, len / @sizeOf(PsInfo))]);
    var tmp: [max_ps]PsInfo = undefined;
    for (snap[0..n], 0..) |s, i| {
        tmp[i] = .{
            .tid = s.tid,
            .pid = s.pid,
            .ppid = s.ppid,
            .state = psState(s),
        };
    }
    userSpace().copyToUser(addr, std.mem.sliceAsBytes(tmp[0..n])) catch return errval(EFAULT);
    return n * @sizeOf(PsInfo);
}

fn sys_brk(ctx: *cpu.Context) u64 {
    return sched.setBrk(@intCast(ctx.rdi)) catch |err| mmErr(err);
}

fn sys_mmap(ctx: *cpu.Context) u64 {
    const addr: usize = @intCast(ctx.rdi);
    const len: usize = @intCast(ctx.rsi);
    const prot = ctx.rdx;
    if (addr != 0) return errval(EINVAL);
    if (prot & prot_exec != 0) return errval(EINVAL);
    if (prot & (prot_read | prot_write) == 0) return errval(EINVAL);
    return sched.mapAnon(len, prot & prot_write != 0) catch |err| mmErr(err);
}

fn sys_munmap(ctx: *cpu.Context) u64 {
    const addr: usize = @intCast(ctx.rdi);
    const len: usize = @intCast(ctx.rsi);
    sched.unmapAnon(addr, len) catch |err| return mmErr(err);
    return 0;
}

fn sys_getdents(ctx: *cpu.Context) u64 {
    const f = fdFile(ctx.rdi) orelse return errval(EBADF);
    const dir = switch (f.kind) {
        .dir => |*d| d,
        else => return errval(ENOTDIR),
    };
    const addr: usize = @intCast(ctx.rsi);
    const len: usize = @intCast(ctx.rdx);
    // checkIo returns 0 for len == 0, and callers treat 0 as the end of the list.
    if (len < @sizeOf(Dirent)) return errval(EINVAL);
    if (checkIo(len)) |r| return r;

    var copied: usize = 0;
    const space = userSpace();
    while (dir.node.childAt(dir.pos)) |e| {
        if (copied + @sizeOf(Dirent) > len) break;
        const n = @min(e.name().len, dirent_name_max);
        var de: Dirent = .{ .size = e.size(), .name_len = n, .name = @splat(0) };
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
    const pair = twoFreeFds() orelse return errval(EMFILE);
    const rw = createPipePair() catch return errval(ENOMEM);
    var fds_out: [2]i64 = .{ @intCast(pair[0]), @intCast(pair[1]) };
    userSpace().copyToUser(addr, std.mem.asBytes(&fds_out)) catch {
        rw[0].release();
        rw[1].release();
        return errval(EFAULT);
    };
    const fds = &cpu.currentProcess().fds;
    fds[pair[0]] = rw[0];
    fds[pair[1]] = rw[1];
    return 0;
}

fn createPipePair() error{OutOfMemory}![2]*file.File {
    const p = try pipe.Pipe.create();
    const r = file.File.create(.{ .pipe_read = p }) catch {
        p.destroy();
        return error.OutOfMemory;
    };
    errdefer r.release();
    const w = try file.File.create(.{ .pipe_write = p });
    return .{ r, w };
}

fn firstFreeFd(start: usize) ?usize {
    const fds = &cpu.currentProcess().fds;
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

const UserStr = extern struct { ptr: u64, len: u64 };

fn copyUserString(ptr: u64, len: u64, buf: []u8) error{ Fault, NameTooLong }![]const u8 {
    if (len > buf.len) return error.NameTooLong;
    const n: usize = @intCast(len);
    if (n == 0) return buf[0..0];
    try userSpace().copyFromUser(buf[0..n], @intCast(ptr));
    return buf[0..n];
}

const ArgvStorage = struct {
    n: usize = 0,
    bufs: [max_argv][max_arg]u8 = undefined,
    ptrs: [max_argv][]const u8 = undefined,

    fn slice(self: *ArgvStorage) []const []const u8 {
        return self.ptrs[0..self.n];
    }
};

fn copyPathArgv(ctx: *const cpu.Context, path_buf: []u8, storage: *ArgvStorage) error{ Fault, NameTooLong, TooMany }!struct {
    path: []const u8,
    argv: []const []const u8,
} {
    const path = try copyUserString(ctx.rdi, ctx.rsi, path_buf);
    const argv = try copyUserArgv(ctx.rdx, ctx.r10, storage);
    return .{ .path = path, .argv = argv };
}

fn copyUserArgv(addr: u64, n: u64, storage: *ArgvStorage) error{ Fault, NameTooLong, TooMany }![]const []const u8 {
    if (n > max_argv) return error.TooMany;
    if (n == 0) return storage.slice();
    const base: usize = @intCast(addr);
    const space = userSpace();
    for (0..@intCast(n)) |i| {
        var s: UserStr = undefined;
        try space.copyFromUser(std.mem.asBytes(&s), base + i * @sizeOf(UserStr));
        const str = try copyUserString(s.ptr, s.len, &storage.bufs[storage.n]);
        storage.ptrs[storage.n] = str;
        storage.n += 1;
    }
    return storage.slice();
}

fn fdSlot(fd: u64) ?*file.Fd {
    if (fd >= file.max_fds) return null;
    return &cpu.currentProcess().fds[@intCast(fd)];
}

fn fdFile(fd: u64) ?*file.File {
    const slot = fdSlot(fd) orelse return null;
    return slot.*;
}

fn userSpace() *vmm.VMM {
    return &cpu.currentProcess().vmm;
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

fn checkIo(len: usize) ?u64 {
    if (len == 0) return 0;
    if (len > max_io) return errval(EINVAL);
    return null;
}

fn writeFile(open: *file.OpenFile, addr: usize, len: usize) u64 {
    var tmp: [io_chunk]u8 = undefined;
    var copied: usize = 0;
    const space = userSpace();
    while (copied < len) {
        const n = @min(tmp.len, len - copied);
        space.copyFromUser(tmp[0..n], addr + copied) catch {
            if (copied == 0) return errval(EFAULT);
            return copied;
        };
        const w = open.node.writeAt(open.pos, tmp[0..n]) catch |err| {
            if (copied == 0) return fsErr(err);
            return copied;
        };
        open.pos += w;
        copied += w;
    }
    return copied;
}

fn fsErr(err: vfs.Error) u64 {
    return errval(switch (err) {
        error.NoEnt => ENOENT,
        error.NotDir => ENOTDIR,
        error.IsDir => EISDIR,
        error.NotEmpty => ENOTEMPTY,
        error.ReadOnly => EROFS,
        error.Exists => EEXIST,
        error.BadName => EINVAL,
        error.Invalid => EINVAL,
        error.TooBig => EINVAL,
        error.OutOfMemory => ENOMEM,
    });
}

fn errval(errno: i64) u64 {
    return @bitCast(-errno);
}
