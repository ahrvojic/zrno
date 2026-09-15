const logger = std.log.scoped(.ps2);

const std = @import("std");

const apic = @import("apic.zig");
const cpu = @import("../sys/cpu.zig");
const ivt = @import("../sys/ivt.zig");
const Lock = @import("../lib/lock.zig");
const port = @import("../sys/port.zig");
const tty = @import("tty.zig");

const Result = union(enum) {
    incomplete,
    unknown: u8,
    ignore,
    ascii: u8,
};

const Map = union(enum) {
    ascii: u8,
    ignore,
    unknown,
};

const Prefix = enum { plain, extended };

const ps2_data_port = 0x60;
const ps2_status_port = 0x64;
const ps2_cmd_port = 0x64;

const status_out_full: u8 = 1 << 0;
const status_in_full: u8 = 1 << 1;

const cmd_read_cfg: u8 = 0x20;
const cmd_write_cfg: u8 = 0x60;
const cmd_disable_p2: u8 = 0xa7;
const cmd_test_ctrl: u8 = 0xaa;
const cmd_test_p1: u8 = 0xab;
const cmd_disable_p1: u8 = 0xad;
const cmd_enable_p1: u8 = 0xae;

const cfg_irq1: u8 = 1 << 0;
const cfg_irq2: u8 = 1 << 1;
const cfg_clock1_disable: u8 = 1 << 4;
const cfg_clock2_disable: u8 = 1 << 5;
const cfg_transl: u8 = 1 << 6;

const kbd_reset: u8 = 0xff;
const kbd_enable_scan: u8 = 0xf4;
const resp_ack: u8 = 0xfa;
const resp_bat_ok: u8 = 0xaa;
const resp_ctrl_ok: u8 = 0x55;
const resp_port_ok: u8 = 0x00;

const io_spins: u32 = 0xfffff;

var shift_left = false;
var shift_right = false;
var pending_e0 = false;
var lock: Lock.SpinLock = .{};
var initialized = false;

pub fn init() !void {
    if (initialized) @panic("ps2 already initialized");
    initialized = true;

    initController() catch |err| {
        logger.warn("8042 init failed: {s}; skip keyboard", .{@errorName(err)});
        return;
    };

    const lapic_id = cpu.bsp().lapicId();
    apic.routeIrq(lapic_id, ivt.vec_keyboard, 1);
    logger.info("irq=1 vec={d}", .{ivt.vec_keyboard});
}

fn initController() !void {
    try writeCmd(cmd_disable_p1);
    try writeCmd(cmd_disable_p2);
    flushOutput();

    try writeDisabledConfig();

    try writeCmd(cmd_test_ctrl);
    if (try readData() != resp_ctrl_ok) return error.SelfTest;

    // Self-test may reset the config byte.
    try writeDisabledConfig();

    try writeCmd(cmd_test_p1);
    if (try readData() != resp_port_ok) return error.PortTest;

    try writeCmd(cmd_enable_p1);

    var cfg = try readConfig();
    cfg |= cfg_irq1 | cfg_transl;
    cfg &= ~(cfg_irq2 | cfg_clock1_disable);
    cfg |= cfg_clock2_disable;
    try writeConfig(cfg);

    try resetKeyboard();
}

fn writeDisabledConfig() !void {
    var cfg = try readConfig();
    cfg &= ~(cfg_irq1 | cfg_irq2 | cfg_transl);
    cfg |= cfg_clock2_disable;
    try writeConfig(cfg);
}

fn resetKeyboard() !void {
    flushOutput();
    try writeData(kbd_reset);
    var got_ack = false;
    var got_bat = false;
    for (0..4) |_| {
        switch (try readData()) {
            resp_ack => got_ack = true,
            resp_bat_ok => got_bat = true,
            0xfe => try writeData(kbd_reset),
            else => return error.NoDevice,
        }
        if (got_ack and got_bat) break;
    }
    if (!got_ack or !got_bat) return error.NoDevice;
    try writeData(kbd_enable_scan);
    if (try readData() != resp_ack) return error.NoDevice;
}

fn writeCmd(cmd: u8) !void {
    try waitInputEmpty();
    port.outb(ps2_cmd_port, cmd);
}

fn writeData(value: u8) !void {
    try waitInputEmpty();
    port.outb(ps2_data_port, value);
}

fn readData() !u8 {
    try waitOutputFull();
    return port.inb(ps2_data_port);
}

fn readConfig() !u8 {
    try writeCmd(cmd_read_cfg);
    return readData();
}

fn writeConfig(cfg: u8) !void {
    try writeCmd(cmd_write_cfg);
    try writeData(cfg);
}

fn flushOutput() void {
    for (0..io_spins) |_| {
        if (port.inb(ps2_status_port) & status_out_full == 0) return;
        _ = port.inb(ps2_data_port);
    }
}

fn waitInputEmpty() !void {
    for (0..io_spins) |_| {
        if (port.inb(ps2_status_port) & status_in_full == 0) return;
    }
    return error.Timeout;
}

fn waitOutputFull() !void {
    for (0..io_spins) |_| {
        if (port.inb(ps2_status_port) & status_out_full != 0) return;
    }
    return error.Timeout;
}

pub fn handleInterrupt() bool {
    const code = port.inb(ps2_data_port);

    const result = blk: {
        lock.lock();
        defer lock.unlock();
        break :blk decode(code);
    };

    // Drop the PS/2 lock before taking tty (sched → tty → … → ps2).
    switch (result) {
        .incomplete => return false,
        .unknown => |c| {
            logger.err("Unknown scan code: {d}", .{c});
            return false;
        },
        .ignore => return true,
        .ascii => |ch| {
            tty.enqueue(ch);
            return true;
        },
    }
}

fn decode(code: u8) Result {
    if (pending_e0) {
        pending_e0 = false;
        return decodeKey(code, .extended);
    }
    if (code == 0xe0) {
        pending_e0 = true;
        return .incomplete;
    }
    return decodeKey(code, .plain);
}

fn decodeKey(code: u8, prefix: Prefix) Result {
    const make = code & 0x7f;
    const pressed = code & 0x80 == 0;

    if (prefix == .plain) {
        if (make == 0x2a) shift_left = pressed;
        if (make == 0x36) shift_right = pressed;
    }

    return switch (mapKey(make, prefix, shift_left or shift_right)) {
        .unknown => .{ .unknown = code },
        .ignore => .ignore,
        .ascii => |ch| if (pressed) .{ .ascii = ch } else .ignore,
    };
}

fn mapKey(make: u8, prefix: Prefix, shift: bool) Map {
    if (prefix == .extended) {
        return switch (make) {
            0x1d, 0x38, 0x5b, 0x5c => .ignore,
            else => .unknown,
        };
    }
    return switch (make) {
        0x01 => .ignore,
        0x02 => .{ .ascii = if (shift) '!' else '1' },
        0x03 => .{ .ascii = if (shift) '@' else '2' },
        0x04 => .{ .ascii = if (shift) '#' else '3' },
        0x05 => .{ .ascii = if (shift) '$' else '4' },
        0x06 => .{ .ascii = if (shift) '%' else '5' },
        0x07 => .{ .ascii = if (shift) '^' else '6' },
        0x08 => .{ .ascii = if (shift) '&' else '7' },
        0x09 => .{ .ascii = if (shift) '*' else '8' },
        0x0a => .{ .ascii = if (shift) '(' else '9' },
        0x0b => .{ .ascii = if (shift) ')' else '0' },
        0x0c => .{ .ascii = if (shift) '_' else '-' },
        0x0d => .{ .ascii = if (shift) '+' else '=' },
        0x0e => .{ .ascii = '\x08' },
        0x0f => .{ .ascii = '\t' },
        0x10 => .{ .ascii = if (shift) 'Q' else 'q' },
        0x11 => .{ .ascii = if (shift) 'W' else 'w' },
        0x12 => .{ .ascii = if (shift) 'E' else 'e' },
        0x13 => .{ .ascii = if (shift) 'R' else 'r' },
        0x14 => .{ .ascii = if (shift) 'T' else 't' },
        0x15 => .{ .ascii = if (shift) 'Y' else 'y' },
        0x16 => .{ .ascii = if (shift) 'U' else 'u' },
        0x17 => .{ .ascii = if (shift) 'I' else 'i' },
        0x18 => .{ .ascii = if (shift) 'O' else 'o' },
        0x19 => .{ .ascii = if (shift) 'P' else 'p' },
        0x1a => .{ .ascii = if (shift) '{' else '[' },
        0x1b => .{ .ascii = if (shift) '}' else ']' },
        0x1c => .{ .ascii = '\n' },
        0x1d => .ignore,
        0x1e => .{ .ascii = if (shift) 'A' else 'a' },
        0x1f => .{ .ascii = if (shift) 'S' else 's' },
        0x20 => .{ .ascii = if (shift) 'D' else 'd' },
        0x21 => .{ .ascii = if (shift) 'F' else 'f' },
        0x22 => .{ .ascii = if (shift) 'G' else 'g' },
        0x23 => .{ .ascii = if (shift) 'H' else 'h' },
        0x24 => .{ .ascii = if (shift) 'J' else 'j' },
        0x25 => .{ .ascii = if (shift) 'K' else 'k' },
        0x26 => .{ .ascii = if (shift) 'L' else 'l' },
        0x27 => .{ .ascii = if (shift) ':' else ';' },
        0x28 => .{ .ascii = if (shift) '"' else '\'' },
        0x29 => .{ .ascii = if (shift) '~' else '`' },
        0x2a => .ignore,
        0x2b => .{ .ascii = if (shift) '|' else '\\' },
        0x2c => .{ .ascii = if (shift) 'Z' else 'z' },
        0x2d => .{ .ascii = if (shift) 'X' else 'x' },
        0x2e => .{ .ascii = if (shift) 'C' else 'c' },
        0x2f => .{ .ascii = if (shift) 'V' else 'v' },
        0x30 => .{ .ascii = if (shift) 'B' else 'b' },
        0x31 => .{ .ascii = if (shift) 'N' else 'n' },
        0x32 => .{ .ascii = if (shift) 'M' else 'm' },
        0x33 => .{ .ascii = if (shift) '<' else ',' },
        0x34 => .{ .ascii = if (shift) '>' else '.' },
        0x35 => .{ .ascii = if (shift) '?' else '/' },
        0x36 => .ignore,
        0x38 => .ignore,
        0x39 => .{ .ascii = ' ' },
        0x3a => .ignore,
        0x3b...0x44 => .ignore,
        0x57, 0x58 => .ignore,
        else => .unknown,
    };
}
