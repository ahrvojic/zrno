//! CPU

const std = @import("std");

const gdt = @import("gdt.zig");
const idt = @import("idt.zig");

pub const CPU = struct {
    gdt: gdt.GDT = .{},
    tss: gdt.TSS = .{},
    idt: idt.IDT = .{},
};

pub fn init() !void {
    var instance: CPU = .{};
    instance.gdt.load(&instance.tss);
    instance.idt.load();
}
