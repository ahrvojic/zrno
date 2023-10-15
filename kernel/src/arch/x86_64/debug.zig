const arch = @import("arch.zig");
const port = @import("port.zig");

const debugcon = 0xe9;

pub fn printInt(num: u64) void {
    if (num == 0) return;
    printInt(num / 10);
    port.outb(debugcon, @truncate(num % 10 + '0'));
}

pub fn print(string: []const u8) void {
    for (string) |byte| {
        port.outb(debugcon, byte);
    }
}

pub fn println(string: []const u8) void {
    print(string);
    print("\r\n");
}

pub fn panic(message: []const u8) noreturn {
    print("KERNEL PANIC: ");
    println(message);
    arch.hang();
}
