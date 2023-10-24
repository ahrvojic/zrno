const std = @import("std");

const acpi = @import("acpi.zig");
const debug = @import("../sys/debug.zig");

const Fields = extern struct {
    local_controller_addr: u32 align(1),
    flags: u32 align(1),
};

const Header = extern struct {
    id: u8 align(1),
    length: u8 align(1),
};

const LocalApic = extern struct {
    processor_id: u8 align(1),
    apic_id: u8 align(1),
    flags: u32 align(1),
};

const IOApic = extern struct {
    apic_id: u8 align(1),
    reserved: u8 align(1),
    address: u32 align(1),
    gsib: u32 align(1),
};

const IOApicISO = extern struct {
    bus_source: u8 align(1),
    irq_source: u8 align(1),
    gsi: u32 align(1),
    flags: u16 align(1),
};

const LocalApicNMI = extern struct {
    processor_id: u8 align(1),
    flags: u16 align(1),
    lint: u8 align(1),
};

pub fn init(sdt: *const acpi.SDT) !void {
    const madt_data = sdt.getData();
    const fields = std.mem.bytesAsValue(Fields, madt_data[0..8]);
    if (fields.flags & 0x1 == 0) {
        debug.panic("System must be PC-AT compatible!");
    }

    const madt_entries = madt_data[8..];
    const header_size = @sizeOf(Header);
    var offset: usize = 0;
    while (madt_entries.len - offset >= header_size) {
        const entry: *const Header = @ptrCast(madt_entries[offset..(offset + header_size)]);
        switch (entry.id) {
            0 => {
                debug.println("[MADT] Found local APIC");
                const lapic: *const LocalApic = @ptrCast(madt_entries[(offset + header_size)..entry.length]);
                _ = lapic; // TODO
            },
            1 => {
                debug.println("[MADT] Found I/O APIC");
                const io_apic: *const IOApic = @ptrCast(madt_entries[(offset + header_size)..entry.length]);
                _ = io_apic; // TODO
            },
            2 => {
                debug.println("[MADT] Found I/O APIC interrupt source override");
                //const io_apic_iso: *const IOApicISO = @ptrCast(madt_entries[(offset + header_size)..entry.length]);
                //_ = io_apic_iso; // TODO
            },
            3 => {
                debug.println("[MADT] Found I/O APIC NMI source");
            },
            4 => {
                debug.println("[MADT] Found local APIC NMIs");
                //const lapic_nmi: *const LocalApicNMI = @ptrCast(madt_entries[(offset + header_size)..entry.length]);
                //_ = lapic_nmi; // TODO
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

        offset += @max(entry.length, header_size);
    }
}
