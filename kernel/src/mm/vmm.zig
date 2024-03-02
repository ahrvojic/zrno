const limine = @import("limine");

const pmm = @import("pmm.zig");

const flags_mask: u64 = 0xfff0_0000_0000_0fff;

pub const Flags = struct {
    pub const Present = 1 << 0;
    pub const Writable = 1 << 1;
    pub const User = 1 << 2;
    pub const NoExecute = 1 << 63;
};

const PageTableEntry = extern struct {
    value: u64,

    pub fn getAddress(self: *const @This()) u64 {
        return self.value & ~flags_mask;
    }

    pub fn getFlags(self: *const @This()) u64 {
        return self.value & flags_mask;
    }

    pub fn setAddress(self: *@This(), address: u64) void {
        self.value = address | self.getFlags();
    }

    pub fn setFlags(self: *@This(), flags: u64) void {
        self.value = self.getAddress() | flags;
    }
};

const PageTable = extern struct {
    entries: [512]PageTableEntry,
};

pub const VMObject = struct {
    base: u64,
    length: u64,
    flags: u64,
};

pub fn init(hhdm_res: *limine.HhdmResponse) !void {
    const pt_addr_phys = pmm.alloc(1) orelse return error.OutOfMemory;
    const page_table = @as(*PageTable, @ptrFromInt(pt_addr_phys + hhdm_res.offset));
    _ = page_table;
    // TODO
}

pub fn handlePageFault() void {
    // TODO
}
