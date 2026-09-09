const sys = @import("sys.zig");

export fn _start(argc: u64, argv: [*]const [*:0]const u8) callconv(.c) noreturn {
    printU64(argc);
    sys.writeAll(1, "\n");
    var i: u64 = 0;
    while (i < argc) : (i += 1) {
        const s = argv[i];
        sys.writeAll(1, s[0..cstrlen(s)]);
        sys.writeAll(1, "\n");
    }
    sys.exit(0);
}

fn cstrlen(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (true) {
        const c = @as(*const volatile u8, @ptrCast(s + n)).*;
        if (c == 0) return n;
        n += 1;
    }
}

fn printU64(v0: u64) void {
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
    sys.writeAll(1, tmp[0..n]);
}
