const logger = std.log.scoped(.pmm);

const std = @import("std");
const limine = @import("limine");

const page_size = 4096;

var usable_pages: usize = undefined;
var reserved_pages: usize = undefined;
var bad_pages: usize = undefined;

var highest_addr: u64 = undefined;

var bitmap: Bitmap = undefined;

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

pub fn init(hhdm_res: *limine.HhdmResponse, mm_res: *limine.MemoryMapResponse) !void {
    // Determine highest usable address
    for (mm_res.entries()) |entry| {
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
    const bitmap_size = std.mem.alignForward(u64, highest_addr / page_size / 8, page_size);
    logger.debug("Bitmap size: {d}", .{bitmap_size});

    // Find where the bitmap can fit in usable memeory
    var bitmap_region: ?*limine.MemoryMapEntry = null;

    for (mm_res.entries()) |entry| {
        if (entry.kind == .usable and entry.length >= bitmap_size) {
            bitmap_region = entry;
            break;
        }
    }

    if (bitmap_region == null) {
        return error.BitmapTooBig;
    }

    // Create the bitmap and initialize all bits to 1 (non-free)
    const bitmap_addr = bitmap_region.?.base + hhdm_res.offset;
    bitmap = Bitmap.init(@as([*]u8, @ptrFromInt(bitmap_addr))[0..bitmap_size]);
    @memset(bitmap.data, 0xff);

    // Clear free bits according to the memory map
    for (mm_res.entries()) |entry| {
        if (entry.kind == .usable) {
            var i: usize = 0;
            while (i < entry.length) : (i += page_size) {
                bitmap.clearBit((entry.base + i) / page_size);
            }
        }
    }
}
