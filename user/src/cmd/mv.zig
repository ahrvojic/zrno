const lib = @import("lib");
const sys = lib.sys;

pub fn main(argv: []const []const u8) u64 {
    if (argv.len != 3) {
        lib.eprint("usage: mv old new\n");
        return 1;
    }
    const rc = sys.rename(argv[1], argv[2]);
    if (rc < 0) {
        lib.eprint(argv[1]);
        lib.printErr(": err ", rc);
        return 1;
    }
    return 0;
}
