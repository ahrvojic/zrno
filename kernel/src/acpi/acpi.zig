const std = @import("std");
const limine = @import("limine");

const debug = @import("../sys/debug.zig");
const fadt = @import("fadt.zig");
const madt = @import("madt.zig");

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

    pub fn getData(self: *const SDT) []const u8 {
        return @as([*]const u8, @ptrCast(self))[0..self.length][@sizeOf(SDT)..];
    }
};

const ACPI = struct {
    rsdt: *const SDT = undefined,

    hhdm_offset: u64 = undefined,
    use_xsdt: bool = undefined,

    pub fn load(self: *ACPI, hhdm_res: *limine.HhdmResponse, rsdp_res: *limine.RsdpResponse) void {
        self.hhdm_offset = hhdm_res.offset;
        self.use_xsdt = rsdp_res.revision >= 2;

        debug.println("[ACPI] Load RSDT");
        switch (rsdp_res.revision) {
            0 => {
                debug.println("[ACPI] Revision 0");
                const rsdp: *align(1) const RSDP = @ptrCast(rsdp_res.address);
                self.rsdt = @ptrFromInt(rsdp.rsdt_addr + self.hhdm_offset);
            },
            2 => {
                debug.println("[ACPI] Revision 2");
                const xsdp: *align(1) const XSDP = @ptrCast(rsdp_res.address);
                self.rsdt = @ptrFromInt(xsdp.xsdt_addr + self.hhdm_offset);
            },
            else => debug.panic("Unknown ACPI revision!"),
        }
    }

    pub fn findSDT(self: *const ACPI, signature: []const u8, index: usize) !*const SDT {
        return if (self.use_xsdt) self.findSDTAt(u64, signature, index) else self.findSDTAt(u32, signature, index);
    }

    fn findSDTAt(self: *const ACPI, comptime T: type, signature: []const u8, index: usize) !*const SDT {
        const entries = std.mem.bytesAsSlice(T, self.rsdt.getData());
        var index_curr = index;

        for (entries) |entry| {
            const sdt: *const SDT = @ptrFromInt(entry + self.hhdm_offset);

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
    var acpi: ACPI = .{};
    acpi.load(hhdm_res, rsdp_res);

    debug.println("[ACPI] Load FADT");
    const fadt_sdt = try acpi.findSDT("FACP", 0);
    try fadt.init(fadt_sdt);

    debug.println("[ACPI] Load MADT");
    const madt_sdt = try acpi.findSDT("APIC", 0);
    try madt.init(madt_sdt);
}
