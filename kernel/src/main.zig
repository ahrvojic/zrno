const logger = std.log.scoped(.main);

const std = @import("std");

const build_options = @import("build_options");

const acpi = @import("acpi/acpi.zig");
const apic = @import("dev/apic.zig");
const boot = @import("sys/boot.zig");
const cpu = @import("sys/cpu.zig");
const debug = @import("lib/debug.zig");
const heap = @import("mm/heap.zig");
const lib_panic = @import("lib/panic.zig");
const pit = @import("dev/pit.zig");
const pmm = @import("mm/pmm.zig");
const ps2 = @import("dev/ps2.zig");
const sched = @import("sched/sched.zig");
const shell = @import("shell.zig");
const tty = @import("dev/tty.zig");
const video = @import("dev/video.zig");
const vmm = @import("mm/vmm.zig");

pub const panic = std.debug.FullPanic(lib_panic.panicImpl);

pub const std_options: std.Options = .{
    .logFn = log,
};

fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    var log_buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&log_buffer);

    writer.print("[{s}] ({s}) ", .{ @tagName(scope), @tagName(level) }) catch {};
    writer.print(fmt ++ "\r\n", args) catch {};

    debug.print(writer.buffered());
}

export fn _start() callconv(.c) noreturn {
    main() catch |err| {
        var buf: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        writer.print("Kernel init failed: {s}", .{@errorName(err)}) catch {};
        @panic(writer.buffered());
    };
    // Not a scheduled thread: yield discards this context and never returns.
    sched.yield();
    unreachable;
}

pub fn main() !void {
    cpu.interruptsOff();
    defer cpu.interruptsOn();

    try boot.init();

    const bootloader_name = std.mem.span(boot.info().bootloader_info.name);
    const bootloader_version = std.mem.span(boot.info().bootloader_info.version);
    logger.info("{s} {s}", .{ bootloader_name, bootloader_version });

    logger.info("Init CPUs", .{});
    try cpu.init();

    logger.info("Init PMM", .{});
    try pmm.init();

    logger.info("Init VMM", .{});
    try vmm.init();

    logger.info("Init local APIC", .{});
    try cpu.bsp().initLapic();

    logger.info("Init video", .{});
    try video.init();

    logger.info("Init heap", .{});
    heap.init();

    logger.info("Init ACPI", .{});
    try acpi.init();

    // HHDM offset and framebuffer metadata are in BSS; ACPI tables and
    // framebuffer pixels stay reserved. Limine responses are now unused.
    boot.drop();

    logger.info("Init APIC", .{});
    try apic.init();

    logger.info("Init PIT", .{});
    try pit.init();

    logger.info("Init scheduler", .{});
    try sched.init();

    logger.info("Init PS/2 keyboard", .{});
    try ps2.init();

    logger.info("Done.", .{});

    tty.print("Zrno kernel {s}\n", .{build_options.version});
    tty.print("READY.\n", .{});

    _ = try sched.spawnKernelThread(@intFromPtr(&shell.thread), 0);

    // Reclaim frees the Limine boot stack we are still on; do not pmm.alloc
    // again until yield has left it.
    logger.info("Reclaim bootloader memory", .{});
    pmm.reclaimBootloader();
}
