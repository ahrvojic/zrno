const lib = @import("lib");
const sys = lib.sys;

pub fn main() u64 {
    var ents: [64]sys.PsInfo = undefined;
    const n = sys.ps(&ents);
    if (n < 0) {
        lib.printErr("ps: err ", n);
        return 1;
    }
    const count = @as(usize, @intCast(n)) / @sizeOf(sys.PsInfo);
    lib.print("pid ppid\n");
    for (ents[0..count]) |e| {
        lib.printU64(e.pid);
        lib.print(" ");
        lib.printU64(e.ppid);
        if (e.flags & sys.ps_zombie != 0) lib.print(" z");
        lib.print("\n");
    }
    return 0;
}
