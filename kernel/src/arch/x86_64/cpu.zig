const std = @import("std");

const gdt = @import("gdt.zig");
const idt = @import("idt.zig");

pub const CPU = struct {
    self: *CPU,
    gdt: gdt.GDT = .{},
    tss: gdt.TSS = .{},
    idt: idt.IDT = .{},
};

pub fn init(allocator: std.mem.Allocator) !void {
    var instance = try allocator.create(@TypeOf(CPU));

    instance.* = .{
        .self = instance,
    };

    instance.gdt.load(&instance.tss);
    instance.idt.load();
}