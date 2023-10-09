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
    data: [*]const u8,
};

const RSDPPtr = *align(1) const RSDP;
const XSDPPtr = *align(1) const XSDP;

const SDTPtr = *align(1) const SDT;

pub const ACPI = struct {
    rsdt: SDTPtr = undefined,

    hhdm_offset: u64 = undefined,
    use_xsdt: bool = undefined,

    pub fn load(self: *ACPI, hhdm_res: *limine.HhdmResponse, rsdp_res: *limine.RsdpResponse) void {
        self.hhdm_offset = hhdm_res.offset;
        self.use_xsdt = rsdp_res.revision >= 2;

        debug.println("[ACPI] Fetching RSDT");
        switch (rsdp_res.revision) {
            0 => {
                debug.println("[ACPI] Revision 0");
                const rsdp: RSDPPtr = @ptrCast(rsdp_res.address);
                self.rsdt = @ptrFromInt(rsdp.rsdt_addr + self.hhdm_offset);
            },
            2 => {
                debug.println("[ACPI] Revision 2");
                const xsdp: XSDPPtr = @ptrCast(rsdp_res.address);
                self.rsdt = @ptrFromInt(xsdp.xsdt_addr + self.hhdm_offset);
            },
            else => debug.panic("Unknown ACPI revision!"),
        }
    }

    pub fn findSDT(self: *ACPI, signature: []const u8, index: usize) !SDTPtr {
        return if (self.use_xsdt) self.findSDTTyped(u64, signature, index) else self.findSDTTyped(u32, signature, index);
    }

    fn findSDTTyped(self: *ACPI, comptime T: type, signature: []const u8, index: usize) !SDTPtr {
        const entries = std.mem.bytesAsSlice(T, self.rsdt.data[0..self.rsdt.length]);
        var index_curr = index;

        for (entries) |entry| {
            const sdt: SDTPtr = @ptrFromInt(entry + self.hhdm_offset);
            debug.println(&sdt.signature);
            if (!std.mem.eql(u8, &sdt.signature, std.mem.sliceTo(signature, 3))) {
                continue;
            }

            if (index_curr > 0) {
                index_curr -= 1;
                continue;
            }

            return sdt;
        }

        debug.print("[ACPI] SDT not found: ");
        debug.println(signature);
        return error.AcpiSdtNotFound;
    }
};

pub fn init(hhdm_res: *limine.HhdmResponse, rsdp_res: *limine.RsdpResponse) !void {
    var instance: ACPI = .{};
    instance.load(hhdm_res, rsdp_res);

    // Find and process desired SDTs
    debug.println("[ACPI] Finding FACP");
    _ = try instance.findSDT("FACP", 0);
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
    const arr1: [4]u8 = .{ 1, 1, 1, 1 };
    try std.testing.expect(sum_bytes([4]u8, arr1) == 4);

    const arr2: [2]u8 = .{ 255, 1 };
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
