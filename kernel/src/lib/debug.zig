const port = @import("../sys/port.zig");
const Lock = @import("lock.zig");

const qemu_debug_console = 0xe9;

var lock: Lock.SpinLock = .{};

pub fn print(string: []const u8) void {
    lock.lock();
    defer lock.unlock();
    write(string);
}

pub fn printUnsafe(string: []const u8) void {
    write(string);
}

fn write(string: []const u8) void {
    for (string) |byte| {
        port.outb(qemu_debug_console, byte);
    }
}
