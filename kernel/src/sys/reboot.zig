const logger = std.log.scoped(.reboot);

const std = @import("std");

const cpu = @import("cpu.zig");
const fadt = @import("../acpi/fadt.zig");
const port = @import("port.zig");

const ps2_cmd_port: u16 = 0x64;
const status_in_full: u8 = 1 << 1;
const cmd_pulse_reset: u8 = 0xfe;
const io_spins: u32 = 0xfffff;
const reset_spins: u32 = 100_000;

pub fn perform() noreturn {
    cpu.interruptsOff();
    logger.info("reboot", .{});
    tryAcpiReset();
    pulseKeyboardReset();
    cpu.halt();
}

fn tryAcpiReset() void {
    const spec = fadt.resetReg() orelse return;
    port.outb(spec.address, spec.value);
    for (0..reset_spins) |_| cpu.pause();
}

// 8042 command 0xFE pulses the CPU reset line. Independent of ps2.init.
fn pulseKeyboardReset() void {
    for (0..io_spins) |_| {
        if (port.inb(ps2_cmd_port) & status_in_full == 0) break;
    }
    port.outb(ps2_cmd_port, cmd_pulse_reset);
}
