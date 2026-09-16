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

fn spawnCmd(path: [*:0]const u8, argv: *Argv) i64 {
    const pid = sys.spawn(path, argv);
    if (pid < 0) {
        lib.print(lib.slice(path));
        lib.printErr(": err ", pid);
    }
    return pid;
}

fn waitPid(pid: i64) void {
    const w = sys.wait(@intCast(pid));
    if (w < 0) lib.printErr("wait: err ", w);
}

fn spawnWait(path: [*:0]const u8, ps: *[*:0]u8) void {
    var ptrs: Argv = undefined;
    if (!fillArgv(&ptrs, path, ps)) return;
    const pid = spawnCmd(path, &ptrs);
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

// Lowest-fd `dup`: close `slot`, then `dup(with)` lands on it.
fn redirect(slot: u64, with: u64) u64 {
    const saved: u64 = @intCast(sys.dup(slot));
    _ = sys.close(slot);
    _ = sys.dup(with);
    _ = sys.close(with);
    return saved;
}

fn restore(slot: u64, saved: u64) void {
    _ = sys.close(slot);
    _ = sys.dup(saved);
    _ = sys.close(saved);
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

    const saved1 = redirect(1, pw);
    const lpid = spawnCmd(left_cmd, &left_argv);
    restore(1, saved1);
    if (lpid < 0) {
        _ = sys.close(pr);
        return;
    }

    const saved0 = redirect(0, pr);
    const rpid = spawnCmd(right_cmd, &right_argv);
    restore(0, saved0);
    if (rpid < 0) {
        waitPid(lpid);
        return;
    }
    waitPid(lpid);
    waitPid(rpid);
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
