const std = @import("std");

const apic = @import("apic.zig");
const cpu = @import("../sys/cpu.zig");
const debug = @import("../sys/debug.zig");
const interrupts = @import("../sys/interrupts.zig");
const port = @import("../sys/port.zig");

const ps2_data_port = 0x60;

const Key = enum {
    esc, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    backtick, n1, n2, n3, n4, n5, n6, n7, n8, n9, n0, minus, equals, backspace,
    tab, q, w, e, r, t, y, u, i, o, p, lbracket, rbracket, backslash,
    caps, a, s, d, f, g, h, j, k, l, semicolon, apostrophe, enter,
    lshift, z, x, c, v, b, n, m, comma, period, slash, rshift,
    lctrl, lsuper, lalt, spacebar, ralt, rsuper, rctrl,
};

const KeyEvent = struct {
    key: Key,
    modifiers: u8,
    pressed: bool,
};

var code_buffer = std.BoundedArray(u8, 8).init(0) catch unreachable;

pub fn init() !void {
    const lapic_id = cpu.get().lapicId();
    apic.get().routeIrq(lapic_id, interrupts.vec_keyboard, 1);
    _ = port.inb(ps2_data_port);
}

pub fn handleKeyboardInterrupt() void {
    const code = port.inb(ps2_data_port);
    debug.print("[PS2] Scan code: ");
    debug.printInt(code);
    debug.println("");

    code_buffer.append(code) catch {};

    const buffer = code_buffer.slice();
    switch (buffer[0]) {
        0xe0 => if (buffer.len >= 2) pushKeyEvent(buffer[1], true),
        else => |byte| pushKeyEvent(byte, false),
    }
}

fn pushKeyEvent(code: u8, extended: bool) void {
    defer code_buffer.resize(0) catch unreachable;

    // Remove MSB make/break from scan code before translation
    const key = toKey(code & 0x7f, extended) orelse {
        debug.print("[PS2] Unknown scan code: ");
        debug.printInt(code);
        debug.println("");
        return;
    };

    const event: KeyEvent = .{
        .key = key,
        .modifiers = 0, // TODO
        .pressed = code & 0x80 == 0,
    };

    _ = event; // TODO
}

fn toKey(code: u8, extended: bool) ?Key {
    if (extended) {
        return switch (code) {
            0x1d => .rctrl,
            0x38 => .ralt,
            0x5b => .lsuper,
            0x5c => .rsuper,
            else => return null,
        };
    } else {
        return switch (code) {
            0x01 => .esc,
            0x02 => .n1,
            0x03 => .n2,
            0x04 => .n3,
            0x05 => .n4,
            0x06 => .n5,
            0x07 => .n6,
            0x08 => .n7,
            0x09 => .n8,
            0x0a => .n9,
            0x0b => .n0,
            0x0c => .minus,
            0x0d => .equals,
            0x0e => .backspace,
            0x0f => .tab,
            0x10 => .q,
            0x11 => .w,
            0x12 => .e,
            0x13 => .r,
            0x14 => .t,
            0x15 => .y,
            0x16 => .u,
            0x17 => .i,
            0x18 => .o,
            0x19 => .p,
            0x1a => .lbracket,
            0x1b => .rbracket,
            0x1c => .enter,
            0x1d => .lctrl,
            0x1e => .a,
            0x1f => .s,
            0x20 => .d,
            0x21 => .f,
            0x22 => .g,
            0x23 => .h,
            0x24 => .j,
            0x25 => .k,
            0x26 => .l,
            0x27 => .semicolon,
            0x28 => .apostrophe,
            0x29 => .backtick,
            0x2a => .lshift,
            0x2b => .backslash,
            0x2c => .z,
            0x2d => .x,
            0x2e => .c,
            0x2f => .v,
            0x30 => .b,
            0x31 => .n,
            0x32 => .m,
            0x33 => .comma,
            0x34 => .period,
            0x35 => .slash,
            0x36 => .rshift,
            0x38 => .lalt,
            0x39 => .spacebar,
            0x3a => .caps,
            0x3b => .f1,
            0x3c => .f2,
            0x3d => .f3,
            0x3e => .f4,
            0x3f => .f5,
            0x40 => .f6,
            0x41 => .f7,
            0x42 => .f8,
            0x43 => .f9,
            0x44 => .f10,
            0x57 => .f11,
            0x58 => .f12,
            else => return null,
        };
    }
}
