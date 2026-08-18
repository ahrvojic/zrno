const logger = std.log.scoped(.panic);

const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const tty = @import("../dev/tty.zig");

var panicking = false;

pub fn panicImpl(message: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    cpu.interruptsOff();
    if (panicking) cpu.halt();
    panicking = true;

    const msg = "KERNEL PANIC: {s}";
    const args = .{message};

    logger.err(msg, args);
    tty.print(msg, args);

    cpu.halt();
}

pub fn panic(comptime message: []const u8) noreturn {
    @panic(message);
}
