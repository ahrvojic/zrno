const arch = @import("arch.zig");
const port = @import("port.zig");

const debugcon = 0xe9;

pub fn printInt(num: u64) void {
    const q = num / 10;
    if (q > 0) printInt(q);
    port.outb(debugcon, @truncate(num % 10 + '0'));
}

pub fn print(string: []const u8) void {
    for (string) |byte| {
        port.outb(debugcon, byte);
    }
}

pub fn println(string: []const u8) callconv(.Inline) void {
    print(string);
    print("\r\n");
}

pub fn panic(comptime message: []const u8) noreturn {
    println("KERNEL PANIC: " ++ message);
    arch.hang();
}
