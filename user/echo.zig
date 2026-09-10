const lib = @import("lib.zig");

export fn _start(argc: u64, argv: [*]const [*:0]const u8) callconv(.c) noreturn {
    lib.exitMain(argc, argv, &main);
}

fn main(argc: usize, argv: []const [*:0]const u8) u64 {
    var i: usize = 1;
    while (i < argc) : (i += 1) {
        if (i > 1) lib.print(" ");
        lib.print(lib.slice(argv[i]));
    }
    lib.print("\n");
    return 0;
}
