const lib = @import("lib");
const sys = lib.sys;

// A u64 is at most 20 digits, and each title is shorter than that.
const spaces = "                    ";

const h_tid = "tid";
const h_pid = "pid";
const h_ppid = "ppid";
const h_state = "state";

fn digits(v: u64) usize {
    var n: usize = 1;
    var x = v;
    while (x >= 10) : (x /= 10) n += 1;
    return n;
}

fn printPad(width: usize, len: usize) void {
    if (len < width) lib.print(spaces[0 .. width - len]);
}

fn printCol(text: []const u8, width: usize) void {
    printPad(width, text.len);
    lib.print(text);
}

fn printNum(v: u64, width: usize) void {
    printPad(width, digits(v));
    lib.printU64(v);
}

fn stateName(state: u64) ?[]const u8 {
    return switch (state) {
        sys.ps_ready => "ready",
        sys.ps_running => "running",
        sys.ps_sleeping => "sleeping",
        sys.ps_waiting => "waiting",
        sys.ps_zombie => "zombie",
        else => null,
    };
}

fn stateLen(state: u64) usize {
    if (stateName(state)) |s| return s.len;
    return digits(state);
}

fn printLeft(text: []const u8, width: usize) void {
    lib.print(text);
    printPad(width, text.len);
}

fn printState(state: u64, width: usize) void {
    if (stateName(state)) |s| {
        printLeft(s, width);
    } else {
        const n = digits(state);
        lib.printU64(state);
        printPad(width, n);
    }
}

pub fn main() u64 {
    var ents: [64]sys.PsInfo = undefined;
    const n = sys.ps(&ents);
    if (n < 0) {
        lib.printErr("ps: err ", n);
        return 1;
    }
    const count = @as(usize, @intCast(n)) / @sizeOf(sys.PsInfo);
    const rows = ents[0..count];

    var w_tid: usize = h_tid.len;
    var w_pid: usize = h_pid.len;
    var w_ppid: usize = h_ppid.len;
    var w_state: usize = h_state.len;
    for (rows) |e| {
        const tid_len: usize = if (e.state == sys.ps_zombie) 1 else digits(e.tid);
        w_tid = @max(w_tid, tid_len);
        w_pid = @max(w_pid, digits(e.pid));
        w_ppid = @max(w_ppid, digits(e.ppid));
        w_state = @max(w_state, stateLen(e.state));
    }

    printCol(h_tid, w_tid);
    lib.print(" ");
    printCol(h_pid, w_pid);
    lib.print(" ");
    printCol(h_ppid, w_ppid);
    lib.print(" ");
    printLeft(h_state, w_state);
    lib.print(" name\n");

    for (rows) |e| {
        if (e.state == sys.ps_zombie) {
            printCol("-", w_tid);
        } else {
            printNum(e.tid, w_tid);
        }
        lib.print(" ");
        printNum(e.pid, w_pid);
        lib.print(" ");
        printNum(e.ppid, w_ppid);
        lib.print(" ");
        printState(e.state, w_state);
        lib.print(" ");
        const name_len = @min(e.name_len, sys.ps_name_max);
        lib.print(e.name[0..name_len]);
        lib.print("\n");
    }
    return 0;
}
