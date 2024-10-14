const cpu = @import("../sys/cpu.zig");

pub const Status = enum {
    ready,
    running,
    dead,
};

pub const Process = struct {
    pid: u64,
    ctx: cpu.Context,
    status: Status,
};
