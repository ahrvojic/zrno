const logger = std.log.scoped(.acpi);

const std = @import("std");

const boot = @import("../sys/boot.zig");
const fadt = @import("fadt.zig");
const hpet = @import("hpet.zig");
const madt = @import("madt.zig");
const virt = @import("../lib/virt.zig");

const rsdp_sig = "RSD PTR ";
const rsdp_v1_len: usize = 20;
const rsdp_v2_len: usize = 36;
const rsdp_max_len: usize = 64;
const max_sdt_len: u32 = 1 << 20;

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

// ACPI 5.2.3.2 Generic Address Structure. 12 bytes on the wire.
pub const GenericAddress = extern struct {
    address_space: u8 align(1),
    bit_width: u8 align(1),
    bit_offset: u8 align(1),
    access_size: u8 align(1),
    address: u64 align(1),
};

pub const gas_space_memory: u8 = 0;
pub const gas_space_io: u8 = 1;

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

    pub fn load(self: *ACPI) !void {
        // Base revision 6 returns a virtual (HHDM) pointer. Table
        // addresses inside RSDP/XSDP are still physical.
        const rsdp: *align(1) const RSDP = @ptrCast(boot.info().rsdp.address);
        try verifyRsdp(rsdp);

        const oem = std.mem.trimEnd(u8, &rsdp.oem_id, " \x00");
        if (rsdp.revision >= 2) {
            logger.info("XSDT rev={d} oem={s}", .{ rsdp.revision, oem });
            const xsdp: *align(1) const XSDP = @ptrCast(rsdp);
            self.rsdt = try mapSdt(@intCast(xsdp.xsdt_addr), "XSDT");
            self.use_xsdt = true;
        } else {
            logger.info("RSDT rev={d} oem={s}", .{ rsdp.revision, oem });
            self.rsdt = try mapSdt(@intCast(rsdp.rsdt_addr), "RSDT");
        }
    }

    pub fn findSDT(self: *const ACPI, signature: *const [4]u8, index: usize) !*align(1) const SDT {
        return (try self.lookupSDT(signature, index)) orelse {
            logger.err("SDT not found: {s}", .{signature});
            return error.AcpiSdtNotFound;
        };
    }

    fn lookupSDT(self: *const ACPI, signature: *const [4]u8, index: usize) !?*align(1) const SDT {
        return if (self.use_xsdt)
            self.lookupSDTAt(u64, signature, index)
        else
            self.lookupSDTAt(u32, signature, index);
    }

    fn lookupSDTAt(self: *const ACPI, comptime T: type, signature: *const [4]u8, index: usize) !?*align(1) const SDT {
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

            try verifySdt(sdt);
            return sdt;
        }

        return null;
    }
};

fn checksum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return sum;
}

fn verifyRsdp(rsdp: *align(1) const RSDP) !void {
    const bytes: [*]const u8 = @ptrCast(rsdp);
    if (!std.mem.eql(u8, bytes[0..8], rsdp_sig)) return error.InvalidAcpiTable;
    if (checksum(bytes[0..rsdp_v1_len]) != 0) return error.InvalidAcpiTable;
    if (rsdp.revision < 2) return;

    const xsdp: *align(1) const XSDP = @ptrCast(rsdp);
    // On the wire XSDP is 36 bytes; @sizeOf may be 40 from extern tail padding.
    if (xsdp.length < rsdp_v2_len or xsdp.length > rsdp_max_len) {
        return error.InvalidAcpiTable;
    }
    if (checksum(bytes[0..xsdp.length]) != 0) return error.InvalidAcpiTable;
}

fn verifySdt(sdt: *align(1) const SDT) !void {
    if (sdt.length < @sizeOf(SDT) or sdt.length > max_sdt_len) {
        return error.InvalidAcpiTable;
    }
    const bytes = @as([*]const u8, @ptrCast(sdt))[0..sdt.length];
    if (checksum(bytes) != 0) {
        logger.err("bad checksum for {s} len={d}", .{ sdt.signature, sdt.length });
        return error.InvalidAcpiTable;
    }
}

fn mapSdt(phys: usize, comptime expected_sig: *const [4]u8) !*align(1) const SDT {
    const sdt = virt.toHH(*align(1) const SDT, phys);
    try verifySdt(sdt);
    if (!std.mem.eql(u8, &sdt.signature, expected_sig)) {
        logger.err("expected {s}, got {s}", .{ expected_sig, &sdt.signature });
        return error.InvalidAcpiTable;
    }
    return sdt;
}

pub fn init() !void {
    var acpi: ACPI = .{};
    try acpi.load();

    const fadt_sdt = try acpi.findSDT("FACP", 0);
    try fadt.init(fadt_sdt);

    const madt_sdt = try acpi.findSDT("APIC", 0);
    try madt.init(madt_sdt);

    try hpet.init(try acpi.lookupSDT("HPET", 0));
}

comptime {
    std.debug.assert(@sizeOf(RSDP) == rsdp_v1_len);
    std.debug.assert(@sizeOf(GenericAddress) == 12);
}

test "acpi checksum is zero iff bytes sum to 0 mod 256" {
    try std.testing.expectEqual(@as(u8, 0), checksum(&.{ 1, 2, 3, 250 }));
    try std.testing.expect(checksum(&.{ 1, 2, 3, 0 }) != 0);
}
