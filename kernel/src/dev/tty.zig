const std = @import("std");

const Lock = @import("../lib/lock.zig");
const sched = @import("../sched/sched.zig");
const serial = @import("serial.zig");
const tty_input = @import("tty_input.zig");
const video = @import("video.zig");

var row: usize = 0;
var col: usize = 0;
var lock: Lock.SpinLock = .{};
var input: tty_input.Input = .{};
var serial_saw_cr = false;

pub fn writeBytes(string: []const u8) void {
    lock.lock();
    defer lock.unlock();
    writeUnlocked(string);
}

/// Block until a cooked line is queued, then copy up to the first newline.
pub fn peek(out: []u8) usize {
    if (out.len == 0) return 0;
    lock.lock();
    defer lock.unlock();
    waitData();
    return input.copyOut(out);
}

pub fn consume(n: usize) void {
    lock.lock();
    defer lock.unlock();
    input.drop(n);
}

pub fn printUnsafe(comptime fmt: []const u8, args: anytype) void {
    var print_buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&print_buffer);

    writer.print(fmt, args) catch {};
    writeUnlocked(writer.buffered());
}

// IRQ-safe: cook into the line buffer and echo.
pub fn enqueue(ch: u8) void {
    lock.lock();
    defer lock.unlock();
    feedUnlocked(ch);
}

// Drain the UART into the cooked line. Call from the timer IRQ before
// taking the sched lock (wakeup takes sched).
pub fn pollSerial() void {
    lock.lock();
    defer lock.unlock();
    for (0..16) |_| {
        const raw = serial.readByte() orelse break;
        const ch = mapSerialByte(raw) orelse continue;
        feedUnlocked(ch);
    }
}

fn waitData() void {
    while (input.empty()) {
        sched.wait(&input.in_buf, &lock);
    }
}

fn mapSerialByte(b: u8) ?u8 {
    if (b == '\n' and serial_saw_cr) {
        serial_saw_cr = false;
        return null;
    }
    serial_saw_cr = b == '\r';
    return switch (b) {
        '\r' => '\n',
        0x7f => '\x08',
        else => b,
    };
}

fn feedUnlocked(ch: u8) void {
    if (input.feed(ch)) |e| writeUnlocked(&.{e});
    if (ch == '\n' and !input.empty()) sched.wakeup(&input.in_buf);
}

fn writeUnlocked(string: []const u8) void {
    for (string) |ch| {
        putSerial(ch);
        putVideo(ch);
    }
}

fn putSerial(ch: u8) void {
    switch (ch) {
        '\n' => serial.write("\r\n"),
        '\x08' => serial.write("\x08 \x08"),
        else => serial.write(&.{ch}),
    }
}

fn putVideo(ch: u8) void {
    if (!video.isReady()) return;

    switch (ch) {
        '\n' => {
            row += 1;
            col = 0;
        },
        '\r' => {
            col = 0;
        },
        '\x08' => { // backspace
            if (col > 0) {
                col -= 1;
                video.plotChar(' ', row, col);
            }
        },
        else => {
            video.plotChar(ch, row, col);
            col += 1;
            if (col == video.maxCol()) {
                col = 0;
                row += 1;
            }
        },
    }

    if (row == video.maxRow()) {
        video.scroll();
        row -= 1;
    }
}
