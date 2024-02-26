const logger = std.log.scoped(.panic);

const std = @import("std");

const cpu = @import("../sys/cpu.zig");

pub fn panic(comptime message: []const u8) noreturn {
    cpu.interruptsDisable();
    logger.err("KERNEL PANIC: {s}", .{message});
    cpu.halt();
}
