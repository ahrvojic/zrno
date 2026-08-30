const logger = std.log.scoped(.madt);

const std = @import("std");

const acpi = @import("acpi.zig");
const BoundedArray = @import("../lib/bounded_array.zig").BoundedArray;

const Fields = extern struct {
    local_controller_addr: u32 align(1),
    flags: u32 align(1),
};

const Header = extern struct {
    id: u8 align(1),
    length: u8 align(1),
};

const Type0Lapic = extern struct {
    processor_id: u8 align(1),
    apic_id: u8 align(1),
    flags: u32 align(1),
};

const Type9X2Apic = extern struct {
    reserved: u16 align(1),
    apic_id: u32 align(1),
    flags: u32 align(1),
    uid: u32 align(1),
};

const Type5Override = extern struct {
    reserved: u16 align(1),
    address: u64 align(1),
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
    gsi_base: u32 align(1),
};

const IOApicISO = extern struct {
    bus_source: u8 align(1),
    irq_source: u8 align(1),
    gsi: u32 align(1),
    flags: u16 align(1),
};

// MADT flags bit 0: dual 8259 PICs are present (PC-AT compatible).
const pcat_compat_flag: u32 = 1 << 0;

// Processor table cap: large enough that MADT parse survives a
// typical desktop/VM, small enough to stay a static array.
pub const max_lapics = 64;
// Each CPU has two LINT pins that can be NMI sources.
pub const max_lapic_nmis = max_lapics * 2;
pub const max_io_apics = 8;
// One override per ISA IRQ (0-15).
pub const max_io_apic_isos = 16;

pub const Lapic = struct {
    processor_id: u32,
    apic_id: u32,
    flags: u32,
    x2apic: bool,
};

var lapics_value: BoundedArray(Lapic, max_lapics) = .{};
var lapic_nmis_value: BoundedArray(LapicNMI, max_lapic_nmis) = .{};
var io_apics_value: BoundedArray(IOApic, max_io_apics) = .{};
var io_apic_isos_value: BoundedArray(IOApicISO, max_io_apic_isos) = .{};
var lapic_address_value: u64 = 0;
var pcat_compat_value: bool = false;
var initialized = false;

pub fn lapics() []const Lapic {
    expectInit();
    return lapics_value.constSlice();
}

pub fn lapicNmis() []const LapicNMI {
    expectInit();
    return lapic_nmis_value.constSlice();
}

pub fn ioApics() []const IOApic {
    expectInit();
    return io_apics_value.constSlice();
}

pub fn ioApicIsos() []const IOApicISO {
    expectInit();
    return io_apic_isos_value.constSlice();
}

pub fn pcatCompat() bool {
    expectInit();
    return pcat_compat_value;
}

pub fn lapicAddress() u64 {
    expectInit();
    return lapic_address_value;
}

pub fn init(sdt: *align(1) const acpi.SDT) !void {
    expectUninit();

    const madt_data = sdt.getData();
    if (madt_data.len < @sizeOf(Fields)) return error.InvalidMadt;
    const fields = std.mem.bytesAsValue(Fields, madt_data[0..@sizeOf(Fields)]);
    lapic_address_value = fields.local_controller_addr;
    pcat_compat_value = fields.flags & pcat_compat_flag != 0;

    const madt_entries = madt_data[@sizeOf(Fields)..];
    const header_size = @sizeOf(Header);

    var offset: u64 = 0;
    var have_lapic_override = false;

    while (madt_entries.len - offset >= header_size) {
        const header_end = offset + header_size;
        const entry: *const Header = @ptrCast(madt_entries[offset..header_end]);
        if (entry.length < header_size or entry.length > madt_entries.len - offset) {
            logger.err("Truncated MADT entry at offset {d}", .{offset});
            return error.InvalidMadt;
        }
        const data = madt_entries[header_end..(offset + entry.length)];

        switch (entry.id) {
            0 => {
                logger.info("Found local APIC", .{});
                if (data.len < @sizeOf(Type0Lapic)) return error.InvalidMadt;
                const raw = std.mem.bytesToValue(Type0Lapic, data[0..@sizeOf(Type0Lapic)]);
                try lapics_value.append(.{
                    .processor_id = raw.processor_id,
                    .apic_id = raw.apic_id,
                    .flags = raw.flags,
                    .x2apic = false,
                });
            },
            1 => {
                logger.info("Found I/O APIC", .{});
                if (data.len < @sizeOf(IOApic)) return error.InvalidMadt;
                const io_apic = std.mem.bytesToValue(IOApic, data[0..@sizeOf(IOApic)]);
                try io_apics_value.append(io_apic);
            },
            2 => {
                logger.info("Found I/O APIC interrupt source override", .{});
                if (data.len < @sizeOf(IOApicISO)) return error.InvalidMadt;
                const io_apic_iso = std.mem.bytesToValue(IOApicISO, data[0..@sizeOf(IOApicISO)]);
                try io_apic_isos_value.append(io_apic_iso);
            },
            3 => {
                logger.info("Found I/O APIC NMI source", .{});
            },
            4 => {
                logger.info("Found local APIC NMIs", .{});
                if (data.len < @sizeOf(LapicNMI)) return error.InvalidMadt;
                const lapic_nmi = std.mem.bytesToValue(LapicNMI, data[0..@sizeOf(LapicNMI)]);
                try lapic_nmis_value.append(lapic_nmi);
            },
            5 => {
                if (data.len < @sizeOf(Type5Override)) return error.InvalidMadt;
                if (have_lapic_override) return error.InvalidMadt;
                const override = std.mem.bytesToValue(Type5Override, data[0..@sizeOf(Type5Override)]);
                logger.info("Found local APIC address override {x}", .{override.address});
                lapic_address_value = override.address;
                have_lapic_override = true;
            },
            9 => {
                logger.info("Found local x2APIC", .{});
                if (data.len < @sizeOf(Type9X2Apic)) return error.InvalidMadt;
                const raw = std.mem.bytesToValue(Type9X2Apic, data[0..@sizeOf(Type9X2Apic)]);
                try lapics_value.append(.{
                    .processor_id = raw.uid,
                    .apic_id = raw.apic_id,
                    .flags = raw.flags,
                    .x2apic = true,
                });
            },
            else => {
                logger.info("Found unrecognized entry", .{});
            },
        }

        offset += @max(entry.length, header_size);
    }

    logger.info("PCAT_COMPAT {} local APIC {x} processors {d}", .{
        pcat_compat_value,
        lapic_address_value,
        lapics_value.len,
    });
    initialized = true;
}

fn expectInit() void {
    if (!initialized) @panic("madt used before init");
}

fn expectUninit() void {
    if (initialized) @panic("madt already initialized");
}
