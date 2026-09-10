pub const malloc = @import("malloc.zig");
pub const sys = @import("sys.zig");

pub fn strlen(s: [*:0]const u8) usize {
    // Volatile so LLVM does not turn this into a `strlen` libcall.
    var n: usize = 0;
    while (true) {
        const c = @as(*const volatile u8, @ptrCast(s + n)).*;
        if (c == 0) return n;
        n += 1;
    }
}

pub fn slice(s: [*:0]const u8) []const u8 {
    return s[0..strlen(s)];
}

pub fn eql(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (a[i] != 0 and a[i] == b[i]) i += 1;
    return a[i] == b[i];
}

pub fn print(bytes: []const u8) void {
    sys.writeAll(1, bytes);
}

pub fn printU64(v0: u64) void {
    var tmp: [20]u8 = undefined;
    var v = v0;
    var i: usize = tmp.len;
    while (true) {
        i -= 1;
        tmp[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
        if (v == 0) break;
    }
    print(tmp[i..]);
}

pub fn printErr(prefix: []const u8, err: i64) void {
    print(prefix);
    const v: u64 = if (err < 0) @intCast(-err) else @intCast(err);
    printU64(v);
    print("\n");
}

pub fn parseU64(s: [*:0]const u8) ?u64 {
    if (s[0] == 0) return null;
    var v: u64 = 0;
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        const ch = s[i];
        if (ch < '0' or ch > '9') return null;
        const digit: u64 = ch - '0';
        if (v > (~@as(u64, 0) - digit) / 10) return null;
        v = v * 10 + digit;
    }
    return v;
}

pub fn copyFd(fd: u64) i64 {
    var buf: [256]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &buf);
        if (n <= 0) return n;
        sys.writeAll(1, buf[0..@intCast(n)]);
    }
}
