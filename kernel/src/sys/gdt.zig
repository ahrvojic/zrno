const logger = std.log.scoped(.gdt);

const std = @import("std");

// GDT long mode selectors
pub const kernel_code_sel = 0x08;
pub const kernel_data_sel = 0x10;
pub const user_code_sel = 0x18;
pub const user_data_sel = 0x20;
pub const tss_sel = 0x28;

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

const GDTR = extern struct {
    limit: u16 align(1),
    base: u64 align(1),
};

const GDTEntry = extern struct {
    limit: u16 align(1),
    base_1: u16 align(1),
    base_2: u8 align(1),
    access: u8 align(1),
    flags: u8 align(1),
    base_3: u8 align(1),

    pub fn make(base: u32, limit: u20, access: u8, flags: u4) GDTEntry {
        return .{
            .base_1 = @truncate(base),
            .base_2 = @truncate(base >> 16),
            .base_3 = @truncate(base >> 24),
            .limit = @truncate(limit),
            .access = access,
            .flags = @as(u8, flags) << 4 | @as(u8, @truncate(limit >> 16)),
        };
    }
};

pub const TSS = extern struct {
    reserved_1: u32 align(1) = 0,
    rsp: [3]u64 align(1) = .{ 0, 0, 0 },
    reserved_2: u32 align(1) = 0,
    reserved_3: u32 align(1) = 0,
    ist: [7]u64 align(1) = .{ 0, 0, 0, 0, 0, 0, 0 },
    reserved_4: u32 align(1) = 0,
    reserved_5: u32 align(1) = 0,
    reserved_6: u16 align(1) = 0,
    iopb_offset: u16 align(1) = 0,
};

const TSSEntry = extern struct {
    limit: u16 align(1),
    base_1: u16 align(1),
    base_2: u8 align(1),
    access: u8 align(1),
    flags: u8 align(1),
    base_3: u8 align(1),
    base_4: u32 align(1),
    reserved: u32 align(1),

    pub fn make(base: u64, limit: u16, access: u8) TSSEntry {
        return .{
            .base_1 = @truncate(base),
            .base_2 = @truncate(base >> 16),
            .base_3 = @truncate(base >> 24),
            .base_4 = @truncate(base >> 32),
            .limit = limit,
            .access = access,
            .flags = 0,
            .reserved = 0,
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

    pub fn load(self: *@This(), tss: *const TSS) void {
        const tss_entry = TSSEntry.make(@intFromPtr(tss), @sizeOf(TSS) - 1, tss_access);
        const tss_entry_bits: [2]u64 = @bitCast(tss_entry);
        self.entries[5] = tss_entry_bits[0];
        self.entries[6] = tss_entry_bits[1];

        const gdtr = GDTR {
            .limit = @sizeOf(GDT) - 1,
            .base = @intFromPtr(self),
        };

        logger.info("Load register", .{});
        asm volatile (
            \\lgdt (%[gdtr])
            :
            : [gdtr] "r" (&gdtr)
        );

        logger.info("Reload selectors", .{});
        reload();

        logger.info("Load TSS", .{});
        asm volatile(
            \\ltr %[tss_sel]
            :
            : [tss_sel] "r" (@as(u16, tss_sel)),
        );
    }
};

fn reload() callconv(.Inline) void {
    asm volatile (
        \\pushq %[kernel_code_sel]
        \\lea .reload_cs(%rip), %rax
        \\push %rax
        \\lretq
        \\
        \\.reload_cs:
        \\movw %[kernel_data_sel], %ax
        \\movw %ax, %ds
        \\movw %ax, %es
        \\movw %ax, %fs
        \\movw %ax, %gs
        \\movw %ax, %ss
        :
        : [kernel_code_sel] "i" (kernel_code_sel),
          [kernel_data_sel] "i" (kernel_data_sel),
    );
}

test "GDT entry construction" {
    const value = GDTEntry.make(0x80808000, 0x8000, 0, 0);
    const expected = GDTEntry {
        .base_1 = 0x8000,
        .base_2 = 0x80,
        .base_3 = 0x80,
        .limit = 0x8000,
        .access = 0,
        .flags = 0,
    };
    try std.testing.expect(std.meta.eql(value, expected));
}

test "TSS entry construction" {
    const value = TSSEntry.make(0x800080808000, 0, 0);
    const expected = TSSEntry {
        .base_1 = 0x8000,
        .base_2 = 0x80,
        .base_3 = 0x80,
        .base_4 = 0x8000,
        .limit = 0,
        .access = 0,
        .flags = 0,
        .reserved = 0,
    };
    try std.testing.expect(std.meta.eql(value, expected));
}
