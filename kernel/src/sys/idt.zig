const logger = std.log.scoped(.idt);

const std = @import("std");

const gdt = @import("gdt.zig");
const ivt = @import("ivt.zig");

// Flags byte:
// | P | DPL(2) | R | Type(4) |
const interrupt_gate = 0b10001110;

const IDTR = extern struct {
    limit: u16 align(1),
    base: u64 align(1),
};

const IDTEntry = extern struct {
    offset_1: u16 align(1),
    selector: u16 align(1),
    ist: u8 align(1),
    flags: u8 align(1),
    offset_2: u16 align(1),
    offset_3: u32 align(1),
    reserved: u32 align(1),

    pub fn make(offset: u64, ist: u8, flags: u8) IDTEntry {
        return .{
            .offset_1 = @truncate(offset),
            .offset_2 = @truncate(offset >> 16),
            .offset_3 = @truncate(offset >> 32),
            .ist = ist,
            .flags = flags,
            .selector = gdt.kernel_code_sel,
            .reserved = 0,
        };
    }
};

pub const IDT = struct {
    entries: [256]IDTEntry align(16) = undefined,

    pub fn load(self: *@This()) void {
        logger.info("Set interrupt handlers", .{});
        comptime var i: usize = 0;
        inline while (i < 256) : (i += 1) {
            const handler = comptime ivt.makeHandler(i);
            self.entries[i] = IDTEntry.make(@intFromPtr(handler), 0, interrupt_gate);
        }

        const idtr = IDTR {
            .limit = @sizeOf(IDT) - 1,
            .base = @intFromPtr(self),
        };

        logger.info("Load register", .{});
        asm volatile (
            \\lidt (%[idtr])
            :
            : [idtr] "r" (&idtr)
        );
    }
};

test "IDT entry construction" {
    const value = IDTEntry.make(0x8000000080008000, 0, 0);
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
