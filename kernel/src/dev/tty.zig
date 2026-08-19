const std = @import("std");

const Lock = @import("../lib/lock.zig");
const video = @import("video.zig");

var row: u64 = 0;
var col: u64 = 0;
var lock: Lock.SpinLock = .{};

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

fn write(string: []const u8) void {
    for (string) |ch| {
        putCharUnlocked(ch);
    }
}

fn putCharUnlocked(ch: u8) void {
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
                video.fb.plotChar(' ', row, col);
            }
        },
        else => {
            video.fb.plotChar(ch, row, col);
            col += 1;
            if (col == video.fb.max_col) {
                col = 0;
                row += 1;
            }
        },
    }

    if (row == video.fb.max_row) {
        video.fb.scroll();
        row -= 1;
    }
}
