//! COM1, 115200 8N1. The kernel reinitializes the same port.

const std = @import("std");

const com1: u16 = 0x3f8;

var ready = false;

pub fn init() void {
    if (!scratchOk()) return;
    outb(com1 + 3, 0x03);
    outb(com1 + 1, 0x00);
    outb(com1 + 3, 0x83);
    outb(com1 + 0, 0x01);
    outb(com1 + 1, 0x00);
    outb(com1 + 3, 0x03);
    outb(com1 + 2, 0xc7);
    outb(com1 + 4, 0x0b);
    ready = true;
}

pub fn puts(bytes: []const u8) void {
    if (!ready) return;
    for (bytes) |byte| {
        var spins: u32 = 0;
        while (inb(com1 + 5) & 0x20 == 0) {
            if (spins == 0xffff) return;
            spins += 1;
            asm volatile ("pause");
        }
        outb(com1, byte);
    }
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [160]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    writer.print(fmt, args) catch {
        puts(buf[0..writer.end]);
        return;
    };
    puts(writer.buffered());
}

fn scratchOk() bool {
    outb(com1 + 7, 0x5a);
    if (inb(com1 + 7) != 0x5a) return false;
    outb(com1 + 7, 0xa5);
    return inb(com1 + 7) == 0xa5;
}

fn outb(comptime port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

fn inb(comptime port: u16) u8 {
    return asm volatile ("inb %[port], %[res]"
        : [res] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}
