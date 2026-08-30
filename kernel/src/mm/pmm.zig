const logger = std.log.scoped(.pmm);

const std = @import("std");
const limine = @import("limine");

const BoundedArray = @import("../lib/bounded_array.zig").BoundedArray;
const boot = @import("../sys/boot.zig");
const Lock = @import("../lib/lock.zig");
const virt = @import("../lib/virt.zig");

pub const page_size: usize = 4096;

const ReclaimRange = struct {
    base: usize,
    length: usize,
};

// Typical Limine maps have a handful of bootloader_reclaimable entries.
const max_reclaim_ranges = 64;

var usable_pages: usize = 0;
var used_pages: usize = 0;
var reserved_pages: usize = 0;
var bad_pages: usize = 0;

var highest_page_index: usize = 0;
var last_used_index: usize = 0;

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

    pub fn testBit(self: *const Bitmap, bit: usize) bool {
        return self.data[bit / 8] & (@as(u8, 1) << @as(u3, @intCast(bit % 8))) != 0;
    }

    pub fn setBit(self: *Bitmap, bit: usize) void {
        self.data[bit / 8] |= (@as(u8, 1) << @as(u3, @intCast(bit % 8)));
    }

    pub fn clearBit(self: *Bitmap, bit: usize) void {
        self.data[bit / 8] &= ~(@as(u8, 1) << @as(u3, @intCast(bit % 8)));
    }
};

pub fn init() !void {
    expectUninit();

    // Bitmap must cover usable RAM and bootloader_reclaimable (freed later).
    var highest_addr: usize = 0;

    for (boot.info().memory_map.entries()) |entry| {
        const base: usize = @intCast(entry.base);
        const length: usize = @intCast(entry.length);
        logger.debug("{s}: base=0x{X:0>16} length=0x{X:0>16}", .{ @tagName(entry.kind), base, length });

        switch (entry.kind) {
            .usable => {
                usable_pages += try std.math.divCeil(usize, length, page_size);
                highest_addr = @max(highest_addr, base + length);
            },
            .bootloader_reclaimable => {
                reserved_pages += try std.math.divCeil(usize, length, page_size);
                highest_addr = @max(highest_addr, base + length);
                try reclaim_ranges.append(.{ .base = base, .length = length });
            },
            .reserved, .acpi_reclaimable, .acpi_nvs, .executable_and_modules, .framebuffer, .reserved_mapped => {
                reserved_pages += try std.math.divCeil(usize, length, page_size);
            },
            .bad_memory => {
                bad_pages += try std.math.divCeil(usize, length, page_size);
            },
        }
    }

    // Determine size of bitmap aligned to page size
    highest_page_index = highest_addr / page_size;
    const bitmap_bytes = try std.math.divCeil(usize, highest_page_index, 8);
    const bitmap_size = std.mem.alignForward(usize, bitmap_bytes, page_size);

    if (bitmap_size == 0) {
        return error.BitmapTooBig;
    }

    // Find where the bitmap can fit in usable memory
    var bitmap_region: ?*limine.MemoryMapEntry = null;

    for (boot.info().memory_map.entries()) |entry| {
        const length: usize = @intCast(entry.length);
        if (entry.kind == .usable and length >= bitmap_size) {
            bitmap_region = entry;
            break;
        }
    }

    if (bitmap_region == null) {
        return error.BitmapTooBig;
    }

    const bitmap_base: usize = @intCast(bitmap_region.?.base);

    // Create the bitmap and initialize all bits to 1 (non-free)
    bitmap = Bitmap.init(virt.toHH([*]u8, bitmap_base)[0..bitmap_size]);
    @memset(bitmap.data, 0xff);

    // Clear free bits according to the memory map
    for (boot.info().memory_map.entries()) |entry| {
        if (entry.kind == .usable) {
            const base: usize = @intCast(entry.base);
            const length: usize = @intCast(entry.length);
            const start = base / page_size;
            const end = start + length / page_size;
            for (start..end) |page| {
                bitmap.clearBit(page);
            }
        }
    }

    // The bitmap itself sits in a usable region and was just marked free.
    const bitmap_page = bitmap_base / page_size;
    const bitmap_pages = bitmap_size / page_size;
    for (0..bitmap_pages) |i| {
        bitmap.setBit(bitmap_page + i);
    }
    used_pages += bitmap_pages;
    initialized = true;

    logger.info("{d} MiB usable, {d} MiB reserved, {d} bad pages; bitmap {d} KiB", .{
        pagesToMiB(usable_pages),
        pagesToMiB(reserved_pages),
        bad_pages,
        bitmap_size / 1024,
    });
}

fn pagesToMiB(pages: usize) usize {
    return (pages * page_size) / (1024 * 1024);
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

    var pages: usize = 0;
    var first_idx: ?usize = null;

    for (reclaim_ranges.constSlice()) |range| {
        const start = range.base / page_size;
        const end = start + range.length / page_size;
        for (start..end) |idx| {
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
    logger.info("reclaimed {d} pages ({d} KiB); usable now {d} MiB", .{
        pages,
        pages * 4,
        pagesToMiB(usable_pages),
    });
}

pub fn alloc(pages: usize) ?usize {
    const res = allocNoZero(pages);

    if (res) |address| {
        // Zero allocated memory before returning address
        const size = pages * page_size;
        const data = virt.toHH([*]u8, address)[0..size];
        @memset(data, 0);
    }

    return res;
}

pub fn allocNoZero(pages: usize) ?usize {
    expectInit();
    if (pages == 0) return null;
    lock.lock();
    defer lock.unlock();
    return allocInner(last_used_index, pages) orelse allocInner(0, pages);
}

fn allocInner(start: usize, pages: usize) ?usize {
    var run: usize = 0;
    const end = for (start..highest_page_index) |idx| {
        if (bitmap.testBit(idx)) {
            run = 0;
        } else {
            run += 1;
            if (run == pages) break idx + 1;
        }
    } else return null;

    const first = end - pages;
    for (first..end) |i| {
        bitmap.setBit(i);
    }

    last_used_index = end;
    used_pages += pages;
    return first * page_size;
}

pub fn free(address: usize, pages: usize) void {
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
