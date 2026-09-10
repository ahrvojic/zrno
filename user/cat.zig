const lib = @import("lib");
const sys = lib.sys;

pub fn main(argv: []const [*:0]const u8) u64 {
    if (argv.len < 2) {
        lib.print("usage: cat [path...]\n");
        return 1;
    }
    var status: u64 = 0;
    for (argv[1..]) |path| {
        if (!catPath(path)) status = 1;
    }
    return status;
}

fn catPath(path: [*:0]const u8) bool {
    const fd = sys.open(path);
    if (fd < 0) {
        lib.printErr("cat: err ", fd);
        return false;
    }
    const fdu: u64 = @intCast(fd);
    const n = lib.copyFd(fdu);
    _ = sys.close(fdu);
    if (n < 0) {
        lib.printErr("cat: err ", n);
        return false;
    }
    return true;
}
