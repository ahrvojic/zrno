const std = @import("std");

const Lock = @import("../lib/lock.zig");
const sched = @import("../sched/sched.zig");
const serial = @import("serial.zig");
const video = @import("video.zig");

var row: u64 = 0;
var col: u64 = 0;
var lock: Lock.SpinLock = .{};

// Wrapping indices fill the ring iff maxInt(InIndex)+1 == in_capacity.
const in_capacity = 256;
const InIndex = std.math.IntFittingRange(0, in_capacity - 1);
comptime {
    std.debug.assert(@as(usize, std.math.maxInt(InIndex)) + 1 == in_capacity);
}
var in_buf: [in_capacity]u8 = undefined;
var in_head: InIndex = 0;
var in_tail: InIndex = 0;
var serial_saw_cr = false;

pub fn writeBytes(string: []const u8) void {
    lock.lock();
    defer lock.unlock();
    write(string);
}

pub fn read(out: []u8) usize {
    if (out.len == 0) return 0;
    lock.lock();
    defer lock.unlock();
    while (in_head == in_tail) {
        sched.wait(&in_buf, &lock);
    }
    var n: usize = 0;
    while (n < out.len and in_head != in_tail) {
        out[n] = in_buf[in_head];
        in_head +%= 1;
        n += 1;
    }
    return n;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var print_buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&print_buffer);

    writer.print(fmt, args) catch {};

    lock.lock();
    defer lock.unlock();
    write(writer.buffered());
}

pub fn printUnsafe(comptime fmt: []const u8, args: anytype) void {
    var print_buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&print_buffer);

    writer.print(fmt, args) catch {};
    write(writer.buffered());
}

pub fn putChar(ch: u8) void {
    lock.lock();
    defer lock.unlock();
    putCharUnlocked(ch);
}

// IRQ-safe: enqueue only. Echo is `putChar` from thread context.
pub fn enqueue(ch: u8) void {
    if (!isInputChar(ch)) return;
    lock.lock();
    defer lock.unlock();
    enqueueUnlocked(ch);
}

// Drain the UART into the input ring. Call from the timer IRQ before
// taking the sched lock (wakeup takes sched).
pub fn pollSerial() void {
    lock.lock();
    defer lock.unlock();
    var n: u32 = 0;
    while (n < 16) : (n += 1) {
        const raw = serial.readByte() orelse break;
        const ch = mapSerialByte(raw) orelse continue;
        enqueueUnlocked(ch);
    }
}

pub fn getChar() u8 {
    lock.lock();
    defer lock.unlock();
    while (in_head == in_tail) {
        sched.wait(&in_buf, &lock);
    }
    const ch = in_buf[in_head];
    in_head +%= 1;
    return ch;
}

pub fn readLine(out: []u8) []u8 {
    var n: usize = 0;
    while (true) {
        const ch = getChar();
        switch (ch) {
            '\n' => {
                putChar('\n');
                return out[0..n];
            },
            '\x08' => {
                if (n > 0) {
                    n -= 1;
                    putChar('\x08');
                }
            },
            else => {
                if (n < out.len) {
                    out[n] = ch;
                    n += 1;
                    putChar(ch);
                }
            },
        }
    }
}

fn isInputChar(ch: u8) bool {
    return ch == '\n' or ch == '\x08' or (ch >= 0x20 and ch <= 0x7e);
}

fn mapSerialByte(b: u8) ?u8 {
    if (b == '\n' and serial_saw_cr) {
        serial_saw_cr = false;
        return null;
    }
    serial_saw_cr = b == '\r';
    const ch: u8 = switch (b) {
        '\r' => '\n',
        0x7f => '\x08',
        else => b,
    };
    if (!isInputChar(ch)) return null;
    return ch;
}

fn enqueueUnlocked(ch: u8) void {
    const next = in_tail +% 1;
    if (next == in_head) return;
    in_buf[in_tail] = ch;
    in_tail = next;
    sched.wakeup(&in_buf);
}

fn write(string: []const u8) void {
    for (string) |ch| {
        putCharUnlocked(ch);
    }
}

fn putCharUnlocked(ch: u8) void {
    putSerial(ch);
    putVideo(ch);
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
