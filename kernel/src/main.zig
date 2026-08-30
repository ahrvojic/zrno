const logger = std.log.scoped(.main);

const std = @import("std");

const build_options = @import("build_options");

const acpi = @import("acpi/acpi.zig");
const apic = @import("dev/apic.zig");
const boot = @import("sys/boot.zig");
const cpu = @import("sys/cpu.zig");
const debug = @import("lib/debug.zig");
const fadt = @import("acpi/fadt.zig");
const heap = @import("mm/heap.zig");
const lib_panic = @import("lib/panic.zig");
const pit = @import("dev/pit.zig");
const pmm = @import("mm/pmm.zig");
const ps2 = @import("dev/ps2.zig");
const sched = @import("sched/sched.zig");
const serial = @import("dev/serial.zig");
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

    if (cpu.nsSinceBoot()) |ns| {
        const ms = ns / 1_000_000;
        debug.printTo(&writer, "[{d:>3}.{d:0>3}] ", .{ ms / 1000, ms % 1000 });
    }
    debug.printTo(&writer, "[{s}] ({s}) ", .{ @tagName(scope), @tagName(level) });
    debug.printTo(&writer, fmt ++ "\r\n", args);

    debug.print(writer.buffered());
}

export fn _start() callconv(.c) noreturn {
    main() catch |err| {
        var buf: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        debug.printTo(&writer, "Kernel init failed: {s}", .{@errorName(err)});
        @panic(writer.buffered());
    };
    // Not a scheduled thread: yield discards this context and never returns.
    sched.yield();
    unreachable;
}

pub fn main() !void {
    cpu.interruptsOff();
    defer cpu.interruptsOn();

    // Port I/O only: no heap, paging, or ACPI. First so boot panics print.
    serial.init();

    cpu.identify();
    logger.info("zrno {s}", .{build_options.version});
    cpu.logIdentity();

    try boot.init();
    try cpu.init();
    try pmm.init();
    try vmm.init();
    heap.init();
    try acpi.init();

    // HHDM offset is already in BSS. Copy framebuffer config before the
    // Limine response goes away; pixels stay reserved via the memory map.
    video.capture();

    // ACPI tables stay reserved. Limine responses are now unused.
    boot.drop();

    try cpu.bsp().initLapic();
    try apic.init();
    try video.init();
    try pit.init();
    try sched.init();

    if (fadt.bootArch().has_8042) {
        try ps2.init();
    } else {
        logger.warn("no 8042; skip PS/2", .{});
    }

    _ = try sched.spawnKernelThread(@intFromPtr(&shell.thread), 0);

    // Reclaim frees the Limine boot stack we are still on; do not pmm.alloc
    // again until yield has left it.
    pmm.reclaimBootloader();

    logger.info("ready", .{});
    tty.print("Zrno kernel {s}\n", .{build_options.version});
    tty.print("READY.\n", .{});
}
