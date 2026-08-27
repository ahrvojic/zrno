const std = @import("std");

const apic = @import("apic.zig");
const cpu = @import("../sys/cpu.zig");
const ivt = @import("../sys/ivt.zig");
const port = @import("../sys/port.zig");

const pit_freq_hz = 1193182;
// 1 kHz: one interrupt per millisecond. `sched.sleep` counts these ticks.
pub const timer_freq_hz = 1000;

pub fn init() !void {
    try setFrequency(timer_freq_hz);
    const lapic_id = cpu.bsp().lapicId();
    apic.routeIrq(lapic_id, ivt.vec_pit, 0);
}

pub fn getCount() u16 {
    // Channel 0, latch count value command, mode 0
    port.outb(0x43, 0x00);
    const lo = port.inb(0x40);
    const hi = port.inb(0x40);
    return @as(u16, @intCast(hi)) << 8 | lo;
}

pub fn setCount(count: u16) void {
    // Channel 0, low/high access mode, mode 2
    port.outb(0x43, 0b00110100);
    port.outb(0x40, @intCast(count & 0xff));
    port.outb(0x40, @intCast(count >> 8));
}

pub fn setFrequency(freq: u64) !void {
    if (freq == 0) return error.InvalidFrequency;
    const count = try std.math.divCeil(u64, pit_freq_hz, freq);
    if (count == 0 or count > std.math.maxInt(u16)) return error.InvalidFrequency;
    setCount(@intCast(count));
}
