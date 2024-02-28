const logger = std.log.scoped(.main);

const std = @import("std");
const limine = @import("limine");

const acpi = @import("acpi/acpi.zig");
const apic = @import("dev/apic.zig");
const cpu = @import("sys/cpu.zig");
const debug = @import("lib/debug.zig");
const fb = @import("dev/fb.zig");
const panic = @import("lib/panic.zig").panic;
const pit = @import("dev/pit.zig");
const pmm = @import("mm/pmm.zig");
const ps2 = @import("dev/ps2.zig");
const tty = @import("dev/tty.zig");
const vmm = @import("mm/vmm.zig");

pub const std_options = struct {
    pub const logFn = log;
};

fn log(
    comptime level: std.log.Level,
    comptime scope: anytype,
    comptime fmt: []const u8,
    args: anytype
) void {
    var log_buffer: [1024]u8 = undefined;
    var buffer = std.io.fixedBufferStream(&log_buffer);
    var writer = buffer.writer();

    writer.print("[{s}] ({s}) ", .{ @tagName(scope), @tagName(level) }) catch unreachable;
    writer.print(fmt ++ "\r\n", args) catch unreachable;

    debug.print(buffer.getWritten());
}

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
        panic("Limine base revision not supported!");
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

    logger.info("Init VMM", .{});
    try vmm.init();

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

    tty.print("ZRNO kernel 1.0\n", .{});
    tty.print("READY.\n", .{});
}
