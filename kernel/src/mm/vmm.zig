const logger = std.log.scoped(.vmm);

const std = @import("std");

const boot = @import("../sys/boot.zig");
const pmm = @import("pmm.zig");
const virt = @import("../lib/virt.zig");

const flags_mask: u64 = 0xfff0_0000_0000_0fff;

var kernel_vmm: VMM = .{};

pub const Flags = struct {
    pub const None = 0;
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
        const entry = try self.virtToPTE(virt_addr, true);

        if (entry.getFlags() & Flags.Present == 0) {
            entry.setAddress(phys_addr);
            entry.setFlags(flags);
        } else {
            return error.AlreadyMapped;
        }
    }

    pub fn unmapPage(self: *@This(), virt_addr: u64) !void {
        const entry = try self.virtToPTE(virt_addr, false);

        if (entry.getFlags() & Flags.Present == 1) {
            entry.setAddress(0);
            entry.setFlags(Flags.None);
            flushTLB(virt_addr);
        } else {
            return error.NotMapped;
        }
    }

    pub fn virtToPTE(self: *@This(), virt_addr: u64, allocate: bool) !*PageTableEntry {
        // Extract page table indexes from virtual address
        const pml4_idx = @as(usize, virt_addr >> 39) & 0x1ff;
        const pml3_idx = @as(usize, virt_addr >> 30) & 0x1ff;
        const pml2_idx = @as(usize, virt_addr >> 21) & 0x1ff;
        const pml1_idx = @as(usize, virt_addr >> 12) & 0x1ff;

        // Walk page table hierarchy to entry
        const pml3 = self.getNextLevel(pml4_idx, allocate) orelse return error.PTENotFound;
        const pml2 = pml3.getNextLevel(pml3_idx, allocate) orelse return error.PTENotFound;
        const pml1 = pml2.getNextLevel(pml2_idx, allocate) orelse return error.PTENotFound;
        return &pml1.entries[pml1_idx];
    }

    pub fn getNextLevel(self: *@This(), index: usize, allocate: bool) ?*PageTable {
        var entry = &self.entries[index];

        if (entry.getFlags() & Flags.Present == 1) {
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

pub const VMM = struct {
    pt_addr_phys: u64 = undefined,
    pt: *PageTable = undefined,

    pub fn map(self: *@This(), virt_addr: u64, phys_addr: u64, size: usize, flags: u64) !void {
        std.debug.assert(std.mem.isAligned(virt_addr, pmm.page_size));
        std.debug.assert(std.mem.isAligned(phys_addr, pmm.page_size));
        std.debug.assert(std.mem.isAligned(size, pmm.page_size));

        var i: usize = 0;
        while (i < size) : (i += pmm.page_size) {
            const new_virt_addr = virt_addr + i;
            const new_phys_addr = phys_addr + i;
            try self.pt.mapPage(new_virt_addr, new_phys_addr, flags);
        }
    }

    pub fn unmap(self: *@This(), virt_addr: u64, size: usize) !void {
        std.debug.assert(std.mem.isAligned(virt_addr, pmm.page_size));
        std.debug.assert(std.mem.isAligned(size, pmm.page_size));

        var i: usize = 0;
        while (i < size) : (i += pmm.page_size) {
            const new_virt_addr = virt_addr + i;
            try self.pt.unmapPage(new_virt_addr);
        }
    }

    pub fn virtToPhys(self: *@This(), virt_addr: u64) !u64 {
        const entry = try self.pt.virtToPTE(virt_addr, false);

        if (entry.getFlags() & Flags.Present == 1) {
            return entry.getAddress();
        } else {
            return error.NotMapped;
        }
    }

    pub fn switchTo(self: *@This()) void {
        switchPageTable(self.pt_addr_phys);
    }
};

pub fn init() !void {
    logger.info("Init kernel VMM", .{});

    // Allocate L4 root page table
    kernel_vmm.pt_addr_phys = pmm.alloc(1) orelse return error.OutOfMemory;
    kernel_vmm.pt = virt.toHH(*PageTable, kernel_vmm.pt_addr_phys);

    // Pre-allocate higher half L3 tables to facilitate sharing kernel space
    // across user spaces
    for (256..512) |i| {
        _ = kernel_vmm.pt.getNextLevel(i, true) orelse return error.OutOfMemory;
    }

    // Map first 4 GiB of kernel space as per Limine protocol base revision 1
    const boundary = 4 * 1024 * 1024 * 1024;
    logger.info("Mapping first {d} bytes", .{boundary});
    var addr: usize = 0;
    while (addr < boundary) : (addr += pmm.page_size) {
        try kernel_vmm.pt.mapPage(virt.toHH(u64, addr), addr,
            Flags.Present | Flags.Writable | Flags.NoExecute);
    }

    // Map identified memory map entries above 4 GiB in kernel space as per
    // Limine protocol base revision 1
    logger.info("Mapping memory map entries", .{});
    for (boot.info.memory_map.entries()) |entry| {
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

            try kernel_vmm.pt.mapPage(virt.toHH(u64, mm_addr), mm_addr,
                Flags.Present | Flags.Writable | Flags.NoExecute);
        }
    }

    // Map kernel
    logger.info("Mapping kernel", .{});
    try mapKernelSection(&kernel_vmm, "text", Flags.Present);
    try mapKernelSection(&kernel_vmm, "rodata", Flags.Present | Flags.NoExecute);
    try mapKernelSection(&kernel_vmm, "data", Flags.Present | Flags.Writable | Flags.NoExecute);

    // Switch address space
    logger.info("Loading kernel VMM", .{});
    kernel_vmm.switchTo();
}

fn mapKernelSection(vmm: *VMM, comptime section_name: []const u8, flags: u64) !void {
    const section_start = @intFromPtr(@extern(*u8, .{.name = section_name ++ "_start_addr"}));
    const section_end = @intFromPtr(@extern(*u8, .{.name = section_name ++ "_end_addr"}));

    const virt_start = std.mem.alignBackward(u64, section_start, pmm.page_size);
    const virt_end = std.mem.alignForward(u64, section_end, pmm.page_size);

    const phys_start = virt_start - boot.info.kernel.virtual_base + boot.info.kernel.physical_base;
    const size = virt_end - virt_start;

    try vmm.map(virt_start, phys_start, size, flags);
}

fn flushTLB(virt_addr: u64) callconv(.Inline) void {
    asm volatile (
        \\invlpg %[virt_addr]
        :
        : [virt_addr] "r" (virt_addr)
        : "memory"
    );
}

fn switchPageTable(phys_addr: u64) callconv(.Inline) void {
    asm volatile (
        \\movq %[phys_addr], %cr3
        :
        : [phys_addr] "r" (phys_addr),
        : "memory"
    );
}

pub fn handlePageFault(fault_addr: u64, reason: u64) !bool {
    _ = reason;

    if (fault_addr < 0x8000_0000_0000_0000) {
        // TODO: Use page faults to allocate physical memory in user space
        return false;
    }

    return false;
}
