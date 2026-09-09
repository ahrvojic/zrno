const sys = @import("sys.zig");

export fn _start() callconv(.c) noreturn {
    const rw = sys.prot_read | sys.prot_write;

    // Hint must be 0 (no MAP_FIXED).
    if (sys.mmap(0x1000, 0x1000, rw) >= 0) fail();
    if (sys.mmap(0, 0, rw) >= 0) fail();
    if (sys.mmap(0, 0x1000, sys.prot_read | sys.prot_exec) >= 0) fail();
    if (sys.mmap(0, 0x1000, 0) >= 0) fail();

    const p = sys.mmap(0, 0x1000, rw);
    if (p <= 0) fail();
    const a: *volatile u8 = @ptrFromInt(@as(usize, @intCast(p)));
    if (a.* != 0) fail();
    a.* = 0xa5;
    if (a.* != 0xa5) fail();

    // Unaligned length rounds up to two pages.
    const q = sys.mmap(0, 0x1001, rw);
    if (q <= 0) fail();
    const b: *volatile u8 = @ptrFromInt(@as(usize, @intCast(q)));
    b.* = 0x5a;
    const c: *volatile u8 = @ptrFromInt(@as(usize, @intCast(q)) + 0x1000);
    if (c.* != 0) fail();
    c.* = 0x3c;
    if (c.* != 0x3c) fail();

    // Over the 32 MiB cap is ENOMEM.
    if (sys.mmap(0, 0x2100000, rw) >= 0) fail();

    sys.writeAll(1, "mmap ok\n");
    sys.exit(0);
}

fn fail() noreturn {
    sys.writeAll(1, "mmap fail\n");
    sys.exit(1);
}
