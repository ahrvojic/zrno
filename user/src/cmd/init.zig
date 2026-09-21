const lib = @import("lib");
const sys = lib.sys;

pub fn main() u64 {
    // SSE/AVX canary: #NM/#UD or a wrong result kills init (and the boot).
    var a: f64 = 1.5;
    const p: *volatile f64 = &a;
    if (p.* * 2.0 != 3.0) return 1;
    var v: @Vector(8, f32) = @splat(1.0);
    const pv: *volatile @Vector(8, f32) = &v;
    pv.* = pv.* + pv.*;
    if (pv.*[0] != 2.0) return 1;
    lib.print("READY.\n");
    const argv = [_][]const u8{"/shell"};
    var shell_pid: i64 = -1;
    while (true) {
        if (shell_pid < 0) {
            const pid = sys.spawn("/shell", &argv, 0, 1, 2);
            if (pid < 0) {
                lib.printErr("spawn /shell: ", pid);
                sys.sleep(1000);
                continue;
            }
            shell_pid = pid;
        }
        const pid = sys.wait(0);
        if (pid < 0) {
            shell_pid = -1;
            continue;
        }
        if (pid == shell_pid) {
            lib.print("shell exited\n");
            shell_pid = -1;
        }
    }
}
