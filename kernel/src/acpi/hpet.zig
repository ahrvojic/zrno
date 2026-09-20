const logger = std.log.scoped(.hpet);

const std = @import("std");

const acpi = @import("acpi.zig");

const Table = extern struct {
    block_id: u32 align(1),
    address: acpi.GenericAddress align(1),
    hpet_number: u8 align(1),
    minimum_tick: u16 align(1),
    page_protection: u8 align(1),
};

comptime {
    std.debug.assert(@sizeOf(Table) == 20);
}

var address_value: ?acpi.GenericAddress = null;
var initialized = false;

pub fn init(sdt: ?*align(1) const acpi.SDT) !void {
    expectUninit();
    defer initialized = true;
    const table_sdt = sdt orelse return;
    address_value = parse(table_sdt) catch |err| {
        logger.warn("HPET table ignored: {s}", .{@errorName(err)});
        return;
    };
}

pub fn present() bool {
    expectInit();
    return address_value != null;
}

pub fn address() acpi.GenericAddress {
    expectInit();
    return address_value orelse @panic("hpet table missing");
}

fn parse(sdt: *align(1) const acpi.SDT) !acpi.GenericAddress {
    const data = sdt.getData();
    if (data.len < @sizeOf(Table)) return error.InvalidHpet;
    const table = std.mem.bytesAsValue(Table, data[0..@sizeOf(Table)]);
    if (table.address.address == 0) return error.InvalidHpet;
    logger.info("table addr=0x{x} num={d} comparators={d} 64bit={} legacy={}", .{
        table.address.address,
        table.hpet_number,
        (table.block_id >> 8) & 0x1f,
        table.block_id & (1 << 13) != 0,
        table.block_id & (1 << 15) != 0,
    });
    return table.address;
}

fn expectInit() void {
    if (!initialized) @panic("hpet table used before init");
}

fn expectUninit() void {
    if (initialized) @panic("hpet table already initialized");
}
