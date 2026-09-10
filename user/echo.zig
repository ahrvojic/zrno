const lib = @import("lib");

pub fn main(argv: []const [*:0]const u8) u64 {
    for (argv[1..], 0..) |arg, i| {
        if (i != 0) lib.print(" ");
        lib.print(lib.slice(arg));
    }
    lib.print("\n");
    return 0;
}
