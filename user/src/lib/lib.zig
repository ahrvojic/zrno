pub const malloc = @import("malloc.zig");
pub const sys = @import("sys.zig");

pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
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

pub fn parseU64(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var v: u64 = 0;
    for (s) |ch| {
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
