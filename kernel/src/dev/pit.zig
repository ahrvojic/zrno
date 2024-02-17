const std = @import("std");

const apic = @import("apic.zig");
const cpu = @import("../sys/cpu.zig");
const debug = @import("../sys/debug.zig");
const interrupts = @import("../sys/interrupts.zig");
const port = @import("../sys/port.zig");

const pit_freq_hz = 1193182;
const timer_freq_ms = 1000;

pub fn init() !void {
    try setFrequency(timer_freq_ms);
    const lapic_id = cpu.get().lapicId();
    apic.get().routeIrq(lapic_id, interrupts.vec_pit, 0);
}

pub fn handleInterrupt() void {
    // TODO
}

pub fn setFrequency(freq: u64) !void {
    const count = try std.math.divCeil(u64, pit_freq_hz, freq);
    setPeriodic(@as(u16, @intCast(count)));
}

fn setPeriodic(count: u16) void {
    // Channel 0, low/high access mode, mode 2 periodic
    port.outb(0x43, 0b00110100);
    port.outb(0x40, @as(u8, @intCast(count & 0xff)));
    port.outb(0x40, @as(u8, @intCast(count >> 8)));
}
