const std = @import("std");

const acpi = @import("acpi.zig");
const debug = @import("../sys/debug.zig");

const MADT = extern struct {
    local_controller_addr: u32 align(1),
    flags: u32 align(1),
};

const MADTEntry = extern struct {
    id: u8 align(1),
    length: u8 align(1),
};

const IOApic = extern struct {
    apic_id: u8 align(1),
    reserved: u8 align(1),
    address: u32 align(1),
    gsib: u32 align(1),
};

pub fn init(sdt: *const acpi.SDT) !void {
    const madt_data = sdt.getData();
    const madt = std.mem.bytesAsValue(MADT, madt_data[0..8]);
    if (madt.flags & 0x1 == 0) {
        debug.panic("System must be PC-AT compatible!");
    }

    const madt_entries = madt_data[8..];
    var offset: usize = 0;
    while (madt_entries.len - offset >= 2) {
        const entry: *const MADTEntry = @ptrCast(madt_entries[offset..offset + 2].ptr);
        switch (entry.id) {
            0 => {
                debug.println("[MADT] Found local APIC");
            },
            1 => {
                debug.println("[MADT] Found I/O APIC");
                const io_apic: *const IOApic = @ptrCast(madt_entries[offset + 2..entry.length]);
                _ = io_apic; // TODO
            },
            2 => {
                debug.println("[MADT] Found I/O APIC interrupt source override");
            },
            3 => {
                debug.println("[MADT] Found I/O APIC NMI source");
            },
            4 => {
                debug.println("[MADT] Found local APIC NMIs");
            },
            5 => {
                debug.println("[MADT] Found local APIC address override");
            },
            9 => {
                debug.println("[MADT] Found local x2APIC");
            },
            else => {
                debug.println("[MADT] Found unrecognized entry");
            }
        }

        offset += @max(entry.length, 2);
    }
}
