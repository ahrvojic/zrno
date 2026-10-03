const std = @import("std");

const Lock = @import("../lib/lock.zig");
const sched = @import("../sched/sched.zig");
const serial = @import("serial.zig");
const tty_input = @import("tty_input.zig");
const video = @import("video.zig");

var row: usize = 0;
var col: usize = 0;
// Cursor is on the glyph that filled this row. The next glyph opens a row.
var pending: bool = false;
// Continuation rows opened by a wrap. Backspace at column 0 climbs back.
var wraps: usize = 0;
var cursor_on: bool = false;
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

// Cook, then stop. The tty lock must be released first: pipe close is the
// same rank, and sched is higher.
pub fn enqueue(ch: u8) void {
    if (feed(ch)) interruptChild();
}

// Drain the UART into the cooked line. Call from the timer IRQ before
// taking the sched lock (wakeup takes sched).
pub fn pollSerial() void {
    var stop = false;
    {
        lock.lock();
        defer lock.unlock();
        for (0..16) |_| {
            const raw = serial.readByte() orelse break;
            const ch = mapSerialByte(raw) orelse continue;
            if (feedUnlocked(ch)) stop = true;
        }
    }
    if (stop) interruptChild();
}

fn feed(ch: u8) bool {
    lock.lock();
    defer lock.unlock();
    return feedUnlocked(ch);
}

fn interruptChild() void {
    if (sched.stopForeground()) writeBytes("^C\n");
}

fn waitData() void {
    while (input.empty()) {
        sched.wait(&input.in.buf, &lock);
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

// Ctrl-C is not cooked. `interruptChild` prints `^C` after the stop.
fn feedUnlocked(ch: u8) bool {
    if (ch == 0x03) return true;
    if (input.feed(ch)) |e| writeUnlocked(&.{e});
    if (ch == '\n' and !input.empty()) sched.wakeup(&input.in.buf);
    return false;
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

fn hideCursor() void {
    if (!cursor_on) return;
    video.invertCell(row, col);
    cursor_on = false;
}

fn showCursor() void {
    if (cursor_on or !video.isReady()) return;
    video.invertCell(row, col);
    cursor_on = true;
}

fn advanceRow() void {
    row += 1;
    col = 0;
    if (row == video.maxRow()) {
        video.scroll();
        row -= 1;
    }
}

fn putVideo(ch: u8) void {
    if (!video.isReady()) return;
    hideCursor();
    defer showCursor();

    switch (ch) {
        '\n' => {
            pending = false;
            wraps = 0;
            advanceRow();
        },
        '\r' => {
            pending = false;
            wraps = 0;
            col = 0;
        },
        '\x08' => {
            if (pending) {
                pending = false;
            } else if (col > 0) {
                col -= 1;
            } else if (wraps > 0 and row > 0) {
                wraps -= 1;
                row -= 1;
                col = video.maxCol() - 1;
            } else return;
            video.plotChar(' ', row, col);
        },
        else => {
            if (pending) {
                pending = false;
                wraps += 1;
                advanceRow();
            }
            video.plotChar(ch, row, col);
            pending = col + 1 == video.maxCol();
            if (!pending) col += 1;
        },
    }
}
