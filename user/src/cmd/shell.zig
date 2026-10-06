const lib = @import("lib");
const sys = lib.sys;

// Matches the kernel path cap. A command with no '/' is looked up from `/`.
const max_path = 128;

pub fn main() u64 {
    lib.print("type 'help'\n");
    var buf: [256]u8 = undefined;
    while (true) {
        lib.print("> ");
        const line = readLine(&buf) orelse break;
        dispatch(line);
    }
    return 0;
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

fn readByte() ?u8 {
    var buf: [1]u8 = undefined;
    const r = sys.read(0, &buf);
    if (r < 0) {
        lib.printErr("read: err ", r);
        sys.exit(1);
    }
    if (r == 0) return null;
    return buf[0];
}

// Null is EOF. A line that does not fit is dropped.
fn readLine(buf: *[256]u8) ?[]u8 {
    var n: usize = 0;
    while (readByte()) |ch| {
        if (ch == '\n') return buf[0..n];
        if (n == buf.len) {
            while (readByte()) |extra| if (extra == '\n') break;
            lib.eprint("line too long\n");
            return buf[0..0];
        }
        buf[n] = ch;
        n += 1;
    }
    return if (n == 0) null else buf[0..n];
}

fn help() void {
    lib.print(
        \\help          commands
        \\yield         yield the CPU
        \\sleep [ms]    sleep (default 1000)
        \\uptime        time since boot
        \\exit [code]   exit the shell
        \\reboot        reboot the machine
        \\poweroff      ACPI S5 power off
        \\cd [dir]      change directory (default /)
        \\[name] [args] spawn /name
        \\a | b         pipe a stdout to b stdin
        \\cmd < file    stdin from file
        \\cmd > file    stdout to file
        \\cmd >> file   append stdout to file
        \\Ctrl-C        stop the running command
    );
}

fn optU64(arg: ?[]const u8, default: u64, usage: []const u8) ?u64 {
    const s = arg orelse return default;
    return lib.parseU64(s) orelse {
        lib.eprint(usage);
        return null;
    };
}

fn doSleep(arg: ?[]const u8) void {
    sys.sleep(optU64(arg, 1000, "usage: sleep [ms]\n") orelse return);
}

fn doUptime() void {
    const ms = sys.uptime() / 1_000_000;
    lib.printU64(ms / 1000);
    lib.print(".");
    const frac = ms % 1000;
    if (frac < 100) lib.print("0");
    if (frac < 10) lib.print("0");
    lib.printU64(frac);
    lib.print("\n");
}

fn doExit(arg: ?[]const u8) void {
    sys.exit(optU64(arg, 0, "usage: exit [code]\n") orelse return);
}

fn doCd(arg: ?[]const u8) void {
    const path = arg orelse "/";
    const rc = sys.chdir(path);
    if (rc < 0) {
        lib.eprint(path);
        lib.printErr(": err ", rc);
    }
}

const Cmd = struct {
    argv: [sys.max_argv][]const u8,
    n: usize,
    in_file: ?[]const u8 = null,
    out_file: ?[]const u8 = null,
    append: bool = false,
};

fn parseCmd(path: []const u8, ps: *[]u8) ?Cmd {
    var argv: [sys.max_argv][]const u8 = undefined;
    argv[0] = path;
    var n: usize = 1;
    var in_file: ?[]const u8 = null;
    var out_file: ?[]const u8 = null;
    var append = false;
    while (nextTok(ps)) |tok| {
        if (tok.len > 0 and tok[0] == '>') {
            const appending = tok.len > 1 and tok[1] == '>';
            const skip: usize = if (appending) 2 else 1;
            const name = if (tok.len > skip) tok[skip..] else nextTok(ps) orelse {
                lib.eprint(if (appending) "usage: cmd >> file\n" else "usage: cmd > file\n");
                return null;
            };
            if (out_file) |_| {
                lib.eprint("too many >\n");
                return null;
            }
            out_file = name;
            append = appending;
            continue;
        }
        if (tok.len > 0 and tok[0] == '<') {
            const name = if (tok.len > 1) tok[1..] else nextTok(ps) orelse {
                lib.eprint("usage: cmd < file\n");
                return null;
            };
            if (in_file) |_| {
                lib.eprint("too many <\n");
                return null;
            }
            in_file = name;
            continue;
        }
        if (n >= argv.len) {
            lib.eprint("too many args\n");
            return null;
        }
        argv[n] = tok;
        n += 1;
    }
    return .{ .argv = argv, .n = n, .in_file = in_file, .out_file = out_file, .append = append };
}

// A token with no '/' is a command at the root (`ls` runs `/ls` after `cd /tmp`).
fn rooted(tok: []const u8, buf: *[max_path]u8) ?[]const u8 {
    for (tok) |c| {
        if (c == '/') return tok;
    }
    if (tok.len + 1 > buf.len) return null;
    buf[0] = '/';
    for (tok, 0..) |c, i| buf[i + 1] = c;
    return buf[0 .. tok.len + 1];
}

fn spawnCmd(cmd: *const Cmd, stdin0: u64, stdout0: u64) i64 {
    var opened_in: ?u64 = null;
    var opened_out: ?u64 = null;
    defer {
        if (opened_in) |fd| _ = sys.close(fd);
        if (opened_out) |fd| _ = sys.close(fd);
    }

    var stdin = stdin0;
    if (cmd.in_file) |f| {
        const fd = sys.open(f);
        if (fd < 0) {
            lib.eprint(f);
            lib.printErr(": err ", fd);
            return fd;
        }
        const nfd: u64 = @intCast(fd);
        opened_in = nfd;
        stdin = nfd;
    }
    var stdout = stdout0;
    if (cmd.out_file) |f| {
        const flags = sys.open_write | sys.open_create | if (cmd.append) sys.open_keep else 0;
        const fd = sys.openAt(f, flags);
        if (fd < 0) {
            lib.eprint(f);
            lib.printErr(": err ", fd);
            return fd;
        }
        const nfd: u64 = @intCast(fd);
        opened_out = nfd;
        stdout = nfd;
        if (cmd.append) {
            const pos = sys.lseek(nfd, 0, sys.seek_end);
            if (pos < 0) {
                lib.printErr("lseek: err ", pos);
                return pos;
            }
        }
    }
    var path_buf: [max_path]u8 = undefined;
    const exe = rooted(cmd.argv[0], &path_buf) orelse {
        lib.eprint("name too long\n");
        return -1;
    };
    const pid = sys.spawn(exe, cmd.argv[0..cmd.n], stdin, stdout, 2);
    if (pid < 0) {
        lib.eprint(cmd.argv[0]);
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
    if (status == 0) return;
    lib.print("exit: ");
    lib.printU64(status);
    lib.print("\n");
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
            lib.eprint("too many |\n");
            return;
        }
    }
    var left_ps: []u8 = left_line;
    var right_ps: []u8 = right_line;
    const left_path = nextTok(&left_ps) orelse {
        lib.eprint("usage: cmd | cmd\n");
        return;
    };
    const right_path = nextTok(&right_ps) orelse {
        lib.eprint("usage: cmd | cmd\n");
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
    } else if (lib.eql(cmd, "uptime")) {
        doUptime();
    } else if (lib.eql(cmd, "exit")) {
        doExit(nextTok(&rest));
    } else if (lib.eql(cmd, "reboot")) {
        sys.reboot();
    } else if (lib.eql(cmd, "poweroff")) {
        sys.poweroff();
    } else if (lib.eql(cmd, "cd")) {
        doCd(nextTok(&rest));
    } else {
        spawnWait(cmd, &rest);
    }
}
