const logger = std.log.scoped(.vmm);

const std = @import("std");

const boot = @import("../sys/boot.zig");
const Lock = @import("../lib/lock.zig");
const mem = @import("../lib/mem.zig");
const pmm = @import("pmm.zig");
const virt = @import("../lib/virt.zig");

pub var kernel_vmm: VMM = .{};

const flags_mask: u64 = 0xfff0_0000_0000_0fff;

// 4K PTE flags. Intel SDM Vol. 3 Table 4-19.
pub const Flags = packed struct(u64) {
    present: bool = false,
    writable: bool = false,
    user: bool = false,
    write_through: bool = false, // PWT
    cache_disable: bool = false, // PCD
    accessed: bool = false,
    dirty: bool = false,
    pat: bool = false, // PAT on a 4K PTE; PS on a PD/PDPT entry
    global: bool = false,
    _avl: u3 = 0,
    _phys: u40 = 0,
    _ignored: u11 = 0,
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

    pub fn getFlags(self: *const PageTableEntry) Flags {
        return @bitCast(self.value & flags_mask);
    }

    pub fn setAddress(self: *PageTableEntry, address: usize) void {
        self.value = @as(u64, @intCast(address)) | @as(u64, @bitCast(self.getFlags()));
    }

    pub fn setFlags(self: *PageTableEntry, flags: Flags) void {
        self.value = self.getAddress() | @as(u64, @bitCast(flags));
    }
};

const page_table_entries = pmm.page_size / @sizeOf(PageTableEntry);
const page_table_index_mask = page_table_entries - 1;
// Canonical higher half: PML4 indices [256, 512). init preallocates these
// L3s and cloneKernel shares them with every address space.
const kernel_pml4_start = page_table_entries / 2;
const kernel_half_start: usize = kernel_pml4_start << 39;

fn kernelHalf(virt_addr: usize) bool {
    return virt_addr >= kernel_half_start;
}

// True when [virt_addr, virt_addr + size) includes a higher-half byte.
fn rangeIntersectsKernelHalf(virt_addr: usize, size: usize) bool {
    if (size == 0) return false;
    if (kernelHalf(virt_addr)) return true;
    return size > kernel_half_start - virt_addr;
}

pub const user_space_end = mem.user_space_end;

pub fn userRange(addr: usize, len: usize) bool {
    if (len == 0) return true;
    if (addr < pmm.page_size) return false;
    if (addr >= user_space_end) return false;
    return len <= user_space_end - addr;
}

/// 0-canonical (bits 63:47 clear). SYSRET/IRET #GP in kernel if RIP or RSP is not.
pub fn userCanonical(addr: usize) bool {
    return addr >> 47 == 0;
}

const PageTable = extern struct {
    entries: [page_table_entries]PageTableEntry,

    pub fn mapPage(self: *PageTable, virt_addr: usize, phys_addr: usize, flags: Flags) !void {
        // A user leaf here would set U on an L3 shared with every address space.
        if (flags.user and kernelHalf(virt_addr)) @panic("user map in kernel half");
        const entry = try self.virtToPTE(virt_addr, true, flags.user);
        const entry_flags = entry.getFlags();

        if (!entry_flags.present) {
            entry.setAddress(phys_addr);
            entry.setFlags(flags);
            // Not-present translations may be cached (SDM 4.10.4).
            flushTLB(virt_addr);
        } else {
            return error.AlreadyMapped;
        }
    }

    fn remapPage(self: *PageTable, virt_addr: usize, phys_addr: usize, flags: Flags) !void {
        const entry = try self.virtToPTE(virt_addr, false, false);
        const entry_flags = entry.getFlags();

        if (entry_flags.present) {
            entry.setAddress(phys_addr);
            entry.setFlags(flags);
            flushTLB(virt_addr);
        } else {
            return error.NotMapped;
        }
    }

    pub fn unmapPage(self: *PageTable, virt_addr: usize) !void {
        const w = try self.walk(virt_addr, false, false);

        const entry = w.pte();
        if (!entry.getFlags().present) return error.NotMapped;
        entry.setAddress(0);
        entry.setFlags(.{});
        flushTLB(virt_addr);

        // Kernel L3/L2/L1 are shared with clones; never release them.
        if (w.pml4_idx >= kernel_pml4_start) return;

        if (!w.pml1.isEmpty()) return;
        pmm.free(w.pml2.entries[w.pml2_idx].getAddress(), 1);
        w.pml2.entries[w.pml2_idx].setAddress(0);
        w.pml2.entries[w.pml2_idx].setFlags(.{});

        if (!w.pml2.isEmpty()) return;
        pmm.free(w.pml3.entries[w.pml3_idx].getAddress(), 1);
        w.pml3.entries[w.pml3_idx].setAddress(0);
        w.pml3.entries[w.pml3_idx].setFlags(.{});

        if (!w.pml3.isEmpty()) return;
        pmm.free(self.entries[w.pml4_idx].getAddress(), 1);
        self.entries[w.pml4_idx].setAddress(0);
        self.entries[w.pml4_idx].setFlags(.{});
    }

    fn expectMappedRange(self: *PageTable, virt_addr: usize, size: usize) !void {
        var off: usize = 0;
        while (off < size) : (off += pmm.page_size) {
            const entry = try self.virtToPTE(virt_addr + off, false, false);
            if (!entry.getFlags().present) return error.NotMapped;
        }
    }

    fn unmapRange(self: *PageTable, virt_addr: usize, size: usize) void {
        var off: usize = 0;
        while (off < size) : (off += pmm.page_size) {
            self.unmapPage(virt_addr + off) catch @panic("unmap of mapped page");
        }
    }

    fn isEmpty(self: *const PageTable) bool {
        for (self.entries) |entry| {
            if (entry.getFlags().present) return false;
        }
        return true;
    }

    const Walk = struct {
        pml4_idx: usize,
        pml3_idx: usize,
        pml2_idx: usize,
        pml1_idx: usize,
        pml3: *PageTable,
        pml2: *PageTable,
        pml1: *PageTable,

        fn pte(self: Walk) *PageTableEntry {
            return &self.pml1.entries[self.pml1_idx];
        }
    };

    fn walk(self: *PageTable, virt_addr: usize, allocate: bool, user: bool) error{PTENotFound}!Walk {
        const pml4_idx = (virt_addr >> 39) & page_table_index_mask;
        const pml3_idx = (virt_addr >> 30) & page_table_index_mask;
        const pml2_idx = (virt_addr >> 21) & page_table_index_mask;
        const pml1_idx = (virt_addr >> 12) & page_table_index_mask;

        const pml3 = self.descend(pml4_idx, allocate, user, virt_addr) orelse return error.PTENotFound;
        const pml2 = pml3.descend(pml3_idx, allocate, user, virt_addr) orelse return error.PTENotFound;
        const pml1 = pml2.descend(pml2_idx, allocate, user, virt_addr) orelse return error.PTENotFound;
        return .{
            .pml4_idx = pml4_idx,
            .pml3_idx = pml3_idx,
            .pml2_idx = pml2_idx,
            .pml1_idx = pml1_idx,
            .pml3 = pml3,
            .pml2 = pml2,
            .pml1 = pml1,
        };
    }

    pub fn virtToPTE(self: *PageTable, virt_addr: usize, allocate: bool, user: bool) !*PageTableEntry {
        return (try self.walk(virt_addr, allocate, user)).pte();
    }

    fn descend(self: *PageTable, index: usize, allocate: bool, user: bool, virt_addr: usize) ?*PageTable {
        const entry = &self.entries[index];
        const before = entry.getFlags();
        const next = self.getNextLevel(index, allocate, user) orelse return null;
        // Setting U on a present directory leaves a cached U=0 entry (SDM 4.10.4).
        if (before.present and allocate and user and !before.user) flushTLB(virt_addr);
        return next;
    }

    pub fn getNextLevel(self: *PageTable, index: usize, allocate: bool, user: bool) ?*PageTable {
        const entry = &self.entries[index];
        const entry_flags = entry.getFlags();

        if (entry_flags.present) {
            // User leaves need U=1 on every ancestor; never clear U for a kernel map.
            if (allocate and user and !entry_flags.user) {
                var flags = entry_flags;
                flags.user = true;
                entry.setFlags(flags);
            }
            return virt.toHH(*PageTable, entry.getAddress());
        } else if (allocate) {
            const next_level = pmm.alloc(1) orelse return null;
            entry.setAddress(next_level);
            // NX stays clear: NX on a PDPT/PD would make the whole subtree
            // non-executable, including user RX leaves.
            entry.setFlags(.{ .present = true, .writable = true, .user = user });
            return virt.toHH(*PageTable, next_level);
        }

        return null;
    }

    // `level` 3 = PDPT, 2 = PD, 1 = PT. Present leaves are mapped pages.
    fn freeLevel(self: *PageTable, level: u8) void {
        for (&self.entries) |*entry| {
            const entry_flags = entry.getFlags();
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
            const entry_flags = entry.getFlags();
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

    pub fn map(self: *VMM, virt_addr: usize, phys_addr: usize, size: usize, flags: Flags) !void {
        self.expectInit();
        std.debug.assert(std.mem.isAligned(virt_addr, pmm.page_size));
        std.debug.assert(std.mem.isAligned(phys_addr, pmm.page_size));
        std.debug.assert(std.mem.isAligned(size, pmm.page_size));
        if (flags.user and rangeIntersectsKernelHalf(virt_addr, size)) @panic("user map in kernel half");

        self.lock.lock();
        defer self.lock.unlock();

        // Callers errdefer-free the physical run; a leftover prefix would dangle.
        var mapped: usize = 0;
        errdefer self.pt.unmapRange(virt_addr, mapped);

        while (mapped < size) : (mapped += pmm.page_size) {
            try self.pt.mapPage(virt_addr + mapped, phys_addr + mapped, flags);
        }
    }

    pub fn unmap(self: *VMM, virt_addr: usize, size: usize) !void {
        self.expectInit();
        std.debug.assert(std.mem.isAligned(virt_addr, pmm.page_size));
        std.debug.assert(std.mem.isAligned(size, pmm.page_size));

        self.lock.lock();
        defer self.lock.unlock();

        try self.pt.expectMappedRange(virt_addr, size);
        self.pt.unmapRange(virt_addr, size);
    }

    pub fn mapMmio(self: *VMM, phys_addr: usize, size: usize) !void {
        self.expectInit();
        std.debug.assert(size > 0);
        const top = std.math.add(usize, phys_addr, size) catch return error.Overflow;
        self.lock.lock();
        defer self.lock.unlock();
        // reserved_mapped (and overlaps) are already in the HHDM as writeback.
        try mapHhdmRange(self.pt, phys_addr, top, mmio_flags, .remap);
    }

    pub fn virtToPhys(self: *VMM, virt_addr: usize) !usize {
        self.expectInit();
        self.lock.lock();
        defer self.lock.unlock();
        const entry = try self.pt.virtToPTE(virt_addr, false, false);
        const entry_flags = entry.getFlags();

        if (entry_flags.present) {
            return entry.getAddress() + (virt_addr & (pmm.page_size - 1));
        } else {
            return error.NotMapped;
        }
    }

    // Copy through the HHDM so a kernel #PF cannot deadlock on the VMM lock.
    pub fn copyFromUser(self: *VMM, dest: []u8, user_addr: usize) error{Fault}!void {
        return self.copyUser(user_addr, dest, false);
    }

    pub fn copyToUser(self: *VMM, user_addr: usize, src: []const u8) error{Fault}!void {
        return self.copyUser(user_addr, @constCast(src), true);
    }

    fn copyUser(self: *VMM, user_addr: usize, kernel: []u8, to_user: bool) error{Fault}!void {
        if (kernel.len == 0) return;
        if (!userRange(user_addr, kernel.len)) return error.Fault;

        self.expectInit();
        self.lock.lock();
        defer self.lock.unlock();

        var off: usize = 0;
        while (off < kernel.len) {
            const va = user_addr + off;
            const page_off = va & (pmm.page_size - 1);
            const chunk = @min(kernel.len - off, pmm.page_size - page_off);
            const phys = try self.userPagePhysLocked(va, to_user);
            const k = kernel[off..][0..chunk];
            const u = virt.toHH([*]u8, phys)[page_off..][0..chunk];
            if (to_user) @memcpy(u, k) else @memcpy(k, u);
            off += chunk;
        }
    }

    fn userPagePhysLocked(self: *VMM, virt_addr: usize, write: bool) error{Fault}!usize {
        const base = std.mem.alignBackward(usize, virt_addr, pmm.page_size);
        const entry = self.pt.virtToPTE(base, false, false) catch return error.Fault;
        const flags = entry.getFlags();
        if (!flags.present or !flags.user) return error.Fault;
        if (write and !flags.writable) return error.Fault;
        return entry.getAddress();
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

    kernel_vmm.pt_addr_phys = pmm.alloc(1) orelse return error.OutOfMemory;
    kernel_vmm.pt = virt.toHH(*PageTable, kernel_vmm.pt_addr_phys);
    kernel_vmm.initialized = true;

    // Pre-allocate higher half L3 tables to facilitate sharing kernel space
    // across user spaces
    for (kernel_pml4_start..page_table_entries) |i| {
        _ = kernel_vmm.pt.getNextLevel(i, true, false) orelse return error.OutOfMemory;
    }

    // Base revision 6 maps only selected memory-map types into the HHDM.
    // Framebuffer pages are write-combining; every other direct-map entry stays write-back.
    var hhdm_bytes: usize = 0;
    logger.debug("mapping HHDM", .{});
    for (boot.info().memory_map.entries()) |entry| {
        if (!entry.kind.inHhdm()) continue;
        const base: usize = @intCast(entry.base);
        const length: usize = @intCast(entry.length);
        const top = std.math.add(usize, base, length) catch return error.Overflow;
        const start = std.mem.alignBackward(usize, base, pmm.page_size);
        const end = try pageAlignForward(top);
        hhdm_bytes += end - start;
        const flags: Flags = switch (entry.kind) {
            .framebuffer => hhdm_fb_flags,
            else => hhdm_ram_flags,
        };
        try mapHhdmRange(kernel_vmm.pt, base, top, flags, .keep);
    }

    // executable_and_modules also covers these frames. Drop the writable
    // alias so text and rodata stay read-only beside the mappings below.
    const text_range = sectionRange("text");
    const rodata_range = sectionRange("rodata");
    const text_top = std.math.add(usize, text_range.phys, text_range.size) catch return error.Overflow;
    const rodata_top = std.math.add(usize, rodata_range.phys, rodata_range.size) catch return error.Overflow;
    try mapHhdmRange(kernel_vmm.pt, text_range.phys, text_top, hhdm_ro_flags, .remap);
    try mapHhdmRange(kernel_vmm.pt, rodata_range.phys, rodata_top, hhdm_ro_flags, .remap);

    const text = try mapKernelSection(&kernel_vmm, text_range, .{ .present = true });
    const rodata = try mapKernelSection(&kernel_vmm, rodata_range, .{ .present = true, .noexec = true });
    const data = try mapKernelSection(&kernel_vmm, sectionRange("data"), .{ .present = true, .writable = true, .noexec = true });

    kernel_vmm.switchTo();
    logger.info("hhdm {d} MiB, kernel text={d} KiB rodata={d} KiB data={d} KiB cr3=0x{x}", .{
        hhdm_bytes / (1024 * 1024),
        text / 1024,
        rodata / 1024,
        data / 1024,
        kernel_vmm.pt_addr_phys,
    });
}

const hhdm_ram_flags = Flags{ .present = true, .writable = true, .noexec = true };
const hhdm_ro_flags = Flags{ .present = true, .noexec = true };
// Limine PAT entry 5 (PWT|PAT, PCD clear) is write-combining.
const hhdm_fb_flags = Flags{
    .present = true,
    .writable = true,
    .write_through = true,
    .pat = true,
    .noexec = true,
};
const mmio_flags = Flags{ .present = true, .writable = true, .cache_disable = true, .noexec = true };

// alignForward adds page_size-1 and panics on overflow in ReleaseSafe.
fn pageAlignForward(addr: usize) error{Overflow}!usize {
    const add = pmm.page_size - 1;
    const padded = std.math.add(usize, addr, add) catch return error.Overflow;
    return padded & ~add;
}

fn mapHhdmRange(pt: *PageTable, base: usize, top: usize, flags: Flags, existing: enum { keep, remap }) !void {
    if (top < base) return error.Overflow;
    var addr = std.mem.alignBackward(usize, base, pmm.page_size);
    const end = try pageAlignForward(top);
    while (addr < end) : (addr += pmm.page_size) {
        const va = virt.toHH(usize, addr);
        pt.mapPage(va, addr, flags) catch |err| switch (err) {
            error.AlreadyMapped => switch (existing) {
                .keep => {},
                .remap => {
                    const pte = try pt.virtToPTE(va, false, false);
                    if (pte.getAddress() != addr) @panic("HHDM phys mismatch");
                    pt.remapPage(va, addr, flags) catch @panic("remap of mapped page");
                },
            },
            else => return err,
        };
    }
}

const SectionRange = struct {
    virt: usize,
    phys: usize,
    size: usize,
};

fn sectionRange(comptime section_name: []const u8) SectionRange {
    const section_start = @intFromPtr(@extern(*u8, .{ .name = section_name ++ "_start_addr" }));
    const section_end = @intFromPtr(@extern(*u8, .{ .name = section_name ++ "_end_addr" }));

    const virt_start = std.mem.alignBackward(usize, section_start, pmm.page_size);
    const virt_end = std.mem.alignForward(usize, section_end, pmm.page_size);

    const virt_base: usize = @intCast(boot.info().kernel.virtual_base);
    const phys_base: usize = @intCast(boot.info().kernel.physical_base);
    return .{
        .virt = virt_start,
        .phys = virt_start - virt_base + phys_base,
        .size = virt_end - virt_start,
    };
}

fn mapKernelSection(vm: *VMM, range: SectionRange, flags: Flags) !usize {
    try vm.map(range.virt, range.phys, range.size, flags);
    return range.size;
}

inline fn flushTLB(virt_addr: usize) void {
    asm volatile (
        \\invlpg (%[virt_addr])
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

test "pageAlignForward rejects an end in the last page" {
    try std.testing.expectEqual(@as(usize, 0), try pageAlignForward(0));
    try std.testing.expectEqual(pmm.page_size, try pageAlignForward(1));
    try std.testing.expectEqual(pmm.page_size, try pageAlignForward(pmm.page_size));
    const last_aligned = std.math.maxInt(usize) - (pmm.page_size - 1);
    try std.testing.expectEqual(last_aligned, try pageAlignForward(last_aligned));
    try std.testing.expectError(error.Overflow, pageAlignForward(last_aligned + 1));
    try std.testing.expectError(error.Overflow, pageAlignForward(std.math.maxInt(usize)));
}

test "Flags construction" {
    try std.testing.expectEqual(0x8000_0000_0000_0003, @as(u64, @bitCast(hhdm_ram_flags)));
    try std.testing.expectEqual(0x8000_0000_0000_0001, @as(u64, @bitCast(hhdm_ro_flags)));
    try std.testing.expectEqual(0x8000_0000_0000_0013, @as(u64, @bitCast(mmio_flags)));
    // PAT index 5: PWT (bit 3) and PAT (bit 7), PCD clear.
    try std.testing.expectEqual(0x8000_0000_0000_008b, @as(u64, @bitCast(hhdm_fb_flags)));
}

test "userRange rejects the null page" {
    try std.testing.expect(!userRange(0, 1));
    try std.testing.expect(!userRange(pmm.page_size - 1, 1));
    try std.testing.expect(userRange(pmm.page_size, 1));
}

test "userRange rejects the kernel half" {
    try std.testing.expect(!userRange(user_space_end, 1));
    try std.testing.expect(!userRange(user_space_end - 1, 2));
    try std.testing.expect(userRange(user_space_end - 1, 1));
}

test "userRange omits the last canonical page" {
    const canonical_end: usize = 1 << 47;
    try std.testing.expectEqual(canonical_end - pmm.page_size, user_space_end);
    try std.testing.expect(!userRange(canonical_end - pmm.page_size, 1));
}

test "userRange empty length is always in range" {
    try std.testing.expect(userRange(0, 0));
    try std.testing.expect(userRange(user_space_end, 0));
}

test "userRange rejects a span past the user half" {
    try std.testing.expect(!userRange(pmm.page_size, user_space_end - pmm.page_size + 1));
    try std.testing.expect(userRange(pmm.page_size, user_space_end - pmm.page_size));
}

test "kernel half starts at PML4 index 256" {
    try std.testing.expectEqual(@as(usize, 1) << 47, kernel_half_start);
    try std.testing.expect(!kernelHalf(0));
    try std.testing.expect(!kernelHalf(user_space_end - 1));
    try std.testing.expect(!kernelHalf(kernel_half_start - 1));
    try std.testing.expect(kernelHalf(kernel_half_start));
    try std.testing.expect(kernelHalf(0xffff_ff00_0000_0000));
    try std.testing.expect(kernelHalf(0xffffffff80000000));
}

test "a user mapping must not reach the shared kernel half" {
    try std.testing.expect(!rangeIntersectsKernelHalf(pmm.page_size, pmm.page_size));
    try std.testing.expect(!rangeIntersectsKernelHalf(kernel_half_start - pmm.page_size, pmm.page_size));
    try std.testing.expect(!rangeIntersectsKernelHalf(kernel_half_start, 0));
    try std.testing.expect(rangeIntersectsKernelHalf(kernel_half_start - pmm.page_size, pmm.page_size * 2));
    try std.testing.expect(rangeIntersectsKernelHalf(kernel_half_start, pmm.page_size));
    try std.testing.expect(rangeIntersectsKernelHalf(std.math.maxInt(usize) - pmm.page_size + 1, pmm.page_size));
}

test "userCanonical is 0-canonical only" {
    try std.testing.expect(userCanonical(0));
    try std.testing.expect(userCanonical((1 << 47) - 1));
    try std.testing.expect(!userCanonical(1 << 47));
    try std.testing.expect(!userCanonical(~@as(usize, 0)));
}
