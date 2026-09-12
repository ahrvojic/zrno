const lib = @import("lib");
const sys = lib.sys;

pub fn main() u64 {
    lib.print("READY.\n");
    const argv = [_:null]?[*:0]const u8{"/shell"};
    while (true) {
        const pid = sys.spawn("/shell", &argv);
        if (pid < 0) {
            lib.printErr("spawn /shell: ", pid);
            sys.sleep(1000);
            continue;
        }
        const code = sys.wait(@intCast(pid));
        if (code < 0) lib.printErr("wait: err ", code);
        lib.print("shell exited\n");
    }
}
