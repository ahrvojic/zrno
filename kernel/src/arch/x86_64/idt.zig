const IDTR = packed struct {
    limit: u16,
    base: u64
};

const IDTEntry = packed struct {
    offset_1: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_2: u16,
    offset_3: u32,
    zero: u32,

    pub fn make(offset: u64, selector: u16, ist: u8, type_attr: u8) IDTEntry {
        return .{
            .offset_1 = @truncate(offset),
            .offset_2 = @truncate(offset >> 16),
            .offset_3 = @truncate(offset >> 32),
            .selector = selector,
            .ist = ist,
            .type_attr = type_attr,
            .zero = 0
        };
    }
};

pub const IDT = struct {
    entries: [256]IDTEntry = undefined,

    pub fn load(self: *IDT) void {
        const idtr = IDTR {
            .limit = @sizeOf(IDT) - 1,
            .base = @intFromPtr(self)
        };

        // TODO: Interrupt handlers

        asm volatile (
            \\lidt (%[idtr])
            :
            : [idtr] "r" (&idtr)
        );
    }
};
