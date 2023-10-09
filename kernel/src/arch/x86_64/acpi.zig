const std = @import("std");
const limine = @import("limine");

const debug = @import("debug.zig");

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

const SDT = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,

    fn getData(self: SDTPtr) []const u8 {
        return @as([*]const u8, @ptrCast(self))[0..self.length][@sizeOf(SDT)..];
    }
};

const RSDPPtr = *align(1) const RSDP;
const XSDPPtr = *align(1) const XSDP;

const SDTPtr = *align(1) const SDT;

pub const ACPI = struct {
    rsdt: SDTPtr = undefined,
    use_xsdt: bool = undefined,

    pub fn load(self: *ACPI, rsdp_res: *limine.RsdpResponse) void {
        switch (rsdp_res.revision) {
            0 => {
                const rsdp: RSDPPtr = @ptrCast(rsdp_res.address);
                self.rsdt = @ptrFromInt(rsdp.rsdt_addr);
            },
            2 => {
                const xsdp: XSDPPtr = @ptrCast(rsdp_res.address);
                self.rsdt = @ptrFromInt(xsdp.xsdt_addr);
            },
            else => debug.panic("Unknown ACPI revision!"),
        }

        self.use_xsdt = rsdp_res.revision >= 2;
    }

    pub fn acpi_find_sdt(self: *ACPI, signature: []const u8, index: usize) !SDT {
        // TODO: Fix type conflict
        const entries = if (self.use_xsdt)
            std.mem.bytesAsSlice(u64, self.rsdt.getData())
        else
            std.mem.bytesAsSlice(u32, self.rsdt.getData());

        for (entries) |entry| {
            if (!std.mem.eql(u8, entry.signature, std.mem.sliceTo(signature, 3))) {
                continue;
            }

            if (index > 0) {
                index -= 1;
                continue;
            }

            return @ptrFromInt(entry);
        }

        return error.AcpiSdtNotFound;
    }
};

pub fn init(rsdp_res: *limine.RsdpResponse) !void {
    var instance: ACPI = .{};
    instance.load(rsdp_res);

    // Find and process desired SDTs
    _ = try instance.acpi_find_sdt("FACP", 0);
}

pub fn sum_bytes(comptime T: type, item: T) u8 {
    const bytes: [@sizeOf(T)]u8 = @bitCast(item);
    var sum: u8 = 0;

    for (bytes) |byte| {
        sum +%= byte;
    }

    return sum;
}

test "byte sums" {
    const arr1: [4]u8 = .{1, 1, 1, 1};
    try std.testing.expect(sum_bytes([4]u8, arr1) == 4);

    const arr2: [2]u8 = .{255, 1};
    try std.testing.expect(sum_bytes([2]u8, arr2) == 0);

    const sdt: SDT = .{
        .signature = "APIC".*,
        .length = 0xbc,
        .revision = 0x02,
        .checksum = 0x41,
        .oem_id = "APPLE ".*,
        .oem_table_id = "Apple00 ".*,
        .oem_revision = 0x01,
        .creator_id = std.mem.bytesAsSlice(u32, "Loki")[0],
        .creator_revision = 0x5f,
    };
    std.debug.print("{any}\n", .{sdt});
    try std.testing.expect(sum_bytes(SDT, sdt) == 0x0f);
}
