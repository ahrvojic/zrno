pub const KERNEL_CODE = 0x08;
pub const KERNEL_DATA = 0x10;
pub const USER_CODE   = 0x18;
pub const USER_DATA   = 0x20;
pub const TSS_DESC    = 0x28;

const GDTDesc = packed struct {
    limit: u16,
    base_1: u16,
    base_2: u8,
    access: u8,
    granularity: u8,
    base_3: u8,
    zero: u32
};

const GDTR = packed struct {
    limit: u16,
    base: *const GDTDesc
};

fn make_desc(limit: u16, base: u32, access: u8, granularity: u8) void {
    return GDTDesc {
        .limit = limit,
        .base_1 = @truncate(u16, base),
        .base_2 = @truncate(u8, base >> 16),
        .base_3 = @truncate(u8, base >> 24),
        .access = access,
        .granularity = granularity
    };
}

var gdt align(4) = []GDTDesc {
    make_desc(0, 0, 0, 0),
    // TODO
};

var gdtr = GDTR {
    .limit = @as(u16, @sizeOf(@TypeOf(gdt)) - 1),
    .base = &gdt[0]
};

pub fn init() void {
    // TODO
}
