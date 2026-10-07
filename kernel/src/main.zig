const logger = std.log.scoped(.main);

const std = @import("std");

const build_options = @import("build_options");

const acpi = @import("acpi/acpi.zig");
const apic = @import("dev/apic.zig");
const boot = @import("sys/boot.zig");
const bootinfo = @import("bootinfo");
const cpu = @import("sys/cpu.zig");
const debug = @import("lib/debug.zig");
const exec = @import("sched/exec.zig");
const fadt = @import("acpi/fadt.zig");
const heap = @import("mm/heap.zig");
const lib_panic = @import("lib/panic.zig");
const pmm = @import("mm/pmm.zig");
const rt = @import("lib/rt.zig");
const ps2 = @import("dev/ps2.zig");
const sched = @import("sched/sched.zig");
const serial = @import("dev/serial.zig");
const timer = @import("dev/timer.zig");
const video = @import("dev/video.zig");
const vfs = @import("fs/vfs.zig");
const virtio_blk = @import("dev/virtio_blk.zig");
const vmm = @import("mm/vmm.zig");

pub const panic = std.debug.FullPanic(lib_panic.panicImpl);

comptime {
    _ = rt;
}

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

export fn _start(info: *const bootinfo.BootInfo) callconv(.c) noreturn {
    main(info) catch |err| {
        var buf: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        debug.printTo(&writer, "Kernel init failed: {s}", .{@errorName(err)});
        @panic(writer.buffered());
    };
    // IF still off: `int` works, a timer cannot run on the boot stack.
    // Not a scheduled thread: yield discards this context and never returns.
    sched.yield();
    unreachable;
}

pub fn main(info: *const bootinfo.BootInfo) !void {
    cpu.interruptsOff();

    // Port I/O only: no heap, paging, or ACPI. First so boot panics print.
    serial.init();

    cpu.identify();
    logger.info("zrno {s}", .{build_options.version});
    cpu.logIdentity();

    try boot.init(info);
    try cpu.init();
    try pmm.init();
    try vmm.init();
    heap.init();
    // /tmp is the block disk. virtio-blk replaces the RAM image when the
    // device is present. The initramfs was mounted before the heap existed.
    if (virtio_blk.init()) |dev| {
        if (vfs.mountVirtio(dev.blocks, dev, virtio_blk.read, virtio_blk.write)) {
            logger.info("virtio-blk {d} blocks", .{dev.blocks});
        } else |err| {
            logger.warn("virtio-blk: {s}", .{@errorName(err)});
            virtio_blk.shutdown(dev);
            try vfs.mountTmp();
        }
    } else {
        try vfs.mountTmp();
    }
    try acpi.init();

    // Framebuffer fields were copied in boot.init. Pixels stay reserved
    // via the memory map. The initramfs aliases its archive for the rest of boot.
    video.capture();
    boot.drop();

    try cpu.bsp().initLapic();
    try apic.init();
    try video.init();
    // Scheduler first: timer.init unmasks the periodic LVT.
    try sched.init();
    try timer.init();

    if (fadt.bootArch().has_8042) {
        try ps2.init();
    } else {
        logger.warn("no 8042; skip PS/2", .{});
    }

    // First user process is pid 1. `_start` yield()s onto it; if it
    // exits, `exitProcess` panics.
    logger.info("run /init as init process", .{});
    const init_pid = try exec.spawnPath("/init");
    if (init_pid != 1) @panic("init is not pid 1");
}
