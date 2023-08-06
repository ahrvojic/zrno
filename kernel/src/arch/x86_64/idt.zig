//! Interrupt Descriptor Table

const gdt = @import("gdt.zig");
const interrupts = @import("interrupts.zig");

const type_intr = 0x0e;
const type_trap = 0x0f;

const IDTR = packed struct {
    limit: u16,
    base: u64,
};

const IDTEntry = packed struct {
    offset_1: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_2: u16,
    offset_3: u32,
    reserved: u32,

    pub fn make(offset: u64, type_attr: u8) IDTEntry {
        return .{
            .offset_1 = @truncate(offset),
            .offset_2 = @truncate(offset >> 16),
            .offset_3 = @truncate(offset >> 32),
            .type_attr = type_attr,
            .selector = gdt.kernel_code_sel,
            .ist = 0,
            .reserved = 0,
        };
    }
};

pub const IDT = struct {
    entries: [256]IDTEntry align(16) = undefined,

    pub fn load(self: *IDT) void {
        const idtr = IDTR {
            .limit = @sizeOf(IDT) - 1,
            .base = @intFromPtr(self),
        };

        // TODO: Interrupt handlers

        asm volatile (
            \\lidt (%[idtr])
            :
            : [idtr] "r" (&idtr)
        );
    }
};
