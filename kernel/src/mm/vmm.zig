const pmm = @import("pmm.zig");

pub fn init() !void {
    _ = pmm.alloc(1) orelse return error.OutOfMemory;
    // TODO
}
