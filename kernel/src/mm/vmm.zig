const logger = std.log.scoped(.vmm);

const std = @import("std");

const boot = @import("../sys/boot.zig");
const Lock = @import("../lib/lock.zig");
const pmm = @import("pmm.zig");
const virt = @import("../lib/virt.zig");

pub var kernel_vmm: VMM = .{};

const flags_mask: u64 = 0xfff0_0000_0000_0fff;

pub const Flags = packed struct(u64) {
    present: bool = false,
    writable: bool = false,
    user: bool = false,
    _padding: u60 = 0,
    noexec: bool = false,
};

pub const FaultReason = packed struct(u64) {
    protection: bool = false,
    write: bool = false,
    user: bool = false,
    reserved: bool = false,
    inst_fetch: bool = false,
    _padding: u59 = 0,
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

const page_table_entries = pmm.page_size / @sizeOf(PageTableEntry);
const page_table_index_mask = page_table_entries - 1;
// Canonical higher half: PML4 indices [256, 512).
const kernel_pml4_start = page_table_entries / 2;

pub const user_space_end: u64 = 0x0000_8000_0000_0000;

pub fn userRange(addr: u64, len: u64) bool {
    if (len == 0) return true;
    if (addr < pmm.page_size) return false;
    if (addr >= user_space_end) return false;
    return len <= user_space_end - addr;
}

const PageTable = extern struct {
    entries: [page_table_entries]PageTableEntry,

    pub fn mapPage(self: *@This(), virt_addr: u64, phys_addr: u64, flags: u64) !void {
        const entry = try self.virtToPTE(virt_addr, true);
        const entry_flags: Flags = @bitCast(entry.getFlags());

        if (!entry_flags.present) {
            entry.setAddress(phys_addr);
            entry.setFlags(flags);
        } else {
            return error.AlreadyMapped;
        }
    }

    pub fn remapPage(self: *@This(), virt_addr: u64, phys_addr: u64, flags: u64) !void {
        const entry = try self.virtToPTE(virt_addr, false);
        const entry_flags: Flags = @bitCast(entry.getFlags());

        if (entry_flags.present) {
            entry.setAddress(phys_addr);
            entry.setFlags(flags);
            flushTLB(virt_addr);
        } else {
            return error.NotMapped;
        }
    }

    pub fn unmapPage(self: *@This(), virt_addr: u64) !void {
        const entry = try self.virtToPTE(virt_addr, false);
        const entry_flags: Flags = @bitCast(entry.getFlags());

        if (entry_flags.present) {
            entry.setAddress(0);
            entry.setFlags(@bitCast(Flags{}));
            flushTLB(virt_addr);
        } else {
            return error.NotMapped;
        }
    }

    pub fn virtToPTE(self: *@This(), virt_addr: u64, allocate: bool) !*PageTableEntry {
        // Extract page table indexes from virtual address
        const pml4_idx = @as(u64, virt_addr >> 39) & page_table_index_mask;
        const pml3_idx = @as(u64, virt_addr >> 30) & page_table_index_mask;
        const pml2_idx = @as(u64, virt_addr >> 21) & page_table_index_mask;
        const pml1_idx = @as(u64, virt_addr >> 12) & page_table_index_mask;

        // Walk page table hierarchy to entry
        const pml3 = self.getNextLevel(pml4_idx, allocate) orelse return error.PTENotFound;
        const pml2 = pml3.getNextLevel(pml3_idx, allocate) orelse return error.PTENotFound;
        const pml1 = pml2.getNextLevel(pml2_idx, allocate) orelse return error.PTENotFound;
        return &pml1.entries[pml1_idx];
    }

    pub fn getNextLevel(self: *@This(), index: u64, allocate: bool) ?*PageTable {
        const entry = &self.entries[index];
        const entry_flags: Flags = @bitCast(entry.getFlags());

        if (entry_flags.present) {
            return virt.toHH(*PageTable, entry.getAddress());
        } else if (allocate) {
            const next_level = pmm.alloc(1) orelse return null;
            entry.setAddress(next_level);
            // User pages are reachable only if every ancestor is user;
            // kernel leaves still protect kernel pages.
            entry.setFlags(@bitCast(Flags{ .present = true, .writable = true, .user = true }));
            return virt.toHH(*PageTable, next_level);
        }

        return null;
    }
};

pub const VMM = struct {
    pt_addr_phys: u64 = undefined,
    pt: *PageTable = undefined,
    lock: Lock.SpinLock = .{},
    initialized: bool = false,

    pub fn map(self: *@This(), virt_addr: u64, phys_addr: u64, size: u64, flags: u64) !void {
        self.expectInit();
        std.debug.assert(std.mem.isAligned(virt_addr, pmm.page_size));
        std.debug.assert(std.mem.isAligned(phys_addr, pmm.page_size));
        std.debug.assert(std.mem.isAligned(size, pmm.page_size));

        self.lock.lock();
        defer self.lock.unlock();

        var i: u64 = 0;
        while (i < size) : (i += pmm.page_size) {
            const new_virt_addr = virt_addr + i;
            const new_phys_addr = phys_addr + i;
            try self.pt.mapPage(new_virt_addr, new_phys_addr, flags);
        }
    }

    pub fn remap(self: *@This(), virt_addr: u64, phys_addr: u64, size: u64, flags: u64) !void {
        self.expectInit();
        std.debug.assert(std.mem.isAligned(virt_addr, pmm.page_size));
        std.debug.assert(std.mem.isAligned(phys_addr, pmm.page_size));
        std.debug.assert(std.mem.isAligned(size, pmm.page_size));

        self.lock.lock();
        defer self.lock.unlock();

        var i: u64 = 0;
        while (i < size) : (i += pmm.page_size) {
            const new_virt_addr = virt_addr + i;
            const new_phys_addr = phys_addr + i;
            try self.pt.remapPage(new_virt_addr, new_phys_addr, flags);
        }
    }

    pub fn unmap(self: *@This(), virt_addr: u64, size: u64) !void {
        self.expectInit();
        std.debug.assert(std.mem.isAligned(virt_addr, pmm.page_size));
        std.debug.assert(std.mem.isAligned(size, pmm.page_size));

        self.lock.lock();
        defer self.lock.unlock();

        var i: u64 = 0;
        while (i < size) : (i += pmm.page_size) {
            const new_virt_addr = virt_addr + i;
            try self.pt.unmapPage(new_virt_addr);
        }
    }

    pub fn mapMmio(self: *@This(), phys_addr: u64, size: u64) !void {
        self.expectInit();
        std.debug.assert(size > 0);
        self.lock.lock();
        defer self.lock.unlock();
        try mapHhdmRange(self.pt, phys_addr, phys_addr + size);
    }

    pub fn virtToPhys(self: *@This(), virt_addr: u64) !u64 {
        self.expectInit();
        self.lock.lock();
        defer self.lock.unlock();
        const entry = try self.pt.virtToPTE(virt_addr, false);
        const entry_flags: Flags = @bitCast(entry.getFlags());

        if (entry_flags.present) {
            return entry.getAddress() + (virt_addr & (pmm.page_size - 1));
        } else {
            return error.NotMapped;
        }
    }

    pub fn switchTo(self: *@This()) void {
        self.expectInit();
        if (readCR3() == self.pt_addr_phys) return;
        switchPageTable(self.pt_addr_phys);
    }

    // Empty lower half; higher-half L3 pointers are shared with kernel_vmm.
    pub fn cloneKernel() !VMM {
        kernel_vmm.expectInit();
        const pt_addr_phys = pmm.alloc(1) orelse return error.OutOfMemory;
        const pt = virt.toHH(*PageTable, pt_addr_phys);

        kernel_vmm.lock.lock();
        defer kernel_vmm.lock.unlock();
        for (kernel_pml4_start..page_table_entries) |i| {
            pt.entries[i] = kernel_vmm.pt.entries[i];
        }

        return .{
            .pt_addr_phys = pt_addr_phys,
            .pt = pt,
            .initialized = true,
        };
    }

    pub fn handlePageFault(self: *@This(), fault_addr: u64, fault_reason: u64) !bool {
        self.expectInit();
        self.lock.lock();
        defer self.lock.unlock();
        const reason: FaultReason = @bitCast(fault_reason);

        if (reason.protection) {
            return false;
        }

        // Demand-page user space only for user-mode faults, and never page 0.
        if (reason.user and fault_addr >= pmm.page_size and fault_addr < user_space_end) {
            const base_addr = std.mem.alignBackward(u64, fault_addr, pmm.page_size);
            const phys_addr = pmm.alloc(1) orelse return error.OutOfMemory;
            const flags = Flags{ .present = true, .writable = true, .user = true };
            try self.pt.mapPage(base_addr, phys_addr, @bitCast(flags));
            return true;
        }

        return false;
    }

    fn expectInit(self: *const @This()) void {
        if (!self.initialized) @panic("vmm used before init");
    }

    fn expectUninit(self: *const @This()) void {
        if (self.initialized) @panic("vmm already initialized");
    }
};

pub fn init() !void {
    kernel_vmm.expectUninit();
    logger.info("Init kernel VMM", .{});

    // Allocate L4 root page table
    kernel_vmm.pt_addr_phys = pmm.alloc(1) orelse return error.OutOfMemory;
    kernel_vmm.pt = virt.toHH(*PageTable, kernel_vmm.pt_addr_phys);
    kernel_vmm.initialized = true;

    // Pre-allocate higher half L3 tables to facilitate sharing kernel space
    // across user spaces
    for (kernel_pml4_start..page_table_entries) |i| {
        _ = kernel_vmm.pt.getNextLevel(i, true) orelse return error.OutOfMemory;
    }

    // Base revision 6 maps only selected memory-map types into the HHDM.
    logger.info("Mapping HHDM regions", .{});
    for (boot.info().memory_map.entries()) |entry| {
        if (!entry.kind.inHhdm()) continue;
        try mapHhdmRange(kernel_vmm.pt, entry.base, entry.base + entry.length);
    }

    // Map kernel
    logger.info("Mapping kernel", .{});
    try mapKernelSection(&kernel_vmm, "text", @bitCast(Flags{ .present = true }));
    try mapKernelSection(&kernel_vmm, "rodata", @bitCast(Flags{ .present = true, .noexec = true }));
    try mapKernelSection(&kernel_vmm, "data", @bitCast(Flags{ .present = true, .writable = true, .noexec = true }));

    // Switch address space
    logger.info("Loading kernel VMM", .{});
    kernel_vmm.switchTo();
}

fn mapHhdmRange(pt: *PageTable, base: u64, top: u64) !void {
    const flags: u64 = @bitCast(Flags{ .present = true, .writable = true, .noexec = true });
    var addr = std.mem.alignBackward(u64, base, pmm.page_size);
    const end = std.mem.alignForward(u64, top, pmm.page_size);
    while (addr < end) : (addr += pmm.page_size) {
        pt.mapPage(virt.toHH(u64, addr), addr, flags) catch |err| switch (err) {
            error.AlreadyMapped => {},
            else => return err,
        };
    }
}

fn mapKernelSection(vmm: *VMM, comptime section_name: []const u8, flags: u64) !void {
    const section_start = @intFromPtr(@extern(*u8, .{ .name = section_name ++ "_start_addr" }));
    const section_end = @intFromPtr(@extern(*u8, .{ .name = section_name ++ "_end_addr" }));

    const virt_start = std.mem.alignBackward(u64, section_start, pmm.page_size);
    const virt_end = std.mem.alignForward(u64, section_end, pmm.page_size);

    const phys_start = virt_start - boot.info().kernel.virtual_base + boot.info().kernel.physical_base;
    const size = virt_end - virt_start;

    try vmm.map(virt_start, phys_start, size, flags);
}

inline fn flushTLB(virt_addr: u64) void {
    asm volatile (
        \\invlpg %[virt_addr]
        :
        : [virt_addr] "r" (virt_addr),
        : .{ .memory = true });
}

inline fn readCR3() u64 {
    return asm volatile (
        \\movq %%cr3, %[cr3]
        : [cr3] "=r" (-> u64),
    );
}

inline fn switchPageTable(phys_addr: u64) void {
    asm volatile (
        \\movq %[phys_addr], %cr3
        :
        : [phys_addr] "r" (phys_addr),
        : .{ .memory = true });
}

test "Flags construction" {
    const flags = Flags{ .present = true, .writable = true, .noexec = true };
    try std.testing.expect(@as(u64, @bitCast(flags)) == 0x8000000000000003);
}
