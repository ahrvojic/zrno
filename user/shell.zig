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
    lib.print("[name] [args] spawn /name\n");
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

fn spawnWait(path: [*:0]const u8, ps: *[*:0]u8) void {
    var ptrs: [32:null]?[*:0]const u8 = undefined;
    ptrs[0] = path;
    var n: usize = 1;
    while (nextTok(ps)) |tok| {
        if (n >= ptrs.len) {
            lib.print("too many args\n");
            return;
        }
        ptrs[n] = tok;
        n += 1;
    }
    ptrs[n] = null;
    const pid = sys.spawn(path, &ptrs);
    if (pid < 0) {
        lib.print(lib.slice(path));
        lib.printErr(": err ", pid);
        return;
    }
    const wpid = sys.wait(@intCast(pid));
    if (wpid < 0) lib.printErr("wait: err ", wpid);
}

fn dispatch(buf: *[128:0]u8) void {
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
    } else {
        spawnWait(cmd, &rest);
    }
}
