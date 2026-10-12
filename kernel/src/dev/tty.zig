const sched = @import("../sched/sched.zig");
const serial = @import("serial.zig");
const tty_input = @import("tty_input.zig");
const tty_screen = @import("tty_screen.zig");
const video = @import("video.zig");

var screen: tty_screen.Screen = .{};
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
        input.discardLine();
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
    video.invertCell(screen.row, screen.col);
    cursor_on = false;
}

fn showCursor() void {
    if (cursor_on or !video.isReady()) return;
    video.invertCell(screen.row, screen.col);
    cursor_on = true;
}

fn putVideo(ch: u8) void {
    if (!video.isReady()) return;
    hideCursor();
    defer showCursor();

    const paint = screen.put(ch, video.maxRow(), video.maxCol());
    if (paint.scroll) video.scroll();
    if (paint.cell) |cell| video.plotChar(cell.ch, cell.row, cell.col);
}
