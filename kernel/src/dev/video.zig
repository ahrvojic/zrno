const logger = std.log.scoped(.video);

const std = @import("std");

const boot = @import("../sys/boot.zig");
const font = @import("font.zig");
const panic = @import("../lib/panic.zig").panic;

const Captured = struct {
    address: [*]u8,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
};

var captured: ?Captured = null;
var initialized = false;
var fb: Framebuffer = .{};

const Framebuffer = struct {
    address: [*]u8 = undefined,
    width: u64 = 0,
    height: u64 = 0,
    pitch: u64 = 0,
    bpp: u16 = 0,
    max_row: u64 = 25,
    max_col: u64 = 80,
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

    fn plotChar(self: *const @This(), ch: u8, row: u64, col: u64) void {
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

    fn toRowOffset(self: *const @This(), row: u64) u64 {
        return row * self.pitch * font.builtin.height;
    }

    fn toColOffset(self: *const @This(), col: u64) u64 {
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

pub fn plotChar(ch: u8, row: u64, col: u64) void {
    fb.plotChar(ch, row, col);
}

pub fn scroll() void {
    fb.scroll();
}

pub fn maxRow() u64 {
    return fb.max_row;
}

pub fn maxCol() u64 {
    return fb.max_col;
}

/// Copy Limine framebuffer metadata into BSS. Call before `boot.drop()`.
pub fn capture() void {
    const fbs = boot.info().framebuffers orelse return;
    if (fbs.framebuffer_count < 1) return;
    const src = fbs.framebuffers()[0];
    captured = .{
        .address = src.address,
        .width = src.width,
        .height = src.height,
        .pitch = src.pitch,
        .bpp = src.bpp,
    };
}

pub fn init() !void {
    if (initialized) panic("video already initialized");
    initialized = true;

    const info = captured orelse {
        logger.warn("no framebuffer", .{});
        return;
    };
    if (info.bpp != 32) {
        panic("Only 32-bit framebuffers are supported!");
    }
    if (info.width < font.builtin.width or info.height < font.builtin.height) {
        panic("Framebuffer too small for builtin font!");
    }

    fb.init(info);
    logger.info("{d}x{d} {d}bpp pitch={d}", .{ info.width, info.height, info.bpp, info.pitch });
}
