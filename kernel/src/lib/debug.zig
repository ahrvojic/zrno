const port = @import("../sys/port.zig");

const qemu_debug_console = 0xe9;

pub fn print(string: []const u8) void {
    for (string) |byte| {
        port.outb(qemu_debug_console, byte);
    }
}
