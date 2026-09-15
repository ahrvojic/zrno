const lib = @import("lib");
const sys = lib.sys;

const EBADF: i64 = -9;
const EPIPE: i64 = -32;

pub fn main(argv: []const [*:0]const u8) u64 {
    if (argv.len >= 3 and lib.eql(argv[1], "child")) {
        const fd = lib.parseU64(argv[2]) orelse return 1;
        sys.sleep(30);
        if (sys.write(fd, "x") != 1) return 1;
        return 0;
    }

    var fds: [2]i64 = undefined;
    if (sys.pipe(&fds) < 0) return fail("pipe");
    const r: u64 = @intCast(fds[0]);
    const w: u64 = @intCast(fds[1]);

    const msg = "hi\n";
    if (sys.write(w, msg) != msg.len) return fail("write");

    var buf: [8]u8 = undefined;
    const n = sys.read(r, &buf);
    if (n != 3 or buf[0] != 'h' or buf[1] != 'i' or buf[2] != '\n') return fail("read");

    _ = sys.close(w);
    if (sys.read(r, &buf) != 0) return fail("eof");
    if (sys.write(r, msg) != EBADF) return fail("ebadf-w");
    _ = sys.close(r);

    if (sys.pipe(&fds) < 0) return fail("pipe2");
    const r2: u64 = @intCast(fds[0]);
    const w2: u64 = @intCast(fds[1]);
    _ = sys.close(r2);
    if (sys.write(w2, msg) != EPIPE) return fail("epipe");
    if (sys.read(w2, &buf) != EBADF) return fail("ebadf-r");
    _ = sys.close(w2);

    if (sys.pipe(&fds) < 0) return fail("pipe3");
    const r3: u64 = @intCast(fds[0]);
    const w3: u64 = @intCast(fds[1]);
    var num: [2:0]u8 = .{
        '0' + @as(u8, @intCast(w3 / 10)),
        '0' + @as(u8, @intCast(w3 % 10)),
    };
    const fdstr: [*:0]const u8 = if (w3 >= 10) &num else @ptrCast(&num[1]);
    const child_argv = [_:null]?[*:0]const u8{ "/pipetest", "child", fdstr };
    const pid = sys.spawn("/pipetest", &child_argv);
    if (pid < 0) return fail("spawn");
    _ = sys.close(w3);
    if (sys.read(r3, &buf) != 1 or buf[0] != 'x') return fail("block");
    if (sys.wait(@intCast(pid)) < 0) return fail("wait");
    if (sys.read(r3, &buf) != 0) return fail("block-eof");
    _ = sys.close(r3);

    lib.print("pipetest ok\n");
    return 0;
}

fn fail(what: []const u8) u64 {
    lib.print("pipetest fail ");
    lib.print(what);
    lib.print("\n");
    return 1;
}
