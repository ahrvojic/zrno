const logger = std.log.scoped(.ps2);

const std = @import("std");

const apic = @import("apic.zig");
const BoundedArray = @import("../lib/bounded_array.zig").BoundedArray;
const cpu = @import("../sys/cpu.zig");
const ivt = @import("../sys/ivt.zig");
const Lock = @import("../lib/lock.zig");
const port = @import("../sys/port.zig");
const sched = @import("../sched/sched.zig");
const tty = @import("tty.zig");

const Decode = struct {
    unknown: ?u8 = null,
    ascii: ?u8 = null,
};

const ps2_data_port = 0x60;

pub const Key = enum {
    esc,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    backtick,
    n1,
    n2,
    n3,
    n4,
    n5,
    n6,
    n7,
    n8,
    n9,
    n0,
    minus,
    equals,
    backspace,
    tab,
    q,
    w,
    e,
    r,
    t,
    y,
    u,
    i,
    o,
    p,
    lbracket,
    rbracket,
    backslash,
    caps,
    a,
    s,
    d,
    f,
    g,
    h,
    j,
    k,
    l,
    semicolon,
    apostrophe,
    enter,
    lshift,
    z,
    x,
    c,
    v,
    b,
    n,
    m,
    comma,
    period,
    slash,
    rshift,
    lctrl,
    lsuper,
    lalt,
    spacebar,
    ralt,
    rsuper,
    rctrl,
};

pub const KeyEvent = struct {
    key: Key,
    pressed: bool,
};

pub const KeyModifier = enum(u2) {
    alt,
    ctrl,
    shift,
    super,
};

const KeyboardState = struct {
    modifiers: std.StaticBitSet(4),

    pub fn notify(self: *@This(), event: KeyEvent) void {
        switch (event.key) {
            .lalt, .ralt => {
                const idx = @intFromEnum(KeyModifier.alt);
                self.modifiers.setValue(idx, event.pressed);
            },
            .lctrl, .rctrl => {
                const idx = @intFromEnum(KeyModifier.ctrl);
                self.modifiers.setValue(idx, event.pressed);
            },
            .lshift, .rshift => {
                const idx = @intFromEnum(KeyModifier.shift);
                self.modifiers.setValue(idx, event.pressed);
            },
            .lsuper, .rsuper => {
                const idx = @intFromEnum(KeyModifier.super);
                self.modifiers.setValue(idx, event.pressed);
            },
            else => {},
        }
    }
};

// Longest AT scan sequence is Pause (8 bytes in set 2).
const max_scan_bytes = 8;
var code_buffer: BoundedArray(u8, max_scan_bytes) = .{};

// Wrapping indices fill the ring iff maxInt(KbIndex)+1 == kb_capacity.
const kb_capacity = 256;
const KbIndex = std.math.IntFittingRange(0, kb_capacity - 1);
comptime {
    std.debug.assert(@as(usize, std.math.maxInt(KbIndex)) + 1 == kb_capacity);
}
var kb_buffer: [kb_capacity]KeyEvent = undefined;
var kb_head: KbIndex = 0;
var kb_tail: KbIndex = 0;

var keyboard_state: KeyboardState = .{ .modifiers = std.StaticBitSet(4).initEmpty() };
var lock: Lock.SpinLock = .{};

pub fn init() !void {
    const lapic_id = cpu.bsp().lapicId();
    apic.routeIrq(lapic_id, ivt.vec_keyboard, 1);
    _ = port.inb(ps2_data_port);
}

pub fn handleInterrupt() void {
    const code = port.inb(ps2_data_port);

    lock.lock();
    code_buffer.append(code) catch {};

    const buffer = code_buffer.slice();
    const result: Decode = switch (buffer[0]) {
        0xe0 => if (buffer.len >= 2) putKey(buffer[1], true) else .{},
        else => |c| putKey(c, false),
    };
    lock.unlock();

    // Drop the PS/2 lock before taking tty (sched → tty → … → ps2).
    if (result.ascii) |ch| tty.enqueue(ch);
    if (result.unknown) |c| logger.err("Unknown scan code: {d}", .{c});
}

pub fn isPressed(modifier: KeyModifier) bool {
    lock.lock();
    defer lock.unlock();
    return keyboard_state.modifiers.isSet(@intFromEnum(modifier));
}

pub fn getKey() KeyEvent {
    lock.lock();
    defer lock.unlock();
    while (kb_head == kb_tail) {
        sched.wait(&kb_buffer, &lock);
    }
    const event = kb_buffer[kb_head];
    kb_head +%= 1;
    return event;
}

pub fn toAscii(key: Key, shift: bool) ?u8 {
    return switch (key) {
        .enter => '\n',
        .backspace => '\x08',
        .tab => '\t',
        .spacebar => ' ',
        .a => if (shift) 'A' else 'a',
        .b => if (shift) 'B' else 'b',
        .c => if (shift) 'C' else 'c',
        .d => if (shift) 'D' else 'd',
        .e => if (shift) 'E' else 'e',
        .f => if (shift) 'F' else 'f',
        .g => if (shift) 'G' else 'g',
        .h => if (shift) 'H' else 'h',
        .i => if (shift) 'I' else 'i',
        .j => if (shift) 'J' else 'j',
        .k => if (shift) 'K' else 'k',
        .l => if (shift) 'L' else 'l',
        .m => if (shift) 'M' else 'm',
        .n => if (shift) 'N' else 'n',
        .o => if (shift) 'O' else 'o',
        .p => if (shift) 'P' else 'p',
        .q => if (shift) 'Q' else 'q',
        .r => if (shift) 'R' else 'r',
        .s => if (shift) 'S' else 's',
        .t => if (shift) 'T' else 't',
        .u => if (shift) 'U' else 'u',
        .v => if (shift) 'V' else 'v',
        .w => if (shift) 'W' else 'w',
        .x => if (shift) 'X' else 'x',
        .y => if (shift) 'Y' else 'y',
        .z => if (shift) 'Z' else 'z',
        .n1 => if (shift) '!' else '1',
        .n2 => if (shift) '@' else '2',
        .n3 => if (shift) '#' else '3',
        .n4 => if (shift) '$' else '4',
        .n5 => if (shift) '%' else '5',
        .n6 => if (shift) '^' else '6',
        .n7 => if (shift) '&' else '7',
        .n8 => if (shift) '*' else '8',
        .n9 => if (shift) '(' else '9',
        .n0 => if (shift) ')' else '0',
        .minus => if (shift) '_' else '-',
        .equals => if (shift) '+' else '=',
        .lbracket => if (shift) '{' else '[',
        .rbracket => if (shift) '}' else ']',
        .backslash => if (shift) '|' else '\\',
        .semicolon => if (shift) ':' else ';',
        .apostrophe => if (shift) '"' else '\'',
        .backtick => if (shift) '~' else '`',
        .comma => if (shift) '<' else ',',
        .period => if (shift) '>' else '.',
        .slash => if (shift) '?' else '/',
        else => null,
    };
}

fn putKey(code: u8, extended: bool) Decode {
    defer code_buffer.resize(0) catch unreachable;

    // Remove MSB make/break from scan code before translation
    const key = toKey(code & 0x7f, extended) orelse return .{ .unknown = code };

    const event: KeyEvent = .{
        .key = key,
        .pressed = code & 0x80 == 0,
    };

    keyboard_state.notify(event);

    const next = kb_tail +% 1;
    if (next != kb_head) {
        kb_buffer[kb_tail] = event;
        kb_tail = next;
        sched.wakeup(&kb_buffer);
    }

    if (!event.pressed) return .{};
    const shift = keyboard_state.modifiers.isSet(@intFromEnum(KeyModifier.shift));
    return .{ .ascii = toAscii(event.key, shift) };
}

fn toKey(code: u8, extended: bool) ?Key {
    if (extended) {
        return switch (code) {
            0x1d => .rctrl,
            0x38 => .ralt,
            0x5b => .lsuper,
            0x5c => .rsuper,
            else => null,
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
            else => null,
        };
    }
}
