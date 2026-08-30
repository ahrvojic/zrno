const logger = std.log.scoped(.video);

const std = @import("std");

const boot = @import("../sys/boot.zig");
const font = @import("font.zig");
const panic = @import("../lib/panic.zig").panic;

const Captured = struct {
    address: [*]u8,
    width: usize,
    height: usize,
    pitch: usize,
    bpp: u16,
};

var captured: ?Captured = null;
var initialized = false;
var fb: Framebuffer = .{};

const Framebuffer = struct {
    address: [*]u8 = undefined,
    width: usize = 0,
    height: usize = 0,
    pitch: usize = 0,
    bpp: u16 = 0,
    max_row: usize = 25,
    max_col: usize = 80,
    initialized: bool = false,

    fn init(self: *@This(), src: Captured) void {
        self.expectUninit();
        self.address = src.address;
        self.width = src.width;
        self.height = src.height;
        self.pitch = src.pitch;
        self.bpp = src.bpp;
        self.max_col = src.width / font.builtin.width;
        self.max_row = src.height / font.builtin.height;
        self.initialized = true;
    }

    fn data(self: *const @This()) []u8 {
        return self.address[0 .. self.pitch * self.height];
    }

    fn plotChar(self: *const @This(), ch: u8, row: usize, col: usize) void {
        self.expectInit();
        if (row >= self.max_row or col >= self.max_col) return;

        const glyph = font.builtin.glyph(ch);

        const row_offset_start = self.toRowOffset(row);
        const col_offset_start = self.toColOffset(col);

        var row_offset = row_offset_start;
        var col_offset = col_offset_start;

        for (glyph) |glyph_row| {
            for (0..font.builtin.width) |i| {
                const pixel: *u32 = @ptrCast(@alignCast(self.address + row_offset + col_offset));
                pixel.* = if (glyph_row & std.math.shr(u8, 0x80, i) != 0) 0xffffffff else 0x00000000;
                col_offset += self.bpp / 8;
            }

            row_offset += self.pitch;
            col_offset = col_offset_start;
        }
    }

    fn scroll(self: *const @This()) void {
        self.expectInit();
        // Shift framebuffer up one character row
        const new_top = self.toRowOffset(1);
        std.mem.copyForwards(u8, self.data(), self.data()[new_top..]);
        // Clear last character row
        for (0..self.max_col) |col| {
            self.plotChar(' ', self.max_row - 1, col);
        }
    }

    fn toRowOffset(self: *const @This(), row: usize) usize {
        return row * self.pitch * font.builtin.height;
    }

    fn toColOffset(self: *const @This(), col: usize) usize {
        return col * self.bpp / 8 * font.builtin.width;
    }

    fn expectInit(self: *const @This()) void {
        if (!self.initialized) @panic("video used before init");
    }

    fn expectUninit(self: *const @This()) void {
        if (self.initialized) @panic("video already initialized");
    }
};

pub fn isReady() bool {
    return fb.initialized;
}

pub fn plotChar(ch: u8, row: usize, col: usize) void {
    fb.plotChar(ch, row, col);
}

pub fn scroll() void {
    fb.scroll();
}

pub fn maxRow() usize {
    return fb.max_row;
}

pub fn maxCol() usize {
    return fb.max_col;
}

/// Copy Limine framebuffer metadata into BSS. Call before `boot.drop()`.
pub fn capture() void {
    const fbs = boot.info().framebuffers orelse return;
    if (fbs.framebuffer_count < 1) return;
    const src = fbs.framebuffers()[0];
    captured = .{
        .address = src.address,
        .width = @intCast(src.width),
        .height = @intCast(src.height),
        .pitch = @intCast(src.pitch),
        .bpp = src.bpp,
    };
}

pub fn init() !void {
    if (initialized) panic("video already initialized");
    initialized = true;

    // GOP/Limine FB is independent of FADT VGA_NOT_PRESENT (legacy VGA
    // I/O). Missing or unusable FB: stay on serial; do not panic.
    const info = captured orelse {
        logger.warn("no framebuffer", .{});
        return;
    };
    if (info.bpp != 32) {
        logger.warn("{d} bpp framebuffer; skip", .{info.bpp});
        return;
    }
    if (info.width < font.builtin.width or info.height < font.builtin.height) {
        logger.warn("framebuffer {d}x{d} too small; skip", .{ info.width, info.height });
        return;
    }

    fb.init(info);
    logger.info("{d}x{d} {d}bpp pitch={d}", .{ info.width, info.height, info.bpp, info.pitch });
}
