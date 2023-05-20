pub const KERNEL_CODE = 0x08;
pub const KERNEL_DATA = 0x10;
pub const USER_CODE   = 0x18;
pub const USER_DATA   = 0x20;
pub const TSS_DESC    = 0x28;

const SegmentDesc = packed struct {
    limit: u16,
    base_1: u16,
    base_2: u8,
    access: u8,
    granularity: u8,
    base_3: u8,
    zero: u32
};

const GDTDesc = packed struct {
    limit: u16,
    base: *const GDTDesc
};
