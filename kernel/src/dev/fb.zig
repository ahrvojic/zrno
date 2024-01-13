const std = @import("std");
const limine = @import("limine");

const debug = @import("../sys/debug.zig");
const font = @import("font.zig");

var fb: Framebuffer = .{};

const Framebuffer = struct {
    info: *limine.Framebuffer = undefined,

    pub fn init(self: *@This(), info: *limine.Framebuffer) void {
        self.info = info;
    }

    pub fn plotChar(self: *const @This(), ch: u8, row: u8, col: u8) void {
        const glyph = font.builtin.glyph(ch);

        const pxRowStart = row * self.info.pitch * font.builtin.height;
        const pxColStart = col * self.info.bpp / 8 * font.builtin.width;

        var pxRow = pxRowStart;
        var pxCol = pxColStart;

        for (glyph) |glyphRow| {
            for (0..font.builtin.width) |i| {
                if (glyphRow & std.math.shr(u8, 0x80, i) != 0)
                {
                    @as(*u32, @ptrCast(@alignCast(self.info.address + pxRow + pxCol))).* = 0xffffffff;
                }

                pxCol += self.info.bpp / 8;
            }

            pxRow += self.info.pitch;
            pxCol = pxColStart;
        }
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
