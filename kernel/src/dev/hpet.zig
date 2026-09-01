const logger = std.log.scoped(.hpet);

const std = @import("std");

const hpet_table = @import("../acpi/hpet.zig");
const acpi = @import("../acpi/acpi.zig");
const cpu = @import("../sys/cpu.zig");
const pmm = @import("../mm/pmm.zig");
const virt = @import("../lib/virt.zig");
const vmm = @import("../mm/vmm.zig");

const cap_period_shift: u6 = 32;
const cap_count_size: u64 = 1 << 13;
const cfg_enable: u64 = 1 << 0;
const cfg_legacy: u64 = 1 << 1;

const reg_cap: u32 = 0x00;
const reg_config: u32 = 0x10;
const reg_counter: u32 = 0xf0;

const tick_spins: u32 = 1_000_000;
// General Capabilities: period in femtoseconds, max 100 ns (spec).
const fs_per_s: u64 = 1_000_000_000_000_000;
const max_period_fs: u32 = 100_000_000;

var mmio_base: usize = 0;
var freq_hz_value: u64 = 0;
var counter_64 = false;
var initialized = false;

pub fn init() void {
    expectUninit();
    defer initialized = true;

    if (!hpet_table.present()) {
        logger.info("no HPET table", .{});
        return;
    }

    const gas = hpet_table.info().address;
    if (gas.address_space != acpi.gas_space_memory or gas.address == 0 or gas.bit_offset != 0) {
        logger.warn("HPET GAS unsupported space={d} addr=0x{x}", .{ gas.address_space, gas.address });
        return;
    }

    const phys: usize = @intCast(gas.address);
    vmm.kernel_vmm.mapMmio(phys, pmm.page_size) catch |err| {
        logger.warn("HPET MMIO map failed: {s}", .{@errorName(err)});
        return;
    };
    mmio_base = virt.toHH(usize, phys);

    const cap = read64(reg_cap);
    const period_fs: u32 = @truncate(cap >> cap_period_shift);
    const freq = freqFromPeriodFs(period_fs) orelse {
        logger.warn("HPET period {d} fs is unusable", .{period_fs});
        mmio_base = 0;
        return;
    };

    counter_64 = cap & cap_count_size != 0;
    // Disable first: spec forbids changing LEG_RT_CNF while ENABLE_CNF is 1.
    const cfg = read32(reg_config);
    write32(reg_config, cfg & ~@as(u32, @truncate(cfg_enable)));
    // Do not enable legacy replacement: it steals ISA IRQ 0/8 from the PIT/RTC.
    write32(reg_config, (cfg & ~@as(u32, @truncate(cfg_legacy))) | @as(u32, @truncate(cfg_enable)));

    const a = readCounter();
    pauseLoop(tick_spins);
    const b = readCounter();
    if (b == a) {
        logger.warn("HPET counter is not ticking", .{});
        write32(reg_config, read32(reg_config) & ~@as(u32, @truncate(cfg_enable)));
        mmio_base = 0;
        return;
    }

    freq_hz_value = freq;
    logger.info("{d} Hz period={d} fs 64bit={} addr=0x{x}", .{
        freq_hz_value,
        period_fs,
        counter_64,
        phys,
    });
}

pub fn present() bool {
    expectInit();
    return mmio_base != 0;
}

pub fn freqHz() u64 {
    expectPresent();
    return freq_hz_value;
}

pub fn read() u64 {
    expectPresent();
    return readCounter();
}

pub fn delta(now: u64, then: u64) u64 {
    expectPresent();
    if (counter_64) return now -% then;
    return (now -% then) & 0xffff_ffff;
}

fn readCounter() u64 {
    if (!counter_64) return read32(reg_counter);
    while (true) {
        const hi1 = read32(reg_counter + 4);
        const lo = read32(reg_counter);
        const hi2 = read32(reg_counter + 4);
        if (hi1 == hi2) return (@as(u64, hi1) << 32) | lo;
    }
}

fn read32(offset: u32) u32 {
    return @as(*align(1) volatile u32, @ptrFromInt(mmio_base + offset)).*;
}

fn read64(offset: u32) u64 {
    const lo = read32(offset);
    const hi = read32(offset + 4);
    return (@as(u64, hi) << 32) | lo;
}

fn write32(offset: u32, value: u32) void {
    @as(*align(1) volatile u32, @ptrFromInt(mmio_base + offset)).* = value;
}

fn pauseLoop(n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) cpu.pause();
}

fn expectPresent() void {
    if (!present()) @panic("hpet used when absent");
}

fn expectInit() void {
    if (!initialized) @panic("hpet used before init");
}

fn expectUninit() void {
    if (initialized) @panic("hpet already initialized");
}

fn freqFromPeriodFs(period_fs: u32) ?u64 {
    if (period_fs == 0 or period_fs > max_period_fs) return null;
    return fs_per_s / period_fs;
}

test "freqFromPeriodFs rejects 0 and periods above 100 ns" {
    try std.testing.expect(freqFromPeriodFs(0) == null);
    try std.testing.expect(freqFromPeriodFs(max_period_fs + 1) == null);
}

test "freqFromPeriodFs converts femtoseconds to hertz" {
    try std.testing.expectEqual(@as(u64, 10_000_000), freqFromPeriodFs(100_000_000).?);
    try std.testing.expectEqual(@as(u64, 20_000_000), freqFromPeriodFs(50_000_000).?);
    // 14.31818 MHz crystal; integer division truncates.
    try std.testing.expectEqual(@as(u64, 14_318_179), freqFromPeriodFs(69_841_279).?);
}