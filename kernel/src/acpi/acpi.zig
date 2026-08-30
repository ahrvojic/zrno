const logger = std.log.scoped(.acpi);

const std = @import("std");

const boot = @import("../sys/boot.zig");
const fadt = @import("fadt.zig");
const madt = @import("madt.zig");
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

    pub fn getData(self: *align(1) const SDT) []const u8 {
        return @as([*]const u8, @ptrCast(self))[0..self.length][@sizeOf(SDT)..];
    }
};

const ACPI = struct {
    rsdt: *align(1) const SDT = undefined,
    use_xsdt: bool = false,

    pub fn load(self: *ACPI) void {
        // Base revision 6 returns a virtual (HHDM) pointer. Table
        // addresses inside RSDP/XSDP are still physical.
        const rsdp: *align(1) const RSDP = @ptrCast(boot.info().rsdp.address);

        const oem = std.mem.trimEnd(u8, &rsdp.oem_id, " \x00");
        if (rsdp.revision >= 2) {
            logger.info("XSDT rev={d} oem={s}", .{ rsdp.revision, oem });
            const xsdp: *align(1) const XSDP = @ptrCast(rsdp);
            self.rsdt = virt.toHH(*align(1) const SDT, @intCast(xsdp.xsdt_addr));
            self.use_xsdt = true;
        } else {
            logger.info("RSDT rev={d} oem={s}", .{ rsdp.revision, oem });
            self.rsdt = virt.toHH(*align(1) const SDT, @intCast(rsdp.rsdt_addr));
        }
    }

    pub fn findSDT(self: *const ACPI, signature: *const [4]u8, index: usize) !*align(1) const SDT {
        return if (self.use_xsdt) self.findSDTAt(u64, signature, index) else self.findSDTAt(u32, signature, index);
    }

    fn findSDTAt(self: *const ACPI, comptime T: type, signature: *const [4]u8, index: usize) !*align(1) const SDT {
        const data = self.rsdt.getData();
        const entry_size = @sizeOf(T);
        var offset: usize = 0;
        var index_curr = index;

        // XSDT entries sit at SDT+36 (4-aligned, not 8). Read them unaligned.
        while (offset + entry_size <= data.len) : (offset += entry_size) {
            const entry = std.mem.readInt(T, data[offset..][0..entry_size], .little);
            const sdt = virt.toHH(*align(1) const SDT, @intCast(entry));

            if (!std.mem.eql(u8, &sdt.signature, signature)) {
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

    const fadt_sdt = try acpi.findSDT("FACP", 0);
    try fadt.init(fadt_sdt);

    const madt_sdt = try acpi.findSDT("APIC", 0);
    try madt.init(madt_sdt);
}
