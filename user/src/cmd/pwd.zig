const lib = @import("lib");
const sys = lib.sys;

pub fn main() u64 {
    var buf: [sys.max_path]u8 = undefined;
    const n = sys.getcwd(&buf);
    if (n < 0) {
        lib.printErr("pwd: err ", n);
        return 1;
    }
    lib.print(buf[0..@intCast(n)]);
    lib.print("\n");
    return 0;
}
