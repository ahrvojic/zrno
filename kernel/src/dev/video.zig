const logger = std.log.scoped(.video);

const std = @import("std");

const boot = @import("../sys/boot.zig");
const font = @import("font.zig");

const Captured = struct {
    address: [*]u8,
    width: usize,
    height: usize,
    pitch: usize,
    bpp: u16,
    max_row: usize = 0,
    max_col: usize = 0,
};

var captured: ?Captured = null;
var initialized = false;
var ready = false;

pub fn isReady() bool {
    return ready;
}

pub fn plotChar(ch: u8, row: usize, col: usize) void {
    const fb = frame();
    if (row >= fb.max_row or col >= fb.max_col) return;

    const glyph = font.builtin.glyph(ch);
    const pixels: [*]u32 = @ptrCast(@alignCast(fb.address));
    const pitch_pixels = fb.pitch / @sizeOf(u32);
    const y0 = row * font.builtin.height;
    const x0 = col * font.builtin.width;

    for (glyph, 0..) |glyph_row, y| {
        for (0..font.builtin.width) |x| {
            const on = glyph_row & (@as(u8, 0x80) >> @intCast(x)) != 0;
            pixels[(y0 + y) * pitch_pixels + (x0 + x)] = if (on) 0xffffffff else 0;
        }
    }
}

pub fn scroll() void {
    const fb = frame();
    const new_top = fb.pitch * font.builtin.height;
    const pixels = fb.address[0 .. fb.pitch * fb.height];
    std.mem.copyForwards(u8, pixels, pixels[new_top..]);
    for (0..fb.max_col) |col| {
        plotChar(' ', fb.max_row - 1, col);
    }
}

pub fn maxRow() usize {
    return frame().max_row;
}

pub fn maxCol() usize {
    return frame().max_col;
}

fn frame() Captured {
    expectReady();
    return captured.?;
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
    if (initialized) @panic("video already initialized");
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
    if (info.pitch % 4 != 0 or @intFromPtr(info.address) % 4 != 0) {
        logger.warn("framebuffer not 4-aligned; skip", .{});
        return;
    }
    if (info.width < font.builtin.width or info.height < font.builtin.height) {
        logger.warn("framebuffer {d}x{d} too small; skip", .{ info.width, info.height });
        return;
    }

    captured = .{
        .address = info.address,
        .width = info.width,
        .height = info.height,
        .pitch = info.pitch,
        .bpp = info.bpp,
        .max_col = info.width / font.builtin.width,
        .max_row = info.height / font.builtin.height,
    };
    ready = true;
    logger.info("{d}x{d} {d}bpp pitch={d}", .{ info.width, info.height, info.bpp, info.pitch });
}

fn expectReady() void {
    if (!ready) @panic("video used before init");
}
