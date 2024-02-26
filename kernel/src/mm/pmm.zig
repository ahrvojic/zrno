const logger = std.log.scoped(.pmm);

const std = @import("std");
const limine = @import("limine");

const page_size = 4096;

var highest_phys_addr: u64 = 0;

var usable_pages: usize = undefined;
var reserved_pages: usize = undefined;
var bad_pages: usize = undefined;

pub fn init(hhdm_res: *limine.HhdmResponse, mm_res: *limine.MemoryMapResponse) !void {
    _ = hhdm_res; // TODO

    for (mm_res.entries()) |entry| {
        logger.info("Entry: base=0x{X:0>16} length=0x{X:0>16} kind={}", .{ entry.base, entry.length, entry.kind });

        switch (entry.kind) {
            .usable => {
                usable_pages += try std.math.divCeil(u64, entry.length, page_size);
                highest_phys_addr = @max(highest_phys_addr, entry.base + entry.length);
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
}
