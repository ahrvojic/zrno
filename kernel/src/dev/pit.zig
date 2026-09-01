const logger = std.log.scoped(.pit);

const std = @import("std");

const apic = @import("apic.zig");
const cpu = @import("../sys/cpu.zig");
const ivt = @import("../sys/ivt.zig");
const port = @import("../sys/port.zig");

pub const osc_freq_hz: u64 = 1_193_182;
const pit_freq_hz = osc_freq_hz;
// 1 kHz: one interrupt per millisecond. `sched.sleep` counts these ticks.
pub const timer_freq_hz = 1000;

const ch2_cmd_latch: u8 = 0x80;
const ch2_cmd_mode0: u8 = 0xb0;
const port_ch2: u16 = 0x42;
const port_cmd: u16 = 0x43;
const port_nmi: u16 = 0x61;
const nmi_ch2_gate: u8 = 1 << 0;
const nmi_speaker: u8 = 1 << 1;
const nmi_ch2_out: u8 = 1 << 5;
const probe_count: u16 = 0xffff;
const probe_spins: u32 = 1_000_000;

var ch2_present = false;
var ch2_probed = false;
var nmi_saved: u8 = 0;

pub fn init() !void {
    try setFrequency(timer_freq_hz);
    const lapic_id = cpu.bsp().lapicId();
    apic.routeIrq(lapic_id, ivt.vec_pit, 0);
    logger.info("{d} Hz irq=0 vec={d}", .{ timer_freq_hz, ivt.vec_pit });
}

/// Channel 2 as a one-shot counter, independent of IRQ 0. Probe, do not
/// trust IAPC_BOOT_ARCH.legacy_devices.
pub fn probeChannel2() bool {
    if (ch2_probed) return ch2_present;
    ch2_probed = true;

    const nmi = port.inb(port_nmi);
    armChannel2(probe_count, nmi);
    const first = readChannel2();
    var i: u32 = 0;
    while (i < probe_spins) : (i += 1) cpu.pause();
    const second = readChannel2();
    port.outb(port_nmi, nmi);

    ch2_present = second < first;
    if (ch2_present) {
        logger.info("ch2 {d} Hz", .{osc_freq_hz});
    } else {
        logger.info("no pit ch2", .{});
    }
    return ch2_present;
}

pub fn hasChannel2() bool {
    return probeChannel2();
}

pub fn startChannel2(count: u16) void {
    if (!probeChannel2()) @panic("pit ch2 missing");
    nmi_saved = port.inb(port_nmi);
    armChannel2(count, nmi_saved);
}

pub fn channel2High() bool {
    return port.inb(port_nmi) & nmi_ch2_out != 0;
}

pub fn readChannel2() u16 {
    port.outb(port_cmd, ch2_cmd_latch);
    const lo = port.inb(port_ch2);
    const hi = port.inb(port_ch2);
    return @as(u16, hi) << 8 | lo;
}

pub fn stopChannel2() void {
    port.outb(port_nmi, nmi_saved);
}

fn armChannel2(count: u16, nmi: u8) void {
    port.outb(port_nmi, (nmi & ~nmi_speaker) | nmi_ch2_gate);
    port.outb(port_cmd, ch2_cmd_mode0);
    port.outb(port_ch2, @truncate(count));
    port.outb(port_ch2, @truncate(count >> 8));
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
