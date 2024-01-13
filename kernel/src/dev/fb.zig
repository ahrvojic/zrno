const std = @import("std");
const limine = @import("limine");

const debug = @import("../sys/debug.zig");
const font = @import("font.zig");

var fb: Framebuffer = .{};

const Framebuffer = struct {
    info: *limine.Framebuffer = undefined,
    maxRow: usize = 25,
    maxCol: usize = 80,

    pub fn init(self: *@This(), info: *limine.Framebuffer) void {
        self.info = info;
    }

    pub fn plotChar(self: *const @This(), ch: u8, row: usize, col: usize) void {
        const glyph = font.builtin.glyph(ch);

        const rowOffsetStart = self.toRowOffset(row);
        const colOffsetStart = self.toColOffset(col);

        var rowOffset = rowOffsetStart;
        var colOffset = colOffsetStart;

        for (glyph) |glyphRow| {
            for (0..font.builtin.width) |i| {
                if (glyphRow & std.math.shr(u8, 0x80, i) != 0)
                {
                    @as(*u32, @ptrCast(@alignCast(self.info.address + rowOffset + colOffset))).* = 0xffffffff;
                }

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

    pub fn toRowOffset(self: *const @This(), row: usize) usize {
        return row * self.info.pitch * font.builtin.height;
    }

    pub fn toColOffset(self: *const @This(), col: usize) usize {
        return col * self.info.bpp / 8 * font.builtin.width;
    }
};

pub fn init(fb_res: *limine.FramebufferResponse) !void {
    if (fb_res.framebuffer_count < 1) {
        debug.panic("No framebuffer available!");
    }

    fb.init(fb_res.framebuffers()[0]);
}

pub fn get() *const Framebuffer {
    return &fb;
}
