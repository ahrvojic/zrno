const lib = @import("lib.zig");

export fn _start(argc: u64, argv: [*]const [*:0]const u8) callconv(.c) noreturn {
    lib.exitMain(argc, argv, &main);
}

fn main(_: usize, _: []const [*:0]const u8) u64 {
    lib.print("Hello from userspace!\n");
    return 0;
}
