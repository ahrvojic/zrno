//! 16550 UART. COM1 (0x3f8) first; SPCR can re-init via `initIo` later.

const logger = std.log.scoped(.serial);

const std = @import("std");

const port = @import("../sys/port.zig");

const com1_io: u16 = 0x3f8;
const baud = 115200;

const data = 0;
const ier = 1;
const iir_fcr = 2;
const lcr = 3;
const mcr = 4;
const lsr = 5;
const scr = 7;

const lcr_dlab: u8 = 0x80;
const lcr_8n1: u8 = 0x03;
const fcr_init: u8 = 0xc7;
const mcr_dtr_rts_out2: u8 = 0x0b;
const lsr_dr: u8 = 1 << 0;
const lsr_thre: u8 = 0x20;
const thre_spins: u32 = 0xffff;

var io_base: u16 = com1_io;
var present = false;
var initialized = false;

pub fn init() void {
    initIo(com1_io);
}

/// Program a legacy 16550 at an I/O-port base. COM1 is 0x3f8.
pub fn initIo(base: u16) void {
    io_base = base;
    present = false;
    initialized = true;

    if (!scratchOk(base)) return;

    // DLAB off so offset 1 is IER, then 115200 8N1, FIFO, DTR|RTS|OUT2.
    port.outb(base + lcr, lcr_8n1);
    port.outb(base + ier, 0x00);
    port.outb(base + lcr, lcr_8n1 | lcr_dlab);
    port.outb(base + data, 0x01);
    port.outb(base + ier, 0x00);
    port.outb(base + lcr, lcr_8n1);
    port.outb(base + iir_fcr, fcr_init);
    port.outb(base + mcr, mcr_dtr_rts_out2);

    present = true;
    logger.info("{s} 0x{x} {d} 8N1", .{ ioName(base), base, baud });
}

pub fn write(bytes: []const u8) void {
    if (!initialized) init();
    if (!present) return;
    for (bytes) |byte| {
        if (!waitThre()) return;
        port.outb(io_base + data, byte);
    }
}

pub fn readByte() ?u8 {
    if (!present) return null;
    if (port.inb(io_base + lsr) & lsr_dr == 0) return null;
    return port.inb(io_base + data);
}

fn ioName(base: u16) []const u8 {
    return switch (base) {
        0x3f8 => "COM1",
        0x2f8 => "COM2",
        0x3e8 => "COM3",
        0x2e8 => "COM4",
        else => "uart",
    };
}

fn scratchOk(base: u16) bool {
    port.outb(base + scr, 0x5a);
    if (port.inb(base + scr) != 0x5a) return false;
    port.outb(base + scr, 0xa5);
    return port.inb(base + scr) == 0xa5;
}

fn waitThre() bool {
    var spins: u32 = 0;
    while (port.inb(io_base + lsr) & lsr_thre == 0) {
        if (spins == thre_spins) return false;
        spins += 1;
        asm volatile ("pause");
    }
    return true;
}
