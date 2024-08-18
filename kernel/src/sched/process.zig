const cpu = @import("../sys/cpu.zig");

pub const Process = struct {
    pid: u64,
    ctx: cpu.Context,
};
