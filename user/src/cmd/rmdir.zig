const lib = @import("lib");

pub fn main(argv: []const []const u8) u64 {
    return lib.eachPath(argv, "usage: rmdir dir\n", lib.sys.rmdir);
}
