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

pub const Info = struct {
    address: acpi.GenericAddress,
    hpet_number: u8,
    comparator_count: u8,
    counter_size_64: bool,
    legacy_irq: bool,
    minimum_tick: u16,
};

var info_value: ?Info = null;
var initialized = false;

pub fn init(sdt: ?*align(1) const acpi.SDT) !void {
    expectUninit();
    defer initialized = true;
    const table_sdt = sdt orelse return;
    info_value = parse(table_sdt) catch |err| {
        logger.warn("HPET table ignored: {s}", .{@errorName(err)});
        return;
    };
    const table = info_value.?;
    logger.info("table addr=0x{x} num={d} comparators={d} 64bit={} legacy={}", .{
        table.address.address,
        table.hpet_number,
        table.comparator_count,
        table.counter_size_64,
        table.legacy_irq,
    });
}

pub fn present() bool {
    expectInit();
    return info_value != null;
}

pub fn info() Info {
    expectInit();
    return info_value orelse @panic("hpet table missing");
}

fn parse(sdt: *align(1) const acpi.SDT) !Info {
    const data = sdt.getData();
    if (data.len < @sizeOf(Table)) return error.InvalidHpet;
    const table = std.mem.bytesAsValue(Table, data[0..@sizeOf(Table)]);
    if (table.address.address == 0) return error.InvalidHpet;
    return .{
        .address = table.address,
        .hpet_number = table.hpet_number,
        .comparator_count = @truncate((table.block_id >> 8) & 0x1f),
        .counter_size_64 = table.block_id & (1 << 13) != 0,
        .legacy_irq = table.block_id & (1 << 15) != 0,
        .minimum_tick = table.minimum_tick,
    };
}

fn expectInit() void {
    if (!initialized) @panic("hpet table used before init");
}

fn expectUninit() void {
    if (initialized) @panic("hpet table already initialized");
}