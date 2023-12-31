const std = @import("std");
const limine = @import("limine");

const debug = @import("debug.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const interrupts = @import("interrupts.zig");

const msr_lapic = 0x1b;

const lapic_reg_id = 0x20;
const lapic_reg_eoi = 0xb0;
const lapic_reg_spurious = 0xf0;

var bsp: CPU = .{};

pub const CPU = struct {
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
        self.lapic_base = (readMSR(msr_lapic) & 0xfffff000) + hhdm_offset;
        self.initLapic();
    }

    pub fn eoi(self: *const CPU) void {
        self.lapicWrite(lapic_reg_eoi, 0);
    }

    pub fn lapicId(self: *const CPU) u32 {
        return self.lapicRead(lapic_reg_id);
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

pub fn interruptsEnable() callconv(.Inline) void {
    asm volatile ("sti");
}

pub fn interruptsDisable() callconv(.Inline) void {
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

    return (@as(u64, high) << 32) | low;
}

fn writeMSR(msr: u32, value: u64) callconv(.Inline) void {
    asm volatile (
        \\wrmsr
        :
        : [_] "{eax}" (@as(u32, @truncate(value))),
          [_] "{edx}" (@as(u32, @truncate(value >> 32))),
          [_] "{ecx}" (msr),
    );
}
