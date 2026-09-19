const lib = @import("lib");
const sys = lib.sys;

pub fn main() u64 {
    lib.print("type 'help'\n");
    var buf: [128]u8 = undefined;
    while (true) {
        lib.print("> ");
        dispatch(readLine(&buf));
    }
}

fn skipSpaces(s: []u8) []u8 {
    var i: usize = 0;
    while (i < s.len and s[i] == ' ') i += 1;
    return s[i..];
}

fn nextTok(ps: *[]u8) ?[]u8 {
    const s = skipSpaces(ps.*);
    if (s.len == 0) {
        ps.* = s;
        return null;
    }
    var i: usize = 0;
    while (i < s.len and s[i] != ' ') i += 1;
    const tok = s[0..i];
    ps.* = if (i < s.len) s[i + 1 ..] else s[i..];
    return tok;
}

fn readLine(buf: *[128]u8) []u8 {
    var n: usize = 0;
    while (true) {
        var ch: [1]u8 = undefined;
        const r = sys.read(0, &ch);
        if (r <= 0) continue;
        if (ch[0] == '\n') {
            lib.print("\n");
            return buf[0..n];
        }
        if (ch[0] == 0x08) {
            if (n > 0) {
                n -= 1;
                lib.print("\x08");
            }
            continue;
        }
        if (n < buf.len) {
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
    lib.print("cmd < file    stdin from file\n");
}

fn optU64(arg: ?[]const u8, default: u64, usage: []const u8) ?u64 {
    const s = arg orelse return default;
    return lib.parseU64(s) orelse {
        lib.print(usage);
        return null;
    };
}

fn doSleep(arg: ?[]const u8) void {
    sys.sleep(optU64(arg, 1000, "usage: sleep [ms]\n") orelse return);
}

fn doExit(arg: ?[]const u8) void {
    sys.exit(optU64(arg, 0, "usage: exit [code]\n") orelse return);
}

const Cmd = struct {
    argv: [sys.max_argv][]const u8,
    n: usize,
    in_file: ?[]const u8 = null,
};

fn parseCmd(path: []const u8, ps: *[]u8) ?Cmd {
    var argv: [sys.max_argv][]const u8 = undefined;
    argv[0] = path;
    var n: usize = 1;
    var in_file: ?[]const u8 = null;
    while (nextTok(ps)) |tok| {
        if (tok.len > 0 and tok[0] == '>') {
            lib.print("no > yet\n");
            return null;
        }
        if (tok.len > 0 and tok[0] == '<') {
            const name = if (tok.len > 1) tok[1..] else nextTok(ps) orelse {
                lib.print("usage: cmd < file\n");
                return null;
            };
            if (in_file) |_| {
                lib.print("too many <\n");
                return null;
            }
            in_file = name;
            continue;
        }
        if (n >= argv.len) {
            lib.print("too many args\n");
            return null;
        }
        argv[n] = tok;
        n += 1;
    }
    return .{ .argv = argv, .n = n, .in_file = in_file };
}

fn spawnCmd(cmd: *const Cmd, stdin0: u64, stdout: u64) i64 {
    var opened: ?u64 = null;
    defer if (opened) |fd| {
        _ = sys.close(fd);
    };

    var stdin = stdin0;
    if (cmd.in_file) |f| {
        const fd = sys.open(f);
        if (fd < 0) {
            lib.print(f);
            lib.printErr(": err ", fd);
            return fd;
        }
        const nfd: u64 = @intCast(fd);
        opened = nfd;
        stdin = nfd;
    }
    const pid = sys.spawn(cmd.argv[0], cmd.argv[0..cmd.n], stdin, stdout, 2);
    if (pid < 0) {
        lib.print(cmd.argv[0]);
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

fn spawnWait(path: []const u8, ps: *[]u8) void {
    const cmd = parseCmd(path, ps) orelse return;
    const pid = spawnCmd(&cmd, 0, 1);
    if (pid >= 0) waitPid(pid);
}

fn splitPipe(line: []u8) ?struct { left: []u8, right: []u8 } {
    for (line, 0..) |c, i| {
        if (c == '|') return .{ .left = line[0..i], .right = line[i + 1 ..] };
    }
    return null;
}

fn doPipe(left_line: []u8, right_line: []u8) void {
    for (right_line) |c| {
        if (c == '|') {
            lib.print("too many |\n");
            return;
        }
    }
    var left_ps: []u8 = left_line;
    var right_ps: []u8 = right_line;
    const left_path = nextTok(&left_ps) orelse {
        lib.print("usage: cmd | cmd\n");
        return;
    };
    const right_path = nextTok(&right_ps) orelse {
        lib.print("usage: cmd | cmd\n");
        return;
    };
    const left = parseCmd(left_path, &left_ps) orelse return;
    const right = parseCmd(right_path, &right_ps) orelse return;

    var p: [2]i64 = undefined;
    const prc = sys.pipe(&p);
    if (prc < 0) {
        lib.printErr("pipe: err ", prc);
        return;
    }
    const pr: u64 = @intCast(p[0]);
    const pw: u64 = @intCast(p[1]);

    const lpid = spawnCmd(&left, 0, pw);
    const rpid: i64 = if (lpid >= 0) spawnCmd(&right, pr, 1) else -1;
    _ = sys.close(pr);
    _ = sys.close(pw);
    if (lpid >= 0) waitPid(lpid);
    if (rpid >= 0) waitPid(rpid);
}

fn dispatch(line: []u8) void {
    if (splitPipe(line)) |parts| {
        doPipe(parts.left, parts.right);
        return;
    }
    var rest = line;
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
