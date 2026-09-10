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
    var v = v0;
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    if (v == 0) {
        tmp[0] = '0';
        n = 1;
    } else {
        while (v != 0) {
            tmp[n] = '0' + @as(u8, @intCast(v % 10));
            n += 1;
            v /= 10;
        }
        var i: usize = 0;
        while (i < n / 2) : (i += 1) {
            const t = tmp[i];
            tmp[i] = tmp[n - 1 - i];
            tmp[n - 1 - i] = t;
        }
    }
    print(tmp[0..n]);
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
        const n = v *% 10 +% (ch - '0');
        if (n < v) return null;
        v = n;
    }
    return v;
}
