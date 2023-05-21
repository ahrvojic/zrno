// GDT long mode offsets
pub const kernel_code_offset = 0x08;
pub const kernel_data_offset = 0x10;
pub const user_code_offset = 0x18;
pub const user_data_offset = 0x20;
pub const tss_offset = 0x28;

// Access byte:
// | P | DPL | S | E | DC | RW | A |
const kernel_code_access = 0x9A;
const kernel_data_access = 0x92;
const user_code_access = 0xFA;
const user_data_access = 0xF2;
const tss_access = 0x89;

// Flags byte:
// | G | DB | L | Reserved |
const lm_flags = 0xA;

const GDTDesc = packed struct {
    limit: u16,
    base_1: u16,
    base_2: u8,
    access: u8,
    flags: u8,
    base_3: u8,
    zero: u32
};

const GDTR = packed struct {
    limit: u16,
    base: *const GDTDesc
};

fn make_desc(base: u32, limit: u16, access: u8, flags: u8) void {
    return GDTDesc {
        .limit = limit,
        .base_1 = @truncate(u16, base),
        .base_2 = @truncate(u8, base >> 16),
        .base_3 = @truncate(u8, base >> 24),
        .access = access,
        .flags = flags
    };
}

var gdt align(4) = []GDTDesc {
    make_desc(0, 0, 0, 0),
    make_desc(0, 0xFFFF, kernel_code_access, lm_flags),
    make_desc(0, 0xFFFF, kernel_data_access, lm_flags),
    make_desc(0, 0xFFFF, user_code_access, lm_flags),
    make_desc(0, 0xFFFF, user_data_access, lm_flags),
    make_desc(0, 0xFFFF, tss_access, 0) // TODO: Set TSS base and limit
};

var gdtr = GDTR {
    .limit = @as(u16, @sizeOf(@TypeOf(gdt)) - 1),
    .base = &gdt[0]
};

pub fn init() void {
    // TODO
}
