const lib = @import("lib");
const sys = lib.sys;

const enotdir: i64 = 20;

pub fn main(argv: []const [*:0]const u8) u64 {
    if (argv.len < 2) return list("/");
    var status: u64 = 0;
    for (argv[1..]) |path| {
        if (list(path) != 0) status = 1;
    }
    return status;
}

fn list(path: [*:0]const u8) u64 {
    const fd = sys.open(path);
    if (fd < 0) {
        lib.printErr("ls: err ", fd);
        return 1;
    }
    const rc = listFd(@intCast(fd), path);
    _ = sys.close(@intCast(fd));
    return rc;
}

fn listFd(fd: u64, path: [*:0]const u8) u64 {
    var ents: [8]sys.Dirent = undefined;
    var listed = false;
    while (true) {
        const n = sys.getdents(fd, &ents);
        if (n < 0) {
            if (n == -enotdir and !listed) {
                lib.print(lib.slice(path));
                lib.print("\n");
                return 0;
            }
            lib.printErr("ls: err ", n);
            return 1;
        }
        if (n == 0) return 0;
        listed = true;
        const bytes: usize = @intCast(n);
        for (ents[0 .. bytes / @sizeOf(sys.Dirent)]) |e| {
            printName(e.name);
        }
    }
}

fn printName(name: [sys.dirent_name_max]u8) void {
    var n: usize = 0;
    while (n < name.len and name[n] != 0) n += 1;
    lib.print(name[0..n]);
    lib.print("\n");
}
