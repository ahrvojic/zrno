const std = @import("std");
const limine = @import("limine");

const acpi = @import("acpi/acpi.zig");
const apic = @import("dev/apic.zig");
const fb = @import("dev/fb.zig");
const pit = @import("dev/pit.zig");
const ps2 = @import("dev/ps2.zig");
const tty = @import("dev/tty.zig");
const pmm = @import("mm/pmm.zig");
const cpu = @import("sys/cpu.zig");
const debug = @import("sys/debug.zig");

pub export var base_revision: limine.BaseRevision = .{ .revision = 1 };

pub export var bootloader_req: limine.BootloaderInfoRequest = .{};
pub export var fb_req: limine.FramebufferRequest = .{};
pub export var hhdm_req: limine.HhdmRequest = .{};
pub export var mm_req: limine.MemoryMapRequest = .{};
pub export var rsdp_req: limine.RsdpRequest = .{};

export fn _start() callconv(.C) noreturn {
    main() catch {};
    cpu.halt();
}

pub fn main() !void {
    cpu.interruptsDisable();
    defer cpu.interruptsEnable();

    if (!base_revision.is_supported()) {
        debug.panic("Limine base revision not supported!");
    }

    // Get needed info from bootloader
    const bootloader_res = bootloader_req.response.?;
    const fb_res = fb_req.response.?;
    const hhdm_res = hhdm_req.response.?;
    const mm_res = mm_req.response.?;
    const rsdp_res = rsdp_req.response.?;

    const bootloader_name = std.mem.span(bootloader_res.name);
    const bootloader_version = std.mem.span(bootloader_res.version);

    debug.print(bootloader_name);
    debug.print(" ");
    debug.println(bootloader_version);

    debug.println("[Main] Init CPU");
    try cpu.init(hhdm_res);

    debug.println("[Main] Init PMM");
    try pmm.init(hhdm_res, mm_res);

    debug.println("[Main] Init ACPI");
    try acpi.init(hhdm_res, rsdp_res);

    debug.println("[Main] Init APIC");
    try apic.init(hhdm_res);

    debug.println("[Main] Init PIT");
    try pit.init();

    debug.println("[Main] Init PS/2 keyboard");
    try ps2.init();

    debug.println("[Main] Init framebuffer");
    try fb.init(fb_res);

    debug.println("[Main] Done.");

    tty.println("ZRNO kernel 1.0");
    tty.println("READY.");
}
