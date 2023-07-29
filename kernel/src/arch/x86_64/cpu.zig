//! CPU

const std = @import("std");

const debug = @import("debug.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");

pub const CPU = struct {
    gdt: gdt.GDT = .{},
    tss: gdt.TSS = .{},
    idt: idt.IDT = .{},
};

pub fn init() !void {
    var instance: CPU = .{};

    debug.print("Load GDT\n");
    instance.gdt.load(&instance.tss);

    debug.print("Load IDT\n");
    instance.idt.load();
}
