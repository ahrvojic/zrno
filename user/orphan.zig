const lib = @import("lib");
const sys = lib.sys;

// Spawn /hello and exit without wait. Init reaps the grandchild.
pub fn main() u64 {
    const argv = [_:null]?[*:0]const u8{"/hello"};
    const pid = sys.spawn("/hello", &argv);
    if (pid < 0) {
        lib.printErr("orphan: spawn ", pid);
        return 1;
    }
    return 0;
}
