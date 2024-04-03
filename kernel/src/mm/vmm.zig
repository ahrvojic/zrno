const std = @import("std");

const boot = @import("../sys/boot.zig");
const pmm = @import("pmm.zig");
const virt = @import("../lib/virt.zig");

extern const text_start_addr: u64;
extern const text_end_addr: u64;
extern const rodata_start_addr: u64;
extern const rodata_end_addr: u64;
extern const data_start_addr: u64;
extern const data_end_addr: u64;

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

        // Walk page table hierarchy to entry
        const pml3 = self.getNextLevel(pml4_idx, true) orelse return error.OutOfMemory;
        const pml2 = pml3.getNextLevel(pml3_idx, true) orelse return error.OutOfMemory;
        const pml1 = pml2.getNextLevel(pml2_idx, true) orelse return error.OutOfMemory;
        const entry = &pml1.entries[pml1_idx];

        entry.setAddress(phys_addr);
        entry.setFlags(flags);
    }

    pub fn mapSection(self: *@This(), start_addr: u64, end_addr: u64, flags: u64) !void {
        const info = boot.get();
        const start = std.mem.alignBackward(u64, start_addr, pmm.page_size);
        const end = std.mem.alignForward(u64, end_addr, pmm.page_size);

        var addr = start;
        while (addr < end) : (addr += pmm.page_size) {
            const phys_addr = addr - info.kernel.virtual_base + info.kernel.physical_base;
            try self.mapPage(addr, phys_addr, flags);
        }
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

fn switchPageTable(phys_addr: u64) callconv(.Inline) void {
    asm volatile (
        \\movq %[phys_addr], %cr3
        :
        : [phys_addr] "r" (phys_addr),
        : "memory"
    );
}

pub fn init() !void {
    // Allocate L4 table
    const pt_addr_phys = pmm.alloc(1) orelse return error.OutOfMemory;
    const pt = virt.toHH(*PageTable, pt_addr_phys);

    // Allocate L3 tables for higher-half memory only
    for (256..512) |i| {
        _ = pt.getNextLevel(i, true);
    }

    // Map kernel sections
    try pt.mapSection(text_start_addr, text_end_addr, Flags.Present);
    try pt.mapSection(rodata_start_addr, rodata_end_addr, Flags.Present | Flags.NoExecute);
    try pt.mapSection(data_start_addr, data_end_addr, Flags.Present | Flags.Writable | Flags.NoExecute);

    // Identity and higher-half map first 4 GiB following Limine protocol
    const boundary = 4 * 1024 * 1024 * 1024;

    var addr: u64 = pmm.page_size;
    while (addr < boundary) : (addr += pmm.page_size) {
        try pt.mapPage(addr, addr, Flags.Present | Flags.Writable);
        try pt.mapPage(virt.toHH(u64, addr), addr, Flags.Present | Flags.Writable | Flags.NoExecute);
    }

    // Map identified memory map entries above 4 GB following Limine protocol
    for (boot.get().memoryMap.entries()) |entry| {
        const base = std.mem.alignBackward(u64, entry.base, pmm.page_size);
        const top = std.mem.alignForward(u64, entry.base + entry.length, pmm.page_size);

        if (top <= boundary) {
            continue;
        }

        var mm_addr = base;
        while (mm_addr < top) : (mm_addr += pmm.page_size) {
            if (mm_addr < boundary) {
                continue;
            }

            try pt.mapPage(mm_addr, mm_addr, Flags.Present | Flags.Writable);
            try pt.mapPage(virt.toHH(u64, mm_addr), mm_addr, Flags.Present | Flags.Writable | Flags.NoExecute);
        }
    }

    switchPageTable(pt_addr_phys);
}

pub fn handlePageFault() void {
    // TODO
}
