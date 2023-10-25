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

const Lapic = extern struct {
    processor_id: u8 align(1),
    apic_id: u8 align(1),
    flags: u32 align(1),
};

const LapicNMI = extern struct {
    processor_id: u8 align(1),
    flags: u16 align(1),
    lint: u8 align(1),
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

pub var lapics = [_]?Lapic{null} ** 8;
pub var lapic_nmis = [_]?LapicNMI{null} ** 8;
pub var io_apics = [_]?IOApic{null} ** 8;
pub var io_apic_isos = [_]?IOApicISO{null} ** 8;

pub fn init(sdt: *const acpi.SDT) !void {
    const madt_data = sdt.getData();
    const fields = std.mem.bytesAsValue(Fields, madt_data[0..8]);
    if (fields.flags & 0x1 == 0) {
        debug.panic("System must be PC-AT compatible!");
    }

    const madt_entries = madt_data[8..];
    const header_size = @sizeOf(Header);

    var lapic_next: usize = 0;
    var lapic_nmi_next: usize = 0;
    var io_apic_next: usize = 0;
    var io_apic_iso_next: usize = 0;

    var offset: usize = 0;

    while (madt_entries.len - offset >= header_size) {
        const header_end = offset + header_size;
        const entry: *const Header = @ptrCast(madt_entries[offset..header_end]);
        const data = madt_entries[header_end..(offset + entry.length)];

        switch (entry.id) {
            0 => {
                debug.println("[MADT] Found local APIC");
                lapics[lapic_next] = std.mem.bytesToValue(Lapic, data[0..@sizeOf(Lapic)]);
                lapic_next += 1;
            },
            1 => {
                debug.println("[MADT] Found I/O APIC");
                io_apics[io_apic_next] = std.mem.bytesToValue(IOApic, data[0..@sizeOf(IOApic)]);
                io_apic_next += 1;
            },
            2 => {
                debug.println("[MADT] Found I/O APIC interrupt source override");
                io_apic_isos[io_apic_iso_next] = std.mem.bytesToValue(IOApicISO, data[0..@sizeOf(IOApicISO)]);
                io_apic_iso_next += 1;
            },
            3 => {
                debug.println("[MADT] Found I/O APIC NMI source");
            },
            4 => {
                debug.println("[MADT] Found local APIC NMIs");
                lapic_nmis[lapic_nmi_next] = std.mem.bytesToValue(LapicNMI, data[0..@sizeOf(LapicNMI)]);
                lapic_nmi_next += 1;
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
