const lib = @import("lib");

pub fn main(argc: usize, argv: []const [*:0]const u8) u64 {
    var i: usize = 1;
    while (i < argc) : (i += 1) {
        if (i > 1) lib.print(" ");
        lib.print(lib.slice(argv[i]));
    }
    lib.print("\n");
    return 0;
}
