const lib = @import("lib");
const sys = lib.sys;

pub fn main() u64 {
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
