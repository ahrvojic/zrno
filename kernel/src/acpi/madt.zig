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
// Local APIC / x2APIC flags bit 0: processor is enabled and usable.
const lapic_enabled_flag: u32 = 1 << 0;

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

    pub fn enabled(self: @This()) bool {
        return self.flags & lapic_enabled_flag != 0;
    }
};

var lapics_value: BoundedArray(Lapic, max_lapics) = .{};
var lapic_nmis_value: BoundedArray(LapicNMI, max_lapic_nmis) = .{};
var io_apics_value: BoundedArray(IOApic, max_io_apics) = .{};
var io_apic_isos_value: BoundedArray(IOApicISO, max_io_apic_isos) = .{};
var lapic_address_value: usize = 0;
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

pub fn lapicAddress() usize {
    expectInit();
    return lapic_address_value;
}

// Enabled processors only. Prefers an entry whose x2apic flag matches
// the CPU mode (firmware often lists both type 0 and type 9).
pub fn find(apic_id: u32, x2apic: bool) ?Lapic {
    return findEnabled(lapics(), apic_id, x2apic);
}

fn findEnabled(entries: []const Lapic, apic_id: u32, x2apic: bool) ?Lapic {
    var fallback: ?Lapic = null;
    for (entries) |entry| {
        if (!entry.enabled()) continue;
        if (entry.apic_id != apic_id) continue;
        if (entry.x2apic == x2apic) return entry;
        if (fallback == null) fallback = entry;
    }
    return fallback;
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

    var offset: usize = 0;
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
                if (data.len < @sizeOf(Type0Lapic)) return error.InvalidMadt;
                const raw = std.mem.bytesToValue(Type0Lapic, data[0..@sizeOf(Type0Lapic)]);
                try lapics_value.append(.{
                    .processor_id = raw.processor_id,
                    .apic_id = raw.apic_id,
                    .flags = raw.flags,
                    .x2apic = false,
                });
                logger.info("cpu {d} apic_id={d} flags=0x{x}", .{ raw.processor_id, raw.apic_id, raw.flags });
            },
            1 => {
                if (data.len < @sizeOf(IOApic)) return error.InvalidMadt;
                const io_apic = std.mem.bytesToValue(IOApic, data[0..@sizeOf(IOApic)]);
                try io_apics_value.append(io_apic);
                logger.info("ioapic {d} addr=0x{x} gsi_base={d}", .{ io_apic.apic_id, io_apic.address, io_apic.gsi_base });
            },
            2 => {
                if (data.len < @sizeOf(IOApicISO)) return error.InvalidMadt;
                const io_apic_iso = std.mem.bytesToValue(IOApicISO, data[0..@sizeOf(IOApicISO)]);
                try io_apic_isos_value.append(io_apic_iso);
                logger.info("irq {d} -> gsi {d} flags=0x{x}", .{ io_apic_iso.irq_source, io_apic_iso.gsi, io_apic_iso.flags });
            },
            3 => {
                logger.debug("ioapic nmi source", .{});
            },
            4 => {
                if (data.len < @sizeOf(LapicNMI)) return error.InvalidMadt;
                const lapic_nmi = std.mem.bytesToValue(LapicNMI, data[0..@sizeOf(LapicNMI)]);
                try lapic_nmis_value.append(lapic_nmi);
                logger.debug("nmi cpu={d} lint={d}", .{ lapic_nmi.processor_id, lapic_nmi.lint });
            },
            5 => {
                if (data.len < @sizeOf(Type5Override)) return error.InvalidMadt;
                if (have_lapic_override) return error.InvalidMadt;
                const override = std.mem.bytesToValue(Type5Override, data[0..@sizeOf(Type5Override)]);
                logger.info("lapic address override 0x{x}", .{override.address});
                lapic_address_value = @intCast(override.address);
                have_lapic_override = true;
            },
            9 => {
                if (data.len < @sizeOf(Type9X2Apic)) return error.InvalidMadt;
                const raw = std.mem.bytesToValue(Type9X2Apic, data[0..@sizeOf(Type9X2Apic)]);
                try lapics_value.append(.{
                    .processor_id = raw.uid,
                    .apic_id = raw.apic_id,
                    .flags = raw.flags,
                    .x2apic = true,
                });
                logger.info("cpu {d} apic_id={d} flags=0x{x} x2apic", .{ raw.uid, raw.apic_id, raw.flags });
            },
            else => {
                logger.warn("unknown MADT type {d} len={d}", .{ entry.id, entry.length });
            },
        }

        offset += @max(entry.length, header_size);
    }

    logger.info("lapic=0x{x} pcat={} cpus={d} ioapics={d}", .{
        lapic_address_value,
        pcat_compat_value,
        lapics_value.len,
        io_apics_value.len,
    });
    initialized = true;
}

fn expectInit() void {
    if (!initialized) @panic("madt used before init");
}

fn expectUninit() void {
    if (initialized) @panic("madt already initialized");
}

test "findEnabled skips disabled and prefers matching mode" {
    const entries = [_]Lapic{
        .{ .processor_id = 0, .apic_id = 1, .flags = 0, .x2apic = false },
        .{ .processor_id = 1, .apic_id = 0, .flags = 1, .x2apic = false },
        .{ .processor_id = 2, .apic_id = 0, .flags = 1, .x2apic = true },
    };
    const x2 = findEnabled(&entries, 0, true).?;
    try std.testing.expectEqual(@as(u32, 2), x2.processor_id);
    const xapic = findEnabled(&entries, 0, false).?;
    try std.testing.expectEqual(@as(u32, 1), xapic.processor_id);
    try std.testing.expect(findEnabled(&entries, 1, false) == null);
    const only_x2 = [_]Lapic{
        .{ .processor_id = 9, .apic_id = 5, .flags = 1, .x2apic = true },
    };
    const fallback = findEnabled(&only_x2, 5, false).?;
    try std.testing.expectEqual(@as(u32, 9), fallback.processor_id);
}
