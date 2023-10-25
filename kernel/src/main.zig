const std = @import("std");
const limine = @import("limine");

const acpi = @import("acpi/acpi.zig");
const arch = @import("sys/arch.zig");
const cpu = @import("sys/cpu.zig");
const debug = @import("sys/debug.zig");

pub export var hhdm_req: limine.HhdmRequest = .{};
pub export var rsdp_req: limine.RsdpRequest = .{};

export fn _start() callconv(.C) noreturn {
    main() catch {};
    arch.hlt();
}

pub fn main() !void {
    // Get needed info from bootloader
    const hhdm_res = hhdm_req.response.?;
    const rsdp_res = rsdp_req.response.?;

    // Disable interrupts and defer reenable
    arch.cli();
    defer arch.sti();

    debug.println("[Main] Init CPU");
    try cpu.init();

    debug.println("[Main] Init ACPI");
    try acpi.init(hhdm_res, rsdp_res);

    debug.println("[Main] Done.");
}
