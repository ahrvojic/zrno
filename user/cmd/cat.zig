const lib = @import("lib");
const sys = lib.sys;

pub fn main(argv: []const [*:0]const u8) u64 {
    if (argv.len < 2) return copy(0);
    var status: u64 = 0;
    for (argv[1..]) |path| {
        const fd = sys.open(path);
        if (fd < 0) {
            lib.printErr("cat: err ", fd);
            status = 1;
            continue;
        }
        if (copy(@intCast(fd)) != 0) status = 1;
        _ = sys.close(@intCast(fd));
    }
    return status;
}

fn copy(fd: u64) u64 {
    const n = lib.copyFd(fd);
    if (n < 0) {
        lib.printErr("cat: err ", n);
        return 1;
    }
    return 0;
}
