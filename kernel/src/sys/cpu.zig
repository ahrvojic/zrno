const std = @import("std");
const limine = @import("limine");

const debug = @import("debug.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");

const lapic_msr = 0x1b;

const CPU = struct {
    gdt: gdt.GDT = .{},
    tss: gdt.TSS = .{},
    idt: idt.IDT = .{},
    lapic_base: u64,
};

pub fn init(hhdm_res: *limine.HhdmResponse, smp_res: *limine.SmpResponse) !void {
    _ = smp_res; // TODO

    var instance: CPU = .{
        .lapic_base = readMSR(lapic_msr) + hhdm_res.offset,
    };

    debug.println("[CPU] Load GDT");
    instance.gdt.load(&instance.tss);

    debug.println("[CPU] Load IDT");
    instance.idt.load();
}

pub fn interrupts_enable() callconv(.Inline) void {
    asm volatile ("sti");
}

pub fn interrupts_disable() callconv(.Inline) void {
    asm volatile ("cli");
}

pub fn halt() callconv(.Inline) noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

fn readMSR(msr: u32) callconv(.Inline) u64 {
    var high: u32 = undefined;
    var low: u32 = undefined;

    asm volatile (
        \\rdmsr
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
        : [_] "{ecx}" (msr),
    );

    return (@as(u64, high) << 32) | @as(u64, low);
}

fn writeMSR(msr: u32, value: u64) callconv(.Inline) void {
    asm volatile (
        \\wrmsr
        :
        : [_] "{eax}" (value & 0xffffffff),
          [_] "{edx}" (value >> 32),
          [_] "{ecx}" (msr),
    );
}
