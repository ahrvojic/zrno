const lib = @import("lib");
const sys = lib.sys;

// Lives on the parent stack. The worker copies the fds out before it
// blocks, and the parent reads the ids before it drops that stack.
const Shared = struct {
    to_parent: i64,
    to_child: i64,
    child_tid: i64,
    child_pid: i64,
};

fn worker(arg: u64) callconv(.c) noreturn {
    const shared: *Shared = @ptrFromInt(arg);
    const to_parent = shared.to_parent;
    const to_child = shared.to_child;
    shared.child_tid = sys.gettid();
    shared.child_pid = sys.getpid();
    _ = sys.write(@intCast(to_parent), "x");
    var buf: [1]u8 = undefined;
    _ = sys.read(@intCast(to_child), &buf);
    lib.print("thread ok\n");
    sys.threadExit(0);
}

pub fn main() u64 {
    var up: [2]i64 = .{ -1, -1 };
    var down: [2]i64 = .{ -1, -1 };
    if (sys.pipe(&up) < 0 or sys.pipe(&down) < 0) {
        lib.print("thread fail\n");
        return 1;
    }
    var shared = Shared{
        .to_parent = up[1],
        .to_child = down[0],
        .child_tid = -1,
        .child_pid = -1,
    };
    const parent_tid = sys.gettid();
    const parent_pid = sys.getpid();
    const child = sys.thread(&worker, @intFromPtr(&shared));
    if (child < 0) {
        lib.print("thread fail\n");
        return 1;
    }
    var buf: [1]u8 = undefined;
    if (sys.read(@intCast(up[0]), &buf) != 1 or
        shared.child_pid != parent_pid or
        shared.child_tid != child or
        shared.child_tid == parent_tid)
    {
        lib.print("thread fail\n");
        return 1;
    }
    _ = sys.write(@intCast(down[1]), "y");
    // Leave the worker running. Its thread_exit is what ends the process.
    sys.threadExit(0);
}
