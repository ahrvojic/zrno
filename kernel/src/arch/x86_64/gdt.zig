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
    reserved_1: u32,
    rsp0: u64,
    rsp1: u64,
    rsp2: u64,
    reserved_2: u32,
    reserved_3: u32,
    ist1: u64,
    ist2: u64,
    ist3: u64,
    ist4: u64,
    ist5: u64,
    ist6: u64,
    ist7: u64,
    reserved_4: u32,
    reserved_5: u32,
    reserved_6: u16,
    io_base: u16
};

const TSSEntry = packed struct {
    limit_1: u16,
    base_1: u16,
    base_2: u8,
    access: u8,
    limit_2: u4,
    flags: u4,
    base_3: u8,
    base_4: u32,
    reserved: u32
};

fn make_gdt_entry(base: u32, limit: u32, access: u8, flags: u4) GDTEntry {
    return GDTEntry {
        .base_1 = @truncate(u16, base),
        .base_2 = @truncate(u8, base >> 16),
        .base_3 = @truncate(u8, base >> 24),
        .limit_1 = @truncate(u16, limit),
        .limit_2 = @truncate(u4, limit >> 16),
        .access = access,
        .flags = flags
    };
}

fn make_tss_entry(base: u64, limit: u32, access: u8, flags: u4) TSSEntry {
    return TSSEntry {
        .base_1 = @truncate(u16, base),
        .base_2 = @truncate(u8, base >> 16),
        .base_3 = @truncate(u8, base >> 24),
        .base_4 = @truncate(u32, base >> 32),
        .limit_1 = @truncate(u16, limit),
        .limit_2 = @truncate(u4, limit >> 16),
        .access = access,
        .flags = flags,
        .reserved = 0
    };
}

var gdt align(8) = [_]GDTEntry {
    make_gdt_entry(0, 0, 0, 0), // null descriptor
    make_gdt_entry(0, 0xFFFF, kernel_code_access, seg_flags),
    make_gdt_entry(0, 0xFFFF, kernel_data_access, seg_flags),
    make_gdt_entry(0, 0xFFFF, user_code_access, seg_flags),
    make_gdt_entry(0, 0xFFFF, user_data_access, seg_flags),
    make_gdt_entry(0, 0, 0, 0) // TSS placeholder
};

const gdtr = GDTR {
    .limit = @as(u16, @sizeOf(@TypeOf(gdt)) - 1),
    .base = &gdt[0]
};

var tss = TSS {
    .reserved_1 = 0,
    .rsp0 = 0,
    .rsp1 = 0,
    .rsp2 = 0,
    .reserved_2 = 0,
    .reserved_3 = 0,
    .ist1 = 0,
    .ist2 = 0,
    .ist3 = 0,
    .ist4 = 0,
    .ist5 = 0,
    .ist6 = 0,
    .ist7 = 0,
    .reserved_4 = 0,
    .reserved_5 = 0,
    .reserved_6 = 0,
    .io_base = 0
};

// See gdt.s
extern fn load_gdt(gdtr: *const GDTR) void;
extern fn load_tss() void;

pub fn init() void {
    load_gdt(&gdtr);

    // Replace TSS placeholder in GDT
    gdt[5] = make_tss_entry(@ptrToInt(&tss), @as(u32, @sizeOf(TSS) - 1), tss_access, tss_flags);
    load_tss();
}
