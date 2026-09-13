const logger = std.log.scoped(.reboot);

const std = @import("std");

const cpu = @import("cpu.zig");
const dsdt = @import("../acpi/dsdt.zig");
const fadt = @import("../acpi/fadt.zig");
const port = @import("port.zig");

const ps2_cmd_port: u16 = 0x64;
const status_in_full: u8 = 1 << 1;
const cmd_pulse_reset: u8 = 0xfe;
const io_spins: u32 = 0xfffff;
const reset_spins: u32 = 100_000;
const slp_en: u16 = 1 << 13;

pub fn perform() noreturn {
    cpu.interruptsOff();
    logger.info("reboot", .{});
    tryAcpiReset();
    pulseKeyboardReset();
    cpu.halt();
}

pub fn poweroff() noreturn {
    cpu.interruptsOff();
    logger.info("poweroff", .{});
    tryAcpiSleep();
    logger.warn("S5 did not power off", .{});
    cpu.halt();
}

fn tryAcpiReset() void {
    const spec = fadt.resetReg() orelse return;
    port.outb(spec.address, spec.value);
    for (0..reset_spins) |_| cpu.pause();
}

fn tryAcpiSleep() void {
    const a = fadt.pm1a();
    if (a.cnt == 0) {
        logger.warn("no PM1a_CNT", .{});
        return;
    }
    const s5 = dsdt.s5() orelse blk: {
        logger.warn("no \\_S5_; try SLP_TYP 0", .{});
        break :blk dsdt.S5{ .slp_typa = 0, .slp_typb = 0 };
    };
    writeSleep(a, fadt.pm1b(), s5.slp_typa, s5.slp_typb);
}

fn writeSleep(a: fadt.Pm1, b: fadt.Pm1, typ_a: u3, typ_b: u3) void {
    if (a.evt != 0) port.outw(a.evt, 0xffff);
    if (b.evt != 0) port.outw(b.evt, 0xffff);
    writePm1(a.cnt, typ_a);
    if (b.cnt != 0) writePm1(b.cnt, typ_b);
    for (0..reset_spins) |_| cpu.pause();
}

fn writePm1(pm1: u16, slp_typ: u3) void {
    const mask: u16 = 0b111 << 10 | slp_en;
    const typ: u16 = @as(u16, slp_typ) << 10;
    port.outw(pm1, (port.inw(pm1) & ~mask) | typ | slp_en);
}

// 8042 command 0xFE pulses the CPU reset line. Independent of ps2.init.
fn pulseKeyboardReset() void {
    for (0..io_spins) |_| {
        if (port.inb(ps2_cmd_port) & status_in_full == 0) break;
    }
    port.outb(ps2_cmd_port, cmd_pulse_reset);
}
