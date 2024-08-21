const logger = std.log.scoped(.madt);

const std = @import("std");

const acpi = @import("acpi.zig");
const debug = @import("../lib/debug.zig");
const panic = @import("../lib/panic.zig").panic;

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

pub var lapics = std.BoundedArray(Lapic, 8).init(0) catch unreachable;
pub var lapic_nmis = std.BoundedArray(LapicNMI, 8).init(0) catch unreachable;
pub var io_apics = std.BoundedArray(IOApic, 8).init(0) catch unreachable;
pub var io_apic_isos = std.BoundedArray(IOApicISO, 8).init(0) catch unreachable;

pub fn init(sdt: *const acpi.SDT) !void {
    const madt_data = sdt.getData();
    const fields = std.mem.bytesAsValue(Fields, madt_data[0..8]);
    if (fields.flags & 0x1 == 0) {
        panic("System must be PC-AT compatible!");
    }

    const madt_entries = madt_data[8..];
    const header_size = @sizeOf(Header);

    var offset: u64 = 0;

    while (madt_entries.len - offset >= header_size) {
        const header_end = offset + header_size;
        const entry: *const Header = @ptrCast(madt_entries[offset..header_end]);
        const data = madt_entries[header_end..(offset + entry.length)];

        switch (entry.id) {
            0 => {
                logger.info("Found local APIC", .{});
                const lapic = std.mem.bytesToValue(Lapic, data[0..@sizeOf(Lapic)]);
                try lapics.append(lapic);
            },
            1 => {
                logger.info("Found I/O APIC", .{});
                const io_apic = std.mem.bytesToValue(IOApic, data[0..@sizeOf(IOApic)]);
                try io_apics.append(io_apic);
            },
            2 => {
                logger.info("Found I/O APIC interrupt source override", .{});
                const io_apic_iso = std.mem.bytesToValue(IOApicISO, data[0..@sizeOf(IOApicISO)]);
                try io_apic_isos.append(io_apic_iso);
            },
            3 => {
                logger.info("Found I/O APIC NMI source", .{});
            },
            4 => {
                logger.info("Found local APIC NMIs", .{});
                const lapic_nmi = std.mem.bytesToValue(LapicNMI, data[0..@sizeOf(LapicNMI)]);
                try lapic_nmis.append(lapic_nmi);
            },
            5 => {
                logger.info("Found local APIC address override", .{});
            },
            9 => {
                logger.info("Found local x2APIC", .{});
            },
            else => {
                logger.info("Found unrecognized entry", .{});
            },
        }

        offset += @max(entry.length, header_size);
    }
}
