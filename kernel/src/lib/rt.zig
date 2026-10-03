//! Symbols LLVM emits that Zig 0.17.0's compiler-rt cannot build for this
//! target. x86 soft-float compiler-rt fails on `c_longdouble` (#37006), and
//! the kernel does not use floating point. `@disableIntrinsics` keeps these
//! bodies from calling themselves.

const builtin = @import("builtin");
const std = @import("std");

comptime {
    if (builtin.os.tag == .freestanding) {
        @export(&memcpy, .{ .name = "memcpy" });
        @export(&memset, .{ .name = "memset" });
        @export(&memmove, .{ .name = "memmove" });
        @export(&udivti3, .{ .name = "__udivti3" });
        @export(&probeStack, .{ .name = "__zig_probe_stack" });
    }
}

fn memcpy(noalias dest: [*]u8, noalias src: [*]const u8, n: usize) callconv(.c) [*]u8 {
    @disableIntrinsics();
    var i: usize = 0;
    while (i < n) : (i += 1) dest[i] = src[i];
    return dest;
}

fn memset(dest: [*]u8, c: c_int, n: usize) callconv(.c) [*]u8 {
    @disableIntrinsics();
    const byte: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var i: usize = 0;
    while (i < n) : (i += 1) dest[i] = byte;
    return dest;
}

fn memmove(dest: [*]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8 {
    @disableIntrinsics();
    if (@intFromPtr(dest) < @intFromPtr(src)) {
        var i: usize = 0;
        while (i < n) : (i += 1) dest[i] = src[i];
    } else {
        var i = n;
        while (i > 0) {
            i -= 1;
            dest[i] = src[i];
        }
    }
    return dest;
}

fn udivti3(n: u128, d: u128) callconv(.c) u128 {
    @disableIntrinsics();
    return udiv(n, d);
}

/// Restoring division. Only constant 1-bit shifts, so LLVM does not emit
/// another 128-bit helper.
fn udiv(n: u128, d: u128) u128 {
    if (d == 0) unreachable;
    var rest = n;
    var q: u128 = 0;
    var r: u128 = 0;
    var left: u8 = 128;
    while (left > 0) {
        left -= 1;
        const bit: u128 = rest >> 127;
        rest <<= 1;
        r = (r << 1) | bit;
        q <<= 1;
        if (r >= d) {
            r -= d;
            q |= 1;
        }
    }
    return q;
}

fn probeStack() callconv(.naked) void {
    // %rax is the probe length. Touch each page, then restore %rsp.
    asm volatile (
        \\        push   %%rcx
        \\        mov    %%rax, %%rcx
        \\        cmp    $0x1000,%%rcx
        \\        jb     2f
        \\ 1:
        \\        sub    $0x1000,%%rsp
        \\        orl    $0,16(%%rsp)
        \\        sub    $0x1000,%%rcx
        \\        cmp    $0x1000,%%rcx
        \\        ja     1b
        \\ 2:
        \\        sub    %%rcx, %%rsp
        \\        orl    $0,16(%%rsp)
        \\        add    %%rax,%%rsp
        \\        pop    %%rcx
        \\        ret
    );
}

test "udiv matches builtin division inside u64" {
    try std.testing.expectEqual(@as(u128, 0), udiv(0, 1));
    try std.testing.expectEqual(@as(u128, 0), udiv(4, 5));
    try std.testing.expectEqual(@as(u128, 2), udiv(10, 5));
    try std.testing.expectEqual(@as(u128, 2), udiv(11, 5));
    try std.testing.expectEqual(@as(u128, 1), udiv(std.math.maxInt(u64), std.math.maxInt(u64)));
}

test "udiv handles a 128-bit numerator" {
    const n = (@as(u128, 1) << 64) * 3 + 7;
    try std.testing.expectEqual(@as(u128, 3), udiv(n, (@as(u128, 1) << 64) + 2));
    try std.testing.expectEqual((@as(u128, 1) << 64) + 2, udiv(n, 3));
}
