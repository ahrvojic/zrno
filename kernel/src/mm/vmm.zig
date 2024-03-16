const std = @import("std");

const boot = @import("../sys/boot.zig");
const pmm = @import("pmm.zig");
const virt = @import("../lib/virt.zig");

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

    pub fn mapPage(self: *@This(), virt_addr: u64, phys_addr: u64, flags: u64) !void {
        // Extract page table indexes from virtual address
        const pml4_idx = @as(usize, virt_addr >> 39) & 0x1ff;
        const pml3_idx = @as(usize, virt_addr >> 30) & 0x1ff;
        const pml2_idx = @as(usize, virt_addr >> 21) & 0x1ff;
        const pml1_idx = @as(usize, virt_addr >> 12) & 0x1ff;

        // Walk page table hierarchy
        const pml3 = self.getNextLevel(pml4_idx, true) orelse return error.OutOfMemory;
        const pml2 = pml3.getNextLevel(pml3_idx, true) orelse return error.OutOfMemory;
        const pml1 = pml2.getNextLevel(pml2_idx, true) orelse return error.OutOfMemory;
        const entry = &pml1.entries[pml1_idx];

        entry.setAddress(phys_addr);
        entry.setFlags(flags);
    }

    fn getNextLevel(self: *@This(), index: usize, allocate: bool) ?*PageTable {
        var entry = &self.entries[index];

        if (entry.getFlags() & Flags.Present != 0) {
            return virt.toHH(*PageTable, entry.getAddress());
        } else if (allocate) {
            const next_level = pmm.alloc(1) orelse return null;
            entry.setAddress(next_level);
            entry.setFlags(Flags.Present | Flags.Writable | Flags.User);
            return virt.toHH(*PageTable, next_level);
        }

        return null;
    }
};

pub const VMObject = struct {
    base: u64,
    length: u64,
    flags: u64,
};

pub fn init() !void {
    const pt_addr_phys = pmm.alloc(1) orelse return error.OutOfMemory;
    const pt = virt.toHH(*PageTable, pt_addr_phys);

    // Allocate L3 tables for higher-half memory
    for (256..512) |i| {
        _ = pt.getNextLevel(i, true);
    }

    // TODO: Map text, rodata, and data sections
    // TODO: Identity-map physical memory
    // TODO: Higher-half-map physical memory
    // TODO: Map memory map entries
    // TODO: Switch address space in cr3
}

pub fn handlePageFault() void {
    // TODO
}
