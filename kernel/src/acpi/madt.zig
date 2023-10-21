const std = @import("std");

const acpi = @import("acpi.zig");
const debug = @import("../sys/debug.zig");

const MADTFields = extern struct {
    local_controller_addr: u32 align(1),
    flags: u32 align(1),
};

pub fn init(sdt: *const acpi.SDT) !void {
    const madt_data = sdt.getData();
    const madt_fields = std.mem.bytesAsValue(MADTFields, madt_data[0..8]);
    _ = madt_fields; // TODO
}
