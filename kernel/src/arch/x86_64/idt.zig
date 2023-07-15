const gdt = @import("gdt.zig");

const IDTEntry = packed struct {
    offset_1: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_2: u16,
    offset_3: u32,
    zero: u32
};

const IDTR = packed struct {
    limit: u16,
    base: u64
};

var idt: [256]IDTEntry = undefined;

pub fn set_gate(n: u8, type_attr: u8, offset: u64) void {
    idt[n].offset_1 = @truncate(u16, offset);
    idt[n].offset_2 = @truncate(u16, offset >> 16);
    idt[n].offset_3 = @truncate(u32, offset >> 32);
    idt[n].selector = gdt.kernel_code_seg;
    idt[n].ist = 0;
    idt[n].type_attr = type_attr;
    idt[n].zero = 0;
}

const idtr = IDTR {
    .limit = @as(u16, @sizeOf(@TypeOf(idt)) - 1),
    .base = 0 // TODO
};

// See idt.s
extern fn load_idt(idtr: *const IDTR) void;

pub fn init() void {
    load_idt(&idtr);
}
