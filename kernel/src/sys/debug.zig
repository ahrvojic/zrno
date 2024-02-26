const cpu = @import("cpu.zig");
const port = @import("port.zig");

const qemu_debug_console = 0xe9;

pub fn print(string: []const u8) void {
    for (string) |byte| {
        port.outb(qemu_debug_console, byte);
    }
}

pub fn println(string: []const u8) callconv(.Inline) void {
    print(string);
    print("\r\n");
}

pub fn panic(comptime message: []const u8) noreturn {
    println("KERNEL PANIC: " ++ message);
    cpu.interruptsDisable();
    cpu.halt();
}
