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

const SDTHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
};

const SDT = extern struct {
    header: SDTHeader,
    data: [*]u8,
};

const RSDPPtr = *align(1) const RSDP;
const XSDPPtr = *align(1) const XSDP;

const SDTPtr = *align(1) const SDT;

pub const ACPI = struct {
    rsdt: SDTPtr = undefined,

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
    }

    pub fn acpi_find_sdt(self: *ACPI, signature: [4]u8) !SDT {
        _ = self;
        _ = signature;
        // TODO
    }
};

pub fn init(rsdp_res: *limine.RsdpResponse) !void {
    var instance: ACPI = .{};
    instance.load(rsdp_res);
    // TODO: Process desired tables
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

    const header: SDTHeader = .{
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
    std.debug.print("{any}\n", .{header});
    try std.testing.expect(sum_bytes(SDTHeader, header) == 0x0f);
}
