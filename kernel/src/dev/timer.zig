const logger = std.log.scoped(.timer);

const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const hpet = @import("hpet.zig");
const panic = @import("../lib/panic.zig").panic;
const pit = @import("pit.zig");
const pmtimer = @import("pmtimer.zig");
const sched = @import("../sched/sched.zig");

const cal_ms: u64 = 10;
const cal_spin_limit: u32 = 1_000_000_000;
const min_lapic_delta: u32 = 100;

var initialized = false;

pub fn init() !void {
    expectUninit();
    defer initialized = true;

    try hpet.init();
    try pmtimer.init();
    _ = pit.probeChannel2();

    const bsp = cpu.bsp();
    if (hpet.present()) {
        if (calibrateHpet(bsp)) |icr| {
            bsp.lapicTimerPeriodic(icr);
            logger.info("{d} Hz lapic via hpet icr={d}", .{ sched.tick_hz, icr });
            return;
        }
        logger.warn("HPET calibration failed", .{});
    }
    if (pmtimer.present()) {
        if (calibratePm(bsp)) |icr| {
            bsp.lapicTimerPeriodic(icr);
            logger.info("{d} Hz lapic via pmtimer icr={d}", .{ sched.tick_hz, icr });
            return;
        }
        logger.warn("PM timer calibration failed", .{});
    }
    if (pit.hasChannel2()) {
        if (calibratePit(bsp)) |icr| {
            bsp.lapicTimerPeriodic(icr);
            logger.info("{d} Hz lapic via pit ch2 icr={d}", .{ sched.tick_hz, icr });
            return;
        }
        logger.warn("PIT ch2 calibration failed", .{});
    }

    panic("No usable APIC timer calibration source (HPET, ACPI PM timer, PIT channel 2)");
}

fn calibrateHpet(bsp: *cpu.CPU) ?u32 {
    return calibrateFreeRunning(bsp, hpet.freqHz(), hpet.read, hpet.delta);
}

fn calibratePm(bsp: *cpu.CPU) ?u32 {
    return calibrateFreeRunning(bsp, pmtimer.freq_hz, pmRead, pmDelta);
}

fn pmRead() u64 {
    return pmtimer.read();
}

fn pmDelta(now: u64, then: u64) u64 {
    return pmtimer.delta(@truncate(now), @truncate(then));
}

fn calibrateFreeRunning(
    bsp: *cpu.CPU,
    ref_hz: u64,
    comptime read_ref: fn () u64,
    comptime delta_ref: fn (u64, u64) u64,
) ?u32 {
    const want = refTicksForCal(ref_hz) orelse return null;
    bsp.lapicTimerArm(0xffff_ffff);
    const r0 = read_ref();
    const c0 = bsp.lapicTimerCurrent();
    var spins: u32 = 0;
    while (delta_ref(read_ref(), r0) < want) {
        cpu.pause();
        spins += 1;
        if (spins >= cal_spin_limit or bsp.lapicTimerCurrent() == 0) return null;
    }
    const c1 = bsp.lapicTimerCurrent();
    const r1 = read_ref();
    if (c1 >= c0) return null;
    return initialCount(c0 - c1, delta_ref(r1, r0), ref_hz);
}

fn calibratePit(bsp: *cpu.CPU) ?u32 {
    const count64 = refTicksForCal(pit.osc_freq_hz) orelse return null;
    if (count64 == 0 or count64 > std.math.maxInt(u16)) return null;
    const count: u16 = @intCast(count64);

    bsp.lapicTimerArm(0xffff_ffff);
    pit.startChannel2(count);
    const c0 = bsp.lapicTimerCurrent();
    var spins: u32 = 0;
    while (!pit.channel2High()) {
        cpu.pause();
        spins += 1;
        if (spins >= cal_spin_limit or bsp.lapicTimerCurrent() == 0) {
            pit.stopChannel2();
            return null;
        }
    }
    const c1 = bsp.lapicTimerCurrent();
    pit.stopChannel2();
    if (c1 >= c0) return null;
    return initialCount(c0 - c1, count, pit.osc_freq_hz);
}

fn refTicksForCal(ref_hz: u64) ?u64 {
    const ticks = std.math.mul(u64, ref_hz, cal_ms) catch return null;
    const want = ticks / 1000;
    if (want == 0) return null;
    return want;
}

fn initialCount(lapic_delta: u32, ref_delta: u64, ref_hz: u64) ?u32 {
    if (lapic_delta < min_lapic_delta or ref_delta == 0 or ref_hz == 0) return null;
    const num: u128 = @as(u128, lapic_delta) * ref_hz;
    const den: u128 = @as(u128, ref_delta) * sched.tick_hz;
    const count = num / den;
    if (count == 0 or count > std.math.maxInt(u32)) return null;
    return @intCast(count);
}

fn expectUninit() void {
    if (initialized) @panic("timer already initialized");
}

test "initialCount converts lapic and ref deltas to a 1 ms ICR" {
    try std.testing.expectEqual(@as(u32, 100_000), initialCount(1_000_000, 1_000_000, 100_000_000).?);
    try std.testing.expectEqual(@as(u32, 1_193), initialCount(11_931, 11_931, 1_193_182).?);
    try std.testing.expect(initialCount(0, 1_000_000, 100_000_000) == null);
    try std.testing.expect(initialCount(50, 1_000_000, 100_000_000) == null);
}