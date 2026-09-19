const lib = @import("lib");
const sys = lib.sys;

pub fn main() u64 {
    lib.print("type 'help'\n");
    var buf: [128:0]u8 = undefined;
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

fn readLine(buf: *[128:0]u8) void {
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
    lib.print("exit [code]   exit the shell\n");
    lib.print("reboot        reboot the machine\n");
    lib.print("poweroff      ACPI S5 power off\n");
    lib.print("[name] [args] spawn /name\n");
    lib.print("a | b         pipe a stdout to b stdin\n");
}

fn doSleep(arg: ?[*:0]u8) void {
    const ms: u64 = if (arg) |s| lib.parseU64(s) orelse {
        lib.print("usage: sleep [ms]\n");
        return;
    } else 1000;
    sys.sleep(ms);
}

fn doExit(arg: ?[*:0]u8) void {
    const code: u64 = if (arg) |s| lib.parseU64(s) orelse {
        lib.print("usage: exit [code]\n");
        return;
    } else 0;
    sys.exit(code);
}

const Argv = [32:null]?[*:0]const u8;

fn fillArgv(ptrs: *Argv, path: [*:0]const u8, ps: *[*:0]u8) bool {
    ptrs[0] = path;
    var n: usize = 1;
    while (nextTok(ps)) |tok| {
        if (n >= ptrs.len) {
            lib.print("too many args\n");
            return false;
        }
        ptrs[n] = tok;
        n += 1;
    }
    ptrs[n] = null;
    return true;
}

fn spawnCmd(path: [*:0]const u8, argv: *Argv, stdin: u64, stdout: u64, stderr: u64) i64 {
    const pid = sys.spawn(path, argv, stdin, stdout, stderr);
    if (pid < 0) {
        lib.print(lib.slice(path));
        lib.printErr(": err ", pid);
    }
    return pid;
}

fn waitPid(pid: i64) void {
    var status: u64 = 0;
    const w = sys.waitStatus(@intCast(pid), &status);
    if (w < 0) {
        lib.printErr("wait: err ", w);
        return;
    }
    lib.print("[");
    lib.printU64(status);
    lib.print("]\n");
}

fn spawnWait(path: [*:0]const u8, ps: *[*:0]u8) void {
    var ptrs: Argv = undefined;
    if (!fillArgv(&ptrs, path, ps)) return;
    const pid = spawnCmd(path, &ptrs, 0, 1, 2);
    if (pid >= 0) waitPid(pid);
}

fn splitPipe(buf: *[128:0]u8) ?[*:0]u8 {
    var i: usize = 0;
    while (buf[i] != 0) : (i += 1) {
        if (buf[i] == '|') {
            buf[i] = 0;
            return buf[i + 1 .. :0];
        }
    }
    return null;
}

fn hasChar(s: [*:0]const u8, ch: u8) bool {
    var p = s;
    while (p[0] != 0) : (p += 1) {
        if (p[0] == ch) return true;
    }
    return false;
}

fn doPipe(left_line: [*:0]u8, right_line: [*:0]u8) void {
    if (hasChar(right_line, '|')) {
        lib.print("too many |\n");
        return;
    }
    var left_rest: [*:0]u8 = left_line;
    const left_cmd = nextTok(&left_rest) orelse {
        lib.print("usage: cmd | cmd\n");
        return;
    };
    var right_rest: [*:0]u8 = right_line;
    const right_cmd = nextTok(&right_rest) orelse {
        lib.print("usage: cmd | cmd\n");
        return;
    };

    var left_argv: Argv = undefined;
    var right_argv: Argv = undefined;
    if (!fillArgv(&left_argv, left_cmd, &left_rest)) return;
    if (!fillArgv(&right_argv, right_cmd, &right_rest)) return;

    var p: [2]i64 = undefined;
    const prc = sys.pipe(&p);
    if (prc < 0) {
        lib.printErr("pipe: err ", prc);
        return;
    }
    const pr: u64 = @intCast(p[0]);
    const pw: u64 = @intCast(p[1]);

    const lpid = spawnCmd(left_cmd, &left_argv, 0, pw, 2);
    const rpid: i64 = if (lpid >= 0) spawnCmd(right_cmd, &right_argv, pr, 1, 2) else -1;
    _ = sys.close(pr);
    _ = sys.close(pw);
    if (lpid >= 0) waitPid(lpid);
    if (rpid >= 0) waitPid(rpid);
}

fn dispatch(buf: *[128:0]u8) void {
    if (splitPipe(buf)) |right| {
        doPipe(buf, right);
        return;
    }
    var rest: [*:0]u8 = buf;
    const cmd = nextTok(&rest) orelse return;
    if (lib.eql(cmd, "help")) {
        help();
    } else if (lib.eql(cmd, "yield")) {
        sys.yield();
    } else if (lib.eql(cmd, "sleep")) {
        doSleep(nextTok(&rest));
    } else if (lib.eql(cmd, "exit")) {
        doExit(nextTok(&rest));
    } else if (lib.eql(cmd, "reboot")) {
        sys.reboot();
    } else if (lib.eql(cmd, "poweroff")) {
        sys.poweroff();
    } else {
        spawnWait(cmd, &rest);
    }
}
