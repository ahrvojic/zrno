const logger = std.log.scoped(.panic);

const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const tty = @import("../dev/tty.zig");

pub fn panic(comptime message: []const u8) noreturn {
    cpu.interruptsDisable();

    const msg = "KERNEL PANIC: {s}";
    const args = .{message};

    logger.err(msg, args);
    tty.print(msg, args);

    cpu.halt();
}
