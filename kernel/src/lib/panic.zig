const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const debug = @import("debug.zig");
const tty = @import("../dev/tty.zig");

const max_frames = 32;

var panicking: std.atomic.Value(bool) = .init(false);

pub fn panicImpl(message: []const u8, first_trace_addr: ?usize) noreturn {
    cpu.interruptsOff();
    if (panicking.swap(true, .acq_rel)) cpu.halt();

    // Skip spinlocks: we may already hold one, and IRQs are off.
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    debug.printTo(&writer, "[panic] (err) KERNEL PANIC: {s}\r\n", .{message});
    debug.printUnsafe(writer.buffered());
    tty.printUnsafe("KERNEL PANIC: {s}\n", .{message});

    dumpErrorReturnTrace();
    dumpStackTrace(first_trace_addr);

    cpu.halt();
}

pub fn panic(comptime message: []const u8) noreturn {
    @panic(message);
}

fn dumpErrorReturnTrace() void {
    const trace = @errorReturnTrace() orelse return;
    if (trace.index == 0) return;

    printTraceLine("error return trace:", .{});
    const n = @min(trace.index, trace.instruction_addresses.len);
    for (trace.instruction_addresses[0..n]) |addr| {
        printTraceLine("  {x:0>16}", .{addr});
    }
}

fn dumpStackTrace(first_trace_addr: ?usize) void {
    var addrs: [max_frames]usize = undefined;
    const n = walkStack(&addrs);

    printTraceLine("stack trace:", .{});

    var start: usize = 0;
    if (first_trace_addr) |first| {
        const found = for (addrs[0..n], 0..) |addr, i| {
            if (addr == first) break i;
        } else null;
        if (found) |i| {
            start = i;
        } else if (inKernelText(first)) {
            printTraceLine("  {x:0>16}", .{first});
        }
    }

    for (addrs[start..n]) |addr| {
        printTraceLine("  {x:0>16}", .{addr});
    }
}

fn walkStack(addrs: *[max_frames]usize) usize {
    var fp = @frameAddress();
    var n: usize = 0;
    while (n < addrs.len) {
        const frame = readFrame(fp) orelse break;
        if (!inKernelText(frame.ra)) break;
        addrs[n] = frame.ra;
        n += 1;
        if (frame.next_fp == 0 or frame.next_fp == fp) break;
        fp = frame.next_fp;
    }
    return n;
}

const Frame = struct {
    next_fp: usize,
    ra: usize,
};

fn readFrame(fp: usize) ?Frame {
    if (!isKernelFp(fp)) return null;
    const slot: *const [2]usize = @ptrFromInt(fp);
    return .{ .next_fp = slot[0], .ra = slot[1] };
}

fn isKernelFp(fp: usize) bool {
    return fp != 0 and std.mem.isAligned(fp, @alignOf(usize)) and fp >> 47 == 0x1ffff;
}

fn inKernelText(addr: usize) bool {
    const start = @intFromPtr(@extern(*u8, .{ .name = "text_start_addr" }));
    const end = @intFromPtr(@extern(*u8, .{ .name = "text_end_addr" }));
    return addr >= start and addr < end;
}

fn printTraceLine(comptime fmt: []const u8, args: anytype) void {
    var debug_buf: [192]u8 = undefined;
    var debug_writer: std.Io.Writer = .fixed(&debug_buf);
    debug.printTo(&debug_writer, "[panic] (err) " ++ fmt ++ "\r\n", args);
    debug.printUnsafe(debug_writer.buffered());

    var tty_buf: [192]u8 = undefined;
    var tty_writer: std.Io.Writer = .fixed(&tty_buf);
    debug.printTo(&tty_writer, fmt ++ "\n", args);
    tty.printUnsafe("{s}", .{tty_writer.buffered()});
}
