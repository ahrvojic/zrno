//! Debug operations

const port = @import("port.zig");

const debugcon = 0xe9;

pub fn print(string: []const u8) void {
    for (string) |byte| {
        port.outb(debugcon, byte);
    }
}
