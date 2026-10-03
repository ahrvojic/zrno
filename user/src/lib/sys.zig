// User SYSCALL ABI. Numbers match kernel/src/sys/syscall.zig.
// RCX and R11 are clobbered (hardware saves RIP/RFLAGS there).
// Args are rdi, rsi, rdx, r10, r8, r9 (r10 not rcx: SYSCALL overwrites rcx).
// Blocks of 16. Append a new call at the end of its block.
// 0x00 process
pub const nr_exit: u64 = 0x00;
pub const nr_spawn: u64 = 0x01;
pub const nr_wait: u64 = 0x02;
pub const nr_getpid: u64 = 0x03;
pub const nr_getppid: u64 = 0x04;
pub const nr_ps: u64 = 0x05;
// 0x10 thread
pub const nr_thread: u64 = 0x10;
pub const nr_thread_exit: u64 = 0x11;
pub const nr_gettid: u64 = 0x12;
pub const nr_yield: u64 = 0x13;
// 0x20 memory
pub const nr_brk: u64 = 0x20;
pub const nr_mmap: u64 = 0x21;
pub const nr_munmap: u64 = 0x22;
// 0x30 file
pub const nr_open: u64 = 0x30;
pub const nr_close: u64 = 0x31;
pub const nr_read: u64 = 0x32;
pub const nr_write: u64 = 0x33;
pub const nr_lseek: u64 = 0x34;
pub const nr_pipe: u64 = 0x35;
pub const nr_getdents: u64 = 0x36;
pub const nr_unlink: u64 = 0x37;
// 0x40 clock
pub const nr_sleep: u64 = 0x40;
pub const nr_uptime: u64 = 0x41;
// 0x50 machine
pub const nr_reboot: u64 = 0x50;
pub const nr_poweroff: u64 = 0x51;

pub const prot_read: u64 = 1;
pub const prot_write: u64 = 2;
pub const prot_exec: u64 = 4;

pub const seek_set: u64 = 0;
pub const seek_cur: u64 = 1;
pub const seek_end: u64 = 2;

// open flags. Zero reads. Write truncates a file under /tmp.
// Create makes a missing file and requires write.
pub const open_write: u64 = 1;
pub const open_create: u64 = 2;

// Packed dirent. Matches kernel/src/sys/syscall.zig. Name is `name_len` bytes.
pub const dirent_name_max: usize = 112;
pub const Dirent = extern struct {
    size: u64,
    name_len: u64,
    name: [dirent_name_max]u8,
};
comptime {
    if (@sizeOf(Dirent) != 128) @compileError("Dirent must be 128 bytes");
}

// Thread state in PsInfo.state. Matches kernel/src/sys/syscall.zig.
// A zombie row has ps_zombie and tid 0; its threads are already gone.
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
    if (@sizeOf(PsInfo) != 32) @compileError("PsInfo must be 32 bytes");
}

pub const max_argv: usize = 32;

const UserStr = extern struct { ptr: u64, len: u64 };
const e2big: i64 = -7;

pub fn syscall3(n: u64, a: u64, b: u64, c: u64) i64 {
    return syscall6(n, a, b, c, 0, 0, 0);
}

pub fn syscall6(n: u64, a: u64, b: u64, c: u64, d: u64, e: u64, f: u64) i64 {
    const ret = asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a),
          [b] "{rsi}" (b),
          [c] "{rdx}" (c),
          [d] "{r10}" (d),
          [e] "{r8}" (e),
          [f] "{r9}" (f),
        : .{ .rcx = true, .r11 = true, .memory = true, .cc = true });
    return @bitCast(ret);
}

pub fn read(fd: u64, buf: []u8) i64 {
    return syscall3(nr_read, fd, @intFromPtr(buf.ptr), buf.len);
}

pub fn write(fd: u64, bytes: []const u8) i64 {
    return syscall3(nr_write, fd, @intFromPtr(bytes.ptr), bytes.len);
}

pub fn writeAll(fd: u64, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const r = write(fd, bytes[off..]);
        if (r <= 0) return;
        off += @intCast(r);
    }
}

pub fn exit(code: u64) noreturn {
    _ = syscall3(nr_exit, code, 0, 0);
    unreachable;
}

pub fn yield() void {
    _ = syscall3(nr_yield, 0, 0, 0);
}

pub fn sleep(ms: u64) void {
    _ = syscall3(nr_sleep, ms, 0, 0);
}

pub fn uptime() u64 {
    return @bitCast(syscall3(nr_uptime, 0, 0, 0));
}

pub fn open(path: []const u8) i64 {
    return openAt(path, 0);
}

pub fn openAt(path: []const u8, flags: u64) i64 {
    return syscall3(nr_open, @intFromPtr(path.ptr), path.len, flags);
}

pub fn unlink(path: []const u8) i64 {
    return syscall3(nr_unlink, @intFromPtr(path.ptr), path.len, 0);
}

pub fn close(fd: u64) i64 {
    return syscall3(nr_close, fd, 0, 0);
}

pub fn lseek(fd: u64, offset: i64, whence: u64) i64 {
    return syscall3(nr_lseek, fd, @bitCast(offset), whence);
}

fn packArgv(argv: []const []const u8, strs: *[max_argv]UserStr) bool {
    if (argv.len > strs.len) return false;
    for (argv, 0..) |a, i| {
        strs[i] = .{ .ptr = @intFromPtr(a.ptr), .len = a.len };
    }
    return true;
}

pub fn spawn(path: []const u8, argv: []const []const u8, stdin: u64, stdout: u64, stderr: u64) i64 {
    var strs: [max_argv]UserStr = undefined;
    if (!packArgv(argv, &strs)) return e2big;
    var stdio = [3]u64{ stdin, stdout, stderr };
    return syscall6(
        nr_spawn,
        @intFromPtr(path.ptr),
        path.len,
        @intFromPtr(&strs),
        argv.len,
        @intFromPtr(&stdio),
        0,
    );
}

/// Wait for a child. `pid` 0 means any. Returns the child's pid, or -errno.
/// If `status` is non-null, stores the child's exit code there.
pub fn wait(pid: u64) i64 {
    return waitStatus(pid, null);
}

pub fn waitStatus(pid: u64, status: ?*u64) i64 {
    const addr: u64 = if (status) |s| @intFromPtr(s) else 0;
    return syscall3(nr_wait, pid, addr, 0);
}

pub fn getpid() i64 {
    return syscall3(nr_getpid, 0, 0, 0);
}

pub fn gettid() i64 {
    return syscall3(nr_gettid, 0, 0, 0);
}

/// Start `entry(arg)` on a new stack in this process. Same page tables and
/// file descriptors. `entry` is `callconv(.c)` and is entered by iretq with
/// the argument in rdi. It must call `threadExit`; a return faults.
pub fn thread(entry: *const fn (u64) callconv(.c) noreturn, arg: u64) i64 {
    return syscall3(nr_thread, @intFromPtr(entry), arg, 0);
}

pub fn threadExit(code: u64) noreturn {
    _ = syscall3(nr_thread_exit, code, 0, 0);
    unreachable;
}

pub fn getppid() i64 {
    return syscall3(nr_getppid, 0, 0, 0);
}

pub fn brk(addr: usize) i64 {
    return syscall3(nr_brk, addr, 0, 0);
}

pub fn mmap(addr: usize, len: usize, prot: u64) i64 {
    return syscall3(nr_mmap, addr, len, prot);
}

pub fn munmap(addr: usize, len: usize) i64 {
    return syscall3(nr_munmap, addr, len, 0);
}

pub fn reboot() noreturn {
    _ = syscall3(nr_reboot, 0, 0, 0);
    unreachable;
}

pub fn poweroff() noreturn {
    _ = syscall3(nr_poweroff, 0, 0, 0);
    unreachable;
}

pub fn pipe(fds: *[2]i64) i64 {
    return syscall3(nr_pipe, @intFromPtr(fds), 0, 0);
}

pub fn getdents(fd: u64, buf: []Dirent) i64 {
    return syscall3(nr_getdents, fd, @intFromPtr(buf.ptr), buf.len * @sizeOf(Dirent));
}

pub fn ps(buf: []PsInfo) i64 {
    return syscall3(nr_ps, @intFromPtr(buf.ptr), buf.len * @sizeOf(PsInfo), 0);
}
