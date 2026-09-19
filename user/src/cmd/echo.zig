const lib = @import("lib");

pub fn main(argv: []const []const u8) u64 {
    for (argv[1..], 0..) |arg, i| {
        if (i != 0) lib.print(" ");
        lib.print(arg);
    }
    lib.print("\n");
    return 0;
}
