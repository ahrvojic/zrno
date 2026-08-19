const logger = std.log.scoped(.pmm);

const std = @import("std");
const limine = @import("limine");

const BoundedArray = @import("../lib/bounded_array.zig").BoundedArray;
const boot = @import("../sys/boot.zig");
const Lock = @import("../lib/lock.zig");
const virt = @import("../lib/virt.zig");

pub const page_size: u64 = 4096;

const ReclaimRange = struct {
    base: u64,
    length: u64,
};

// Typical Limine maps have a handful of bootloader_reclaimable entries.
const max_reclaim_ranges = 64;

var usable_pages: u64 = 0;
var used_pages: u64 = 0;
var reserved_pages: u64 = 0;
var bad_pages: u64 = 0;

var highest_page_index: u64 = 0;
var last_used_index: u64 = 0;

var bitmap: Bitmap = undefined;
var lock: Lock.SpinLock = .{};
var initialized = false;
var bootloader_reclaimed = false;
var reclaim_ranges: BoundedArray(ReclaimRange, max_reclaim_ranges) = .{};

fn expectInit() void {
    if (!initialized) @panic("pmm used before init");
}

fn expectUninit() void {
    if (initialized) @panic("pmm already initialized");
}

const Bitmap = struct {
    data: []u8,

    pub fn init(data: []u8) Bitmap {
        return .{ .data = data };
    }

    pub fn testBit(self: *const @This(), bit: u64) bool {
        return self.data[bit / 8] & (@as(u8, 1) << @as(u3, @intCast(bit % 8))) != 0;
    }

    pub fn setBit(self: *@This(), bit: u64) void {
        self.data[bit / 8] |= (@as(u8, 1) << @as(u3, @intCast(bit % 8)));
    }

    pub fn clearBit(self: *@This(), bit: u64) void {
        self.data[bit / 8] &= ~(@as(u8, 1) << @as(u3, @intCast(bit % 8)));
    }
};

pub fn init() !void {
    expectUninit();

    // Bitmap must cover usable RAM and bootloader_reclaimable (freed later).
    var highest_addr: u64 = 0;

    for (boot.info().memory_map.entries()) |entry| {
        logger.info("Entry: base=0x{X:0>16} length=0x{X:0>16} kind={}", .{ entry.base, entry.length, entry.kind });

        switch (entry.kind) {
            .usable => {
                usable_pages += try std.math.divCeil(u64, entry.length, page_size);
                highest_addr = @max(highest_addr, entry.base + entry.length);
            },
            .bootloader_reclaimable => {
                reserved_pages += try std.math.divCeil(u64, entry.length, page_size);
                highest_addr = @max(highest_addr, entry.base + entry.length);
                try reclaim_ranges.append(.{ .base = entry.base, .length = entry.length });
            },
            .reserved, .acpi_reclaimable, .acpi_nvs, .executable_and_modules, .framebuffer, .reserved_mapped => {
                reserved_pages += try std.math.divCeil(u64, entry.length, page_size);
            },
            .bad_memory => {
                bad_pages += try std.math.divCeil(u64, entry.length, page_size);
            },
        }
    }

    logger.info("Pages: usable={d} reserved={d} bad={d}", .{ usable_pages, reserved_pages, bad_pages });

    // Determine size of bitmap aligned to page size
    highest_page_index = highest_addr / page_size;
    const bitmap_bytes = try std.math.divCeil(u64, highest_page_index, 8);
    const bitmap_size = std.mem.alignForward(u64, bitmap_bytes, page_size);
    logger.info("Bitmap: highest_index={d} size={d}", .{ highest_page_index, bitmap_size });

    if (bitmap_size == 0) {
        return error.BitmapTooBig;
    }

    // Find where the bitmap can fit in usable memory
    var bitmap_region: ?*limine.MemoryMapEntry = null;

    for (boot.info().memory_map.entries()) |entry| {
        if (entry.kind == .usable and entry.length >= bitmap_size) {
            bitmap_region = entry;
            break;
        }
    }

    if (bitmap_region == null) {
        return error.BitmapTooBig;
    }

    // Create the bitmap and initialize all bits to 1 (non-free)
    bitmap = Bitmap.init(virt.toHH([*]u8, bitmap_region.?.base)[0..bitmap_size]);
    @memset(bitmap.data, 0xff);

    // Clear free bits according to the memory map
    for (boot.info().memory_map.entries()) |entry| {
        if (entry.kind == .usable) {
            var i: u64 = 0;
            while (i < entry.length) : (i += page_size) {
                bitmap.clearBit((entry.base + i) / page_size);
            }
        }
    }

    // The bitmap itself sits in a usable region and was just marked free.
    const bitmap_page = bitmap_region.?.base / page_size;
    const bitmap_pages = bitmap_size / page_size;
    for (0..bitmap_pages) |i| {
        bitmap.setBit(bitmap_page + i);
    }
    used_pages += bitmap_pages;
    initialized = true;
}

/// Mark previously reserved bootloader_reclaimable pages free. Call after
/// Limine responses have been copied out and `boot.drop()` has run. The
/// Limine boot stack lives in this memory; do not allocate until the
/// first schedule has abandoned it.
pub fn reclaimBootloader() void {
    expectInit();
    if (bootloader_reclaimed) @panic("bootloader already reclaimed");

    lock.lock();
    defer lock.unlock();

    var pages: u64 = 0;
    var first_idx: ?u64 = null;

    for (reclaim_ranges.constSlice()) |range| {
        var offset: u64 = 0;
        while (offset < range.length) : (offset += page_size) {
            const idx = (range.base + offset) / page_size;
            if (idx >= highest_page_index) continue;
            if (!bitmap.testBit(idx)) continue;
            bitmap.clearBit(idx);
            if (first_idx == null) first_idx = idx;
            pages += 1;
        }
    }

    reserved_pages -= pages;
    usable_pages += pages;
    if (first_idx) |idx| {
        last_used_index = @min(last_used_index, idx);
    }
    bootloader_reclaimed = true;
    logger.info("Reclaimed {d} bootloader pages ({d} KiB)", .{ pages, pages * 4 });
}

pub fn alloc(pages: u64) ?u64 {
    const res = allocNoZero(pages);

    if (res) |address| {
        // Zero allocated memory before returning address
        const size = pages * page_size;
        const data = virt.toHH([*]u8, address)[0..size];
        @memset(data, 0);
    }

    return res;
}

pub fn allocNoZero(pages: u64) ?u64 {
    expectInit();
    if (pages == 0) return null;
    lock.lock();
    defer lock.unlock();
    return allocInner(last_used_index, pages) orelse allocInner(0, pages);
}

fn allocInner(start: u64, pages: u64) ?u64 {
    // Scan the bitmap for a contiguous block of free pages
    var p_idx: u64 = start;
    var p_count: u64 = 0;

    while (p_idx < highest_page_index and p_count < pages) : (p_idx += 1) {
        if (bitmap.testBit(p_idx)) {
            p_count = 0; // used page; reset counter
        } else {
            p_count += 1;
        }
    }

    if (p_count < pages) {
        return null;
    }

    // p_idx sits one past the last free page of the run
    const first = p_idx - pages;
    for (first..p_idx) |i| {
        bitmap.setBit(i);
    }

    last_used_index = p_idx;
    used_pages += pages;

    return first * page_size;
}

pub fn free(address: u64, pages: u64) void {
    expectInit();
    lock.lock();
    defer lock.unlock();

    const start = address / page_size;
    const end = start + pages;

    for (start..end) |i| {
        bitmap.clearBit(i);
    }

    last_used_index = @min(last_used_index, start);
    used_pages -= pages;
}
