const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const debug = @import("debug.zig");
const tty = @import("../dev/tty.zig");

var panicking: std.atomic.Value(bool) = .init(false);

pub fn panicImpl(message: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    cpu.interruptsOff();
    if (panicking.swap(true, .acq_rel)) cpu.halt();

    // Skip spinlocks: we may already hold one, and IRQs are off.
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    writer.print("[panic] (err) KERNEL PANIC: {s}\r\n", .{message}) catch {};
    debug.printUnsafe(writer.buffered());
    tty.printUnsafe("KERNEL PANIC: {s}\n", .{message});

    cpu.halt();
}

pub fn panic(comptime message: []const u8) noreturn {
    @panic(message);
}
