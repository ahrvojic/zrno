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

    pub fn getAddress(self: *const PageTableEntry) usize {
        return @intCast(self.value & ~flags_mask);
    }

    pub fn getFlags(self: *const PageTableEntry) u64 {
        return self.value & flags_mask;
    }

    pub fn setAddress(self: *PageTableEntry, address: usize) void {
        self.value = @as(u64, @intCast(address)) | self.getFlags();
    }

    pub fn setFlags(self: *PageTableEntry, flags: u64) void {
        self.value = self.getAddress() | flags;
    }
};

const page_table_entries = pmm.page_size / @sizeOf(PageTableEntry);
const page_table_index_mask = page_table_entries - 1;
// Canonical higher half: PML4 indices [256, 512).
const kernel_pml4_start = page_table_entries / 2;

pub const user_space_end: usize = 0x0000_8000_0000_0000;

pub fn userRange(addr: usize, len: usize) bool {
    if (len == 0) return true;
    if (addr < pmm.page_size) return false;
    if (addr >= user_space_end) return false;
    return len <= user_space_end - addr;
}

const PageTable = extern struct {
    entries: [page_table_entries]PageTableEntry,

    pub fn mapPage(self: *PageTable, virt_addr: usize, phys_addr: usize, flags: u64) !void {
        const entry = try self.virtToPTE(virt_addr, true);
        const entry_flags: Flags = @bitCast(entry.getFlags());

        if (!entry_flags.present) {
            entry.setAddress(phys_addr);
            entry.setFlags(flags);
        } else {
            return error.AlreadyMapped;
        }
    }

    pub fn remapPage(self: *PageTable, virt_addr: usize, phys_addr: usize, flags: u64) !void {
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

    pub fn unmapPage(self: *PageTable, virt_addr: usize) !void {
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

    pub fn virtToPTE(self: *PageTable, virt_addr: usize, allocate: bool) !*PageTableEntry {
        // Extract page table indexes from virtual address
        const pml4_idx = (virt_addr >> 39) & page_table_index_mask;
        const pml3_idx = (virt_addr >> 30) & page_table_index_mask;
        const pml2_idx = (virt_addr >> 21) & page_table_index_mask;
        const pml1_idx = (virt_addr >> 12) & page_table_index_mask;

        // Walk page table hierarchy to entry
        const pml3 = self.getNextLevel(pml4_idx, allocate) orelse return error.PTENotFound;
        const pml2 = pml3.getNextLevel(pml3_idx, allocate) orelse return error.PTENotFound;
        const pml1 = pml2.getNextLevel(pml2_idx, allocate) orelse return error.PTENotFound;
        return &pml1.entries[pml1_idx];
    }

    pub fn getNextLevel(self: *PageTable, index: usize, allocate: bool) ?*PageTable {
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

    // `level` 3 = PDPT, 2 = PD, 1 = PT. Present leaves are mapped pages.
    fn freeLevel(self: *PageTable, level: u8) void {
        for (&self.entries) |*entry| {
            const entry_flags: Flags = @bitCast(entry.getFlags());
            if (!entry_flags.present) continue;
            const phys = entry.getAddress();
            if (level > 1) {
                virt.toHH(*PageTable, phys).freeLevel(level - 1);
            }
            pmm.free(phys, 1);
        }
    }

    fn freeLowerHalf(self: *PageTable) void {
        for (0..kernel_pml4_start) |i| {
            const entry = &self.entries[i];
            const entry_flags: Flags = @bitCast(entry.getFlags());
            if (!entry_flags.present) continue;
            const phys = entry.getAddress();
            virt.toHH(*PageTable, phys).freeLevel(3);
            pmm.free(phys, 1);
        }
    }
};

pub const VMM = struct {
    pt_addr_phys: usize = undefined,
    pt: *PageTable = undefined,
    lock: Lock.SpinLock = .{},
    initialized: bool = false,

    pub fn map(self: *VMM, virt_addr: usize, phys_addr: usize, size: usize, flags: u64) !void {
        self.expectInit();
        std.debug.assert(std.mem.isAligned(virt_addr, pmm.page_size));
        std.debug.assert(std.mem.isAligned(phys_addr, pmm.page_size));
        std.debug.assert(std.mem.isAligned(size, pmm.page_size));

        self.lock.lock();
        defer self.lock.unlock();

        var i: usize = 0;
        while (i < size) : (i += pmm.page_size) {
            const new_virt_addr = virt_addr + i;
            const new_phys_addr = phys_addr + i;
            try self.pt.mapPage(new_virt_addr, new_phys_addr, flags);
        }
    }

    pub fn remap(self: *VMM, virt_addr: usize, phys_addr: usize, size: usize, flags: u64) !void {
        self.expectInit();
        std.debug.assert(std.mem.isAligned(virt_addr, pmm.page_size));
        std.debug.assert(std.mem.isAligned(phys_addr, pmm.page_size));
        std.debug.assert(std.mem.isAligned(size, pmm.page_size));

        self.lock.lock();
        defer self.lock.unlock();

        var i: usize = 0;
        while (i < size) : (i += pmm.page_size) {
            const new_virt_addr = virt_addr + i;
            const new_phys_addr = phys_addr + i;
            try self.pt.remapPage(new_virt_addr, new_phys_addr, flags);
        }
    }

    pub fn unmap(self: *VMM, virt_addr: usize, size: usize) !void {
        self.expectInit();
        std.debug.assert(std.mem.isAligned(virt_addr, pmm.page_size));
        std.debug.assert(std.mem.isAligned(size, pmm.page_size));

        self.lock.lock();
        defer self.lock.unlock();

        var i: usize = 0;
        while (i < size) : (i += pmm.page_size) {
            const new_virt_addr = virt_addr + i;
            try self.pt.unmapPage(new_virt_addr);
        }
    }

    pub fn mapMmio(self: *VMM, phys_addr: usize, size: usize) !void {
        self.expectInit();
        std.debug.assert(size > 0);
        self.lock.lock();
        defer self.lock.unlock();
        try mapHhdmRange(self.pt, phys_addr, phys_addr + size);
    }

    pub fn virtToPhys(self: *VMM, virt_addr: usize) !usize {
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

    // Copy through the HHDM so a hole is mapped, not a kernel #PF on the user VA.
    pub fn copyFromUser(self: *VMM, dest: []u8, user_addr: usize) error{ Fault, OutOfMemory }!void {
        try self.copyUser(dest, user_addr, false);
    }

    pub fn copyToUser(self: *VMM, user_addr: usize, src: []const u8) error{ Fault, OutOfMemory }!void {
        try self.copyUser(@constCast(src), user_addr, true);
    }

    fn copyUser(self: *VMM, kernel: []u8, user_addr: usize, to_user: bool) error{ Fault, OutOfMemory }!void {
        if (kernel.len == 0) return;
        if (!userRange(user_addr, kernel.len)) return error.Fault;

        self.expectInit();
        self.lock.lock();
        defer self.lock.unlock();

        var off: usize = 0;
        const len = kernel.len;
        while (off < len) {
            const va = user_addr + off;
            const page_off = va & (pmm.page_size - 1);
            const chunk = @min(len - off, pmm.page_size - page_off);
            const phys = try self.userPagePhysLocked(va, to_user);
            const page = virt.toHH([*]u8, phys);
            if (to_user) {
                @memcpy(page[page_off..][0..chunk], kernel[off..][0..chunk]);
            } else {
                @memcpy(kernel[off..][0..chunk], page[page_off..][0..chunk]);
            }
            off += chunk;
        }
    }

    fn userPagePhysLocked(self: *VMM, virt_addr: usize, write: bool) error{ Fault, OutOfMemory }!usize {
        const base = std.mem.alignBackward(usize, virt_addr, pmm.page_size);
        const entry = self.pt.virtToPTE(base, false) catch {
            return self.populateUserPageLocked(base);
        };
        const flags: Flags = @bitCast(entry.getFlags());
        if (!flags.present) {
            return self.populateUserPageLocked(base);
        }
        if (!flags.user) return error.Fault;
        if (write and !flags.writable) return error.Fault;
        return entry.getAddress();
    }

    fn populateUserPageLocked(self: *VMM, base_addr: usize) error{OutOfMemory}!usize {
        const phys_addr = pmm.alloc(1) orelse return error.OutOfMemory;
        errdefer pmm.free(phys_addr, 1);
        const flags = Flags{ .present = true, .writable = true, .user = true };
        self.pt.mapPage(base_addr, phys_addr, @bitCast(flags)) catch |err| switch (err) {
            error.AlreadyMapped => @panic("populate already mapped"),
            error.PTENotFound => return error.OutOfMemory,
        };
        return phys_addr;
    }

    pub fn switchTo(self: *VMM) void {
        self.expectInit();
        if (readCR3() == self.pt_addr_phys) return;
        switchPageTable(self.pt_addr_phys);
    }

    pub fn isCurrent(self: *const VMM) bool {
        self.expectInit();
        return readCR3() == self.pt_addr_phys;
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

    // Free only the lower half and the unique PML4; never the cloned kernel L3s.
    pub fn destroy(self: *VMM) void {
        self.expectInit();
        if (self == &kernel_vmm) @panic("destroy kernel vmm");
        if (self.isCurrent()) @panic("destroy current address space");
        self.lock.lock();
        const phys = self.pt_addr_phys;
        self.initialized = false;
        destroyPhys(phys);
        self.lock.unlock();
    }

    pub fn handlePageFault(self: *VMM, fault_addr: usize, fault_reason: u64) !bool {
        self.expectInit();
        self.lock.lock();
        defer self.lock.unlock();
        const reason: FaultReason = @bitCast(fault_reason);

        if (reason.protection) {
            return false;
        }

        // Demand-page user space only for user-mode faults, and never page 0.
        if (reason.user and fault_addr >= pmm.page_size and fault_addr < user_space_end) {
            const base_addr = std.mem.alignBackward(usize, fault_addr, pmm.page_size);
            _ = try self.populateUserPageLocked(base_addr);
            return true;
        }

        return false;
    }

    fn expectInit(self: *const VMM) void {
        if (!self.initialized) @panic("vmm used before init");
    }

    fn expectUninit(self: *const VMM) void {
        if (self.initialized) @panic("vmm already initialized");
    }
};

// Walk a cloned PML4. Caller must not be executing on this root.
pub fn destroyPhys(pt_addr_phys: usize) void {
    if (pt_addr_phys == kernel_vmm.pt_addr_phys) @panic("destroy kernel vmm");
    if (readCR3() == pt_addr_phys) @panic("destroy current address space");
    virt.toHH(*PageTable, pt_addr_phys).freeLowerHalf();
    pmm.free(pt_addr_phys, 1);
}

pub fn init() !void {
    kernel_vmm.expectUninit();

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
    var hhdm_bytes: usize = 0;
    logger.debug("mapping HHDM", .{});
    for (boot.info().memory_map.entries()) |entry| {
        if (!entry.kind.inHhdm()) continue;
        const base: usize = @intCast(entry.base);
        const top: usize = @intCast(entry.base + entry.length);
        const start = std.mem.alignBackward(usize, base, pmm.page_size);
        const end = std.mem.alignForward(usize, top, pmm.page_size);
        hhdm_bytes += end - start;
        try mapHhdmRange(kernel_vmm.pt, base, top);
    }

    const text = try mapKernelSection(&kernel_vmm, "text", @bitCast(Flags{ .present = true }));
    const rodata = try mapKernelSection(&kernel_vmm, "rodata", @bitCast(Flags{ .present = true, .noexec = true }));
    const data = try mapKernelSection(&kernel_vmm, "data", @bitCast(Flags{ .present = true, .writable = true, .noexec = true }));

    kernel_vmm.switchTo();
    logger.info("hhdm {d} MiB, kernel text={d} KiB rodata={d} KiB data={d} KiB cr3=0x{x}", .{
        hhdm_bytes / (1024 * 1024),
        text / 1024,
        rodata / 1024,
        data / 1024,
        kernel_vmm.pt_addr_phys,
    });
}

fn mapHhdmRange(pt: *PageTable, base: usize, top: usize) !void {
    const flags: u64 = @bitCast(Flags{ .present = true, .writable = true, .noexec = true });
    var addr = std.mem.alignBackward(usize, base, pmm.page_size);
    const end = std.mem.alignForward(usize, top, pmm.page_size);
    while (addr < end) : (addr += pmm.page_size) {
        pt.mapPage(virt.toHH(usize, addr), addr, flags) catch |err| switch (err) {
            error.AlreadyMapped => {},
            else => return err,
        };
    }
}

fn mapKernelSection(vmm: *VMM, comptime section_name: []const u8, flags: u64) !usize {
    const section_start = @intFromPtr(@extern(*u8, .{ .name = section_name ++ "_start_addr" }));
    const section_end = @intFromPtr(@extern(*u8, .{ .name = section_name ++ "_end_addr" }));

    const virt_start = std.mem.alignBackward(usize, section_start, pmm.page_size);
    const virt_end = std.mem.alignForward(usize, section_end, pmm.page_size);

    const virt_base: usize = @intCast(boot.info().kernel.virtual_base);
    const phys_base: usize = @intCast(boot.info().kernel.physical_base);
    const phys_start = virt_start - virt_base + phys_base;
    const size = virt_end - virt_start;

    try vmm.map(virt_start, phys_start, size, flags);
    return size;
}

inline fn flushTLB(virt_addr: usize) void {
    asm volatile (
        \\invlpg %[virt_addr]
        :
        : [virt_addr] "r" (virt_addr),
        : .{ .memory = true });
}

pub fn readCR3() usize {
    return asm volatile (
        \\movq %%cr3, %[cr3]
        : [cr3] "=r" (-> usize),
    );
}

inline fn switchPageTable(phys_addr: usize) void {
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
