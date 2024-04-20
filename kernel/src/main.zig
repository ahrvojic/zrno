const logger = std.log.scoped(.main);

const std = @import("std");

const acpi = @import("acpi/acpi.zig");
const apic = @import("dev/apic.zig");
const boot = @import("sys/boot.zig");
const cpu = @import("sys/cpu.zig");
const debug = @import("lib/debug.zig");
const heap = @import("mm/heap.zig");
const pit = @import("dev/pit.zig");
const pmm = @import("mm/pmm.zig");
const ps2 = @import("dev/ps2.zig");
const tty = @import("dev/tty.zig");
const video = @import("dev/video.zig");
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

export fn _start() callconv(.C) noreturn {
    main() catch {};
    cpu.halt();
}

pub fn main() !void {
    cpu.interruptsDisable();
    defer cpu.interruptsEnable();

    try boot.init();

    const bootloader_name = std.mem.span(boot.info.bootloader_info.name);
    const bootloader_version = std.mem.span(boot.info.bootloader_info.version);
    logger.info("{s} {s}", .{bootloader_name, bootloader_version});

    logger.info("Init CPUs", .{});
    try cpu.init();

    logger.info("Init PMM", .{});
    try pmm.init();

    logger.info("Init VMM", .{});
    try vmm.init();

    logger.info("Init kernel heap", .{});
    try heap.init();

    logger.info("Init ACPI", .{});
    try acpi.init();

    logger.info("Init APIC", .{});
    try apic.init();

    logger.info("Init PIT", .{});
    try pit.init();

    logger.info("Init PS/2 keyboard", .{});
    try ps2.init();

    logger.info("Init video", .{});
    try video.init();

    logger.info("Done.", .{});

    tty.print("ZRNO kernel 1.0\n", .{});
    tty.print("READY.\n", .{});
}
