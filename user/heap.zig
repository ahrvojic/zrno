const sys = @import("sys.zig");
const malloc = @import("malloc.zig");

var data_cell: u64 = 0x1122334455667788;
var bss_cell: u64 = 0;

export fn _start() callconv(.c) noreturn {
    const d: *volatile u64 = &data_cell;
    if (d.* != 0x1122334455667788) fail();
    d.* = 0x99aabbccddeeff00;
    if (d.* != 0x99aabbccddeeff00) fail();

    const b: *volatile u64 = &bss_cell;
    if (b.* != 0) fail();
    b.* = 0x0102030405060708;
    if (b.* != 0x0102030405060708) fail();

    const a = malloc.malloc(16) orelse fail();
    poke(a, 0, 0xa5);
    poke(a, 15, 0xa6);
    if (peek(a, 0) != 0xa5 or peek(a, 15) != 0xa6) fail();

    const q = malloc.malloc(64) orelse fail();
    poke(q, 0, 0x5a);
    poke(q, 63, 0x5b);
    if (peek(a, 0) != 0xa5) fail();
    if (peek(q, 0) != 0x5a or peek(q, 63) != 0x5b) fail();

    malloc.free(a);
    const a2 = malloc.malloc(16) orelse fail();
    poke(a2, 0, 0x3c);
    if (peek(a2, 0) != 0x3c) fail();
    if (peek(q, 0) != 0x5a) fail();

    malloc.free(q);
    malloc.free(a2);

    // Grow past the first brk page.
    const big = malloc.malloc(0x2000) orelse fail();
    poke(big, 0, 0x11);
    poke(big, 0x1fff, 0x22);
    if (peek(big, 0) != 0x11 or peek(big, 0x1fff) != 0x22) fail();
    malloc.free(big);

    if (d.* != 0x99aabbccddeeff00 or b.* != 0x0102030405060708) fail();

    sys.writeAll(1, "heap ok\n");
    sys.exit(0);
}

fn poke(ptr: [*]u8, off: usize, val: u8) void {
    const p: *volatile u8 = @ptrFromInt(@intFromPtr(ptr) + off);
    p.* = val;
}

fn peek(ptr: [*]u8, off: usize) u8 {
    const p: *volatile u8 = @ptrFromInt(@intFromPtr(ptr) + off);
    return p.*;
}

fn fail() noreturn {
    sys.writeAll(1, "heap fail\n");
    sys.exit(1);
}
