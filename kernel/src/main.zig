const logger = std.log.scoped(.main);

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

pub const std_options = struct {
    pub const logFn = log;
};

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

    logger.info("{s} {s}", .{bootloader_name, bootloader_version});

    logger.info("Init CPU", .{});
    try cpu.init(hhdm_res);

    logger.info("Init PMM", .{});
    try pmm.init(hhdm_res, mm_res);

    logger.info("Init ACPI", .{});
    try acpi.init(hhdm_res, rsdp_res);

    logger.info("Init APIC", .{});
    try apic.init(hhdm_res);

    logger.info("Init PIT", .{});
    try pit.init();

    logger.info("Init PS/2 keyboard", .{});
    try ps2.init();

    logger.info("Init framebuffer", .{});
    try fb.init(fb_res);

    logger.info("Done.", .{});

    tty.println("ZRNO kernel 1.0");
    tty.println("READY.");
}

var bytes: [16 * 4096]u8 = undefined;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: anytype,
    comptime fmt: []const u8,
    args: anytype
) void {
    var buffer = std.io.fixedBufferStream(&bytes);
    var writer = buffer.writer();

    writer.print("[{s}] {s} - ", .{ @tagName(scope), @tagName(level) }) catch unreachable;
    writer.print(fmt, args) catch unreachable;

    debug.println(buffer.getWritten());
}
