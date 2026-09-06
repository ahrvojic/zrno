const sys = @import("sys.zig");

export fn _start() callconv(.c) noreturn {
    sys.writeAll(1, "Hello from userspace!\n");
    sys.exit(0);
}
