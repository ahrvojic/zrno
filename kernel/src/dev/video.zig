const std = @import("std");
const limine = @import("limine");

const boot = @import("../sys/boot.zig");
const font = @import("font.zig");
const panic = @import("../lib/panic.zig").panic;

pub var fb: Framebuffer = .{};
var ready = false;

const Framebuffer = struct {
    info: *limine.Framebuffer = undefined,
    max_row: u64 = 25,
    max_col: u64 = 80,

    pub fn init(self: *@This(), info: *limine.Framebuffer) void {
        self.info = info;
        self.max_col = info.width / font.builtin.width;
        self.max_row = info.height / font.builtin.height;
    }

    pub fn plotChar(self: *const @This(), ch: u8, row: u64, col: u64) void {
        if (row >= self.max_row or col >= self.max_col) return;

        const glyph = font.builtin.glyph(ch);

        const row_offset_start = self.toRowOffset(row);
        const col_offset_start = self.toColOffset(col);

        var row_offset = row_offset_start;
        var col_offset = col_offset_start;

        for (glyph) |glyph_row| {
            for (0..font.builtin.width) |i| {
                const pixel: *u32 = @ptrCast(@alignCast(self.info.address + row_offset + col_offset));
                pixel.* = if (glyph_row & std.math.shr(u8, 0x80, i) != 0) 0xffffffff else 0x00000000;
                col_offset += self.info.bpp / 8;
            }

            row_offset += self.info.pitch;
            col_offset = col_offset_start;
        }
    }

    pub fn scroll(self: *const @This()) void {
        // Shift framebuffer up one character row
        const new_top = self.toRowOffset(1);
        std.mem.copyForwards(u8, self.info.data(), self.info.data()[new_top..]);
        // Clear last character row
        for (0..self.max_col) |col| {
            self.plotChar(' ', self.max_row - 1, col);
        }
    }

    fn toRowOffset(self: *const @This(), row: u64) u64 {
        return row * self.info.pitch * font.builtin.height;
    }

    fn toColOffset(self: *const @This(), col: u64) u64 {
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
