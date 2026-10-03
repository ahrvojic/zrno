const lib = @import("lib");
const sys = lib.sys;

fn printState(state: u64) void {
    const name: ?[]const u8 = switch (state) {
        sys.ps_ready => "ready",
        sys.ps_running => "running",
        sys.ps_sleeping => "sleeping",
        sys.ps_waiting => "waiting",
        sys.ps_zombie => "zombie",
        else => null,
    };
    if (name) |s| {
        lib.print(s);
    } else {
        lib.printU64(state);
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
    lib.print("tid pid ppid state\n");
    for (ents[0..count]) |e| {
        if (e.state == sys.ps_zombie) {
            lib.print("-");
        } else {
            lib.printU64(e.tid);
        }
        lib.print(" ");
        lib.printU64(e.pid);
        lib.print(" ");
        lib.printU64(e.ppid);
        lib.print(" ");
        printState(e.state);
        lib.print("\n");
    }
    return 0;
}
