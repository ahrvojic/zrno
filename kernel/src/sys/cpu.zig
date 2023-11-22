const std = @import("std");
const limine = @import("limine");

const debug = @import("debug.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const interrupts = @import("interrupts.zig");

const msr_lapic = 0x1b;

const lapic_reg_eoi = 0x0b0;
const lapic_reg_spurious = 0x0f0;

var bsp: CPU = .{};

const CPU = struct {
    gdt: gdt.GDT = .{},
    tss: gdt.TSS = .{},
    idt: idt.IDT = .{},
    lapic_base: u64 = undefined,

    pub fn init(self: *CPU, hhdm_offset: u64) void {
        debug.println("[CPU] Load GDT");
        self.gdt.load(&self.tss);

        debug.println("[CPU] Load IDT");
        self.idt.load();

        debug.println("[CPU] Init local APIC");
        self.lapic_base = readMSR(msr_lapic) + hhdm_offset;
        self.initLapic();
    }

    pub fn eoi(self: *const CPU) void {
        self.lapicWrite(lapic_reg_eoi, 0);
    }

    fn initLapic(self: *const CPU) void {
        // Spurious interrupt vector register:
        // - Set lowest byte to interrupt vector
        // - Set bit 8 to enable local APIC
        self.lapicWrite(
            lapic_reg_spurious,
            self.lapicRead(lapic_reg_spurious) | interrupts.vec_apic_spurious | 0x100
        );
    }

    fn lapicRead(self: *const CPU, reg: u32) u32 {
        const addr = self.lapic_base + reg;
        const ptr: *align(4) volatile u32 = @ptrFromInt(addr);
        return ptr.*;
    }

    fn lapicWrite(self: *const CPU, reg: u32, value: u32) void {
        const addr = self.lapic_base + reg;
        const ptr: *align(4) volatile u32 = @ptrFromInt(addr);
        ptr.* = value;
    }
};

pub fn init(hhdm_res: *limine.HhdmResponse) !void {
    bsp.init(hhdm_res.offset);
}

pub fn get() *const CPU {
    return &bsp;
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
