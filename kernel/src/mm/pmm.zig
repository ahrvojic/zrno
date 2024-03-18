const logger = std.log.scoped(.pmm);

const std = @import("std");
const limine = @import("limine");

const boot = @import("../sys/boot.zig");
const virt = @import("../lib/virt.zig");

pub const page_size = 4096;

var usable_pages: usize = 0;
var used_pages: usize = 0;
var reserved_pages: usize = 0;
var bad_pages: usize = 0;

var highest_page_index: usize = 0;
var last_used_index: usize = 0;

var bitmap: Bitmap = undefined;

const Bitmap = struct {
    data: []u8,

    pub fn init(data: []u8) Bitmap {
        return .{ .data = data };
    }

    pub fn testBit(self: *const @This(), bit: usize) bool {
        return self.data[bit / 8] & (@as(u8, 1) << @as(u3, @intCast(bit % 8))) != 0;
    }

    pub fn setBit(self: *@This(), bit: usize) void {
        self.data[bit / 8] |= (@as(u8, 1) << @as(u3, @intCast(bit % 8)));
    }

    pub fn clearBit(self: *@This(), bit: usize) void {
        self.data[bit / 8] &= ~(@as(u8, 1) << @as(u3, @intCast(bit % 8)));
    }
};

pub fn init() !void {
    // Determine highest usable address
    var highest_addr: u64 = 0;

    for (boot.get().memoryMap.entries()) |entry| {
        logger.info("Entry: base=0x{X:0>16} length=0x{X:0>16} kind={}", .{entry.base, entry.length, entry.kind});

        switch (entry.kind) {
            .usable => {
                usable_pages += try std.math.divCeil(u64, entry.length, page_size);
                highest_addr = @max(highest_addr, entry.base + entry.length);
            },
            .reserved,
            .acpi_reclaimable,
            .acpi_nvs,
            .bootloader_reclaimable,
            .kernel_and_modules,
            .framebuffer => {
                reserved_pages += try std.math.divCeil(u64, entry.length, page_size);
            },
            .bad_memory => {
                bad_pages += try std.math.divCeil(u64, entry.length, page_size);
            }
        }
    }

    logger.info("Pages: usable={d} reserved={d} bad={d}", .{usable_pages, reserved_pages, bad_pages});

    // Determine size of bitmap aligned to page size
    highest_page_index = highest_addr / page_size;
    const bitmap_size = std.mem.alignForward(u64, highest_page_index / 8, page_size);
    logger.debug("Bitmap: highest_index={d} size={d}", .{highest_page_index, bitmap_size});

    // Find where the bitmap can fit in usable memeory
    var bitmap_region: ?*limine.MemoryMapEntry = null;

    for (boot.get().memoryMap.entries()) |entry| {
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
    for (boot.get().memoryMap.entries()) |entry| {
        if (entry.kind == .usable) {
            var i: usize = 0;
            while (i < entry.length) : (i += page_size) {
                bitmap.clearBit((entry.base + i) / page_size);
            }
        }
    }
}

pub fn alloc(pages: usize) ?u64 {
    const res = allocNoZero(pages);

    if (res) |address| {
        // Zero allocated memory before returning address
        const size = pages * page_size;
        const data = virt.toHH([*]u8, address)[0..size];
        @memset(data, 0);
    }

    return res;
}

pub fn allocNoZero(pages: usize) ?u64 {
    return allocInner(last_used_index, pages) orelse allocInner(0, pages);
}

fn allocInner(start: usize, pages: usize) ?u64 {
    // Scan the bitmap for a contiguous block of free pages
    var p_idx: usize = start;
    var p_count: usize = 0;

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

    // Mark found pages as used and return the address
    var i = p_idx - pages + 1;
    while (i <= p_idx) : (i += 1) {
        bitmap.setBit(i);
    }

    last_used_index = p_idx;
    used_pages += pages;

    return i * page_size;
}

pub fn free(address: u64, pages: usize) void {
    const start = address / page_size;
    const end = start + pages;

    for (start..end) |i| {
        bitmap.clearBit(i);
    }

    used_pages -= pages;
}
