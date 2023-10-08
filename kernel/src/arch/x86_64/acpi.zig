const std = @import("std");
const limine = @import("limine");

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

const RSDT = extern struct {
    header: SDTHeader,
    addresses: *u32,
};

const XSDT = extern struct {
    header: SDTHeader,
    addresses: *u64,
};

const RSDPPtr = *align(1) const RSDP;
const XSDPPtr = *align(1) const XSDP;

const RSDTPtr = *align(1) const RSDT;
const XSDTPtr = *align(1) const XSDT;

pub fn init(rsdp_res: *limine.RsdpResponse) !void {
    switch (rsdp_res.revision) {
        0 => {
            const rsdp: RSDPPtr = @ptrCast(rsdp_res.address);
            const rsdt: RSDTPtr = @ptrFromInt(rsdp.rsdt_addr);
            _ = rsdt;
            // TODO: Parse tables
        },
        2 => {
            const xsdp: XSDPPtr = @ptrCast(rsdp_res.address);
            const xsdt: XSDTPtr = @ptrFromInt(xsdp.xsdt_addr);
            _ = xsdt;
            // TODO: Parse tables
        },
        else => std.debug.panic("Unknown ACPI revision: {}", .{rsdp_res.revision}),
    }
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
