const lib = @import("lib.zig");
const sys = @import("sys.zig");

export fn _start(argc: u64, argv: [*]const [*:0]const u8) callconv(.c) noreturn {
    lib.exitMain(argc, argv, &main);
}

fn main(argc: usize, argv: []const [*:0]const u8) u64 {
    if (argc < 2) {
        lib.print("usage: cat [path...]\n");
        return 1;
    }
    var status: u64 = 0;
    var i: usize = 1;
    while (i < argc) : (i += 1) {
        if (!catPath(argv[i])) status = 1;
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
    var buf: [256]u8 = undefined;
    var ok = true;
    while (true) {
        const n = sys.read(fdu, &buf);
        if (n < 0) {
            lib.printErr("cat: err ", n);
            ok = false;
            break;
        }
        if (n == 0) break;
        sys.writeAll(1, buf[0..@intCast(n)]);
    }
    _ = sys.close(fdu);
    return ok;
}
