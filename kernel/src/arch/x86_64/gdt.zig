//! Global Descriptor Table

const debug = @import("debug.zig");

// GDT long mode segments
pub const kernel_code_seg = 0x08;
pub const kernel_data_seg = 0x10;
pub const user_code_seg   = 0x18;
pub const user_data_seg   = 0x20;
pub const tss_seg         = 0x28;

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
const seg_flags = 0b1010;
const tss_flags = 0b0010;

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

    pub fn make(base: u32, limit: u32, access: u8, flags: u4) GDTEntry {
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
        @as(u64, @bitCast(GDTEntry.make(0, 0xFFFF, kernel_code_access, seg_flags))),
        @as(u64, @bitCast(GDTEntry.make(0, 0xFFFF, kernel_data_access, seg_flags))),
        @as(u64, @bitCast(GDTEntry.make(0, 0xFFFF, user_code_access, seg_flags))),
        @as(u64, @bitCast(GDTEntry.make(0, 0xFFFF, user_data_access, seg_flags))),
        0, // TSS low
        0, // TSS high
    },

    pub fn load(self: *GDT, tss: *TSS) void {
        const tss_entry = TSSEntry.make(
            @intFromPtr(tss),
            @sizeOf(TSS) - 1,
            tss_access,
            tss_flags,
        );

        const tss_entry_bits: [2]u64 = @bitCast(tss_entry);
        self.entries[5] = tss_entry_bits[0];
        self.entries[6] = tss_entry_bits[1];

        const gdtr = GDTR {
            .limit = @sizeOf(GDT) - 1,
            .base = @intFromPtr(self),
        };

        debug.print("[GDT] Load register and TSS\n");
        asm volatile (
            \\lgdt (%[gdtr])
            \\ltr %[tss_seg]
            :
            : [gdtr] "r" (&gdtr),
              [tss_seg] "r" (@as(u16, tss_seg))
        );

        debug.print("[GDT] Reload segments\n");
        flush();
    }

    /// Replaces the segements set by the bootloader
    fn flush() void {
        asm volatile (
            \\movw %[kernel_data_seg], %ax
            \\movw %ax, %ds
            \\movw %ax, %es
            \\movw %ax, %fs
            \\movw %ax, %gs
            \\movw %ax, %ss
            \\
            \\popq %rdi
            \\push %[kernel_code_seg]
            \\push %rdi
            \\lretq
            :
            : [kernel_data_seg] "i" (kernel_data_seg),
              [kernel_code_seg] "i" (kernel_code_seg)
        );
    }
};
