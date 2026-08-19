const std = @import("std");
const limine = @import("limine");

const boot = @import("../sys/boot.zig");
const font = @import("font.zig");
const panic = @import("../lib/panic.zig").panic;

pub var fb: Framebuffer = .{};
var ready = false;

const Framebuffer = struct {
    info: *limine.Framebuffer = undefined,
    maxRow: u64 = 25,
    maxCol: u64 = 80,

    pub fn init(self: *@This(), info: *limine.Framebuffer) void {
        self.info = info;
        self.maxCol = info.width / font.builtin.width;
        self.maxRow = info.height / font.builtin.height;
    }

    pub fn plotChar(self: *const @This(), ch: u8, row: u64, col: u64) void {
        if (row >= self.maxRow or col >= self.maxCol) return;

        const glyph = font.builtin.glyph(ch);

        const rowOffsetStart = self.toRowOffset(row);
        const colOffsetStart = self.toColOffset(col);

        var rowOffset = rowOffsetStart;
        var colOffset = colOffsetStart;

        for (glyph) |glyphRow| {
            for (0..font.builtin.width) |i| {
                const pixel: *u32 = @ptrCast(@alignCast(self.info.address + rowOffset + colOffset));
                pixel.* = if (glyphRow & std.math.shr(u8, 0x80, i) != 0) 0xffffffff else 0x00000000;
                colOffset += self.info.bpp / 8;
            }

            rowOffset += self.info.pitch;
            colOffset = colOffsetStart;
        }
    }

    pub fn scroll(self: *const @This()) void {
        // Shift framebuffer up one character row
        const newTop = self.toRowOffset(1);
        std.mem.copyForwards(u8, self.info.data(), self.info.data()[newTop..]);
        // Clear last character row
        for (0..self.maxCol) |col| {
            self.plotChar(' ', self.maxRow - 1, col);
        }
    }

    pub fn toRowOffset(self: *const @This(), row: u64) u64 {
        return row * self.info.pitch * font.builtin.height;
    }

    pub fn toColOffset(self: *const @This(), col: u64) u64 {
        return col * self.info.bpp / 8 * font.builtin.width;
    }
};

pub fn isReady() bool {
    return ready;
}

pub fn init() !void {
    if (boot.info.framebuffers.framebuffer_count < 1) {
        panic("No framebuffer available!");
    }

    const info = boot.info.framebuffers.framebuffers()[0];
    if (info.bpp != 32) {
        panic("Only 32-bit framebuffers are supported!");
    }
    if (info.width < font.builtin.width or info.height < font.builtin.height) {
        panic("Framebuffer too small for builtin font!");
    }

    fb.init(info);
    ready = true;
}
