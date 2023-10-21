const std = @import("std");

const acpi = @import("acpi.zig");
const debug = @import("../sys/debug.zig");

const MADTFields = extern struct {
    local_controller_addr: u32 align(1),
    flags: u32 align(1),
};

const MADTHeader = extern struct {
    id: u8 align(1),
    length: u8 align(1),
};

pub fn init(sdt: *const acpi.SDT) !void {
    const madt_data = sdt.getData();
    const madt_fields = std.mem.bytesAsValue(MADTFields, madt_data[0..8]);
    if (madt_fields.flags & 0x1 == 0) {
        debug.panic("System must be PC-AT compatible!");
    }

    const madt_entries = madt_data[8..];
    _ = madt_entries; // TODO
}
