const lib = @import("lib");
const sys = lib.sys;

pub fn main(_: usize, _: []const [*:0]const u8) u64 {
    lib.print("READY.\n");
    lib.print("type 'help'\n");
    var buf: [128]u8 = undefined;
    while (true) {
        lib.print("> ");
        readLine(&buf);
        dispatch(&buf);
    }
}

fn skipSpaces(s: [*:0]u8) [*:0]u8 {
    var p = s;
    while (p[0] == ' ') p += 1;
    return p;
}

fn nextTok(ps: *[*:0]u8) ?[*:0]u8 {
    var s = skipSpaces(ps.*);
    if (s[0] == 0) {
        ps.* = s;
        return null;
    }
    const tok = s;
    while (s[0] != 0 and s[0] != ' ') s += 1;
    if (s[0] == ' ') {
        s[0] = 0;
        s += 1;
    }
    ps.* = s;
    return tok;
}

fn readLine(buf: *[128]u8) void {
    var n: usize = 0;
    while (true) {
        var ch: [1]u8 = undefined;
        const r = sys.read(0, &ch);
        if (r <= 0) continue;
        if (ch[0] == '\n') {
            lib.print("\n");
            buf[n] = 0;
            return;
        }
        if (ch[0] == 0x08) {
            if (n > 0) {
                n -= 1;
                lib.print("\x08");
            }
            continue;
        }
        if (n < buf.len - 1) {
            buf[n] = ch[0];
            n += 1;
            _ = sys.write(1, &ch);
        }
    }
}

fn help() void {
    lib.print("help          commands\n");
    lib.print("yield         yield the CPU\n");
    lib.print("sleep [ms]    sleep (default 1000)\n");
    lib.print("echo [text]   print arguments\n");
    lib.print("cat [path]    print a ramfs file\n");
    lib.print("run [path] [args...]  spawn a ramfs ELF\n");
    lib.print("[name] [args] spawn /name\n");
}

fn doSleep(arg: ?[*:0]u8) void {
    const ms: u64 = if (arg) |s| lib.parseU64(s) orelse {
        lib.print("usage: sleep [ms]\n");
        return;
    } else 1000;
    sys.sleep(ms);
}

fn spawnWait(path: [*:0]const u8, ps: *[*:0]u8) void {
    var ptrs: [33]u64 = undefined;
    ptrs[0] = @intFromPtr(path);
    var n: usize = 1;
    while (nextTok(ps)) |tok| {
        if (n >= ptrs.len - 1) {
            lib.print("too many args\n");
            return;
        }
        ptrs[n] = @intFromPtr(tok);
        n += 1;
    }
    ptrs[n] = 0;
    const pid = sys.spawn(path, @intFromPtr(&ptrs));
    if (pid < 0) {
        lib.print(lib.slice(path));
        lib.printErr(": err ", pid);
        return;
    }
    const code = sys.wait(@intCast(pid));
    if (code < 0) lib.printErr("wait: err ", code);
}

fn doRun(ps: *[*:0]u8) void {
    const path = nextTok(ps) orelse {
        lib.print("usage: run [path] [args...]\n");
        return;
    };
    spawnWait(path, ps);
}

fn doCat(path: ?[*:0]u8) void {
    const p = path orelse {
        lib.print("usage: cat [path]\n");
        return;
    };
    const fd = sys.open(p);
    if (fd < 0) {
        lib.printErr("cat: err ", fd);
        return;
    }
    const fdu: u64 = @intCast(fd);
    var buf: [256]u8 = undefined;
    while (true) {
        const n = sys.read(fdu, &buf);
        if (n < 0) {
            lib.printErr("cat: err ", n);
            break;
        }
        if (n == 0) break;
        sys.writeAll(1, buf[0..@intCast(n)]);
    }
    _ = sys.close(fdu);
}

fn dispatch(buf: *[128]u8) void {
    var rest: [*:0]u8 = @ptrCast(buf);
    const cmd = nextTok(&rest) orelse return;
    if (lib.eql(cmd, "help")) {
        help();
    } else if (lib.eql(cmd, "yield")) {
        sys.yield();
    } else if (lib.eql(cmd, "sleep")) {
        doSleep(nextTok(&rest));
    } else if (lib.eql(cmd, "echo")) {
        lib.print(lib.slice(skipSpaces(rest)));
        lib.print("\n");
    } else if (lib.eql(cmd, "run")) {
        doRun(&rest);
    } else if (lib.eql(cmd, "cat")) {
        doCat(nextTok(&rest));
    } else {
        spawnWait(cmd, &rest);
    }
}
