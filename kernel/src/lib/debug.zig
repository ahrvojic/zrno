const serial = @import("../dev/serial.zig");
const Lock = @import("lock.zig");

var lock: Lock.SpinLock = .{};

pub fn print(string: []const u8) void {
    lock.lock();
    defer lock.unlock();
    serial.write(string);
}

pub fn printUnsafe(string: []const u8) void {
    serial.write(string);
}
