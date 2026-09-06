const sys = @import("sys.zig");

export fn _start() callconv(.c) noreturn {
    const cur = sys.brk(0);
    if (cur <= 0) fail();
    const base: usize = @intCast(cur);

    // Below image end is EINVAL.
    if (sys.brk(base - 1) >= 0) fail();

    // Same-page grow, then store.
    if (sys.brk(base + 1) != base + 1) fail();
    const p: *volatile u8 = @ptrFromInt(base);
    if (p.* != 0) fail();
    p.* = 0xa5;
    if (p.* != 0xa5) fail();

    // Two more pages.
    const two = base + 0x2000;
    if (sys.brk(two) != two) fail();
    const p1: *volatile u8 = @ptrFromInt(base + 0x1000);
    p1.* = 0x5a;
    if (p1.* != 0x5a) fail();
    const p2: *volatile u8 = @ptrFromInt(base + 0x1fff);
    p2.* = 0x3c;
    if (p2.* != 0x3c) fail();

    // Over the 32 MiB cap is ENOMEM.
    if (sys.brk(base + 0x2100000) >= 0) fail();

    // Shrink back to the original break.
    if (sys.brk(base) != base) fail();
    if (sys.brk(0) != base) fail();

    sys.writeAll(1, "brk ok\n");
    sys.exit(0);
}

fn fail() noreturn {
    sys.writeAll(1, "brk fail\n");
    sys.exit(1);
}
