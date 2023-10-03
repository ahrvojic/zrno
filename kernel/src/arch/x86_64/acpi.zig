//! ACPI tables

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
    addresses: []u32 = undefined,
};

const XSDT = extern struct {
    header: SDTHeader,
    addresses: []u64 = undefined,
};

pub fn is_sdp_valid(comptime T: type, sdp: T) bool {
    const bytes: [@sizeOf(T)]u8 = @bitCast(sdp);
    var sum: usize = 0;

    for (bytes) |byte| {
        sum += byte;
    }

    return sum & 0xff == 0;
}

pub fn is_sdt_valid(header: SDTHeader) bool {
    const bytes: [@sizeOf(SDTHeader)]u8 = @bitCast(header);
    var sum: usize = 0;

    for (bytes) |byte| {
        sum += byte;
    }

    return sum == 0;
}

pub fn init(rsdp_res: *limine.RsdpResponse) !void {
    _ = rsdp_res;
    // TODO
}
