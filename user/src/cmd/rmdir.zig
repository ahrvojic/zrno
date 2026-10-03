const lib = @import("lib");
const sys = lib.sys;

pub fn main(argv: []const []const u8) u64 {
    if (argv.len < 2) {
        lib.eprint("usage: rmdir dir\n");
        return 1;
    }
    var status: u64 = 0;
    for (argv[1..]) |path| {
        const rc = sys.rmdir(path);
        if (rc < 0) {
            lib.eprint(path);
            lib.printErr(": err ", rc);
            status = 1;
        }
    }
    return status;
}
