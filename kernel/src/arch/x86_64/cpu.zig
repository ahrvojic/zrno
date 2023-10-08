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

    debug.println("[CPU] Load GDT");
    instance.gdt.load(&instance.tss);

    debug.println("[CPU] Load IDT");
    instance.idt.load();
}
