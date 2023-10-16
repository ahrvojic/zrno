const std = @import("std");

const debug = @import("debug.zig");
const gdt = @import("gdt.zig");
const interrupts = @import("interrupts.zig");

// Flags byte:
// | P | DPL(2) | R | Type(4) |
const interrupt_gate = 0b10001110;

const IDTR = packed struct {
    limit: u16,
    base: u64,
};

const IDTEntry = packed struct {
    offset_1: u16,
    selector: u16,
    ist: u8,
    flags: u8,
    offset_2: u16,
    offset_3: u32,
    reserved: u32,

    pub fn make(offset: u64, flags: u8) IDTEntry {
        return .{
            .offset_1 = @truncate(offset),
            .offset_2 = @truncate(offset >> 16),
            .offset_3 = @truncate(offset >> 32),
            .flags = flags,
            .selector = gdt.kernel_code_sel,
            .ist = 0,
            .reserved = 0,
        };
    }
};

pub const IDT = struct {
    entries: [256]IDTEntry align(16) = undefined,

    pub fn load(self: *IDT) void {
        debug.println("[IDT] Set interrupt handlers");
        comptime var i: usize = 0;
        inline while (i < 256) : (i += 1) {
            const handler = comptime interrupts.makeHandler(i);
            self.entries[i] = IDTEntry.make(@intFromPtr(handler), interrupt_gate);
        }

        const idtr = IDTR {
            .limit = @sizeOf(IDT) - 1,
            .base = @intFromPtr(self),
        };

        debug.println("[IDT] Load register");
        asm volatile (
            \\lidt (%[idtr])
            :
            : [idtr] "r" (&idtr)
        );
    }
};

test "IDT entry construction" {
    const value = IDTEntry.make(0x8000000080008000, 0);
    const expected = IDTEntry {
        .offset_1 = 0x8000,
        .offset_2 = 0x8000,
        .offset_3 = 0x80000000,
        .flags = 0,
        .selector = gdt.kernel_code_sel,
        .ist = 0,
        .reserved = 0,
    };
    try std.testing.expect(std.meta.eql(value, expected));
}
