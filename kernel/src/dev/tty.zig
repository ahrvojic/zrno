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
var input: tty_input.Input = .{};
var serial_saw_cr = false;

pub fn writeBytes(string: []const u8) void {
    for (string) |ch| {
        putSerial(ch);
        putVideo(ch);
    }
}

/// Block until a cooked line is queued, then copy up to the first newline.
pub fn peek(out: []u8) usize {
    if (out.len == 0) return 0;
    while (readWait()) |chan| sched.wait(chan);
    return input.copyOut(out);
}

/// Null when a cooked line is queued. Otherwise the channel `peek` sleeps on.
pub fn readWait() ?*const anyopaque {
    if (!input.empty()) return null;
    return &input.in.buf;
}

pub fn consume(n: usize) void {
    input.drop(n);
}

// Ctrl-C stops the foreground child and is not cooked.
pub fn enqueue(ch: u8) void {
    if (ch == 0x03) {
        if (sched.stopForeground()) writeBytes("^C\n");
        return;
    }
    if (input.feed(ch)) |e| writeBytes(&.{e});
    if (ch == '\n' and !input.empty()) sched.wakeup(&input.in.buf);
}

/// Drain the UART into the cooked line. Called from the timer IRQ.
pub fn pollSerial() void {
    for (0..16) |_| {
        const raw = serial.readByte() orelse break;
        const ch = mapSerialByte(raw) orelse continue;
        enqueue(ch);
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
