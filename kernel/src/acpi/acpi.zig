const logger = std.log.scoped(.acpi);

const std = @import("std");

const boot = @import("../sys/boot.zig");
const debug = @import("../lib/debug.zig");
const fadt = @import("fadt.zig");
const madt = @import("madt.zig");
const panic = @import("../lib/panic.zig").panic;
const virt = @import("../lib/virt.zig");

const RSDP = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_addr: u32,
};

const XSDP = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_addr: u32,
    length: u32,
    xsdt_addr: u64,
    extended_checksum: u8,
    reserved: [3]u8,
};

pub const SDT = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,

    pub fn getData(self: *const @This()) []const u8 {
        return @as([*]const u8, @ptrCast(self))[0..self.length][@sizeOf(SDT)..];
    }
};

const ACPI = struct {
    rsdt: *const SDT = undefined,

    pub fn load(self: *@This()) void {
        switch (boot.get().rsdp.revision) {
            0 => {
                logger.info("Load RSDT revision 0", .{});
                const rsdp: *align(1) const RSDP = @ptrCast(boot.get().rsdp.address);
                self.rsdt = virt.toHH(*const SDT, rsdp.rsdt_addr);
            },
            2 => {
                logger.info("Load RSDT revision 2", .{});
                const xsdp: *align(1) const XSDP = @ptrCast(boot.get().rsdp.address);
                self.rsdt = virt.toHH(*const SDT, xsdp.xsdt_addr);
            },
            else => panic("Unknown ACPI revision!"),
        }
    }

    pub fn findSDT(self: *const @This(), signature: []const u8, index: usize) !*const SDT {
        return if (boot.get().rsdp.revision > 0) self.findSDTAt(u64, signature, index)
        else self.findSDTAt(u32, signature, index);
    }

    fn findSDTAt(self: *const @This(), comptime T: type, signature: []const u8, index: usize) !*const SDT {
        const entries = std.mem.bytesAsSlice(T, self.rsdt.getData());
        var index_curr = index;

        for (entries) |entry| {
            const sdt = virt.toHH(*const SDT, entry);

            if (!std.mem.eql(u8, &sdt.signature, std.mem.sliceTo(signature, 3))) {
                continue;
            }

            if (index_curr > 0) {
                index_curr -= 1;
                continue;
            }

            return sdt;
        }

        logger.err("SDT not found: {s}", .{signature});
        return error.AcpiSdtNotFound;
    }
};

pub fn init() !void {
    var acpi: ACPI = .{};
    acpi.load();

    logger.info("Load FADT", .{});
    const fadt_sdt = try acpi.findSDT("FACP", 0);
    try fadt.init(fadt_sdt);

    logger.info("Load MADT", .{});
    const madt_sdt = try acpi.findSDT("APIC", 0);
    try madt.init(madt_sdt);
}
