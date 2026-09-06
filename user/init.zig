const sys = @import("sys.zig");

export fn _start() callconv(.c) noreturn {
    writeStr("type 'help'\n");
    var buf: [128]u8 = undefined;
    while (true) {
        writeStr("> ");
        readLine(&buf);
        dispatch(&buf);
    }
}

fn writeStr(s: [*:0]const u8) void {
    sys.writeAll(1, s[0..cstrlen(s)]);
}

fn writeErr(prefix: [*:0]const u8, err: i64) void {
    writeStr(prefix);
    var v: u64 = if (err < 0) @intCast(-err) else @intCast(err);
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    if (v == 0) {
        tmp[0] = '0';
        n = 1;
    } else {
        while (v != 0) {
            tmp[n] = '0' + @as(u8, @intCast(v % 10));
            n += 1;
            v /= 10;
        }
        var i: usize = 0;
        while (i < n / 2) : (i += 1) {
            const t = tmp[i];
            tmp[i] = tmp[n - 1 - i];
            tmp[n - 1 - i] = t;
        }
    }
    sys.writeAll(1, tmp[0..n]);
    writeStr("\n");
}

fn cstrlen(s: [*:0]const u8) usize {
    // Volatile so LLVM does not turn this into a `strlen` libcall.
    var n: usize = 0;
    while (true) {
        const c = @as(*const volatile u8, @ptrCast(s + n)).*;
        if (c == 0) return n;
        n += 1;
    }
}

fn streq(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (a[i] != 0 and a[i] == b[i]) i += 1;
    return a[i] == b[i];
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

fn parseU64(s: [*:0]const u8) ?u64 {
    if (s[0] == 0) return null;
    var v: u64 = 0;
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        const ch = s[i];
        if (ch < '0' or ch > '9') return null;
        const n = v *% 10 +% (ch - '0');
        if (n < v) return null;
        v = n;
    }
    return v;
}

fn readLine(buf: *[128]u8) void {
    var n: usize = 0;
    while (true) {
        var ch: [1]u8 = undefined;
        const r = sys.read(0, &ch);
        if (r <= 0) continue;
        if (ch[0] == '\n') {
            writeStr("\n");
            buf[n] = 0;
            return;
        }
        if (ch[0] == 0x08) {
            if (n > 0) {
                n -= 1;
                writeStr("\x08");
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
    writeStr("help          commands\n");
    writeStr("yield         yield the CPU\n");
    writeStr("sleep [ms]    sleep (default 1000)\n");
    writeStr("echo [text]   print arguments\n");
    writeStr("run [path]    spawn a ramfs ELF\n");
    writeStr("cat [path]    print a ramfs file\n");
}

fn doSleep(arg: ?[*:0]u8) void {
    const ms: u64 = if (arg) |s| parseU64(s) orelse {
        writeStr("usage: sleep [ms]\n");
        return;
    } else 1000;
    sys.sleep(ms);
}

fn doRun(path: ?[*:0]u8) void {
    const p = path orelse {
        writeStr("usage: run [path]\n");
        return;
    };
    const pid = sys.spawn(p);
    if (pid < 0) {
        writeErr("run: err ", pid);
        return;
    }
    const code = sys.wait(@intCast(pid));
    if (code < 0) writeErr("wait: err ", code);
}

fn doCat(path: ?[*:0]u8) void {
    const p = path orelse {
        writeStr("usage: cat [path]\n");
        return;
    };
    const fd = sys.open(p);
    if (fd < 0) {
        writeErr("cat: err ", fd);
        return;
    }
    const fdu: u64 = @intCast(fd);
    var buf: [256]u8 = undefined;
    while (true) {
        const n = sys.read(fdu, &buf);
        if (n < 0) {
            writeErr("cat: err ", n);
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
    if (streq(cmd, "help")) {
        help();
    } else if (streq(cmd, "yield")) {
        sys.yield();
    } else if (streq(cmd, "sleep")) {
        doSleep(nextTok(&rest));
    } else if (streq(cmd, "echo")) {
        writeStr(skipSpaces(rest));
        writeStr("\n");
    } else if (streq(cmd, "run")) {
        doRun(nextTok(&rest));
    } else if (streq(cmd, "cat")) {
        doCat(nextTok(&rest));
    } else {
        writeStr("unknown command: ");
        writeStr(cmd);
        writeStr("\n");
    }
}
