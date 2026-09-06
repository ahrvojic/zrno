const sys = @import("sys.zig");

// Null load: #PF must kill this process, not the kernel.
export fn _start() callconv(.c) noreturn {
    sys.writeAll(1, "faulting...\n");
    const p: *allowzero volatile u8 = @ptrFromInt(0);
    _ = p.*;
    sys.exit(1);
}
