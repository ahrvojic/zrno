const std = @import("std");
const limine = @import("limine");

const acpi = @import("acpi/acpi.zig");

const apic = @import("dev/apic.zig");
const ps2 = @import("dev/ps2.zig");

const cpu = @import("sys/cpu.zig");
const debug = @import("sys/debug.zig");

pub export var hhdm_req: limine.HhdmRequest = .{};
pub export var rsdp_req: limine.RsdpRequest = .{};

export fn _start() callconv(.C) noreturn {
    main() catch {};
    cpu.halt();
}

pub fn main() !void {
    // Get needed info from bootloader
    const hhdm_res = hhdm_req.response.?;
    const rsdp_res = rsdp_req.response.?;

    cpu.interruptsDisable();
    defer cpu.interruptsEnable();

    debug.println("[Main] Init CPU");
    try cpu.init(hhdm_res);

    debug.println("[Main] Init ACPI");
    try acpi.init(hhdm_res, rsdp_res);

    debug.println("[Main] Init APIC");
    try apic.init(hhdm_res);

    debug.println("[Main] Init PS/2 keyboard");
    try ps2.init();

    debug.println("[Main] Done.");
}
