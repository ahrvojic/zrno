const lib = @import("lib");

pub fn main(argv: []const []const u8) u64 {
    return lib.eachPath(argv, "usage: rm file\n", lib.sys.unlink);
}
