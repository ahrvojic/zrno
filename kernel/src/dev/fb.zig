const std = @import("std");
const limine = @import("limine");

const debug = @import("../sys/debug.zig");
const font = @import("font.zig");

var fb: Framebuffer = .{};

const Framebuffer = struct {
    info: *limine.Framebuffer = undefined,

    pub fn init(self: *Framebuffer, info: *limine.Framebuffer) void {
        self.info = info;
    }

    pub fn putChar(self: *Framebuffer, char: u8, row: u16, col: u16) void {
        const glyph = font.builtin.glyph(char);

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
    fb.putChar(90, 2, 1);
    fb.putChar(82, 2, 2);
    fb.putChar(78, 2, 3);
    fb.putChar(79, 2, 4);
}
