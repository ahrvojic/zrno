const logger = std.log.scoped(.panic);

const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const tty = @import("../dev/tty.zig");

pub fn panic(comptime message: []const u8) noreturn {
    cpu.interruptsDisable();

    const msg = "KERNEL PANIC: {s}";
    logger.err(msg, .{message});
    tty.print(msg ++ "\n", .{message});

    cpu.halt();
}
