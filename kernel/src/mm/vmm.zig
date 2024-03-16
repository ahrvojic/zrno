const std = @import("std");

const boot = @import("../sys/boot.zig");
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

    pub fn mapPage(self: *@This(), virt: u64, phys: u64, flags: u64) !void {
        _ = self;
        _ = virt;
        _ = phys;
        _ = flags;
    }
};

pub const VMObject = struct {
    base: u64,
    length: u64,
    flags: u64,
};

pub fn init() !void {
    const pt_addr_phys = pmm.alloc(1) orelse return error.OutOfMemory;
    const page_table = toHH(*PageTable, pt_addr_phys);
    _ = page_table;

    // TODO: Populate higher-half address space in page table
    // TODO: Map text, rodata, and data sections
    // TODO: Identity-map physical memory
    // TODO: Higher-half-map physical memory
    // TODO: Map memory map entries
    // TODO: Switch address space in cr3
}

pub fn handlePageFault() void {
    // TODO
}

pub fn toHH(comptime T: type, address: u64) T {
    const res = address + boot.get().higherHalf.offset;
    return if (@typeInfo(T) == .Pointer) @as(T, @ptrFromInt(res)) else @as(T, res);
}
