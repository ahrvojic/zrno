//! Global Descriptor Table

const std = @import("std");

const debug = @import("debug.zig");

// GDT long mode selectors
pub const kernel_code_sel = 0x08;
pub const kernel_data_sel = 0x10;
pub const user_code_sel   = 0x18;
pub const user_data_sel   = 0x20;
pub const tss_sel         = 0x28;

// Access byte:
// | P | DPL(2) | S | 1 | C | R | A |
const kernel_code_access = 0b10011010;
const user_code_access   = 0b11111010;
// | P | DPL(2) | S | 0 | E | W | A |
const kernel_data_access = 0b10010010;
const user_data_access   = 0b11110010;

// System access byte:
// | P | DPL(2) | S | Type(4) |
const tss_access = 0b10001001;

// Flags nibble:
// | G | DB | L | AVL |
const code_flags = 0b1010;
const data_flags = 0b1100;

const TSSEntry = packed struct {
    limit_1: u16,
    base_1: u16,
    base_2: u8,
    access: u8,
    limit_2: u4,
    flags: u4,
    base_3: u8,
    base_4: u32,
    reserved: u32,

    pub fn make(base: u64, limit: u32, access: u8, flags: u4) TSSEntry {
        return .{
            .base_1 = @truncate(base),
            .base_2 = @truncate(base >> 16),
            .base_3 = @truncate(base >> 24),
            .base_4 = @truncate(base >> 32),
            .limit_1 = @truncate(limit),
            .limit_2 = @truncate(limit >> 16),
            .access = access,
            .flags = flags,
            .reserved = 0,
        };
    }
};

pub const TSS = packed struct {
    reserved_1: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved_2: u32 = 0,
    reserved_3: u32 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved_4: u32 = 0,
    reserved_5: u32 = 0,
    reserved_6: u16 = 0,
    io_base: u16 = 0,
};

const GDTR = packed struct {
    limit: u16,
    base: u64,
};

const GDTEntry = packed struct {
    limit_1: u16,
    base_1: u16,
    base_2: u8,
    access: u8,
    flags: u4,
    limit_2: u4,
    base_3: u8,

    pub fn make(base: u32, limit: u20, access: u8, flags: u4) GDTEntry {
        return .{
            .base_1 = @truncate(base),
            .base_2 = @truncate(base >> 16),
            .base_3 = @truncate(base >> 24),
            .limit_1 = @truncate(limit),
            .limit_2 = @truncate(limit >> 16),
            .access = access,
            .flags = flags,
        };
    }
};

pub const GDT = struct {
    entries: [7]u64 align(8) = .{
        0, // null
        @as(u64, @bitCast(GDTEntry.make(0, 0xfffff, kernel_code_access, code_flags))),
        @as(u64, @bitCast(GDTEntry.make(0, 0xfffff, kernel_data_access, data_flags))),
        @as(u64, @bitCast(GDTEntry.make(0, 0xfffff, user_code_access, code_flags))),
        @as(u64, @bitCast(GDTEntry.make(0, 0xfffff, user_data_access, data_flags))),
        0, // TSS low
        0, // TSS high
    },

    pub fn load(self: *GDT, tss: *TSS) void {
        const tss_entry = TSSEntry.make(
            @intFromPtr(tss),
            @sizeOf(TSS) - 1,
            tss_access,
            0,
        );

        const tss_entry_bits: [2]u64 = @bitCast(tss_entry);
        self.entries[5] = tss_entry_bits[0];
        self.entries[6] = tss_entry_bits[1];

        const gdtr = GDTR {
            .limit = @sizeOf(GDT) - 1,
            .base = @intFromPtr(self),
        };

        debug.print("[GDT] Load register and TSS\r\n");
        asm volatile (
            \\lgdt (%[gdtr])
            \\ltr %[tss_sel]
            :
            : [gdtr] "r" (&gdtr),
              [tss_sel] "r" (@as(u16, tss_sel)),
        );

        debug.print("[GDT] Reload selectors\r\n");
        flush();
    }

    /// Replaces the selectors set by the bootloader
    fn flush() void {
        asm volatile (
            \\push %[kernel_code_sel]
            \\lea .reload_cs(%rip), %rax
            \\push %rax
            \\lretq
            \\.reload_cs:
            \\mov %[kernel_data_sel], %ax
            \\mov %ax, %ds
            \\mov %ax, %es
            \\mov %ax, %fs
            \\mov %ax, %gs
            \\mov %ax, %ss
            :
            : [kernel_code_sel] "i" (@as(u16, kernel_code_sel)),
              [kernel_data_sel] "i" (@as(u16, kernel_data_sel)),
        );
    }
};

test "TSS entry construction" {
    const value = TSSEntry.make(0x800080808000, 0x00088000, 0x80, 0);
    const expected = TSSEntry {
        .base_1 = 0x8000,
        .base_2 = 0x80,
        .base_3 = 0x80,
        .base_4 = 0x8000,
        .limit_1 = 0x8000,
        .limit_2 = 0x8,
        .access = 0,
        .flags = 0,
        .reserved = 0,
    };
    try std.testing.expect(value.base_1 == expected.base_1);
    try std.testing.expect(value.base_2 == expected.base_2);
    try std.testing.expect(value.base_3 == expected.base_3);
    try std.testing.expect(value.base_4 == expected.base_4);
    try std.testing.expect(value.limit_1 == expected.limit_1);
    try std.testing.expect(value.limit_2 == expected.limit_2);
}

test "GDT entry construction" {
    const value = GDTEntry.make(0x80808000, 0x88000, 0, 0);
    const expected = GDTEntry {
        .base_1 = 0x8000,
        .base_2 = 0x80,
        .base_3 = 0x80,
        .limit_1 = 0x8000,
        .limit_2 = 0x8,
        .access = 0,
        .flags = 0,
    };
    try std.testing.expect(value.base_1 == expected.base_1);
    try std.testing.expect(value.base_2 == expected.base_2);
    try std.testing.expect(value.base_3 == expected.base_3);
    try std.testing.expect(value.limit_1 == expected.limit_1);
    try std.testing.expect(value.limit_2 == expected.limit_2);
}
