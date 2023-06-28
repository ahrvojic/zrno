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

const GDTEntry = packed struct {
    limit_1: u16,
    base_1: u16,
    base_2: u8,
    access: u8,
    flags: u4,
    limit_2: u4,
    base_3: u8
};

const GDTR = packed struct {
    limit: u16,
    base: *const GDTEntry
};

const TSS = packed struct {
    limit_1: u16,
    base_1: u16,
    base_2: u8,
    access: u8,
    limit_2: u4,
    flags: u4,
    base_3: u8,
    base_4: u32,
    zero: u32
};

fn make_desc(base: u32, limit: u32, access: u8, flags: u8) void {
    return GDTEntry {
        .base_1  = @truncate(u16, base),
        .base_2  = @truncate(u8, base >> 16),
        .base_3  = @truncate(u8, base >> 24),
        .limit_1 = @truncate(u16, limit),
        .limit_2 = @truncate(u4, limit >> 16),
        .access  = access,
        .flags   = flags
    };
}

const gdt align(8) = []GDTEntry {
    make_desc(0, 0, 0, 0), // null descriptor
    make_desc(0, 0xFFFF, kernel_code_access, seg_flags),
    make_desc(0, 0xFFFF, kernel_data_access, seg_flags),
    make_desc(0, 0xFFFF, user_code_access, seg_flags),
    make_desc(0, 0xFFFF, user_data_access, seg_flags)
};

export const gdtr = GDTR {
    .limit = @as(u16, @sizeOf(@TypeOf(gdt)) - 1),
    .base  = &gdt[0]
};

const tss_base = @ptrToInt(&tss_seg);
const tss_limit = @sizeOf(TSS);
export const tss_seg align(8) = TSS {
    .base_1  = @truncate(u16, tss_base),
    .base_2  = @truncate(u8, tss_base >> 16),
    .base_3  = @truncate(u8, tss_base >> 24),
    .base_4  = @truncate(u32, tss_base >> 32),
    .limit_1 = @truncate(u16, tss_limit),
    .limit_2 = @truncate(u4, tss_limit >> 16),
    .access  = tss_access,
    .flags   = tss_flags,
    .zero    = 0
};

// See gdt.s
extern fn load_gdt() void;
extern fn load_tss() void;

pub fn init() void {
    load_gdt();
    load_tss();
}
