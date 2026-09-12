// User SYSCALL ABI. Numbers match kernel/src/sys/syscall.zig.
// RCX and R11 are clobbered (hardware saves RIP/RFLAGS there).
pub const nr_read: u64 = 0;
pub const nr_write: u64 = 1;
pub const nr_exit: u64 = 2;
pub const nr_yield: u64 = 3;
pub const nr_sleep: u64 = 4;
pub const nr_open: u64 = 5;
pub const nr_close: u64 = 6;
pub const nr_spawn: u64 = 7;
pub const nr_wait: u64 = 8;
pub const nr_getpid: u64 = 9;
pub const nr_getppid: u64 = 10;
pub const nr_exec: u64 = 11;
pub const nr_dup: u64 = 12;
pub const nr_brk: u64 = 13;
pub const nr_mmap: u64 = 14;

pub const prot_read: u64 = 1;
pub const prot_write: u64 = 2;
pub const prot_exec: u64 = 4;

pub const Argv = [*:null]const ?[*:0]const u8;

pub fn syscall3(n: u64, a: u64, b: u64, c: u64) i64 {
    const ret = asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a),
          [b] "{rsi}" (b),
          [c] "{rdx}" (c),
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
    while (true) {}
}

pub fn yield() void {
    _ = syscall3(nr_yield, 0, 0, 0);
}

pub fn sleep(ms: u64) void {
    _ = syscall3(nr_sleep, ms, 0, 0);
}

pub fn open(path: [*:0]const u8) i64 {
    return syscall3(nr_open, @intFromPtr(path), 0, 0);
}

pub fn close(fd: u64) i64 {
    return syscall3(nr_close, fd, 0, 0);
}

pub fn spawn(path: [*:0]const u8, argv: Argv) i64 {
    return syscall3(nr_spawn, @intFromPtr(path), @intFromPtr(argv), 0);
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

pub fn getppid() i64 {
    return syscall3(nr_getppid, 0, 0, 0);
}

pub fn exec(path: [*:0]const u8, argv: Argv) i64 {
    return syscall3(nr_exec, @intFromPtr(path), @intFromPtr(argv), 0);
}

pub fn dup(fd: u64) i64 {
    return syscall3(nr_dup, fd, 0, 0);
}

pub fn brk(addr: usize) i64 {
    return syscall3(nr_brk, addr, 0, 0);
}

pub fn mmap(addr: usize, len: usize, prot: u64) i64 {
    return syscall3(nr_mmap, addr, len, prot);
}
